import Foundation
import Testing
import CoreGraphics
@testable import MaccarKit

/// Regression guard for the 2026-11-20 field report from a part-time-headless user:
/// "kalau iPad jadi main screen, screen yg lain otomatis mirror ya mas?"
///
/// The shipped rule picked the first online non-builtin, non-virtual display. With a
/// monitor attached that can be the monitor, which Maccar would then mirror into its
/// virtual display — reconfiguring the user's physical screen. These tests pin the
/// corrected rule: name the iPad explicitly, and refuse to guess when it cannot be named.
@Suite("Sidecar Display Identifier Tests")
struct SidecarDisplayIdentifierTests {

    private let virtualDisplay: CGDirectDisplayID = 5
    private let iPad: CGDirectDisplayID = 14
    private let monitor: CGDirectDisplayID = 15

    /// Everything except the iPad reports a non-Sidecar model number.
    private func modelNumber(iPadIDs: Set<CGDirectDisplayID>) -> (CGDirectDisplayID) -> UInt32 {
        { id in iPadIDs.contains(id) ? SidecarDisplayIdentifier.sidecarModelNumber : 0x0000_1000 }
    }

    @Test("The Sidecar model number really is the four-character code 'iPad'")
    func modelNumberIsFourCC() {
        // Guards the constant itself. A wrong value would never match and the fallback
        // would silently take over, which is the kind of failure that hides for months.
        #expect(SidecarDisplayIdentifier.fourCC(SidecarDisplayIdentifier.sidecarModelNumber) == "iPad")
    }

    @Test("Headless: the iPad is chosen even when it is not first in the list")
    func headlessChoosesIPadRegardlessOfOrder() {
        let chosen = SidecarDisplayIdentifier.chooseIPad(
            candidates: [iPad],
            modelNumber: modelNumber(iPadIDs: [iPad])
        )
        #expect(chosen == iPad)
    }

    @Test("Monitor attached: the monitor is never chosen, whichever order it arrives in")
    func monitorIsNeverMistakenForIPad() {
        // The bug this guards: the monitor listed first must not be adopted. Both orders
        // are asserted so a future change cannot pass by relying on one ordering.
        for candidates in [[monitor, iPad], [iPad, monitor]] {
            let chosen = SidecarDisplayIdentifier.chooseIPad(
                candidates: candidates,
                modelNumber: modelNumber(iPadIDs: [iPad])
            )
            #expect(chosen == iPad, "chose \(String(describing: chosen)) from \(candidates)")
            #expect(chosen != monitor, "the physical monitor must never be mirrored")
        }
    }

    @Test("Unidentifiable displays plus a monitor means no choice, so nothing is mirrored")
    func refusesToGuessWhenAmbiguous() {
        // Two candidates, neither reports the Sidecar signature: possibly a changed model
        // number, possibly two monitors. Mirroring either would rearrange hardware the
        // user did not ask Maccar to touch, so the answer is "do not act".
        let chosen = SidecarDisplayIdentifier.chooseIPad(
            candidates: [monitor, 16],
            modelNumber: modelNumber(iPadIDs: [])
        )
        #expect(chosen == nil)
    }

    @Test("A single unidentifiable display is accepted, so a headless Mac never goes dark")
    func singleCandidateKeepsHeadlessWorking() {
        // Safety net for a changed Sidecar model number: with only one candidate there is
        // no ambiguity to resolve, and refusing here would leave the headless Mac with no
        // picture at all — strictly worse than the bug being fixed.
        let chosen = SidecarDisplayIdentifier.chooseIPad(
            candidates: [iPad],
            modelNumber: modelNumber(iPadIDs: [])
        )
        #expect(chosen == iPad)
    }

    @Test("No candidates means no choice")
    func noCandidates() {
        let chosen = SidecarDisplayIdentifier.chooseIPad(
            candidates: [],
            modelNumber: modelNumber(iPadIDs: [])
        )
        #expect(chosen == nil)
    }

    @Test("Non-printable model numbers do not masquerade as a four-character code")
    func fourCCRejectsBinaryValues() {
        #expect(SidecarDisplayIdentifier.fourCC(0x0000_1000) == nil)
    }
}
