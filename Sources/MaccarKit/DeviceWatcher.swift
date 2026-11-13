import Foundation
import CoreGraphics
import os

public final class DeviceWatcher: @unchecked Sendable {
    internal enum Timing {
        static let initialTimerDelay: DispatchTimeInterval = .seconds(1)
        static let fallbackTimerInterval: DispatchTimeInterval = .seconds(5)
        static let debounceDelayMilliseconds: Int = 250
        static let usbAttachDebounceMilliseconds: Int = 750
        static let ghostWarningThrottleSeconds: TimeInterval = 10.0
        static let detachConsecutiveMissThreshold: Int = 2
        static let teardownPollTimeoutSeconds: TimeInterval = 2.0
        static let teardownPollStepSeconds: TimeInterval = 0.1
        static let postDisconnectSettleSeconds: TimeInterval = 0.4
        static let displayReadyTimeoutSeconds: TimeInterval = 3.0
        static let displayReadyStepSeconds: TimeInterval = 0.15
    }

    internal struct State: Sendable {
        var status: DeviceWatcherStatus = .stopped
        var isStopped: Bool = false
        var isManualDisconnectHold: Bool = false
        var manualReconnectRequested: Bool = false
        var lastManualDisconnectTime: Date = .distantPast
        var reconfigurationDepth: Int = 0
        var backoff = DeviceWatcherBackoff.Tracker()
        var consecutiveDetachMisses: Int = 0
        var lastGhostWarningTime: Date = .distantPast
        var isReconnectPending: Bool = false
        /// Set when a manual reconnect could not take the work slot. Unlike
        /// `isReconnectPending` (which only dedupes the in-flight dispatch), this
        /// records user intent that must survive until it is actually served.
        var pendingManualReconnect: Bool = false
        var reconnectGeneration: UInt64 = 0
        var isWorking: Bool = false
        var cachedReachableDevices: [String] = []
        var onStatusChange: (@Sendable (DeviceWatcherStatus) -> Void)?
        var onReachableDevicesChange: (@Sendable ([String]) -> Void)?
    }

    public static let shared = DeviceWatcher()

