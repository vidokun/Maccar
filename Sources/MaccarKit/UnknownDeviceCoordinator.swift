import Foundation
import os

/// Detects iPads that are reachable but not registered, and decides when to ask about them.
///
/// The prompt must be rare. A `connect()` is not involved here, so a prompt cannot raise an Apple
/// popup — but asking on every 5 s poll would be its own kind of hostile. The rules (DD-4):
///
/// - Ask only about a device absent from the registry.
/// - Ask at most **once per identifier per session**; a dismissal survives for the session only,
///   so a future replug may ask again rather than being silenced forever.
/// - Never ask about the device Maccar is already connected to or configured for.
///
/// Session-scoped by construction: the state lives in this instance and is never written to disk.
public final class UnknownDeviceCoordinator: @unchecked Sendable {
    private struct State: Sendable {
        /// Identifiers the user dismissed this session.
        var dismissed: Set<String> = []
        /// Identifiers already offered this session, whether accepted or dismissed, so one
        /// attach event cannot produce two prompts.
        var offered: Set<String> = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// The device to ask about, or `nil` when there is nothing new to ask.
    ///
    /// `reachable` is what Sidecar reports: devices it has *paired with*, over USB **or Wi-Fi**.
    /// That is not the same set as devices that are plugged in, so `attachedIdentifiers` narrows
    /// the offer to hardware that is physically present. Without it a headless Mac raises a
    /// registration prompt for an iPad it cannot connect to — `connect(wired:)` would refuse and
    /// the prompt would be unanswerable in any useful way.
    ///
    /// `registeredIdentifiers` is the registry's contents; `currentTargetName` is what Maccar is
    /// already pointed at by name, which covers the pre-registry era where identity was typed in.
    public func nextUnknownDevice(
        reachable: [SidecarDevice],
        registeredIdentifiers: Set<String>,
        currentTargetName: String? = nil,
        attachedIdentifiers: Set<String>? = nil
    ) -> SidecarDevice? {
        let normalizedTarget = currentTargetName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return lock.withLock { state in
            for device in reachable {
                if registeredIdentifiers.contains(device.identifier) { continue }
                // Not plugged in: Sidecar still lists it because it was paired somewhere, but
                // offering it would produce a prompt for hardware that cannot connect.
                if let attached = attachedIdentifiers, !attached.contains(device.identifier) { continue }
                if state.offered.contains(device.identifier) { continue }
                if let target = normalizedTarget, !target.isEmpty,
                   device.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target {
                    // The user typed this iPad's name before the registry existed; prompting them
                    // to register the device they already configured would be noise.
                    continue
                }
                state.offered.insert(device.identifier)
                return device
            }
            return nil
        }
    }

    /// Records that the user declined this device for the rest of the session.
    public func dismiss(identifier: String) {
        lock.withLock { $0.dismissed.insert(identifier) }
    }

    /// Clears a dismissal and the "already offered" mark for one device.
    ///
    /// Needed because "Forget" is the inverse of register: a user who forgets a device has said
    /// "I do not know this iPad any more", so the prompt must be able to ask about it again. Without
    /// this, a device dismissed earlier in the session would stay silently ignored even after the
    /// user explicitly removed it from the registry.
    public func clearDismissal(identifier: String) {
        lock.withLock { state in
            state.dismissed.remove(identifier)
            state.offered.remove(identifier)
        }
    }

    /// Whether the user has declined this device during this session.
    public func isDismissed(identifier: String) -> Bool {
        lock.withLock { $0.dismissed.contains(identifier) }
    }

    /// Resets the session, as a fresh launch would. Provided for tests and for an explicit
    /// "ask me again" action; nothing calls it implicitly.
    public func resetSession() {
        lock.withLock { $0 = State() }
    }
}
