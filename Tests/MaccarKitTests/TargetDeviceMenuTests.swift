import Foundation
import Testing
@testable import MaccarKit

/// Wave 3.3: the target-device menu model.
///
/// The decision this protects (agreed 2026-11-16): switching iPads is an explicit menu action.
/// Every `connect()` can raise an Apple popup, so auto-switching on attach would produce a
/// stream of them — the menu must never imply that a device will be adopted silently.
@Suite("Target Device Menu Tests", .serialized)
struct TargetDeviceMenuTests {
    private func device(_ id: String, name: String = "VPad", model: String = "") -> SidecarDevice {
        SidecarDevice(identifier: id, name: name, model: model)
    }

    @Test("The active device is marked and the header shows it")
    func activeDeviceIsMarked() {
        let devices = [device("A", name: "DeskPad"), device("B", name: "TravelPad")]
        let items = TargetDeviceMenuBuilder.items(registryDevices: devices, activeIdentifier: "B")

        #expect(items.first?.title == "Target: TravelPad")
        let selectable = items.filter { $0.kind == .select }
        #expect(selectable.count == 2)
        #expect(selectable.first { $0.isActive }?.identifier == "B")
        #expect(selectable.filter(\.isActive).count == 1, "exactly one active device")
    }

    @Test("Two iPads sharing a name are distinguishable in the menu")
    func duplicateNamesAreDisambiguated() {
        let devices = [
            device("A", name: "VPad", model: "iPad16,1"),
            device("B", name: "VPad", model: "iPad16,2")
        ]
        let items = TargetDeviceMenuBuilder.items(registryDevices: devices, activeIdentifier: "A")
        let titles = items.filter { $0.kind == .select }.map(\.title)

        // Without this, the D3 bug returns: two rows a user cannot tell apart.
        #expect(Set(titles) == ["VPad (iPad16,1)", "VPad (iPad16,2)"])
    }

    @Test("A device that is not currently detected is marked but stays selectable")
    func undetectedDeviceStaysSelectable() {
        let devices = [device("A", name: "DeskPad")]
        let items = TargetDeviceMenuBuilder.items(
            registryDevices: devices, activeIdentifier: "A", reachableIdentifiers: []
        )
        let row = items.first { $0.identifier == "A" }
        #expect(row?.title == "DeskPad (not detected)")
        #expect(row?.isEnabled == true, "a sleeping iPad is still the user's choice")
    }

    /// Changed 2026-11-18 (was: "Forget actions appear only when there is more than one device").
    ///
    /// The old rule assumed a fallback existed — the typed-name menu item — so removing the only
    /// registered device was recoverable. That path was removed with the registration rebuild
    /// (the registry is now the single source of truth), which turned "Forget" into the *only*
    /// way out of a wrong device. A user whose single device was the wrong one — the field case,
    /// an iPad paired over Wi-Fi and registered by mistake — then had no menu action at all and
    /// had to edit defaults by hand.
    ///
    /// The old worry, "forgetting the only device leaves nothing to connect to", is real but
    /// self-healing: with the registry empty the "New iPad detected" prompt offers the attached
    /// iPad again, so the state lasts until the next attach. Owner approved the change.
    @Test("Every registered device offers Forget, including the only one")
    func forgetOfferedForEveryDevice() {
        let single = TargetDeviceMenuBuilder.items(registryDevices: [device("A")], activeIdentifier: "A")
        #expect(single.filter { $0.kind == .forget }.count == 1,
                "the only registered device must be removable, or a wrong device is a dead end")

        let multiple = TargetDeviceMenuBuilder.items(
            registryDevices: [device("A"), device("B", name: "Other")], activeIdentifier: "A"
        )
        #expect(multiple.filter { $0.kind == .forget }.count == 2)
    }

    @Test("An empty registry explains the state instead of showing a blank submenu")
    func emptyRegistryIsExplained() {
        let items = TargetDeviceMenuBuilder.items(registryDevices: [], activeIdentifier: nil)
        #expect(items.count == 1)
        #expect(items.first?.title == "No iPad Registered")
        #expect(items.first?.identifier == nil)
    }

    @Test("A legacy typed name is still shown when no device is registered")
    func legacyNameIsShown() {
        let items = TargetDeviceMenuBuilder.items(
            registryDevices: [], activeIdentifier: nil, fallbackRegisteredName: "TypedPad"
        )
        #expect(items.first?.title == "Target: TypedPad")
    }

    @Test("Every action row is disabled while an operation is in flight")
    func actionsDisabledWhileBusy() {
        let items = TargetDeviceMenuBuilder.items(
            registryDevices: [device("A"), device("B", name: "Other")],
            activeIdentifier: "A",
            isEnabled: false
        )
        let actions = items.filter { $0.kind == .select || $0.kind == .forget }
        #expect(actions.allSatisfy { !$0.isEnabled })
    }
}
