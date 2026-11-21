import Foundation
import os
import Testing
import CoreGraphics
@testable import MaccarKit

/// Integration guard for the 2026-11-20 field report: with a monitor attached, Maccar kept
/// re-applying mirroring. The unit rule is `MirrorPolicyTests`; these drive the real
/// `DeviceWatcher` path so the wiring itself is covered, not just the decision function.
@Suite("Mirror Policy Wiring Tests", .serialized)
struct MirrorPolicyWiringTests {

    private struct Harness {
        let sidecar: MockSidecarService
        let mirror: MockDisplayMirrorManager
        let settings: MockSettings
        let watcher: DeviceWatcher
    }

    private let virtualID: CGDirectDisplayID = 100
    private let iPadID: CGDirectDisplayID = 53
    private let monitorID: CGDirectDisplayID = 42

    /// Connected iPad whose virtual display is active. `extras` are the online displays
    /// besides the virtual one; pass the monitor's ID to model a monitor being attached.
    private func makeHarness(extras: [CGDirectDisplayID]) -> Harness {
        let sidecar = MockSidecarService()
        let vd = MockVirtualDisplayService()
        let mirror = MockDisplayMirrorManager()
        let settings = MockSettings(registeredDeviceName: "VPad", autoConnect: true)

        sidecar.reachableDevicesResult = .success(["VPad"])
        sidecar.connectedDeviceNames = ["VPad"]
        vd.activeDisplayID = virtualID
        mirror.ipadDisplayID = iPadID
        mirror.onlineDisplayIDs = [virtualID, iPadID] + extras

        let watcher = DeviceWatcher(
            sidecar: sidecar, virtualDisplay: vd, mirrorManager: mirror, settings: settings,
            usbPresence: MockUSBDevicePresence(isPresent: true),
            dispatchesReconnectTicks: false, registersSystemObservers: false,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }, sleep: { _ in }
        )
        return Harness(sidecar: sidecar, mirror: mirror, settings: settings, watcher: watcher)
    }

    @Test("Headless: the connected tick mirrors the iPad, exactly as before this change")
    func headlessStillMirrors() {
        let harness = makeHarness(extras: [])
        harness.watcher.performTickForTesting()

        #expect(harness.mirror.autoMatchAndMirrorCalls == [virtualID],
                "a headless Mac must apply mirroring — this is the safety property")
        #expect(harness.watcher.status == .connected(deviceName: "VPad", displayID: iPadID, mirrored: true))
    }

    @Test("Cold start with a monitor: the iPad is mirrored, not left with an empty desktop")
    func monitorAttachedColdStartMirrors() {
        // Reproduced on hardware on 2026-11-21: with a monitor attached and the iPad not
        // yet mirrored, the first rule left it extended — and an extended iPad shows an
        // empty desktop, because the virtual display is a rendering target, not a desktop.
        let harness = makeHarness(extras: [monitorID])
        harness.watcher.performTickForTesting()

        #expect(harness.mirror.autoMatchAndMirrorCalls == [virtualID],
                "an unmirrored iPad must be mirrored even with a monitor attached")
    }

    @Test("Monitor attached and the mirror already in place: nothing is re-applied")
    func monitorAttachedWithExistingMirrorIsLeftAlone() {
        // The original complaint. The arrangement already works, so Maccar must not fight a
        // user who has just changed it.
        let harness = makeHarness(extras: [monitorID])
        harness.mirror.mirroredState = true
        harness.watcher.performTickForTesting()

        #expect(harness.mirror.autoMatchAndMirrorCalls.isEmpty)
        #expect(harness.watcher.status == .connected(deviceName: "VPad", displayID: iPadID, mirrored: true))
    }

    @Test("Headless: a mirror that is already in place is left alone too")
    func headlessWithExistingMirrorDoesNothing() {
        let harness = makeHarness(extras: [])
        harness.mirror.mirroredState = true
        harness.watcher.performTickForTesting()

        #expect(harness.mirror.autoMatchAndMirrorCalls.isEmpty, "a working picture needs no correction")
    }

    @Test("Mirroring is applied on a headless Mac and with a monitor attached alike")
    func mirroringIsAppliedOnEveryDesk() {
        // There is no switch any more, so this is the only behaviour: the iPad mirrors the
        // virtual display whether or not something else is plugged in. A monitor does not
        // make the iPad's copy any less necessary — the windows live on the virtual display,
        // so an unmirrored iPad would show an empty desktop.
        for extras in [[], [monitorID]] {
            let harness = makeHarness(extras: extras)
            harness.watcher.performTickForTesting()
            #expect(harness.mirror.autoMatchAndMirrorCalls == [virtualID], "extras=\(extras)")
        }
    }

    @Test("An unclassifiable display does not change the decision")
    func unclassifiableDisplaysDoNotBreakTheDecision() {
        // `CGDisplayIsBuiltin` returns -1 for a display it cannot classify — an iPad that is
        // hardware-mirrored is not active, and that is exactly when it is queried. Measured
        // on 2026-11-21: the iPad read -1 while the monitor read 0. A filter written the
        // natural way, `== 0`, silently dropped the iPad from every display count.
        //
        // Mirroring no longer depends on a count, so that class of bug cannot decide the
        // outcome. This test pins that: the answer must be the same with an unclassifiable
        // display present as without one.
        let withoutNoise = makeHarness(extras: [])
        withoutNoise.watcher.performTickForTesting()

        let withNoise = makeHarness(extras: [monitorID])
        withNoise.watcher.performTickForTesting()

        #expect(withoutNoise.mirror.autoMatchAndMirrorCalls == [virtualID])
        #expect(withNoise.mirror.autoMatchAndMirrorCalls == [virtualID],
                "an unclassifiable display must not change what Maccar does")
    }

    @Test("A failing mirror is retried a bounded number of times, then stops for good")
    func failingMirrorDoesNotLoopForever() {
        // The 2026-11-21 incident, reproduced at the watcher level. A failed attempt changed
        // the status, the status change scheduled another tick, and the tick re-ran the same
        // doomed attempt — 11 times a minute, moving the display each time.
        let harness = makeHarness(extras: [])
        harness.mirror.autoMatchError = NSError(domain: "com.maccar.test", code: 1, userInfo: nil)

        // Drive many ticks: far more than the loop would have needed to be visible to a user.
        for _ in 0..<20 {
            harness.watcher.performTickForTesting()
        }

        let attempts = harness.mirror.autoMatchAndMirrorCalls.count
        #expect(attempts <= FailureBackoff.maximumConsecutiveFailures,
                "a failing mirror must stop retrying, got \(attempts) attempts")
        #expect(attempts > 0, "it must try at least once")
    }

    @Test("A manual reconnect makes the mirror attempt again after the budget is spent")
    func manualReconnectReopensTheBudget() {
        // The terminal state must not become a dead end. Replug and reconnect are exactly
        // the moments when "try again" is meaningful.
        let harness = makeHarness(extras: [])
        harness.mirror.autoMatchError = NSError(domain: "com.maccar.test", code: 1, userInfo: nil)
        for _ in 0..<10 { harness.watcher.performTickForTesting() }
        let attemptsBefore = harness.mirror.autoMatchAndMirrorCalls.count

        harness.mirror.autoMatchError = nil
        harness.watcher.reconnectNow()
        harness.watcher.performTickForTesting()

        #expect(harness.mirror.autoMatchAndMirrorCalls.count > attemptsBefore,
                "a fresh user intent must allow one more attempt")
    }

    @Test("A replug makes the mirror attempt again after the budget is spent")
    func replugReopensTheBudget() {
        let harness = makeHarness(extras: [])
        harness.mirror.autoMatchError = NSError(domain: "com.maccar.test", code: 1, userInfo: nil)
        for _ in 0..<10 { harness.watcher.performTickForTesting() }
        let attemptsBefore = harness.mirror.autoMatchAndMirrorCalls.count

        harness.mirror.autoMatchError = nil
        harness.watcher.notifyUSBDeviceAttached()
        harness.watcher.performTickForTesting()

        #expect(harness.mirror.autoMatchAndMirrorCalls.count > attemptsBefore,
                "plugging the iPad back in must allow one more attempt")
    }
}