    internal let sidecar: any SidecarControlling
    internal let virtualDisplay: any VirtualDisplayControlling
    internal let mirrorManager: any DisplayMirroring
    internal let settings: any SettingsProviding
    private let dispatchesReconnectTicks: Bool
    private let registersSystemObservers: Bool
    private let usbAttachMonitorFactory: (@Sendable (DispatchQueue, @escaping @Sendable () -> Void) -> (any USBAttachMonitoring)?)?
    internal let now: @Sendable () -> Date
    internal let sleep: @Sendable (TimeInterval) -> Void
    internal let stateLock = OSAllocatedUnfairLock(initialState: State())
    private let lifecycleLock = NSLock()
    private let queue = DispatchQueue(label: "com.maccar.devicewatcher", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var observer: DeviceWatcherObserver?

    /// Serial queue that owns every work-slot transition. Extensions enqueue onto
    /// it so a deferred reconnect resumes on the same serial context as a tick.
    internal var workQueue: DispatchQueue { queue }

    public var status: DeviceWatcherStatus { stateLock.withLock { $0.status } }
    public var cachedReachableDevices: [String] { stateLock.withLock { $0.cachedReachableDevices } }
    public var isManualDisconnectHold: Bool { stateLock.withLock { $0.isManualDisconnectHold } }
    public var isReconfiguringDisplay: Bool { stateLock.withLock { $0.reconfigurationDepth > 0 } }
    public var onStatusChange: (@Sendable (DeviceWatcherStatus) -> Void)? {
        get { stateLock.withLock { $0.onStatusChange } }
        set { stateLock.withLock { $0.onStatusChange = newValue } }
    }
    public var onReachableDevicesChange: (@Sendable ([String]) -> Void)? {
        get { stateLock.withLock { $0.onReachableDevicesChange } }
        set { stateLock.withLock { $0.onReachableDevicesChange = newValue } }
    }

    internal init(
        sidecar: any SidecarControlling = SidecarService.shared,
        virtualDisplay: any VirtualDisplayControlling = VirtualDisplayService.shared,
        mirrorManager: any DisplayMirroring = DisplayMirrorManager.shared,
        settings: any SettingsProviding = MaccarSettings.shared,
        dispatchesReconnectTicks: Bool = true, registersSystemObservers: Bool = true,
        usbAttachMonitorFactory: (@Sendable (DispatchQueue, @escaping @Sendable () -> Void) -> (any USBAttachMonitoring)?)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.sidecar = sidecar; self.virtualDisplay = virtualDisplay
        self.mirrorManager = mirrorManager; self.settings = settings
        self.dispatchesReconnectTicks = dispatchesReconnectTicks
        self.registersSystemObservers = registersSystemObservers
        self.usbAttachMonitorFactory = usbAttachMonitorFactory
        self.now = now; self.sleep = sleep
    }

    deinit {
        teardownLifecycle()
        // Track explicit stop separately from initial .stopped status so unit tests can tick/reconnect without timer startup.
        stateLock.withLock { $0.isStopped = true; $0.reconnectGeneration &+= 1 }
    }

    public func shouldAttemptAutoConnect(autoConnectEnabled: Bool) -> Bool {
        stateLock.withLock { ($0.manualReconnectRequested || autoConnectEnabled) && !$0.isManualDisconnectHold && $0.reconfigurationDepth == 0 }
    }

    internal func consumeConnectPermission(autoConnectEnabled: Bool) -> Bool {
        stateLock.withLock { state in
            let allowed = (autoConnectEnabled || state.manualReconnectRequested) && !state.isManualDisconnectHold && state.reconfigurationDepth == 0
            state.manualReconnectRequested = false
            return allowed
        }
    }

    internal func consumeAutoConnectGate(autoConnectEnabled: Bool, at currentTime: Date) -> Bool {
        stateLock.withLock { state in
            let allowed = (autoConnectEnabled || state.manualReconnectRequested)
                && !state.isManualDisconnectHold && state.reconfigurationDepth == 0 && !state.backoff.isAutoRetryPaused
            guard allowed, state.backoff.canAutoConnect(at: currentTime) else { return false }
            state.manualReconnectRequested = false
            return true
        }
    }

    internal func performTickForTesting() { tick() }
    internal func flushQueueForTesting() { queue.sync {} }
    internal func releaseWorkSlotForTesting() { releaseWorkSlot() }
    internal var isAutoRetryPausedForTesting: Bool { stateLock.withLock { $0.backoff.isAutoRetryPaused } }
    public func forceConnect() { reconnectNow() }

    public func start() {
        let setup: (timer: DispatchSourceTimer, observer: DeviceWatcherObserver?)? = lifecycleLock.withLock {
            guard timer == nil else { return nil }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + Timing.initialTimerDelay, repeating: Timing.fallbackTimerInterval)
            source.setEventHandler { [weak self] in self?.tick() }
            let newObserver = registersSystemObservers ? DeviceWatcherObserver(
                queue: queue, debounceDelayMilliseconds: Timing.debounceDelayMilliseconds,
                usbAttachDebounceMilliseconds: Timing.usbAttachDebounceMilliseconds, sidecar: sidecar,
                isReconfiguring: { [weak self] in self?.isReconfiguringDisplay ?? false },
                usbAttachMonitorFactory: usbAttachMonitorFactory,
                onDebouncedEvent: { [weak self] in self?.tick() },
                onUSBDeviceAttached: { [weak self] in self?.notifyUSBDeviceAttached() }
            ) : nil
            timer = source; observer = newObserver
            return (source, newObserver)
        }
        guard let setup else { return }
        stateLock.withLock { $0.isStopped = false }
        let target = resolvedTargetName()
        MaccarLogger.shared.info("DeviceWatcher", "Started device watcher (target: \(target ?? "none")).")
        updateStatus(.waitingForDevice(targetName: target))
        if let obs = setup.observer, lifecycleLock.withLock({ self.observer === obs }) {
            obs.start()
            MaccarLogger.shared.info("DeviceWatcher", "Registered SidecarCore & CGDisplay reconfiguration observers.")
        }
        setup.timer.resume()
    }

