import Foundation
import Testing
@testable import MaccarKit

/// The menu must offer a way out of a single wrong device.
///
/// Once the typed-name path is gone, the registry is the only way to register an iPad.
/// That makes "Forget" the only way to undo one — and it was gated on `count > 1`, so a
/// user whose *only* registered device was the wrong one (exactly the field case: an iPad
/// paired over Wi-Fi, registered by mistake, impossible to connect) had no menu action at
/// all and had to edit defaults by hand.
@Suite("Forget Single Device Tests")
struct ForgetSingleDeviceTests {

    private func device(_ name: String, id: String) -> SidecarDevice {
        SidecarDevice(identifier: id, name: name, model: "")
    }

    @Test("A single registered device can be forgotten from the menu")
    func singleDeviceOffersForget() {
        let items = TargetDeviceMenuBuilder.items(
            registryDevices: [device("VPad", id: "id-vpad")],
            activeIdentifier: "id-vpad"
        )

        let forgets = items.filter { $0.kind == .forget }
        #expect(forgets.count == 1, "the only registered device must be removable")
        #expect(forgets.first?.identifier == "id-vpad")
        #expect(forgets.first?.title == "Forget VPad")
    }

    @Test("Every registered device offers its own Forget, and each is distinct")
    func everyDeviceOffersForget() {
        let devices = [device("DeskPad", id: "A"), device("TravelPad", id: "B")]
        let items = TargetDeviceMenuBuilder.items(registryDevices: devices, activeIdentifier: "A")

        let forgets = items.filter { $0.kind == .forget }
        #expect(forgets.count == 2)
        #expect(Set(forgets.map(\.identifier)) == ["A", "B"])
    }

    @Test("An empty registry offers no Forget action")
    func emptyRegistryHasNoForget() {
        let items = TargetDeviceMenuBuilder.items(registryDevices: [], activeIdentifier: nil)
        #expect(items.filter { $0.kind == .forget }.isEmpty)
    }

    @Test("Forget is separated from the selectable devices")
    func forgetIsSeparatedFromSelection() {
        let items = TargetDeviceMenuBuilder.items(
            registryDevices: [device("VPad", id: "id-vpad")],
            activeIdentifier: "id-vpad"
        )

        // A separator must come before the forget entries, so a mis-click cannot land on
        // "Forget" while aiming at the device name.
        let forgetIndex = items.firstIndex { $0.kind == .forget }
        let selectIndex = items.firstIndex { $0.kind == .select }
        #expect(forgetIndex != nil && selectIndex != nil)
        if let forgetIndex, let selectIndex {
            let between = items[selectIndex...forgetIndex]
            #expect(between.contains { $0.kind == .separator },
                    "a separator must stand between selection and deletion")
        }
    }
}
