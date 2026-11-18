import Foundation
import Testing
@testable import MaccarKit

/// The manual "Register Connected iPad..." action filters what it offers.
///
/// The prompt can be missed — it fires once per attach and stands down while a connect is in
/// flight — so the menu needs a door of its own. It must not become a second way to register the
/// wrong device: only unknown identifiers are candidates, and more than one candidate is an
/// explicit choice rather than a guess.
@Suite("Scan Candidate Tests")
struct ScanCandidateTests {

    private func device(_ name: String, id: String) -> SidecarDevice {
        SidecarDevice(identifier: id, name: name, model: "")
    }

    @Test("An already-registered iPad is not a scan candidate")
    func registeredDeviceIsNotOffered() {
        let candidates = ScanCandidates.unknown(
            reachable: [device("VPad", id: "id-vpad")],
            registeredIdentifiers: ["id-vpad"]
        )
        #expect(candidates.isEmpty, "no second registration path may duplicate an entry")
    }

    @Test("An unattached-but-paired device is still a candidate only if reachable")
    func unknownReachableIsCandidate() {
        let candidates = ScanCandidates.unknown(
            reachable: [device("VPad", id: "id-vpad")],
            registeredIdentifiers: []
        )
        #expect(candidates.map(\.identifier) == ["id-vpad"])
    }

    @Test("Several unknown iPads stay separate so the menu can ask which one")
    func multipleCandidatesAreAllReturned() {
        let candidates = ScanCandidates.unknown(
            reachable: [device("A", id: "a"), device("B", id: "b"), device("C", id: "c")],
            registeredIdentifiers: ["b"]
        )
        #expect(candidates.map(\.identifier) == ["a", "c"],
                "registered entries are filtered out, the rest remain individually selectable")
    }

    @Test("No reachable devices means no candidate and no registration")
    func emptyReachableYieldsNothing() {
        #expect(ScanCandidates.unknown(reachable: [], registeredIdentifiers: []).isEmpty)
    }
}
