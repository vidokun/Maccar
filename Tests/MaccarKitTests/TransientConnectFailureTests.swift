import Foundation
import Testing
@testable import MaccarKit

/// D6b regression guard.
///
/// After a replug the app connected 120 ms after observing that the previous Sidecar
/// session ended — and `connect()` failed 43 ms later with "The device was not found".
/// `Sidecar` needs the device to settle first. The manual path already waits via
/// `postDisconnectSettleSeconds`; the automatic session-end path waited for nothing.
///
/// Two independent protections are pinned here:
///   1. a settle window before the *first* automatic attempt after a session ends
///      (prevents the guaranteed transient failure, and costs zero extra popups), and
///   2. a small, bounded retry budget for transport-settling errors, so one unlucky
///      attempt cannot latch auto-connect until a manual press.
///
/// A genuine refusal still latches on first occurrence: DD-6 remains intact.
@Suite("Transient Connect Failure Tests", .serialized)
struct TransientConnectFailureTests {
    private func makeError(_ domain: String = "SidecarErrorDomain", code: Int) -> NSError {
        NSError(domain: domain, code: code, userInfo: nil)
    }

    @Test("Transport-settling Sidecar errors are classified transient, not refusals")
    func transportSettlingErrorsAreTransient() {
        // Codes measured from hardware, 2026-11-16: "The device was not found." is -200 and
        // "The device was disconnected." is -101. Both clear themselves within seconds; a
        // connect on the next attempt succeeds.
        //
        // This test previously asserted -201 for "disconnected" because that code was guessed
        // rather than measured. The guess made the real error look like a refusal, so the gate
        // latched on the first failure and the transient retry never ran.
        #expect(DeviceWatcherBackoff.deviceDisconnectedErrorCode == -101,
                "measured on hardware; -201 was a guess that broke the classification")
        for code in [DeviceWatcherBackoff.deviceNotFoundErrorCode, DeviceWatcherBackoff.deviceDisconnectedErrorCode] {
            #expect(DeviceWatcherBackoff.Tracker.isTransportSettlingError(makeError(code: code)))
        }
        #expect(DeviceWatcherBackoff.Tracker.isTransportSettlingError(
            makeError("com.maccar.sidecar", code: DeviceWatcherBackoff.deviceDisconnectedErrorCode)
        ))
    }

    @Test("Sidecar's settling wording is transient even if the numeric code changes")
    func settlingWordingIsTransientRegardlessOfCode() {
        // Scoped to Sidecar's domain: Apple may renumber its private errors between OS
        // releases, and a renumber must not silently restore the permanent latch.
        for (code, message) in [(-101, "The device was disconnected."), (-200, "The device was not found.")] {
            let error = NSError(domain: "SidecarErrorDomain", code: code,
                                userInfo: [NSLocalizedDescriptionKey: message])
            #expect(DeviceWatcherBackoff.Tracker.isTransportSettlingError(error))
        }
        // But wording from a foreign domain is not ours to interpret.
        let foreign = NSError(domain: "NSURLErrorDomain", code: -101,
                              userInfo: [NSLocalizedDescriptionKey: "The device was disconnected."])
        #expect(!DeviceWatcherBackoff.Tracker.isTransportSettlingError(foreign))
    }

    @Test("Refusals and unknown errors are not transient, so they keep latching immediately")
    func refusalsAreNotTransient() {
        // -100 already has its own recovery path; -302 is an interrupted recovery. Neither
        // improves by waiting, and retrying them would only add popups.
        for code in [-100, -302, -1, -202] {
            #expect(!DeviceWatcherBackoff.Tracker.isTransportSettlingError(makeError(code: code)))
        }
        // A transient code in a foreign domain is not ours to interpret.
        #expect(!DeviceWatcherBackoff.Tracker.isTransportSettlingError(
            makeError("NSURLErrorDomain", code: DeviceWatcherBackoff.deviceNotFoundErrorCode)
        ))
    }

    @Test("A transient failure spends budget instead of latching, and stops when exhausted")
    func transientFailuresSpendBoundedBudget() {
        var tracker = DeviceWatcherBackoff.Tracker()
        let transient = makeError(code: DeviceWatcherBackoff.deviceDisconnectedErrorCode)

        let budget = DeviceWatcherBackoff.transientRetryBudget
        #expect(budget > 0, "A zero budget is the old latch-everything behaviour")

        // The first `budget` transient failures leave auto-retry armed. Only the final granted
        // retry waits long (transientRetrySecondsFinal): the last attempt must land near the
        // measured ~35 s Sidecar warm-up, while earlier ones stay short so an ordinary replug
        // still feels quick. With budget 3 the waits are 5 s, 5 s, 15 s.
        for attempt in 0..<budget {
            let outcome = tracker.recordFailure(error: transient, at: Date())
            #expect(!outcome.isAutoRetryPaused, "Transient attempt \(attempt + 1) must not latch")
            let isFinalGrantedRetry = attempt == budget - 1
            let expected = isFinalGrantedRetry
                ? DeviceWatcherBackoff.transientRetrySecondsFinal
                : DeviceWatcherBackoff.transientRetrySeconds
            #expect(outcome.interval == expected,
                    "attempt \(attempt + 1) should wait \(expected)s, got \(outcome.interval)s")
        }

        // The next one exhausts the budget and latches, so a persistent transient cannot
        // loop forever — DD-6's zero-popup promise is bounded, not abandoned.
        let exhausted = tracker.recordFailure(error: transient, at: Date())
        #expect(exhausted.isAutoRetryPaused)
        #expect(tracker.isAutoRetryPaused)
    }

    @Test("A refusal latches on the first occurrence regardless of remaining budget")
    func refusalLatchesImmediately() {
        var tracker = DeviceWatcherBackoff.Tracker()
        let outcome = tracker.recordFailure(error: makeError(code: -100), at: Date())
        #expect(outcome.isAutoRetryPaused)
        #expect(tracker.isAutoRetryPaused)
    }

    @Test("A successful connect refills the transient budget")
    func successRestoresTransientBudget() {
        var tracker = DeviceWatcherBackoff.Tracker()
        let transient = makeError(code: DeviceWatcherBackoff.deviceDisconnectedErrorCode)

        for _ in 0..<DeviceWatcherBackoff.transientRetryBudget {
            _ = tracker.recordFailure(error: transient, at: Date())
        }
        tracker.resetForConnected()
        #expect(!tracker.isAutoRetryPaused)

        // After a healthy connection, the whole budget is available again.
        let outcome = tracker.recordFailure(error: transient, at: Date())
        #expect(!outcome.isAutoRetryPaused)
    }
}
