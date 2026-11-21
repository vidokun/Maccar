import Foundation
import Testing
@testable import MaccarKit

/// There is one rule and no switch: **make the picture work, then leave it alone.**
///
/// The switch that used to exist here ("Auto-Mirroring") had two positions, and only one of
/// them was ever useful. The virtual display is where the windows live and the iPad is the
/// screen they are shown on, so an unmirrored iPad is a second, empty desktop while the real
/// windows sit on a display nobody can see. Removing the switch removed that state.
@Suite("Mirror Policy Tests")
struct MirrorPolicyTests {

    @Test("Nothing mirrored: apply it")
    func unmirroredApplies() {
        #expect(MirrorPolicy.decide(isMirrorAlreadyApplied: false) == .mirrorRequired)
    }

    @Test("Already mirrored: change nothing")
    func alreadyMirroredDoesNothing() {
        // Re-applying a working mirror tears it down and rebuilds it, which moves the user's
        // screen for no reason — and was once the difference between a working app and a
        // resolution-switch loop.
        #expect(MirrorPolicy.decide(isMirrorAlreadyApplied: true) == .leaveUserArrangementAlone)
    }

    @Test("SAFETY KPI: an unmirrored iPad is always mirrored")
    func unmirroredIPadIsAlwaysMirrored() {
        // The product promise, stated as its own test. The virtual display is where the
        // windows are; without mirroring, nobody can see them.
        #expect(MirrorPolicy.decide(isMirrorAlreadyApplied: false) == .mirrorRequired)
    }

    @Test("The decision never flaps: the same input always gives the same answer")
    func decisionIsDeterministic() {
        #expect(
            MirrorPolicy.decide(isMirrorAlreadyApplied: false)
                == MirrorPolicy.decide(isMirrorAlreadyApplied: false)
        )
    }

    @Test("The rule has no user-configurable escape hatch")
    func ruleTakesNoUserPreference() {
        // Guards the removal itself. If a preference is ever reintroduced, this test fails and
        // the change has to be argued for rather than slipped in: the only useful state is
        // "mirrored", so a switch can only offer states that do not work.
        #expect(MirrorPolicy.decide(isMirrorAlreadyApplied: false) == .mirrorRequired)
    }
}
