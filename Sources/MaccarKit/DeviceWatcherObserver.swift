import Foundation
import CoreGraphics
import os

internal final class DeviceWatcherObserver: @unchecked Sendable {
    private static let minimumDebounceMilliseconds = 1

    private final class WorkItemBox: @unchecked Sendable {
        let workItem: DispatchWorkItem

        init(_ workItem: DispatchWorkItem) {
            self.workItem = workItem
        }
    }

    private struct ObserverState: Sendable {
        var isRegistered: Bool = false
        var sidecarToken: SidecarObserverToken?
        var pendingDebounceWorkItem: WorkItemBox?
        var pendingUSBAttachWorkItem: WorkItemBox?
        var usbAttachMonitor: (any USBAttachMonitoring)?
    }

    private let queue: DispatchQueue
    private let debounceDelayMilliseconds: Int
    private let usbAttachDebounceMilliseconds: Int
    private let sidecar: any SidecarControlling
    private let isReconfiguring: @Sendable () -> Bool
    private let usbAttachMonitorFactory: (@Sendable (DispatchQueue, @escaping @Sendable () -> Void) -> (any USBAttachMonitoring)?)?
    private let onDebouncedEvent: @Sendable () -> Void
    private let onUSBDeviceAttached: (@Sendable () -> Void)?
    private let stateLock = OSAllocatedUnfairLock(initialState: ObserverState())

    internal init(
        queue: DispatchQueue,
        debounceDelayMilliseconds: Int = 250,
        usbAttachDebounceMilliseconds: Int = 750,
        sidecar: any SidecarControlling,
        isReconfiguring: @escaping @Sendable () -> Bool,
        usbAttachMonitorFactory: (@Sendable (DispatchQueue, @escaping @Sendable () -> Void) -> (any USBAttachMonitoring)?)? = nil,
        onDebouncedEvent: @escaping @Sendable () -> Void,
        onUSBDeviceAttached: (@Sendable () -> Void)? = nil
    ) {
        self.queue = queue
        self.debounceDelayMilliseconds = max(Self.minimumDebounceMilliseconds, debounceDelayMilliseconds)
        self.usbAttachDebounceMilliseconds = max(Self.minimumDebounceMilliseconds, usbAttachDebounceMilliseconds)
        self.sidecar = sidecar
        self.isReconfiguring = isReconfiguring
        self.usbAttachMonitorFactory = usbAttachMonitorFactory
        self.onDebouncedEvent = onDebouncedEvent
        self.onUSBDeviceAttached = onUSBDeviceAttached
    }

    deinit {
        stop()
    }

    internal func start() {
        let shouldStart = stateLock.withLock { state -> Bool in
            guard !state.isRegistered else { return false }
            state.isRegistered = true
            return true
        }
        guard shouldStart else { return }

        let token = sidecar.startObservingNotifications { [weak self] _ in
            self?.scheduleDebouncedEvent()
        }
        let usbMonitor = makeAndStartUSBMonitor()

        let registered = stateLock.withLock { state -> Bool in
            guard state.isRegistered else { return false }
            state.sidecarToken = token
            state.usbAttachMonitor = usbMonitor
            CGDisplayRegisterReconfigurationCallback(
                Self.displayReconfigCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
            return true
        }
        if !registered {
            token?.invalidate()
            usbMonitor?.stop()
        }
    }

    internal func stop() {
        let cleanup: (
            token: SidecarObserverToken?,
            workItem: WorkItemBox?,
            usbWorkItem: WorkItemBox?,
            usbMonitor: (any USBAttachMonitoring)?
        )? = stateLock.withLock { state in
            guard state.isRegistered else { return nil }
            state.isRegistered = false
            let activeToken = state.sidecarToken
            let pendingWorkItem = state.pendingDebounceWorkItem
            let pendingUSBWorkItem = state.pendingUSBAttachWorkItem
            let activeUSBMonitor = state.usbAttachMonitor
            state.sidecarToken = nil
            state.pendingDebounceWorkItem = nil
            state.pendingUSBAttachWorkItem = nil
            state.usbAttachMonitor = nil
            return (activeToken, pendingWorkItem, pendingUSBWorkItem, activeUSBMonitor)
        }
        guard let cleanup else { return }

        cleanup.workItem?.workItem.cancel()
        cleanup.usbWorkItem?.workItem.cancel()
        cleanup.token?.invalidate()
        cleanup.usbMonitor?.stop()
        CGDisplayRemoveReconfigurationCallback(
            Self.displayReconfigCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    internal func scheduleDebouncedEvent() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let isActive = self.stateLock.withLock { $0.isRegistered }
            guard isActive else { return }
            self.onDebouncedEvent()
        }

        let workItemBox = WorkItemBox(workItem)
        let scheduleResult: (shouldSchedule: Bool, previous: WorkItemBox?) = stateLock.withLock { state in
            guard state.isRegistered else { return (false, nil) }
            let previous = state.pendingDebounceWorkItem
            state.pendingDebounceWorkItem = workItemBox
            return (true, previous)
        }
        guard scheduleResult.shouldSchedule else { return }

        scheduleResult.previous?.workItem.cancel()
        let delayMilliseconds = max(Self.minimumDebounceMilliseconds, debounceDelayMilliseconds)
        queue.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds), execute: workItem)
    }

    internal func scheduleDebouncedUSBAttach() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let isActive = self.stateLock.withLock { $0.isRegistered }
            guard isActive, !self.isReconfiguring() else { return }
            self.onUSBDeviceAttached?()
        }

        let workItemBox = WorkItemBox(workItem)
        let scheduleResult: (shouldSchedule: Bool, previous: WorkItemBox?) = stateLock.withLock { state in
            guard state.isRegistered else { return (false, nil) }
            let previous = state.pendingUSBAttachWorkItem
            state.pendingUSBAttachWorkItem = workItemBox
            return (true, previous)
        }
        guard scheduleResult.shouldSchedule else { return }

        scheduleResult.previous?.workItem.cancel()
        let delayMilliseconds = max(Self.minimumDebounceMilliseconds, usbAttachDebounceMilliseconds)
        queue.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds), execute: workItem)
    }

    private func makeAndStartUSBMonitor() -> (any USBAttachMonitoring)? {
        let attachHandler: @Sendable () -> Void = { [weak self] in
            self?.scheduleDebouncedUSBAttach()
        }
        let usbMonitor: (any USBAttachMonitoring)?
        if let factory = usbAttachMonitorFactory {
            usbMonitor = factory(queue, attachHandler)
        } else if onUSBDeviceAttached != nil {
            usbMonitor = USBDeviceAttachMonitor(queue: queue, onIPadAttached: attachHandler)
        } else {
            usbMonitor = nil
        }
        usbMonitor?.start()
        return usbMonitor
    }

    private static let displayReconfigCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
        let observer = Unmanaged<DeviceWatcherObserver>.fromOpaque(userInfo).takeUnretainedValue()
        guard !observer.isReconfiguring() else { return }
        observer.queue.async { [weak observer] in
            observer?.scheduleDebouncedEvent()
        }
    }
}
