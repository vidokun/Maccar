import Foundation

/// One row in the "Target iPad Device" menu.
///
/// A pure value so the menu's contents can be tested without AppKit, following the same rule as
/// `DiagnosticsReport`: testable logic lives in `MaccarKit` because there is no `MaccarAppTests`
/// target.
public struct TargetDeviceMenuItem: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Non-interactive text.
        case info
        case separator
        /// Selects the device with `identifier`.
        case select
        /// Removes the device with `identifier` from the registry.
        case forget
    }

    /// Display text, already disambiguated when two iPads share a name.
    public let title: String
    /// What the action acts on. `nil` for informational rows.
    public let identifier: String?
    public let isActive: Bool
    public let isEnabled: Bool
    public let kind: Kind

    public var isSeparator: Bool { kind == .separator }

    public static let separator = TargetDeviceMenuItem(
        title: "", identifier: nil, isActive: false, isEnabled: false, kind: .separator
    )

    public static func info(_ title: String) -> TargetDeviceMenuItem {
        TargetDeviceMenuItem(title: title, identifier: nil, isActive: false, isEnabled: false, kind: .info)
    }
}

/// Builds the contents of the target-device menu from the registry.
///
/// Design decision (agreed 2026-11-16): switching devices is an **explicit menu action**, never
/// something that happens automatically on attach. Every `connect()` can raise an Apple popup, so
/// auto-switching between iPads would produce a stream of them. The menu therefore shows the
/// selection and lets the user change it deliberately.
public enum TargetDeviceMenuBuilder {
    public static func items(
        registryDevices: [SidecarDevice],
        activeIdentifier: String?,
        /// Identifiers Sidecar currently reports. `nil` means "detection unknown", which must not
        /// be rendered as "(not detected)" — that would claim knowledge we do not have.
        reachableIdentifiers: Set<String>? = nil,
        isEnabled: Bool = true,
        fallbackRegisteredName: String? = nil
    ) -> [TargetDeviceMenuItem] {
        guard !registryDevices.isEmpty else {
            // Pre-registry state: the user typed a name and never registered a device. Say so
            // rather than showing an empty submenu with no explanation.
            let title = fallbackRegisteredName.map { "Target: \($0)" } ?? "No iPad Registered"
            return [.info(title)]
        }

        var items: [TargetDeviceMenuItem] = []
        items.append(.info(
            activeIdentifier.flatMap { identifier in
                registryDevices.first { $0.identifier == identifier }
            }.map { "Target: \($0.name)" } ?? "No iPad Selected"
        ))
        items.append(.separator)

        for device in registryDevices {
            let label = device.displayLabel(disambiguatingAmong: registryDevices)
            // Reachability is shown but never blocks selection: an iPad that is asleep is still
            // the user's choice, and Maccar waits for it rather than forgetting it.
            let undetected = reachableIdentifiers.map { !$0.contains(device.identifier) } ?? false
            items.append(TargetDeviceMenuItem(
                title: undetected ? "\(label) (not detected)" : label,
                identifier: device.identifier,
                isActive: device.identifier == activeIdentifier,
                isEnabled: isEnabled,
                kind: .select
            ))
        }

        // Forget is offered for every registered device, including the only one. Gating this on
        // `count > 1` left a user whose single device was the wrong one — the field case: an iPad
        // paired over Wi-Fi, registered by mistake, unable to connect — with no menu action at all.
        // The registry is now the only way to register, so this is the only way to undo it.
        items.append(.separator)
        for device in registryDevices {
            let label = device.displayLabel(disambiguatingAmong: registryDevices)
            items.append(TargetDeviceMenuItem(
                title: "Forget \(label)",
                identifier: device.identifier,
                isActive: false,
                isEnabled: isEnabled,
                kind: .forget
            ))
        }

        return items
    }
}
