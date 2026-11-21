import Foundation
import os

/// Bounds how often a *failing* automatic operation may be retried.
///
/// Written for the 2026-11-21 incident, reproduced on hardware: a resolution switch kept
/// failing, and because each failure changed the reported status the watcher re-ran it on
/// the next tick. The log shows 11 failures per minute, sustained, with the display mode
/// drifting each time. The user could not leave it; only quitting the app stopped it.
///
/// A status change is the wrong signal for "try again". Status changes on failure, so
/// retrying on status change is a loop with nothing to break it. This type makes the retry
/// budget explicit and, crucially, gives it a **terminal** state: once spent, the operation
/// is not retried until something outside it changes.
public final class FailureBackoff: @unchecked Sendable {

    /// Consecutive automatic failures tolerated before the operation stops retrying itself.
    ///
    /// Deliberately small. Each attempt reconfigures a display, so an unbounded retry is not
    /// merely wasteful — it moves the user's screen while they are using it. Two attempts
    /// absorb a genuinely transient cause; anything beyond that is a real fault that belongs
    /// in the log, not in a loop.
    public static let maximumConsecutiveFailures = 2

    private let lock = OSAllocatedUnfairLock(initialState: 0)

    public init() {}

    public var consecutiveFailures: Int { lock.withLock { $0 } }

    /// Whether another automatic attempt may be made.
    public func mayAttempt() -> Bool {
        lock.withLock { $0 < Self.maximumConsecutiveFailures }
    }

    public func recordFailure() {
        lock.withLock { $0 += 1 }
    }

    /// A success clears the budget, so a later unrelated failure gets a fresh start.
    public func recordSuccess() {
        lock.withLock { $0 = 0 }
    }

    /// Clears the budget unconditionally.
    ///
    /// Called from the paths that represent a new user intent — a replug, a manual
    /// reconnect, a settings change. Those are exactly the moments when "try again" is
    /// meaningful, and they are why the terminal state does not leave the app stuck.
    public func reset() {
        lock.withLock { $0 = 0 }
    }
}
