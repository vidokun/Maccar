import Foundation
import Testing
@testable import MaccarKit

/// D6c regression guard.
///
/// Field log, 2026-11-16 10:03: the cable was pulled at :29, and at :32 the app called
/// `connect()` anyway because `SidecarDisplayManager.devices` still listed `VPad` — Sidecar
/// reports devices it has *paired with*, not devices currently attached. The connect failed
/// 106 ms later with "The device was not found" and raised an Apple popup for a device the
/// user had already unplugged.
///
/// The gate below makes the physical presence check authoritative before any `connect()`.
@Suite("USB Presence Gate Tests", .serialized)
struct USBPresenceGateTests {
    @Test("A pulled cable suppresses connect even when Sidecar still lists the device")
    func pulledCableSuppressesConnectDespiteReachableList() {
        let sidecar = MockSidecarService(), vd = MockVirtualDisplayService(), mirror = MockDisplayMirrorManager()
        let settings = MockSettings(registeredDeviceName: "VPad", autoConnect: true, autoMirror: true)
        let clock = ManualTestClock()
        let presence = MockUSBDevicePresence(isPresent: false)
        let watcher = DeviceWatcher(
            sidecar: sidecar, virtualDisplay: vd, mirrorManager: mirror, settings: settings,
            usbPresence: presence,
            dispatchesReconnectTicks: false, registersSystemObservers: false,
            now: { clock.now() }, sleep: { _ in }
        )

        // Sidecar still advertises the device — exactly what the field log showed.
        sidecar.reachableDevicesResult = .success(["VPad"])
        watcher.performTickForTesting()

        #expect(sidecar.connectCalls.isEmpty,
                "no connect() may be issued while the cable is out; each one raises a popup")
        #expect(watcher.status == .waitingForDevice(targetName: "VPad"))
    }

    @Test("A present iPad still connects normally")
    func presentIPadStillConnects() {
        let sidecar = MockSidecarService(), vd = MockVirtualDisplayService(), mirror = MockDisplayMirrorManager()
        let settings = MockSettings(registeredDeviceName: "VPad", autoConnect: true, autoMirror: true)
        let clock = ManualTestClock()
        let presence = MockUSBDevicePresence(isPresent: true)
        let watcher = DeviceWatcher(
            sidecar: sidecar, virtualDisplay: vd, mirrorManager: mirror, settings: settings,
            usbPresence: presence,
            dispatchesReconnectTicks: false, registersSystemObservers: false,
            now: { clock.now() }, sleep: { _ in }
        )

        sidecar.reachableDevicesResult = .success(["VPad"])
        vd.activeDisplayID = 100
        mirror.ipadDisplayID = 53
        watcher.performTickForTesting()

        #expect(sidecar.connectCalls.count == 1)
        #expect(watcher.status == .connected(deviceName: "VPad", displayID: 53, mirrored: true))
    }
}