    public func stop() {
        teardownLifecycle()
        let callback = stateLock.withLock { state -> (@Sendable (DeviceWatcherStatus) -> Void)? in
            state.isStopped = true; state.reconnectGeneration &+= 1
            guard state.status != .stopped else { return nil }
            state.status = .stopped
            return state.onStatusChange
        }
        MaccarLogger.shared.info("DeviceWatcher", "Stopped device watcher.")
        if let callback { DispatchQueue.main.async { callback(.stopped) } }
    }

    public func setManualDisconnectHold(_ hold: Bool) {
        let target = resolvedTargetName()
        let nextStatus = stateLock.withLock { state -> DeviceWatcherStatus? in
            state.isManualDisconnectHold = hold
            guard hold else {
                if case .disconnectedManually = state.status { return .waitingForDevice(targetName: target) }
                return nil
            }
            state.manualReconnectRequested = false
            state.reconnectGeneration &+= 1
            if case .connected = state.status { return nil }
            if case .connecting = state.status { return nil }
            return .disconnectedManually(targetName: target ?? "iPad")
        }
        if let nextStatus { updateStatus(nextStatus) }
    }

    public func beginDisplayReconfiguration() {
        stateLock.withLock { $0.reconfigurationDepth += 1 }
        MaccarLogger.shared.debug("DeviceWatcher", "Paused background watcher for display reconfiguration.")
    }

    public func endDisplayReconfiguration() {
        let remaining = stateLock.withLock { $0.reconfigurationDepth = max(0, $0.reconfigurationDepth - 1); return $0.reconfigurationDepth }
        if remaining == 0 { MaccarLogger.shared.debug("DeviceWatcher", "Resumed background watcher after display reconfiguration.") }
    }

    public func disconnectManually(deviceName: String? = nil) throws {
        let explicit = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = (explicit?.isEmpty == false ? explicit : nil) ?? resolvedTargetName() ?? "iPad"
        let disconnectTime = now()
        let previousHold = stateLock.withLock { state -> Bool in
            let prior = state.isManualDisconnectHold
            state.isManualDisconnectHold = true; state.manualReconnectRequested = false; state.reconnectGeneration &+= 1
            state.lastManualDisconnectTime = disconnectTime; state.consecutiveDetachMisses = 0
            state.backoff.resetForTargetOrToggleClear()
            return prior
        }
        MaccarLogger.shared.info("DeviceWatcher", "Manual disconnect requested for '\(target)'; pausing auto-connect until Reconnect or USB replug.")
        do {
            try sidecar.disconnect(deviceName: target, ignoreNotConnected: true)
            MaccarLogger.shared.info("DeviceWatcher", "Manual disconnect completed for '\(target)'.")
            updateStatus(.disconnectedManually(targetName: target))
        } catch {
            stateLock.withLock { $0.isManualDisconnectHold = previousHold }
            MaccarLogger.shared.error("DeviceWatcher", "Manual disconnect failed for '\(target)': \(error.localizedDescription)")
            updateStatus(.error(message: error.localizedDescription))
            throw error
        }
    }

    /// A manual press re-arms the strict zero-popup gate (DD-6). Without this the press
    /// would be swallowed by `tick()`'s `isAutoRetryPaused` branch before it could ever
    /// reach `consumeAutoConnectGate`, which is exactly the "Reconnect Now does nothing"
    /// symptom. `resetForReconnect()` clears the latch.
    public func reconnectNow() {
        let shouldDispatch = stateLock.withLock { state -> Bool in
            // The user's intent is applied unconditionally: a press is a fresh
            // instruction, so it must clear the hold and reset the retry gate even
            // when a previous reconnect is still in flight. Only the *dispatch* is
            // deduplicated, otherwise a press lands as a no-op and the menu keeps
            // showing "Disconnected" after the user asked to reconnect.
            state.isManualDisconnectHold = false; state.manualReconnectRequested = true
            state.lastManualDisconnectTime = .distantPast; state.consecutiveDetachMisses = 0
            state.backoff.resetForReconnect()
            guard dispatchesReconnectTicks else { return true }
            guard !state.isReconnectPending else { return false }
            state.isReconnectPending = true; state.reconnectGeneration &+= 1
            return true
        }
        if !shouldDispatch {
            MaccarLogger.shared.debug("DeviceWatcher", "Coalesced duplicate reconnect request while reconnect is pending; intent recorded."); return
        }
        MaccarLogger.shared.info("DeviceWatcher", "Explicit reconnect requested; resuming connection for registered iPad.")
        if dispatchesReconnectTicks { queue.async { [weak self] in self?.performForceReconnect() } }
    }

