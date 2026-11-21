import Foundation
import CoreGraphics

/// Decides whether Maccar may ensure the iPad mirrors the virtual display.
///
/// There is only one answer, and it is why this type has no user switch. The virtual display
/// is where the windows live — it is the Mac's desktop, rendered to a screen that does not
/// physically exist — and mirroring is what puts that desktop on the iPad. Measured on
/// 2026-11-21: every visible application window was on the virtual display, and the iPad's
/// bounds were identical to it because it was mirroring. With mirroring off the iPad would be
/// a second, empty desktop and the windows would remain on a screen nobody can see.
///
/// So an unmirrored iPad is never a useful state, on any desk:
///
/// | Situation | Mirror already applied? | Decision |
/// |---|---|---|
/// | Headless, nothing mirrored | no | mirror |
/// | iPad only, nothing mirrored | no | mirror |
/// | Monitor attached, nothing mirrored (cold start) | no | mirror |
/// | Any of the above, already mirroring | yes | leave alone |
///
/// The "leave alone" row is not politeness: re-applying a working mirror tears it down and
/// rebuilds it, which moves the user's screen for no reason. It also used to be the difference
/// between a working app and a resolution-switch loop, so it is worth stating explicitly.
public enum MirrorPolicy {

    public enum Decision: Equatable, Sendable {
        /// Ensure the iPad mirrors the virtual display.
        case mirrorRequired
        /// The picture already works: change nothing.
        case leaveUserArrangementAlone
    }

    /// Whether Maccar should apply mirroring.
    ///
    /// - Parameter isMirrorAlreadyApplied: whether the iPad already mirrors the virtual
    ///   display. The only input, because there is no legitimate reason to leave it
    ///   unmirrored.
    public static func decide(isMirrorAlreadyApplied: Bool) -> Decision {
        isMirrorAlreadyApplied ? .leaveUserArrangementAlone : .mirrorRequired
    }
}
