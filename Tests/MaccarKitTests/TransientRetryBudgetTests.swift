import Foundation
import Testing
@testable import MaccarKit

/// Field log 2026-11-19 16:00, one cable insertion, v1.5.0 (official build):
///
///     15:59:57  attach
///     16:00:05  connect -> FAILED  "The device was not found" (-200, transient)
///     16:00:11  retry   -> FAILED  (-200, transient)   <- 11.8 s, already past any 10 s guess
///     16:00:11  auto-connect SUPPRESSED
///     16:00:35  manual  -> SUCCEEDED (0.85 s)
///
/// After a long idle the iPad was fine; Sidecar was not ready for ~35 s. Two attempts inside
/// 12 s could never have worked, and the app then gave up — on a headless Mac the only way back
/// was a remote session, which is the situation Maccar exists to avoid.
///
/// The fix is one more attempt with a much longer wait, not a longer first wait: the second
/// attempt in the log was already at 11.8 s and still failed.
@Suite("Transient Retry Budget Tests")
struct TransientRetryBudgetTests {

    /// The error Sidecar raises while it is still coming up. Code and wording both matter —
    /// see `isTransportSettlingError`.
    private func notFound() -> NSError {
        NSError(domain: "SidecarErrorDomain", code: -200,
                userInfo: [NSLocalizedDescriptionKey: "The device was not found"])
    }

    /// An error the app must never retry: a refusal latches immediately.
    private func refusal() -> NSError {
        NSError(domain: "SidecarErrorDomain", code: -100,
                userInfo: [NSLocalizedDescriptionKey: "The device was refused"])
    }

    @Test("A snapshot from one insertion grants three attempts, matching the measured need")
    func budgetCoversLongIdle() {
        // Two attempts can never reach 35 s (4 s settle + 5 s + 5 s = 14 s at best). A third
        // with a long final wait is what the field log says was required.
        #expect(DeviceWatcherBackoff.transientRetryBudget >= 3,
                "two attempts cannot cover the measured ~35 s Sidecar warm-up")
    }

    @Test("The final retry waits long enough to clear the measured 35 s warm-up")
    func finalRetryWaitsLongEnough() {
        #expect(DeviceWatcherBackoff.transientRetrySecondsFinal >= 15,
                "the last attempt must land near the measured success point, not 5 s later")
    }

    @Test("Transient failures keep retrying until the budget is spent, then latch")
    func exhaustsBudgetThenLatches() {
        var state = DeviceWatcherBackoff.Tracker()
        var attempts = 0
        let start = Date(timeIntervalSince1970: 1000)

        // Walk the failure path exactly as `recordFailure` would for a settling error.
        for step in 0..<5 {
            let at = start.addingTimeInterval(Double(step) * 40)
            let outcome = state.recordFailure(error: notFound(), at: at)
            if outcome.isAutoRetryPaused { break }
            attempts += 1
        }

        #expect(attempts >= 3, "should allow at least three transient attempts before latching")
        #expect(state.isAutoRetryPaused, "it must still latch eventually — this is not an infinite loop")
    }

    @Test("A refusal still latches immediately, without spending budget")
    func refusalStillLatchesImmediately() {
        var state = DeviceWatcherBackoff.Tracker()
        let outcome = state.recordFailure(error: refusal(), at: Date(timeIntervalSince1970: 1000))

        #expect(outcome.isAutoRetryPaused,
                "a real refusal must never be retried; zero-popup policy depends on it")
    }

    @Test("The interval grows across attempts so the last one waits longest")
    func intervalsEscalate() {
        var state = DeviceWatcherBackoff.Tracker()
        var intervals: [TimeInterval] = []
        let start = Date(timeIntervalSince1970: 1000)

        for step in 0..<4 {
            let outcome = state.recordFailure(error: notFound(), at: start.addingTimeInterval(Double(step) * 60))
            if outcome.isAutoRetryPaused { break }
            intervals.append(outcome.interval)
        }

        #expect(intervals.count >= 2)
        #expect(intervals.last! > intervals.first!,
                "the final wait must be longer than the first, got \(intervals)")
    }

    @Test("A successful connect clears the budget back to full")
    func successRestoresBudget() {
        var state = DeviceWatcherBackoff.Tracker()
        _ = state.recordFailure(error: notFound(), at: Date(timeIntervalSince1970: 1000))
        state.resetForConnected()

        let outcome = state.recordFailure(error: notFound(), at: Date(timeIntervalSince1970: 2000))
        #expect(!outcome.isAutoRetryPaused, "after a good session the full budget must be available again")
    }
}
