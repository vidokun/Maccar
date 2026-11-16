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

    @Test("Forget actions appear only when there is more than one device")
    func forgetOnlyWhenMultipleDevices() {
        let single = TargetDeviceMenuBuilder.items(registryDevices: [device("A")], activeIdentifier: "A")
        #expect(single.contains { $0.title.hasPrefix("Forget") } == false,
                "forgetting the only device would leave nothing to connect to")

        let multiple = TargetDeviceMenuBuilder.items(
            registryDevices: [device("A"), device("B", name: "Other")], activeIdentifier: "A"
        )
        #expect(multiple.filter { $0.title.hasPrefix("Forget") }.count == 2)
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
