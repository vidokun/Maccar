import Foundation

/// Persists a `DeviceRegistry` between launches.
///
/// Kept apart from `DeviceRegistry` (a pure value container) so the registry can be tested
/// without touching `UserDefaults`, and so a future storage change does not reach into the
/// in-memory model.
///
/// `@unchecked Sendable` for the same reason as `MaccarSettings`: `UserDefaults` is not marked
/// `Sendable`, but this type only reads and writes through it and adds no shared mutable state.
public struct DeviceRegistryStore: @unchecked Sendable {
    internal static let storageKey = "maccar_device_registry"

    private struct Payload: Codable, Sendable {
        struct Entry: Codable, Sendable {
            let identifier: String
            let name: String
            let model: String
        }

        let devices: [Entry]
        let activeIdentifier: String?
    }

    private let defaults: UserDefaults

    /// The store the running app writes through. Tests pass an isolated `UserDefaults` instead.
    public static let shared = DeviceRegistryStore()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Persists the registry's current state in one call, so callers cannot save devices and the
    /// selection out of step with each other.
    public func save(_ registry: DeviceRegistry) {
        save(devices: registry.devices, activeIdentifier: registry.activeDevice?.identifier)
    }

    public func save(devices: [SidecarDevice], activeIdentifier: String?) {
        let payload = Payload(
            devices: devices.map { Payload.Entry(identifier: $0.identifier, name: $0.name, model: $0.model) },
            activeIdentifier: activeIdentifier
        )
        guard let data = try? JSONEncoder().encode(payload) else {
            MaccarLogger.shared.warning("DeviceRegistry", "Could not encode the device registry; keeping the previous copy.")
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Reads the persisted registry.
    ///
    /// Unreadable data is discarded rather than partially trusted: a registry we cannot parse is
    /// a registry whose identifiers we cannot vouch for, and connecting to the wrong iPad is worse
    /// than asking the user to register again. `DeviceRegistry.restore` then re-derives the active
    /// device, so a stale selection can never dangle.
    public func load() -> DeviceRegistry {
        let registry = DeviceRegistry()
        guard let data = defaults.data(forKey: Self.storageKey) else { return registry }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            MaccarLogger.shared.warning("DeviceRegistry", "Discarding unreadable device registry data.")
            return registry
        }
        registry.restore(
            devices: payload.devices.map {
                SidecarDevice(identifier: $0.identifier, name: $0.name, model: $0.model)
            },
            activeIdentifier: payload.activeIdentifier
        )
        return registry
    }
}
