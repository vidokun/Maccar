import Foundation

/// Resolves the one name the menu should show as the target iPad.
///
/// The app briefly had two stores and read only one of them: registering from the "New iPad
/// detected" dialog wrote `DeviceRegistry`, while the menu rendered
/// `MaccarSettings.registeredDeviceName`. The visible result was a menu that said "No iPad
/// Registered" above a submenu listing the iPad that had just been registered.
///
/// The registry is the source of truth. The legacy name is consulted only while the registry is
/// still empty, which is the upgrade window before a device is registered again — and that is the
/// only reason this type knows about it at all.
public enum MenuTargetResolver {

    /// The target name to display, or `nil` when nothing is registered anywhere.
    ///
    /// - Parameters:
    ///   - registryActiveName: `DeviceRegistry.activeDevice?.name`, or `nil` when no device is
    ///     active.
    ///   - legacyName: the pre-registry `registeredDeviceName` string, still populated for users
    ///     upgrading from v1.4.x.
    ///   - registryHasDevices: whether the registry holds any device. Once it does, the registry is
    ///     authoritative even when nothing is active — falling back then would resurrect the drift
    ///     this resolver exists to remove.
    public static func targetName(
        registryActiveName: String?,
        legacyName: String?,
        registryHasDevices: Bool = false
    ) -> String? {
        if let active = normalized(registryActiveName) { return active }
        // A registry with devices but no active selection is a real state ("no iPad selected"),
        // not an invitation to read a stale string.
        if registryHasDevices { return nil }
        return normalized(legacyName)
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