    internal func notifyUSBDeviceAttached() {
        let activeTarget = resolvedTargetName()
        let result = stateLock.withLock { state -> (status: DeviceWatcherStatus?, callback: (@Sendable (DeviceWatcherStatus) -> Void)?, shouldTick: Bool, isHeld: Bool, isStopped: Bool) in
            state.backoff.resetForUSBAttach(); state.consecutiveDetachMisses = 0
            let shouldTick = dispatchesReconnectTicks && !state.isManualDisconnectHold && !state.isStopped
            guard !state.isStopped, case .autoRetryPaused = state.status else {
                return (nil, nil, shouldTick, state.isManualDisconnectHold, state.isStopped)
            }
            let nextStatus = DeviceWatcherStatus.waitingForDevice(targetName: activeTarget)
            guard state.status != nextStatus else { return (nil, nil, shouldTick, state.isManualDisconnectHold, state.isStopped) }
            state.status = nextStatus
            return (nextStatus, state.onStatusChange, shouldTick, state.isManualDisconnectHold, state.isStopped)
        }
        if !result.isStopped {
            let note = result.isHeld ? "while manual disconnect hold is active; preserving hold." : "resetting retry backoff."
            MaccarLogger.shared.info("DeviceWatcher", "USB iPad attach detected; \(note)")
        }
        if let nextStatus = result.status, let callback = result.callback { DispatchQueue.main.async { callback(nextStatus) } }
        if result.shouldTick { queue.async { [weak self] in self?.tick() } }
    }

    public func setAutoConnectEnabled(_ enabled: Bool) {
        let activeTarget = resolvedTargetName()
        let transition = stateLock.withLock { state -> (status: DeviceWatcherStatus?, callback: (@Sendable (DeviceWatcherStatus) -> Void)?, shouldTick: Bool) in
            state.backoff.resetForTargetOrToggleClear(); state.consecutiveDetachMisses = 0
            let shouldTick = enabled && dispatchesReconnectTicks && !state.isManualDisconnectHold && !state.isStopped
            guard !state.isStopped, case .autoRetryPaused = state.status else { return (nil, nil, shouldTick) }
            let nextStatus = DeviceWatcherStatus.waitingForDevice(targetName: activeTarget)
            guard state.status != nextStatus else { return (nil, nil, shouldTick) }
            state.status = nextStatus
            return (nextStatus, state.onStatusChange, shouldTick)
        }
        if let nextStatus = transition.status, let callback = transition.callback { DispatchQueue.main.async { callback(nextStatus) } }
        if transition.shouldTick { queue.async { [weak self] in self?.tick() } }
    }

    public func clearTargetState() {
        let activeTarget = resolvedTargetName()
        let transition = stateLock.withLock { state -> (status: DeviceWatcherStatus?, callback: (@Sendable (DeviceWatcherStatus) -> Void)?) in
            state.backoff.resetForTargetOrToggleClear()
            state.isManualDisconnectHold = false; state.manualReconnectRequested = false
            state.consecutiveDetachMisses = 0; state.lastManualDisconnectTime = .distantPast; state.reconnectGeneration &+= 1
            guard !state.isStopped, state.status != .stopped else { return (nil, nil) }
            switch state.status {
            case .connected, .connecting, .stopped: return (nil, nil)
            case .disconnectedManually, .autoRetryPaused, .error, .waitingForDevice:
                let nextStatus = DeviceWatcherStatus.waitingForDevice(targetName: activeTarget)
                guard state.status != nextStatus else { return (nil, nil) }
                state.status = nextStatus
                return (nextStatus, state.onStatusChange)
            }
        }
        if let nextStatus = transition.status, let callback = transition.callback { DispatchQueue.main.async { callback(nextStatus) } }
    }

    private func teardownLifecycle() {
        let (activeTimer, activeObserver) = lifecycleLock.withLock {
            let pair = (timer, observer); timer = nil; observer = nil; return pair
        }
        activeObserver?.stop()
        activeTimer?.cancel()
    }

