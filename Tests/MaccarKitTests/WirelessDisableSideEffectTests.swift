import Foundation
import Testing
@testable import MaccarKit

/// Regression guard for a bug I introduced and the user hit on 2026-11-22: turning Wi-Fi Mode
/// off used `disconnectManually()`, which *also* installs the manual-disconnect hold. After
/// that, plugging the cable in did nothing — the log filled with "while manual disconnect hold
/// is active; preserving hold".
///
/// The earlier tests only checked the `wired:` argument, so they all passed while the feature
/// was visibly broken. These check the side effect instead.
@Suite("Wireless Disable Side Effects")
struct WirelessDisableSideEffectTests {

    private struct Harness {
        let sidecar: MockSidecarService
        let presence: MockUSBDevicePresence
        let clock: ManualTestClock
        let watcher: DeviceWatcher
    }

    private func makeHarness() -> Harness {
        let sidecar = MockSidecarService()
        let vd = MockVirtualDisplayService()
        let mirror = MockDisplayMirrorManager()
        let settings = MockSettings(registeredDeviceName: "VPad", autoConnect: true)
        let clock = ManualTestClock()
        let presence = MockUSBDevicePresence(isPresent: true)

        sidecar.reachableDevicesResult = .success(["VPad"])
        vd.activeDisplayID = 100
        mirror.ipadDisplayID = 53
        mirror.onlineDisplayIDs = [100, 53]

        let watcher = DeviceWatcher(
            sidecar: sidecar, virtualDisplay: vd, mirrorManager: mirror, settings: settings,
            usbPresence: presence, wirelessSession: WirelessSession(),
            dispatchesReconnectTicks: false, registersSystemObservers: false,
            now: { clock.now() }, sleep: { _ in }
        )
        return Harness(sidecar: sidecar, presence: presence, clock: clock, watcher: watcher)
    }

    @Test("disconnectManually installs the hold — the reason it must not be used to close Wi-Fi")
    func disconnectManuallyInstallsHold() {
        // Documents the trap rather than the fix: this is what `disconnectManually` does, and it
        // is why closing a Wi-Fi session uses the plain Sidecar disconnect instead.
        let harness = makeHarness()
        harness.sidecar.connectedDeviceNames = ["VPad"]
        try? harness.watcher.disconnectManually()
        #expect(harness.watcher.isManualDisconnectHold,
                "if this ever stops holding, revisit why the Wi-Fi toggle avoids it")
    }

    @Test("A replug while the hold is active does NOT resume auto-connect")
    func holdSurvivesReplug() {
        // The exact symptom the user reported: cable in, nothing happens.
        let harness = makeHarness()
        harness.sidecar.connectedDeviceNames = ["VPad"]
        try? harness.watcher.disconnectManually()
        #expect(harness.watcher.isManualDisconnectHold)

        let connectsBefore = harness.sidecar.connectCalls.count
        harness.watcher.notifyUSBDeviceAttached()
        harness.clock.advance(by: 30)
        harness.watcher.performTickForTesting()
        harness.watcher.flushQueueForTesting()

        #expect(harness.sidecar.connectCalls.count == connectsBefore,
                "a manual hold must keep auto-connect suppressed, even after a replug")
        #expect(harness.watcher.isManualDisconnectHold)
    }

    @Test("Clearing the hold lets a replug connect again")
    func clearingTheHoldRestoresAutoConnect() {
        // The recovery path, and proof that the hold was the only thing suppressing connect.
        let harness = makeHarness()
        harness.sidecar.connectedDeviceNames = ["VPad"]
        try? harness.watcher.disconnectManually()

        harness.watcher.setManualDisconnectHold(false)
        harness.sidecar.connectedDeviceNames = []
        harness.watcher.notifyUSBDeviceAttached()
        harness.clock.advance(by: DeviceWatcherBackoff.usbAttachSettleSeconds)
        harness.watcher.performTickForTesting()
        harness.watcher.flushQueueForTesting()

        #expect(harness.sidecar.connectCalls.isEmpty == false,
                "with the hold cleared, the replug must be able to connect")
    }
}
