import Foundation
import os

/// Whether Maccar may connect to the iPad over Wi-Fi.
///
/// This is a *permission*, not a transport manager. See
/// `.claude/plans/maccar-wireless-mode/index.md` for the measurements; in short:
///
/// - A session created without a wired transport survives the cable being pulled, and Sidecar
///   moves it to USB on its own when the cable returns.
/// - Sidecar does **not** move a wired session to Wi-Fi — proved by pulling the cable on
///   2026-11-21 and watching the screen go dark. That is why this exists.
/// - Reconnecting with no wired transport works when the cable is gone, so Maccar never needs
///   to track which transport is in use; it only needs to know what it may ask for.
///
/// The value is deliberately **in memory only**. A crash, a relaunch, or a restart is always
/// `off`, which is both the user's requirement and the safer default: Wi-Fi is opt-in for one
/// session, and nobody inherits it from a session they cannot remember granting.
public final class WirelessSession: @unchecked Sendable {
    /// The process-wide session. Tests build their own instances so they never share state.
    public static let shared = WirelessSession()

    private let lock = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    /// Always `false` at launch; never persisted.
    public var isEnabled: Bool { lock.withLock { $0 } }

    /// The `wired:` argument for the next connect.
    public var prefersWired: Bool { !isEnabled }

    public func enable() { lock.withLock { $0 = true } }
    public func disable() { lock.withLock { $0 = false } }
}