    internal func resolvedTargetName() -> String? {
        guard let raw = settings.registeredDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }

    internal func updateStatus(_ newStatus: DeviceWatcherStatus) {
        let callback = stateLock.withLock { state -> (@Sendable (DeviceWatcherStatus) -> Void)? in
            guard !state.isStopped, state.status != newStatus else { return nil }
            state.status = newStatus
            return state.onStatusChange
        }
        if let callback { DispatchQueue.main.async { callback(newStatus) } }
    }

    @discardableResult
    internal func fetchAndCacheReachableDevices() -> [String]? {
        guard let reachable = try? sidecar.reachableDevices() else { return nil }
        cacheReachableDevices(reachable)
        return reachable
    }

    internal func cacheReachableDevices(_ devices: [String]) {
        let callback = stateLock.withLock { state -> (@Sendable ([String]) -> Void)? in
            guard state.cachedReachableDevices != devices else { return nil }
            state.cachedReachableDevices = devices
            return state.onReachableDevicesChange
        }
        if let callback { DispatchQueue.main.async { callback(devices) } }
    }

    internal func acquireWorkSlot(respectReconfig: Bool) -> Bool {
        stateLock.withLock {
            let blockedByReconfig = respectReconfig && $0.reconfigurationDepth > 0
            guard !$0.isStopped, !$0.isWorking, !blockedByReconfig else { return false }
            $0.isWorking = true
            return true
        }
    }

    private func tick() {
        guard acquireWorkSlot(respectReconfig: true) else { return }
        defer { releaseWorkSlot() }

        guard let target = resolvedTargetName() else {
            _ = fetchAndCacheReachableDevices(); updateStatus(.waitingForDevice(targetName: nil)); return
        }
        if stateLock.withLock({ $0.isManualDisconnectHold }) { handleManualDisconnectHold(for: target); return }
        if sidecar.isDeviceConnected(deviceName: target) { handleConnectedTick(for: target); return }
        if case .connected = status {
            MaccarLogger.shared.info("DeviceWatcher", "Active Sidecar session ended for '\(target)'; returning to waiting state.")
            updateStatus(.waitingForDevice(targetName: target))
        }
        if stateLock.withLock({ $0.backoff.isAutoRetryPaused }) { handleAutoRetryPaused(for: target); return }
        guard consumeAutoConnectGate(autoConnectEnabled: settings.autoConnect, at: now()) else {
            _ = fetchAndCacheReachableDevices(); return
        }
        attemptReachableConnect(for: target, autoMirror: settings.autoMirror)
    }

    private func handleManualDisconnectHold(for target: String) {
        if let reachable = fetchAndCacheReachableDevices() {
            let attached = reachable.contains { $0.caseInsensitiveCompare(target) == .orderedSame }
            let cleared = stateLock.withLock { state -> Bool in
                if attached { state.consecutiveDetachMisses = 0; return false }
                state.consecutiveDetachMisses += 1
                guard state.consecutiveDetachMisses >= Timing.detachConsecutiveMissThreshold else { return false }
                state.isManualDisconnectHold = false; state.consecutiveDetachMisses = 0; state.lastManualDisconnectTime = .distantPast
                return true
            }
            if cleared {
                MaccarLogger.shared.info("DeviceWatcher", "Registered device '\(target)' detached; clearing manual disconnect hold.")
                updateStatus(.waitingForDevice(targetName: target)); return
            }
        }
        updateStatus(.disconnectedManually(targetName: target))
        suppressGhostConnectionIfNeeded(for: target)
    }

    private func handleAutoRetryPaused(for target: String) {
        if let reachable = fetchAndCacheReachableDevices() {
            let stillReachable = reachable.contains { $0.caseInsensitiveCompare(target) == .orderedSame }
            let cleared = stateLock.withLock { state -> Bool in
                if stillReachable { state.consecutiveDetachMisses = 0; return false }
                state.consecutiveDetachMisses += 1
                guard state.consecutiveDetachMisses >= Timing.detachConsecutiveMissThreshold else { return false }
                state.backoff.resetForTargetOrToggleClear(); state.consecutiveDetachMisses = 0
                return true
            }
            if cleared {
                MaccarLogger.shared.info("DeviceWatcher", "Registered device '\(target)' detached; clearing auto-retry pause.")
                updateStatus(.waitingForDevice(targetName: target)); return
            }
        }
        updateStatus(.autoRetryPaused(targetName: target))
    }

