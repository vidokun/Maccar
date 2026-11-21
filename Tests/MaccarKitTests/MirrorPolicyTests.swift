import Foundation
import Testing
@testable import MaccarKit

/// The rule, stated once: **make the picture work, then leave it alone.**
///
/// The virtual display is not a desktop anybody fills — it is a rendering target. So an iPad
/// that is not mirroring it is showing nothing, whatever else is attached to the Mac. And a
/// mirror that already works needs no correction: re-applying it would only fight a user who
/// has just changed the arrangement.
///
/// | Mirror already applied? | autoMirror | Decision |
/// |---|---|---|
/// | no | on | mirror |
/// | yes | on | leave alone |
/// | either | off | leave alone |
@Suite("Mirror Policy Tests")
struct MirrorPolicyTests {

    @Test("Nothing mirrored: apply it")
    func unmirroredApplies() {
        #expect(MirrorPolicy.decide(isMirrorAlreadyApplied: false, autoMirror: true) == .mirrorRequired)
    }

    @Test("Already mirrored: change nothing")
    func alreadyMirroredDoesNothing() {
        #expect(MirrorPolicy.decide(isMirrorAlreadyApplied: true, autoMirror: true) == .leaveUserArrangementAlone)
    }

    @Test("A user who turned auto-mirror off is respected, mirrored or not")
    func autoMirrorOffIsAlwaysRespected() {
        // Overriding an explicit switch would be worse than the bug being fixed: the user
        // would have no way to tell why their setting was ignored.
        for mirrored in [true, false] {
            #expect(
                MirrorPolicy.decide(isMirrorAlreadyApplied: mirrored, autoMirror: false) == .leaveUserArrangementAlone,
                "mirrored=\(mirrored)"
            )
        }
    }

    @Test("SAFETY KPI: an unmirrored iPad is always mirrored")
    func unmirroredIPadIsAlwaysMirrored() {
        // The product promise. An extended iPad has no desktop to show, because nothing
        // fills the virtual display it would extend beside. This is the property a
        // display-count rule violated on a cold start with a monitor attached, measured on
        // hardware on 2026-11-21.
        #expect(MirrorPolicy.decide(isMirrorAlreadyApplied: false, autoMirror: true) == .mirrorRequired)
    }

    @Test("The decision never flaps: the same inputs always give the same answer")
    func decisionIsDeterministic() {
        let first = MirrorPolicy.decide(isMirrorAlreadyApplied: false, autoMirror: true)
        let second = MirrorPolicy.decide(isMirrorAlreadyApplied: false, autoMirror: true)
        #expect(first == second)
    }
}
