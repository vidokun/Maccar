import Foundation
import CMaccarBridge

/// A device Sidecar has paired with, identified by its stable `identifier`.
///
/// Keyed by identifier rather than name because names are neither unique nor stable — two iPads
/// can share a name, and either can be renamed on the device. `identifier` was verified stable
/// across a physical unplug/replug on 2026-11-16 (PRD U4), which is what makes a multi-device
/// registry expressible at all.
public struct SidecarDevice: Sendable, Hashable {
    /// Sidecar's NSUUID for this device, serialised as a string.
    public let identifier: String
    /// The iPad's user-visible name. Display only; never used for matching.
    public let name: String
    /// e.g. `iPad16,1`. Empty when Sidecar does not report one.
    public let model: String

    public init(identifier: String, name: String, model: String) {
        self.identifier = identifier
        self.name = name
        self.model = model
    }

    /// A stable, human-readable label for menus: the name, with the model as a disambiguator
    /// when two devices would otherwise look identical.
    public func displayLabel(disambiguatingAmong others: [SidecarDevice]) -> String {
        let duplicates = others.filter { $0.name == name && $0.identifier != identifier }
        guard !duplicates.isEmpty, !model.isEmpty else { return name }
        return "\(name) (\(model))"
    }
}

public extension SidecarDevice {
    /// Builds a device from the bridge's dictionary form. Returns `nil` when the identifier is
    /// absent, because a device without a stable identity must never be published as if it had one.
    init?(_ rawDictionary: [String: Any]) {
        guard let identifier = rawDictionary["identifier"] as? String, !identifier.isEmpty else {
            return nil
        }
        self.init(
            identifier: identifier,
            name: rawDictionary["name"] as? String ?? "",
            model: rawDictionary["model"] as? String ?? ""
        )
    }
}