    private func suppressGhostConnectionIfNeeded(for target: String) {
        guard sidecar.isDeviceConnected(deviceName: target) else { return }
        let shouldWarn = stateLock.withLock { state -> Bool in
            let t = now()
            guard t.timeIntervalSince(state.lastGhostWarningTime) >= Timing.ghostWarningThrottleSeconds else { return false }
            state.lastGhostWarningTime = t; return true
        }
        if shouldWarn {
            MaccarLogger.shared.warning("DeviceWatcher", "Suppressed spurious Sidecar reconnect for '\(target)' during manual disconnect hold.")
        }
        try? sidecar.disconnect(deviceName: target, ignoreNotConnected: true)
    }

    private func handleConnectedTick(for target: String) {
        // Adopting a session that already exists issues no `connect()`, so it cannot raise a
        // popup and DD-6's gate has nothing to suppress. The old post-failure suppression
        // window is gone: with a sticky latch it would disconnect the user's Control Center
        // session on every tick, forever.
        stateLock.withLock { state in
            state.isManualDisconnectHold = false; state.manualReconnectRequested = false
            state.consecutiveDetachMisses = 0; state.backoff.resetForConnected()
        }
        let (mirrored, ipadDisplayID) = syncMirrorIfNeeded(autoMirror: settings.autoMirror)
        _ = fetchAndCacheReachableDevices()
        if case .connected(let curName, let curDisplayID, let curMirrored) = status,
           curName.caseInsensitiveCompare(target) == .orderedSame,
           curDisplayID == ipadDisplayID, curMirrored == mirrored { return }
        MaccarLogger.shared.info("DeviceWatcher", "Detected active Sidecar session for '\(target)' (mirrored: \(mirrored)).")
        updateStatus(.connected(deviceName: target, displayID: ipadDisplayID, mirrored: mirrored))
    }

    private func attemptReachableConnect(for target: String, autoMirror: Bool) {
        let capturedGeneration = stateLock.withLock { $0.reconnectGeneration }
        let reachable: [String]
        do { reachable = try sidecar.reachableDevices(); cacheReachableDevices(reachable) } catch {
            handleConnectFailure(target: target, error: error, capturedGeneration: capturedGeneration); return
        }
        guard let deviceToConnect = reachable.first(where: { $0.caseInsensitiveCompare(target) == .orderedSame }) else {
            if !shouldAbortConnectAttempt(capturedGeneration: capturedGeneration) { updateStatus(.waitingForDevice(targetName: target)) }
            return
        }
        guard !shouldAbortConnectAttempt(capturedGeneration: capturedGeneration) else { return }
        updateStatus(.connecting(targetName: deviceToConnect))
        MaccarLogger.shared.info("DeviceWatcher", "Auto-connecting to registered iPad '\(deviceToConnect)'...")
        executeConnectAndMirror(deviceName: deviceToConnect, autoMirror: autoMirror, capturedGeneration: capturedGeneration)
    }

    internal func handleConnectFailure(target: String, error: Error, capturedGeneration: UInt64) {
        guard !shouldAbortConnectAttempt(capturedGeneration: capturedGeneration) else {
            MaccarLogger.shared.info("DeviceWatcher", "Ignoring connect error for '\(target)' after cancellation or manual hold."); return
        }
        let failureTime = now()
        stateLock.withLock { state in
            state.consecutiveDetachMisses = 0
            _ = state.backoff.recordFailure(error: error, at: failureTime)
        }
        // DD-6: any failed connect() already raised a Sidecar popup, so this is the last
        // automatic attempt. It stays suppressed until a replug or a manual reconnect.
        MaccarLogger.shared.warning("DeviceWatcher", "Connect failed for '\(target)': \(error.localizedDescription). Auto-connect suppressed until USB replug or manual reconnect.")
        updateStatus(.autoRetryPaused(targetName: target))
    }
}
