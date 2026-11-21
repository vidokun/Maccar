import Foundation
import Testing
@testable import MaccarKit

/// Regression guard for the 2026-11-21 incident, which the user described as "resolusi tiba-tiba
/// berubah sendiri, gak bisa diatur" and which the log shows as 11 failures per minute,
/// sustained, until the app was quit.
///
/// The loop had no braking mechanism: a failed mirror attempt changed the watcher status, a
/// status change scheduled another tick, and the tick re-ran the same doomed attempt. The
/// fix is a bounded, *terminal* budget that only a fresh user intent clears.
@Suite("Failure Backoff Tests")
struct FailureBackoffTests {

    @Test("A fresh budget allows an attempt")
    func freshBudgetAllowsAttempt() {
        let backoff = FailureBackoff()
        #expect(backoff.consecutiveFailures == 0)
        #expect(backoff.mayAttempt())
    }

    @Test("The budget is spent after the allowed failures, then stays closed")
    func budgetClosesAndStaysClosed() {
        // The incident: an unbounded retry reconfigured a display 11 times a minute. Once
        // closed, the budget must stay closed on its own — that is what ends the loop.
        let backoff = FailureBackoff()
        for _ in 0..<FailureBackoff.maximumConsecutiveFailures {
            #expect(backoff.mayAttempt(), "still within budget")
            backoff.recordFailure()
        }
        #expect(!backoff.mayAttempt(), "budget is spent and must not allow another attempt")

        // Repeated checks must not reopen it. A caller polling `mayAttempt()` cannot
        // accidentally resume the loop.
        for _ in 0..<10 {
            #expect(!backoff.mayAttempt())
        }
    }

    @Test("A success clears the budget")
    func successClearsBudget() {
        let backoff = FailureBackoff()
        backoff.recordFailure()
        backoff.recordFailure()
        #expect(!backoff.mayAttempt())
        backoff.recordSuccess()
        #expect(backoff.mayAttempt(), "a working attempt must restore the budget")
    }

    @Test("A user intent clears an exhausted budget")
    func resetClearsBudget() {
        // Replug, manual reconnect and settings changes all call reset(). Without this the
        // terminal state would leave the app permanently unable to retry, which would be a
        // worse bug than the loop.
        let backoff = FailureBackoff()
        backoff.recordFailure()
        backoff.recordFailure()
        #expect(!backoff.mayAttempt())
        backoff.reset()
        #expect(backoff.mayAttempt())
        #expect(backoff.consecutiveFailures == 0)
    }

    @Test("The limit is small enough to stop a loop quickly")
    func limitIsSmall() {
        // Each attempt reconfigures a display, so a generous budget would still move the
        // user's screen repeatedly. Assert the property, not the literal, so the constant
        // can be tuned without silently losing the guarantee.
        #expect(FailureBackoff.maximumConsecutiveFailures <= 3,
                "a larger budget would reconfigure the display too many times before stopping")
        #expect(FailureBackoff.maximumConsecutiveFailures >= 2,
                "a budget of one would not absorb a genuinely transient cause")
    }
}
