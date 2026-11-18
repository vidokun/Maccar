import Foundation

/// Which devices a manual "register" scan may offer.
///
/// Kept out of the UI layer so the filtering rule has a test: the registry is keyed by Sidecar's
/// stable identifier, and offering an identifier that is already registered would create a second
/// path to a duplicate entry — the exact class of bug this rebuild removes.
public enum ScanCandidates {

    /// Reachable devices that are not in the registry yet, in Sidecar's order.
    ///
    /// More than one result is not an error: the caller asks which one, because guessing would
    /// register a device the user did not choose.
    public static func unknown(
        reachable: [SidecarDevice],
        registeredIdentifiers: Set<String>
    ) -> [SidecarDevice] {
        reachable.filter { !registeredIdentifiers.contains($0.identifier) }
    }
}
