import Foundation
import os

/// The set of iPads Maccar may connect to, keyed by Sidecar's stable `identifier`.
///
/// Replaces the single `MaccarSettings.registeredDeviceName` string, which made D3 unfixable:
/// identity was a *name*, so two iPads with the same name were indistinguishable and
/// "Forget device" could not be expressed. `identifier` stability was verified on hardware
/// across a physical unplug/replug (PRD U4), which is what makes this registry possible.
///
/// Deliberately in-memory-only for the prototype path: `DeviceRegistry` is a value type with no
/// I/O, so it can be constructed in tests and handed to `MaccarSettings` for persistence.
public final class DeviceRegistry: @unchecked Sendable {
    private struct State: Sendable {
        var devices: [SidecarDevice] = []
        var activeIdentifier: String?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// The registry the running app uses. Tests construct their own instances instead.
    public static let shared: DeviceRegistry = DeviceRegistryStore.shared.load()

    public init() {}

    /// Every known device, in registration order.
    public var devices: [SidecarDevice] { lock.withLock { $0.devices } }

    /// Devices offered to the user. Currently identical to `devices`; kept as a separate
    /// accessor because Wave 4 will subtract devices the user has hidden.
    public var selectableDevices: [SidecarDevice] { devices }

    public var count: Int { lock.withLock { $0.devices.count } }

    /// The device Maccar connects to, or `nil` when nothing is selected.
    public var activeDevice: SidecarDevice? {
        lock.withLock { state in
            guard let identifier = state.activeIdentifier else { return nil }
            return state.devices.first { $0.identifier == identifier }
        }
    }

    /// Adds a device, or updates it in place when the identifier is already known.
    ///
    /// Registration is idempotent per identifier: a rename on the iPad updates the stored name
    /// without creating a second entry, because the identifier — not the name — is the key.
    public func register(_ device: SidecarDevice) {
        lock.withLock { state in
            if let index = state.devices.firstIndex(where: { $0.identifier == device.identifier }) {
                state.devices[index] = device
            } else {
                state.devices.append(device)
            }
            // The first device registered becomes active, so a fresh install connects somewhere
            // instead of requiring a second action.
            if state.activeIdentifier == nil { state.activeIdentifier = device.identifier }
        }
    }

    /// Removes a device by identifier. Repeatable: forgetting an unknown identifier is a no-op.
    public func forget(identifier: String) {
        lock.withLock { state in
            state.devices.removeAll { $0.identifier == identifier }
            if state.activeIdentifier == identifier {
                state.activeIdentifier = state.devices.first?.identifier
            }
        }
    }

    /// Selects the active device. An unknown identifier is ignored, so a stale menu action
    /// cannot leave the registry pointing at a device that no longer exists.
    public func setActive(identifier: String) {
        lock.withLock { state in
            guard state.devices.contains(where: { $0.identifier == identifier }) else { return }
            state.activeIdentifier = identifier
        }
    }

    /// Restores a persisted registry in one step, keeping the active selection when it still
    /// refers to a known device.
    public func restore(devices: [SidecarDevice], activeIdentifier: String?) {
        lock.withLock { state in
            state.devices = devices
            state.activeIdentifier = devices.contains { $0.identifier == activeIdentifier }
                ? activeIdentifier
                : devices.first?.identifier
        }
    }
}
