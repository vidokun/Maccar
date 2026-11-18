import Foundation
import Testing
@testable import MaccarKit

/// Once a legacy configured name has been migrated into the registry, the legacy key must be
/// cleared. Leaving it set is what let the two stores drift apart in the first place: the menu
/// read one, the prompt wrote the other, and deleting a registration could resurrect a device
/// from the leftover string.
@Suite("Legacy Name Migration Tests")
struct LegacyNameMigrationTests {

    /// Isolated defaults per test: the registry store writes here, and two tests sharing a suite
    /// would see each other's registrations.
    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "com.maccar.tests.migration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    private func makeWatcher(
        settings: MockSettings,
        registry: DeviceRegistry,
        defaults: UserDefaults
    ) -> DeviceWatcher {
        let sidecar = MockSidecarService()
        sidecar.reachableDevicesWithIdentityResult = .success([
            SidecarDevice(identifier: "UUID-B", name: "TravelPad", model: "")
        ])
        return DeviceWatcher(
            sidecar: sidecar,
            virtualDisplay: MockVirtualDisplayService(),
            mirrorManager: MockDisplayMirrorManager(),
            settings: settings,
            usbPresence: MockUSBDevicePresence(isPresent: true),
            registry: registry,
            registryStore: DeviceRegistryStore(defaults: defaults),
            dispatchesReconnectTicks: false,
            registersSystemObservers: false,
            now: { ManualTestClock().now() },
            sleep: { _ in }
        )
    }

    @Test("A successful adoption clears the legacy name")
    func adoptionClearsLegacyName() throws {
        try withIsolatedDefaults { defaults in
            let settings = MockSettings(registeredDeviceName: "TravelPad")
            let registry = DeviceRegistry()
            let watcher = makeWatcher(settings: settings, registry: registry, defaults: defaults)

            watcher.adoptActiveDeviceIfUnregistered()

            #expect(registry.activeDevice?.identifier == "UUID-B", "adoption should still happen")
            #expect(settings.registeredDeviceName == nil,
                    "the legacy string must not survive migration, or the two stores can drift again")
        }
    }

    @Test("Names differing only by case or spacing still migrate, and the key is still cleared")
    func caseInsensitiveMatchStillClears() throws {
        try withIsolatedDefaults { defaults in
            // Users typed this by hand, so whitespace and casing vary. The comparison has always
            // ignored both; only the cleanup is new.
            let settings = MockSettings(registeredDeviceName: "  travelpad  ")
            let registry = DeviceRegistry()
            let watcher = makeWatcher(settings: settings, registry: registry, defaults: defaults)

            watcher.adoptActiveDeviceIfUnregistered()

            #expect(registry.count == 1)
            #expect(settings.registeredDeviceName == nil)
        }
    }

    @Test("A name that matches nothing is left alone for the user to see and correct")
    func unmatchedNameIsNotCleared() throws {
        try withIsolatedDefaults { defaults in
            let settings = MockSettings(registeredDeviceName: "Some Old Name")
            let registry = DeviceRegistry()
            let watcher = makeWatcher(settings: settings, registry: registry, defaults: defaults)

            watcher.adoptActiveDeviceIfUnregistered()

            #expect(registry.count == 0, "nothing may be adopted on a failed match")
            #expect(settings.registeredDeviceName == "Some Old Name",
                    "no adoption means no migration, so the name stays until the user acts")
        }
    }
}
