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
        /// Let Sidecar settle after an active session ends before the next automatic
        /// connect. See `DeviceWatcherBackoff.sessionEndSettleSeconds` for the field evidence.
        static let sessionEndSettleSeconds: TimeInterval = DeviceWatcherBackoff.sessionEndSettleSeconds
        /// Let Sidecar become connectable after a USB attach. See
        /// `DeviceWatcherBackoff.usbAttachSettleSeconds` for the measured timings.
        static let usbAttachSettleSeconds: TimeInterval = DeviceWatcherBackoff.usbAttachSettleSeconds
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
    /// Physical presence, authoritative over Sidecar's paired-device list. See D6c.
    internal let usbPresence: any USBDevicePresenceChecking
    /// Multi-device registry (Wave 3). Optional: when absent, the legacy single-name setting is
    /// used, which keeps the existing tests and any pre-registry state working unchanged.
    internal let registryStorage: DeviceRegistry?
    internal let registryStore: DeviceRegistryStore?
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
        usbPresence: any USBDevicePresenceChecking = SystemUSBDevicePresence(),
        registry: DeviceRegistry? = nil,
        registryStore: DeviceRegistryStore? = nil,
        dispatchesReconnectTicks: Bool = true, registersSystemObservers: Bool = true,
        usbAttachMonitorFactory: (@Sendable (DispatchQueue, @escaping @Sendable () -> Void) -> (any USBAttachMonitoring)?)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.sidecar = sidecar; self.virtualDisplay = virtualDisplay
        self.mirrorManager = mirrorManager; self.settings = settings
        self.usbPresence = usbPresence
        self.registryStorage = registry
        self.registryStore = registryStore
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
            // D6d: Sidecar is not ready the instant the USB node appears — attempts 0.8 s and
            // 1.9 s after attach both failed on hardware, while the one at 6.5 s succeeded.
            // Defer the first attempt rather than letting it raise a popup for nothing.
            state.backoff.deferNextAutoConnect(by: Timing.usbAttachSettleSeconds, from: now())
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

    /// The name of the device to connect to.
    ///
    /// Name-based for now, because `SidecarService.connect` still takes a name. The registry's
    /// identifier is the authoritative selection (Wave 3.1); this resolves *that* selection to a
    /// current name, so a rename between launches cannot silently point at a different iPad.
    /// When the selected device is not currently reported by Sidecar, the stored name is used as
    /// a last resort so a sleeping iPad still gets waited for rather than being forgotten.
    internal func resolvedTargetName() -> String? {
        if let active = registry?.activeDevice {
            if let live = (try? sidecar.reachableDevicesWithIdentity())?.first(where: { $0.identifier == active.identifier }) {
                return live.name
            }
            let stored = active.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stored.isEmpty { return stored }
        }
        guard let raw = settings.registeredDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }

    /// The device registry, when one has been supplied. Wave 3 uses this for targeting; the
    /// legacy `settings.registeredDeviceName` path still applies when it is absent.
    internal var registry: DeviceRegistry? { registryStorage }

    /// Publishes the registry's current device list so the menu can render it.
    internal func refreshRegisteredDevices() {
        guard let registry else { return }
        guard let devices = try? sidecar.reachableDevicesWithIdentity() else { return }
        for device in devices { registry.register(device) }
        registryStore?.save(devices: registry.devices, activeIdentifier: registry.activeDevice?.identifier)
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
            // D6b: the field log connected 120 ms after this line and failed 43 ms later with
            // "The device was not found". Sidecar needs the device to settle; the manual path
            // already waits (`postDisconnectSettleSeconds`), this automatic path waited for
            // nothing — which made the first attempt after every replug a guaranteed failure.
            // Deferring by the settle window turns that doomed call into a successful one and
            // costs no extra popups, which a blanket retry would.
            stateLock.withLock { $0.backoff.deferNextAutoConnect(by: Timing.sessionEndSettleSeconds, from: now()) }
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
        // D6c: Sidecar lists devices it has *paired with*, not devices that are plugged in.
        // The field log on 2026-11-16 10:03 connected 3.5 s after the cable was pulled because
        // `reachableDevices()` still contained the iPad; that call raised an Apple popup and
        // failed. Physical presence is therefore checked first, and it fails closed.
        guard usbPresence.isIPadAttached() else {
            MaccarLogger.shared.debug("DeviceWatcher", "Skipping connect for '\(target)': no iPad is attached over USB.")
            if !shouldAbortConnectAttempt(capturedGeneration: stateLock.withLock { $0.reconnectGeneration }) {
                updateStatus(.waitingForDevice(targetName: target))
            }
            _ = fetchAndCacheReachableDevices()
            return
        }
        // D6d: Sidecar needs ~19 s after a replug before it will accept a connection, and every
        // attempt before that fails with `-101` and raises an Apple popup. Neither the paired
        // device list nor the display-agent process is a usable readiness signal (measured: the
        // agent was already running at 11.0 s and the connect still failed), so the attach itself
        // is deferred in `notifyUSBDeviceAttached` by `usbAttachSettleSeconds` and this path
        // simply connects once that has elapsed.
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
        // Do NOT tear down an existing session here.
        //
        // An earlier revision forced `teardownSessionBeforeReconnect` on this path, on the theory
        // that Sidecar keeps a stale session after a replug. The field log proves the opposite:
        // every automatic connect preceded by a `disconnect()` failed with `-101`, while the one
        // that went straight to `connect()` succeeded on the first try at 9.4 s after attach
        // (10:40:24, "Connecting" with no preceding "Disconnecting").
        //
        // The disconnect itself is what puts Sidecar into the state that rejects the following
        // connect. The manual path only tears down when it is actually replacing a *live* session
        // (`wasConnected`), which is a different situation from this one.
        executeConnectAndMirror(deviceName: deviceToConnect, autoMirror: autoMirror, capturedGeneration: capturedGeneration)
    }

    internal func handleConnectFailure(target: String, error: Error, capturedGeneration: UInt64) {
        guard !shouldAbortConnectAttempt(capturedGeneration: capturedGeneration) else {
            MaccarLogger.shared.info("DeviceWatcher", "Ignoring connect error for '\(target)' after cancellation or manual hold."); return
        }
        let failureTime = now()
        let nsError = error as NSError
        // Diagnostic for D6b classification: the error *code* is what decides transient vs
        // refusal, and it was never observable in the field log. Domain + code are safe to log.
        MaccarLogger.shared.warning(
            "DeviceWatcher",
            "Connect failure detail for '\(target)': domain=\(nsError.domain) code=\(nsError.code) transient=\(DeviceWatcherBackoff.Tracker.isTransportSettlingError(error))"
        )
        let paused = stateLock.withLock { state -> Bool in
            state.consecutiveDetachMisses = 0
            _ = state.backoff.recordFailure(error: error, at: failureTime)
            return state.backoff.isAutoRetryPaused
        }
        guard paused else {
            // A transport-settling failure (the device is present but still coming up) is
            // worth the bounded retry this failure just spent. Showing the paused status
            // would be a lie the menu renders, and the next tick retries on its own.
            MaccarLogger.shared.warning("DeviceWatcher", "Connect failed for '\(target)': \(error.localizedDescription). Retrying once after the device settles.")
            updateStatus(.waitingForDevice(targetName: target))
            return
        }
        // DD-6: the popup budget is spent. It stays suppressed until a replug or a manual
        // reconnect re-arms it.
        MaccarLogger.shared.warning("DeviceWatcher", "Connect failed for '\(target)': \(error.localizedDescription). Auto-connect suppressed until USB replug or manual reconnect.")
        updateStatus(.autoRetryPaused(targetName: target))
    }
}
