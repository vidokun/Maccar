import Foundation
import Testing
@testable import MaccarKit

/// Wave 3: the device registry that replaces the single `registeredDeviceName` string.
///
/// D3's root cause was that identity was a *name*, so two iPads with the same name were
/// indistinguishable and "Forget device" was not expressible. The registry is keyed by the
/// identifier U4 proved stable across replug.
@Suite("Device Registry Tests", .serialized)
struct DeviceRegistryTests {
    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "com.maccar.tests.registry.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    private func makeDevice(_ id: String, name: String = "VPad", model: String = "iPad16,1") -> SidecarDevice {
        SidecarDevice(identifier: id, name: name, model: model)
    }

    @Test("Registering devices accumulates them instead of replacing the single slot")
    func registeringAccumulatesDevices() {
        let registry = DeviceRegistry()
        let first = makeDevice("UUID-A", name: "VPad")
        let second = makeDevice("UUID-B", name: "VPad")  // same name, different iPad

        registry.register(first)
        registry.register(second)

        // The D3 defect: two iPads sharing a name collapsed into one. Both must be present.
        #expect(registry.count == 2)
        #expect(Set(registry.devices.map(\.identifier)) == ["UUID-A", "UUID-B"])
    }

    @Test("Registering the same identifier twice updates the device rather than duplicating it")
    func registerIsIdempotentPerIdentifier() {
        let registry = DeviceRegistry()
        registry.register(makeDevice("UUID-A", name: "Old Name"))
        registry.register(makeDevice("UUID-A", name: "Renamed", model: "iPad16,2"))

        #expect(registry.count == 1)
        #expect(registry.devices.first?.name == "Renamed")
        #expect(registry.devices.first?.model == "iPad16,2")
    }

    @Test("Forgetting a device removes exactly that one and is repeatable")
    func forgetRemovesOneDevice() {
        let registry = DeviceRegistry()
        registry.register(makeDevice("UUID-A"))
        registry.register(makeDevice("UUID-B"))

        registry.forget(identifier: "UUID-A")
        #expect(registry.selectableDevices.map(\.identifier) == ["UUID-B"])

        // D3 also said Unregister did not truly forget; a second forget must be a no-op, not a crash.
        registry.forget(identifier: "UUID-A")
        #expect(registry.count == 1)
        registry.forget(identifier: "UUID-B")
        #expect(registry.count == 0)
        #expect(registry.activeDevice == nil)
    }

    @Test("The active device is an identifier, so a rename cannot hijack the selection")
    func activeDeviceSurvivesRename() {
        let registry = DeviceRegistry()
        registry.register(makeDevice("UUID-A", name: "VPad"))
        registry.register(makeDevice("UUID-B", name: "OtherPad"))
        registry.setActive(identifier: "UUID-B")

        // Renaming B on the iPad must not move the selection, because it is not name-keyed.
        registry.register(makeDevice("UUID-B", name: "Renamed"))
        #expect(registry.activeDevice?.identifier == "UUID-B")
        #expect(registry.activeDevice?.name == "Renamed")
    }

    @Test("Selecting an unregistered identifier does not become the active device")
    func selectingUnknownDeviceIsRejected() {
        let registry = DeviceRegistry()
        registry.register(makeDevice("UUID-A"))
        registry.setActive(identifier: "UUID-UNKNOWN")
        #expect(registry.activeDevice?.identifier == "UUID-A")
    }

    @Test("Display labels disambiguate two devices that share a name")
    func displayLabelsDisambiguateDuplicates() {
        let registry = DeviceRegistry()
        registry.register(makeDevice("UUID-A", name: "VPad", model: "iPad16,1"))
        registry.register(makeDevice("UUID-B", name: "VPad", model: "iPad16,2"))

        let labels = registry.selectableDevices.map { $0.displayLabel(disambiguatingAmong: registry.devices) }
        #expect(Set(labels) == ["VPad (iPad16,1)", "VPad (iPad16,2)"])
    }

    @Test("A device with a unique name keeps its plain label")
    func uniqueNameKeepsPlainLabel() {
        let registry = DeviceRegistry()
        registry.register(makeDevice("UUID-A", name: "DeskPad"))
        registry.register(makeDevice("UUID-B", name: "OtherPad"))
        #expect(registry.selectableDevices.first?.displayLabel(disambiguatingAmong: registry.devices) == "DeskPad")
    }

    @Test("The registry round-trips through UserDefaults, including the active selection")
    func registryPersistsAcrossRelaunch() throws {
        try withIsolatedDefaults { defaults in
            let stored = DeviceRegistryStore(defaults: defaults)
            let first = makeDevice("UUID-A", name: "DeskPad", model: "iPad16,1")
            let second = makeDevice("UUID-B", name: "TravelPad", model: "iPad16,2")
            stored.save(devices: [first, second], activeIdentifier: "UUID-B")

            // A fresh process reads the same defaults: both devices and the selection survive.
            let reloaded = DeviceRegistryStore(defaults: defaults).load()
            #expect(reloaded.count == 2)
            #expect(reloaded.activeDevice?.identifier == "UUID-B")
            #expect(reloaded.activeDevice?.name == "TravelPad")
        }
    }

    @Test("A persisted selection for a forgotten device falls back instead of dangling")
    func persistedSelectionFallsBackWhenDeviceIsGone() throws {
        try withIsolatedDefaults { defaults in
            let store = DeviceRegistryStore(defaults: defaults)
            store.save(devices: [makeDevice("UUID-A"), makeDevice("UUID-B")], activeIdentifier: "UUID-B")

            // B is forgotten out-of-band; the stored selection now points at nothing.
            store.save(devices: [makeDevice("UUID-A")], activeIdentifier: "UUID-B")
            let reloaded = store.load()
            #expect(reloaded.count == 1)
            #expect(reloaded.activeDevice?.identifier == "UUID-A", "must not keep a dangling selection")
        }
    }

    @Test("An empty store loads an empty registry rather than crashing")
    func emptyStoreLoadsEmptyRegistry() throws {
        try withIsolatedDefaults { defaults in
            let reloaded = DeviceRegistryStore(defaults: defaults).load()
            #expect(reloaded.count == 0)
            #expect(reloaded.activeDevice == nil)
        }
    }

    @Test("Corrupt persisted data is discarded rather than trusted")
    func corruptDataIsDiscarded() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: "maccar_device_registry")
            let reloaded = DeviceRegistryStore(defaults: defaults).load()
            // A registry we cannot parse is a registry we cannot trust; starting empty is the
            // only safe answer, and the user simply registers again.
            #expect(reloaded.count == 0)
        }
    }

    @Test("Targeting resolves the selected identifier to its CURRENT name after a rename")
    func targetingFollowsRenameViaIdentifier() throws {
        let sidecar = MockSidecarService()
        // The registry selected UUID-B while it was called "Old Name".
        let registry = DeviceRegistry()
        registry.register(makeDevice("UUID-B", name: "Old Name"))
        registry.setActive(identifier: "UUID-B")

        // Sidecar now reports the same identifier under a new name.
        sidecar.reachableDevicesWithIdentityResult = .success([
            SidecarDevice(identifier: "UUID-B", name: "RenamedPad", model: "iPad16,1")
        ])
        let settings = MockSettings(registeredDeviceName: nil, autoConnect: true)
        let watcher = DeviceWatcher(
            sidecar: sidecar,
            virtualDisplay: MockVirtualDisplayService(),
            mirrorManager: MockDisplayMirrorManager(),
            settings: settings,
            usbPresence: MockUSBDevicePresence(isPresent: true),
            registry: registry,
            dispatchesReconnectTicks: false,
            registersSystemObservers: false,
            now: { ManualTestClock().now() },
            sleep: { _ in }
        )

        // Name-keying would have kept "Old Name" and connected to nothing.
        #expect(watcher.resolvedTargetName() == "RenamedPad")
    }

    @Test("Targeting falls back to the stored name when the selected iPad is asleep")
    func targetingFallsBackToStoredNameWhenAbsent() {
        let sidecar = MockSidecarService()
        sidecar.reachableDevicesWithIdentityResult = .success([])  // nothing reachable right now
        let registry = DeviceRegistry()
        registry.register(makeDevice("UUID-B", name: "SleepingPad"))
        registry.setActive(identifier: "UUID-B")

        let watcher = DeviceWatcher(
            sidecar: sidecar,
            virtualDisplay: MockVirtualDisplayService(),
            mirrorManager: MockDisplayMirrorManager(),
            settings: MockSettings(registeredDeviceName: nil, autoConnect: true),
            usbPresence: MockUSBDevicePresence(isPresent: true),
            registry: registry,
            dispatchesReconnectTicks: false,
            registersSystemObservers: false,
            now: { ManualTestClock().now() },
            sleep: { _ in }
        )

        // The iPad must still be waited for rather than silently forgotten.
        #expect(watcher.resolvedTargetName() == "SleepingPad")
    }

    @Test("Refreshing the registry adopts newly seen devices and persists the result")
    func refreshAdoptsNewDevices() throws {
        try withIsolatedDefaults { defaults in
            let sidecar = MockSidecarService()
            sidecar.reachableDevicesWithIdentityResult = .success([
                SidecarDevice(identifier: "UUID-A", name: "DeskPad", model: "iPad16,1"),
                SidecarDevice(identifier: "UUID-B", name: "TravelPad", model: "iPad16,2")
            ])
            let registry = DeviceRegistry()
            let store = DeviceRegistryStore(defaults: defaults)
            let watcher = DeviceWatcher(
                sidecar: sidecar,
                virtualDisplay: MockVirtualDisplayService(),
                mirrorManager: MockDisplayMirrorManager(),
                settings: MockSettings(registeredDeviceName: nil, autoConnect: true),
                usbPresence: MockUSBDevicePresence(isPresent: true),
                registry: registry,
                registryStore: store,
                dispatchesReconnectTicks: false,
                registersSystemObservers: false,
                now: { ManualTestClock().now() },
                sleep: { _ in }
            )

            watcher.refreshRegisteredDevices()
            #expect(registry.count == 2)

            // What the menu showed survives a relaunch.
            let reloaded = DeviceRegistryStore(defaults: defaults).load()
            #expect(reloaded.count == 2)
        }
    }

    @Test("Launch adoption registers only the configured iPad, leaving others for the prompt")
    func adoptionRegistersOnlyConfiguredDevice() throws {
        try withIsolatedDefaults { defaults in
            let sidecar = MockSidecarService()
            sidecar.reachableDevicesWithIdentityResult = .success([
                SidecarDevice(identifier: "UUID-A", name: "DeskPad", model: "iPad16,1"),
                SidecarDevice(identifier: "UUID-B", name: "TravelPad", model: "iPad16,2")
            ])
            let registry = DeviceRegistry()
            let watcher = DeviceWatcher(
                sidecar: sidecar,
                virtualDisplay: MockVirtualDisplayService(),
                mirrorManager: MockDisplayMirrorManager(),
                // The user configured "TravelPad" back when identity was a typed name.
                settings: MockSettings(registeredDeviceName: "TravelPad", autoConnect: true),
                usbPresence: MockUSBDevicePresence(isPresent: true),
                registry: registry,
                registryStore: DeviceRegistryStore(defaults: defaults),
                dispatchesReconnectTicks: false,
                registersSystemObservers: false,
                now: { ManualTestClock().now() },
                sleep: { _ in }
            )

            watcher.adoptActiveDeviceIfUnregistered()

            // Exactly one: adopting both would pre-empt the Wave-4 prompt for the other iPad.
            #expect(registry.count == 1)
            #expect(registry.activeDevice?.identifier == "UUID-B")
        }
    }

    @Test("Adoption does nothing once the registry has devices")
    func adoptionIsIgnoredWhenRegistryPopulated() throws {        try withIsolatedDefaults { defaults in
            let sidecar = MockSidecarService()
            sidecar.reachableDevicesWithIdentityResult = .success([
                SidecarDevice(identifier: "UUID-A", name: "DeskPad", model: ""),
                SidecarDevice(identifier: "UUID-B", name: "Other", model: "")
            ])
            let registry = DeviceRegistry()
            registry.register(SidecarDevice(identifier: "UUID-A", name: "DeskPad", model: ""))
            let watcher = DeviceWatcher(
                sidecar: sidecar,
                virtualDisplay: MockVirtualDisplayService(),
                mirrorManager: MockDisplayMirrorManager(),
                settings: MockSettings(registeredDeviceName: "Other", autoConnect: true),
                usbPresence: MockUSBDevicePresence(isPresent: true),
                registry: registry,
                registryStore: DeviceRegistryStore(defaults: defaults),
                dispatchesReconnectTicks: false,
                registersSystemObservers: false,
                now: { ManualTestClock().now() },
                sleep: { _ in }
            )

            watcher.adoptActiveDeviceIfUnregistered()
            #expect(registry.count == 1, "existing registrations must never be added to here")
        }
    }

    @Test("Adoption never guesses: an unmatched configured name leaves the registry empty")
    func adoptionRequiresExactNameMatch() throws {
        try withIsolatedDefaults { defaults in
            let sidecar = MockSidecarService()
            sidecar.reachableDevicesWithIdentityResult = .success([
                SidecarDevice(identifier: "UUID-A", name: "DeskPad", model: "iPad16,1")
            ])
            let registry = DeviceRegistry()
            let watcher = DeviceWatcher(
                sidecar: sidecar,
                virtualDisplay: MockVirtualDisplayService(),
                mirrorManager: MockDisplayMirrorManager(),
                // Configured for an iPad that is not the one attached.
                settings: MockSettings(registeredDeviceName: "SomeOtherPad", autoConnect: true),
                usbPresence: MockUSBDevicePresence(isPresent: true),
                registry: registry,
                registryStore: DeviceRegistryStore(defaults: defaults),
                dispatchesReconnectTicks: false,
                registersSystemObservers: false,
                now: { ManualTestClock().now() },
                sleep: { _ in }
            )

            watcher.adoptActiveDeviceIfUnregistered()

            // "The only device present" must NOT be adopted: that would silently register an iPad
            // the user never chose and suppress the Wave-4 prompt.
            #expect(registry.count == 0)
        }
    }

    @Test("Adoption is a no-op on a fresh install with no configured name")
    func adoptionSkipsFreshInstall() throws {        try withIsolatedDefaults { defaults in
            let sidecar = MockSidecarService()
            sidecar.reachableDevicesWithIdentityResult = .success([
                SidecarDevice(identifier: "UUID-A", name: "DeskPad", model: "")
            ])
            let registry = DeviceRegistry()
            let watcher = DeviceWatcher(
                sidecar: sidecar,
                virtualDisplay: MockVirtualDisplayService(),
                mirrorManager: MockDisplayMirrorManager(),
                settings: MockSettings(registeredDeviceName: nil, autoConnect: true),
                usbPresence: MockUSBDevicePresence(isPresent: true),
                registry: registry,
                registryStore: DeviceRegistryStore(defaults: defaults),
                dispatchesReconnectTicks: false,
                registersSystemObservers: false,
                now: { ManualTestClock().now() },
                sleep: { _ in }
            )

            watcher.adoptActiveDeviceIfUnregistered()
            #expect(registry.count == 0, "a fresh install has nothing to migrate; the prompt decides")
        }
    }
}
