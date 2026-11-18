import Foundation
import Testing
@testable import MaccarKit

/// Regression guard for "No iPad Registered" while the registry is not empty.
///
/// Field report, 2026-11-18: the user pressed Register in the "New iPad detected"
/// dialog and the menu then said "No iPad Registered" — while the Target iPad submenu
/// in the *same* menu listed the device. Two stores existed and only one was read back:
///
///   promptForUnknownDeviceIfNeeded → DeviceRegistry        (written)
///   setupMenu                      → settings.registeredDeviceName  (read)
///
/// The menu must render from one resolved value so a registered iPad can never look
/// unregistered.
@Suite("Menu Registration Consistency Tests")
struct MenuRegistrationConsistencyTests {

    private func device(_ name: String, id: String) -> SidecarDevice {
        SidecarDevice(identifier: id, name: name, model: "iPad")
    }

    @Test("A registry with an active device never renders the empty state")
    func activeRegistryDeviceIsShownAsTarget() {
        let registry = DeviceRegistry()
        registry.register(device("VPad", id: "id-vpad"))

        let resolved = MenuTargetResolver.targetName(
            registryActiveName: registry.activeDevice?.name,
            legacyName: nil
        )

        #expect(resolved == "VPad",
                "after Register the menu must name the device, not claim none is registered")
    }

    @Test("Registering via the dialog wins over a stale legacy name")
    func registryBeatsStaleLegacyName() {
        let registry = DeviceRegistry()
        registry.register(device("Studio iPad", id: "id-studio"))

        // The legacy key still holds an old name from the typed-name era. The registry is the
        // source of truth, so the menu must follow it and not the leftover string.
        let resolved = MenuTargetResolver.targetName(
            registryActiveName: registry.activeDevice?.name,
            legacyName: "VPad"
        )

        #expect(resolved == "Studio iPad")
    }

    @Test("An empty registry falls back to the legacy name for the migration window")
    func emptyRegistryFallsBackToLegacyName() {
        let resolved = MenuTargetResolver.targetName(
            registryActiveName: nil,
            legacyName: "VPad"
        )

        #expect(resolved == "VPad",
                "an upgrading user keeps their target until the registry is populated")
    }

    @Test("Nothing registered anywhere still renders the honest empty state")
    func nothingRegisteredIsEmpty() {
        let resolved = MenuTargetResolver.targetName(registryActiveName: nil, legacyName: nil)
        #expect(resolved == nil)
    }

    @Test("A registry with devices but no active one does not borrow the legacy name silently")
    func registryWithoutActiveDeviceIsNotLegacyFallback() {
        let registry = DeviceRegistry()
        registry.register(device("VPad", id: "id-vpad"))

        // Devices exist, so the registry is authoritative. Falling back to the legacy string here
        // would resurrect exactly the drift this fix removes.
        let resolved = MenuTargetResolver.targetName(
            registryActiveName: nil,
            legacyName: "Old Typed Name",
            registryHasDevices: true
        )

        #expect(resolved == nil,
                "a populated registry must not fall back to the legacy string")
    }
}
