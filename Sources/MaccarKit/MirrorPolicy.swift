import Foundation
import CoreGraphics

/// Decides whether Maccar may ensure the iPad mirrors the virtual display.
///
/// The product promise is a Mac with no screen of its own that puts a picture somewhere
/// anyway. On such a Mac, mirroring is not a preference — it is the only thing that makes
/// any display show the desktop, and the virtual display is not a desktop anyone fills but a
/// rendering target. So an iPad that is not mirroring it is showing nothing, whatever else
/// is attached. That is why the rule turns on the mirror state rather than on the number of
/// displays.
///
/// This distinction was measured the hard way on 2026-11-21. A rule that read "two or more
/// displays means leave it alone" could not tell these two situations apart, and on a cold
/// start with a monitor attached it left the iPad extended and blank:
///
/// | Situation | Mirror already applied? | Decision |
/// |---|---|---|
/// | Headless, nothing mirrored | no | mirror |
/// | iPad only, nothing mirrored | no | mirror |
/// | Monitor attached, nothing mirrored (cold start) | no | **mirror** |
/// | Monitor attached, iPad already mirroring | yes | leave alone |
public enum MirrorPolicy {

    public enum Decision: Equatable, Sendable {
        /// Ensure the iPad mirrors the virtual display.
        case mirrorRequired
        /// The picture already works: change nothing.
        case leaveUserArrangementAlone
    }

    /// Whether Maccar should apply mirroring.
    ///
    /// - Parameters:
    ///   - isMirrorAlreadyApplied: whether the iPad already mirrors the virtual display.
    ///   - autoMirror: the user's own switch. Checked first: a user who turned auto-mirror
    ///     off has made an explicit choice that no arrangement rule may override, and
    ///     silently overriding it would leave them unable to tell why the setting was
    ///     ignored.
    public static func decide(isMirrorAlreadyApplied: Bool, autoMirror: Bool) -> Decision {
        guard autoMirror else { return .leaveUserArrangementAlone }
        // A working picture is the whole goal. Re-applying it would only fight a user who
        // has just changed the arrangement.
        return isMirrorAlreadyApplied ? .leaveUserArrangementAlone : .mirrorRequired
    }
}
