import Foundation
import os
import Testing
@testable import MaccarKit

/// D6 end-to-end guards.
///
/// The field log showed the automatic path issuing `connect()` 120 ms after observing that
/// the previous Sidecar session ended, and failing 43 ms later with "The device was not
/// found". These tests pin the whole seam: a session ending must not immediately produce a
/// doomed connect, a replug must produce exactly one connect with no manual press, and a
/// genuine refusal must still stop the app dead.
@Suite("Replug Seamlessness Tests", .serialized)
struct ReplugSeamlessnessTests {
    private struct Harness {
        let sidecar: MockSidecarService
        let virtualDisplay: MockVirtualDisplayService
        let mirror: MockDisplayMirrorManager
        let settings: MockSettings
        let clock: ManualTestClock
        let sleeps: OSAllocatedUnfairLock<[TimeInterval]>
        let watcher: DeviceWatcher
    }

    private func makeHarness() -> Harness {
        let sidecar = MockSidecarService(), vd = MockVirtualDisplayService(), mirror = MockDisplayMirrorManager()
        let settings = MockSettings(registeredDeviceName: "VPad", autoConnect: true, autoMirror: true)
        let clock = ManualTestClock()
        let sleeps = OSAllocatedUnfairLock<[TimeInterval]>(initialState: [])
        let watcher = DeviceWatcher(
            sidecar: sidecar, virtualDisplay: vd, mirrorManager: mirror, settings: settings,
            // Presence is asserted via the mock so the suite is deterministic on any machine.
            // The "cable pulled" case is D6c and lives in `USBPresenceGateTests`.
            usbPresence: MockUSBDevicePresence(isPresent: true),
            dispatchesReconnectTicks: false, registersSystemObservers: false,
            now: { clock.now() },
            sleep: { duration in
                sleeps.withLock { $0.append(duration) }
                clock.advance(by: duration)
            }
        )
        return Harness(sidecar: sidecar, virtualDisplay: vd, mirror: mirror,
                       settings: settings, clock: clock, sleeps: sleeps, watcher: watcher)
    }

    /// Puts the harness into "was connected, then the cable was pulled" — the state the app is
    /// in the instant before the doomed automatic attempt.
    private func driveToSessionEnded(_ harness: Harness) {
        harness.sidecar.reachableDevicesResult = .success(["VPad"])
        harness.sidecar.connectedDeviceNames = ["VPad"]
        harness.virtualDisplay.activeDisplayID = 100
        harness.mirror.ipadDisplayID = 53
        harness.watcher.performTickForTesting()
        #expect(harness.watcher.status == .connected(deviceName: "VPad", displayID: 53, mirrored: true))

        // Cable pulled: Sidecar no longer reports the session.
        harness.sidecar.connectedDeviceNames = []
    }

    @Test("A session ending settles before the next automatic connect is issued")
    func sessionEndWaitsForDeviceToSettle() {
        let harness = makeHarness()
        driveToSessionEnded(harness)
        let connectsBefore = harness.sidecar.connectCalls.count

        // The tick that observes the session ending must not immediately connect: that is the
        // exact call that failed 43 ms later in the field.
        harness.watcher.performTickForTesting()
        #expect(harness.sidecar.connectCalls.count == connectsBefore,
                "the settle window must elapse before the first automatic attempt")

