import Foundation
import os
import Testing
@testable import MaccarKit

/// Opening the app first and plugging in afterwards must still offer registration.
///
/// Field log 2026-11-18 13:30 (v1.5.0, app already open):
///
///     13:30:32  Started device watcher (target: none)
///     13:30:32  Offering to register a newly detected iPad
///     13:30:57  [USBDeviceAttachMonitor] Detected USB attachment of Apple iPad
///     13:30:58  USB iPad attach detected; resetting retry backoff
///     13:40:04  [USBDeviceAttachMonitor] Detected USB attachment of Apple iPad   <- cable back in
///
/// The attach notification fired twice and the prompt never did, because nothing tells
/// the menu layer that a cable arrived. Plug in first and launch second, and the prompt
/// works — the whole difference is whether the watcher had already settled into
/// `.waitingForDevice` before the cable appeared, so the status never changed on attach.
@Suite("USB Attach Notification Tests")
struct USBAttachNotificationTests {

    private func makeWatcher(_ presence: MockUSBDevicePresence, _ sidecar: MockSidecarService) -> DeviceWatcher {
        DeviceWatcher(
            sidecar: sidecar,
            virtualDisplay: MockVirtualDisplayService(),
            mirrorManager: MockDisplayMirrorManager(),
            settings: MockSettings(registeredDeviceName: nil),
            usbPresence: presence,
            dispatchesReconnectTicks: false,
            registersSystemObservers: false,
            now: { ManualTestClock().now() },
            sleep: { _ in }
        )
    }

    /// Thread-safe counter: the callback is @Sendable and may run on any queue.
    private final class Counter: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: 0)
        var value: Int { lock.withLock { $0 } }
        func increment() { lock.withLock { $0 += 1 } }
    }

    @Test("An attach notification reaches the menu layer even when the status does not change")
    func attachFiresCallbackWhileAlreadyWaiting() async throws {
        let sidecar = MockSidecarService()
        let watcher = makeWatcher(MockUSBDevicePresence(isPresent: true), sidecar)

        let attachCount = Counter()
        watcher.onUSBDeviceAttached = { attachCount.increment() }

        // First attach: status is already `.waitingForDevice` from launch, which is exactly the
        // state the field log was in. A status-change callback cannot carry this event.
        watcher.notifyUSBDeviceAttached()
        try await Task.sleep(nanoseconds: 100_000_000)  // the callback is dispatched to main
        #expect(attachCount.value == 1,
                "the attach must be reported on its own channel, not via a status change")

        watcher.notifyUSBDeviceAttached()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(attachCount.value == 2, "every attach is a new decision point")
    }

    @Test("No attach callback is delivered after the watcher stops")
    func stoppedWatcherDoesNotNotify() async throws {
        let sidecar = MockSidecarService()
        let watcher = makeWatcher(MockUSBDevicePresence(isPresent: true), sidecar)
        let attachCount = Counter()
        watcher.onUSBDeviceAttached = { attachCount.increment() }
        watcher.stop()

        watcher.notifyUSBDeviceAttached()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(attachCount.value == 0, "a stopped watcher must not wake the UI")
    }
}
