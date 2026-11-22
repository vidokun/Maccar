import Foundation
import Testing
import CoreGraphics
@testable import MaccarKit

/// The wiring guard for Wi-Fi Mode: the `wired:` argument passed to Sidecar must follow the
/// session permission. This is the whole feature — everything else (transport switching,
/// Wi-Fi→USB handover) is Sidecar's job, measured on 2026-11-21.
@Suite("Wireless Mode Wiring Tests", .serialized)
struct WirelessModeWiringTests {

    private struct Harness {
        let sidecar: MockSidecarService
        let wireless: WirelessSession
        let clock: ManualTestClock
        let presence: MockUSBDevicePresence
        let watcher: DeviceWatcher

        /// Flips physical presence the way unplugging would, for the transport-report tests.
        func setPresenceForTesting(isPresent: Bool) {
            presence.isPresent = isPresent
        }
    }

    private func makeHarness(wirelessEnabled: Bool) -> Harness {
        let sidecar = MockSidecarService()
        let vd = MockVirtualDisplayService()
        let mirror = MockDisplayMirrorManager()
        let settings = MockSettings(registeredDeviceName: "VPad", autoConnect: true)
        let wireless = WirelessSession()
        let clock = ManualTestClock()
        let presence = MockUSBDevicePresence(isPresent: true)
        if wirelessEnabled { wireless.enable() }

        sidecar.reachableDevicesResult = .success(["VPad"])
        vd.activeDisplayID = 100
        mirror.ipadDisplayID = 53
        mirror.onlineDisplayIDs = [100, 53]

        let watcher = DeviceWatcher(
            sidecar: sidecar, virtualDisplay: vd, mirrorManager: mirror, settings: settings,
            usbPresence: presence,
            wirelessSession: wireless,
            dispatchesReconnectTicks: false, registersSystemObservers: false,
            // A movable clock: the auto-connect gate is time-based, so a fixed `now` makes the
            // second tick refuse to attempt and the test would prove nothing about the flag.
            now: { clock.now() }, sleep: { _ in }
        )
        return Harness(sidecar: sidecar, wireless: wireless, clock: clock, presence: presence, watcher: watcher)
    }

    @Test("Default: the connect asks for a wired transport")
    func defaultIsWired() {
        let harness = makeHarness(wirelessEnabled: false)
        harness.watcher.performTickForTesting()

        #expect(harness.sidecar.connectCalls.count == 1)
        #expect(harness.sidecar.connectCalls.first?.wired == true,
                "with Wi-Fi off, behaviour must be identical to v1.5.3")
    }

    @Test("Enabled: the connect is allowed to choose Wi-Fi")
    func enabledIsTransportAgnostic() {
        let harness = makeHarness(wirelessEnabled: true)
        harness.watcher.performTickForTesting()

        #expect(harness.sidecar.connectCalls.count == 1)
        #expect(harness.sidecar.connectCalls.first?.wired == false,
                "with Wi-Fi on, Sidecar must be free to use either transport")
    }

    @Test("Turning it off restores the wired connect")
    func disablingRestoresWired() {
        let harness = makeHarness(wirelessEnabled: true)
        harness.watcher.performTickForTesting()
        harness.watcher.flushQueueForTesting()
        #expect(harness.sidecar.connectCalls.first?.wired == false)

        harness.wireless.disable()
        harness.sidecar.connectedDeviceNames = []
        harness.sidecar.reachableDevicesResult = .success(["VPad"])

        // Drive ticks the way the app does — repeatedly, over time. A single extra tick is not
        // enough here: discovering that the session ended defers the next attempt by
        // `sessionEndSettleSeconds`, and that deferral stacks on any earlier one. Looping keeps
        // the test about the *flag* rather than about the settle arithmetic.
        for _ in 0..<10 where harness.sidecar.connectCalls.count < 2 {
            harness.clock.advance(by: 10)
            harness.watcher.performTickForTesting()
            harness.watcher.flushQueueForTesting()
        }

        #expect(harness.sidecar.connectCalls.count >= 2,
                "a second connect must happen once wireless is off; got \(harness.sidecar.connectCalls)")
        #expect(harness.sidecar.connectCalls.last?.wired == true,
                "after disabling, connects must be wired again")
    }

    @Test("SAFETY KPI: a fresh launch never connects on Wi-Fi")
    func freshLaunchIsAlwaysWired() {
        // A relaunch builds a new WirelessSession, so this is what the user actually gets:
        // "setiap aplikasi maccar baru nyala, otomatis wifi mode set ke off".
        let harness = makeHarness(wirelessEnabled: false)
        #expect(harness.wireless.isEnabled == false)
        harness.watcher.performTickForTesting()
        #expect(harness.sidecar.connectCalls.allSatisfy { $0.wired },
                "no connect may request Wi-Fi before the user turns it on")
    }

    @Test("A live session with no cable is reported as Wi-Fi, even when the permission is off")
    func detectsWiFiSessionWithoutPermission() {
        // The stuck state observed on 2026-11-21: a session created outside Maccar's control
        // keeps running over Wi-Fi while the toggle says "off". The menu must be able to see it
        // and to close it, or the user has no control at all.
        let harness = makeHarness(wirelessEnabled: false)
        harness.sidecar.connectedDeviceNames = ["VPad"]
        harness.setPresenceForTesting(isPresent: false)

        #expect(harness.watcher.isConnectedOverWiFi,
                "an unmirrored-by-cable live session is a Wi-Fi session")
    }

    @Test("A live session with the cable attached is not reported as Wi-Fi")
    func cableSessionIsNotWiFi() {
        let harness = makeHarness(wirelessEnabled: true)
        harness.sidecar.connectedDeviceNames = ["VPad"]
        harness.setPresenceForTesting(isPresent: true)

        #expect(harness.watcher.isConnectedOverWiFi == false,
                "the picture is arriving over the cable, whatever the permission says")
    }

    @Test("No session at all is never reported as Wi-Fi")
    func noSessionIsNotWiFi() {
        let harness = makeHarness(wirelessEnabled: true)
        harness.sidecar.connectedDeviceNames = []
        harness.setPresenceForTesting(isPresent: false)
        #expect(harness.watcher.isConnectedOverWiFi == false)
    }
}