        // Once the device has had time to settle, the retry is allowed.
        harness.clock.advance(by: DeviceWatcherBackoff.sessionEndSettleSeconds)
        harness.watcher.performTickForTesting()
        #expect(harness.sidecar.connectCalls.count == connectsBefore + 1)
    }

    @Test("A replug after a transient failure connects once, with no manual press")
    func replugAfterTransientFailureConnectsWithoutManualPress() {
        let harness = makeHarness()
        harness.sidecar.reachableDevicesResult = .success(["VPad"])
        harness.sidecar.connectError = NSError(
            domain: "SidecarErrorDomain",
            code: DeviceWatcherBackoff.deviceNotFoundErrorCode,
            userInfo: nil
        )

        // First automatic attempt fails transiently: the gate stays open.
        harness.watcher.performTickForTesting()
        #expect(harness.sidecar.connectCalls.count == 1)
        #expect(!harness.watcher.isAutoRetryPausedForTesting)

        // Cable comes back: the device is reachable but there is no live session yet, which is
        // exactly the replug case. (`connectedDeviceNames` must stay empty — if Sidecar already
        // reported a session the app would *adopt* it, issue no connect, and this test would
        // prove nothing.)
        harness.sidecar.connectError = nil
        harness.sidecar.connectedDeviceNames = []
        harness.virtualDisplay.activeDisplayID = 100
        harness.mirror.ipadDisplayID = 53
        harness.watcher.notifyUSBDeviceAttached()
        harness.watcher.performTickForTesting()

        // D6d: the attach defers the first attempt — Sidecar is not connectable yet, and a
        // `connect()` here would raise an Apple popup for nothing.
        #expect(harness.sidecar.connectCalls.count == 1)

        harness.clock.advance(by: DeviceWatcherBackoff.usbAttachSettleSeconds)
        harness.watcher.performTickForTesting()

        #expect(harness.watcher.status == .connected(deviceName: "VPad", displayID: 53, mirrored: true))
        // One initial failure plus exactly one successful connect: no manual press involved.
        #expect(harness.sidecar.connectCalls.count == 2)
    }

    @Test("The automatic replug path connects WITHOUT tearing down the ended session")
    func autoPathDoesNotTearDownBeforeConnect() {
        let harness = makeHarness()
        harness.sidecar.reachableDevicesResult = .success(["VPad"])

        // Reproduce the field sequence: a live session, then the cable is pulled.
        driveToSessionEnded(harness)
        harness.watcher.performTickForTesting()

        harness.watcher.notifyUSBDeviceAttached()
        harness.clock.advance(by: DeviceWatcherBackoff.usbAttachSettleSeconds)
        harness.watcher.performTickForTesting()

        // The field log settles this: every automatic connect preceded by a `disconnect()`
        // failed with -101 (even 23 s after attach), while the connect that went straight to
        // `connect()` succeeded on the first try at 9.4 s. The disconnect is what puts Sidecar
        // into the state that rejects the next connect.
        let timeline = harness.sidecar.operationTimeline
        #expect(timeline.contains("connect:VPad"))
        #expect(timeline.contains("disconnect:VPad") == false,
                "a teardown before an automatic connect reintroduces the -101 failure; timeline was \(timeline)")
    }

    @Test("An adopted Control Center session is never torn down by the automatic path")
    func adoptedSessionIsNotTornDown() {
        let harness = makeHarness()
        harness.sidecar.reachableDevicesResult = .success(["VPad"])
        // The user started this session themselves; Maccar merely adopts it. `handleConnectedTick`
        // returns before the connect path, so no teardown may happen.
        harness.sidecar.connectedDeviceNames = ["VPad"]
        harness.virtualDisplay.activeDisplayID = 100
        harness.mirror.ipadDisplayID = 53

        harness.watcher.performTickForTesting()

        #expect(harness.watcher.status == .connected(deviceName: "VPad", displayID: 53, mirrored: true))
        #expect(harness.sidecar.disconnectCalls.isEmpty, "a legitimate session must never be torn down")
        #expect(harness.sidecar.connectCalls.isEmpty, "adoption must never call connect()")
    }

    @Test("A USB attach does not connect before Sidecar can accept the connection")
    func attachDefersFirstAttemptUntilSidecarIsReady() {
        let harness = makeHarness()
        harness.sidecar.reachableDevicesResult = .success(["VPad"])

        harness.watcher.notifyUSBDeviceAttached()
        harness.watcher.performTickForTesting()

        // Measured on hardware: every attempt at or below 11.0 s after attach failed with
        // Sidecar's -101, and each failure raised an Apple popup; the attempt at 18.7 s
        // succeeded. Nothing may be attempted inside the settle window.
        #expect(harness.sidecar.connectCalls.isEmpty)

        harness.clock.advance(by: DeviceWatcherBackoff.usbAttachSettleSeconds - 0.1)
        harness.watcher.performTickForTesting()
        #expect(harness.sidecar.connectCalls.isEmpty, "still inside the settle window")

        harness.clock.advance(by: 0.2)
        harness.watcher.performTickForTesting()
        #expect(harness.sidecar.connectCalls.count == 1, "the first attempt happens after the settle window")
    }

    @Test("The settle window stays short — waiting longer does not prevent the -101 failure")
    func settleWindowStaysShort() {
        // Measured: with a teardown before the connect, the attempt still failed at 23 s.
        // Without the teardown, the attempt at 9.4 s succeeded first time. Elapsed time is
        // therefore not what makes the connection possible, so a long wait buys nothing and
        // only delays recovery. The transient retry covers the remaining flakiness.
        #expect(DeviceWatcherBackoff.usbAttachSettleSeconds <= 5.0,
                "a long settle window was measured to change nothing; do not reintroduce it")
    }

    @Test("A refusal still stops all automatic attempts immediately")
    func refusalStopsImmediately() {
        let harness = makeHarness()
        harness.sidecar.reachableDevicesResult = .success(["VPad"])
        harness.sidecar.connectError = NSError(domain: "SidecarErrorDomain", code: -300, userInfo: nil)

        harness.watcher.performTickForTesting()
        #expect(harness.sidecar.connectCalls.count == 1)
        #expect(harness.watcher.isAutoRetryPausedForTesting)
        #expect(harness.watcher.status == .autoRetryPaused(targetName: "VPad"))

        for gap in [5.0, 20.0, 60.0, 300.0] {
            harness.clock.advance(by: gap)
            harness.watcher.performTickForTesting()
        }
        #expect(harness.sidecar.connectCalls.count == 1, "DD-6: a refusal is never retried automatically")
    }
}
