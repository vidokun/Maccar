import Foundation

internal enum DeviceWatcherBackoff {
    static let deviceNotFoundErrorCode: Int = -200
    /// Sidecar's "The device was disconnected." — measured in the field, not guessed:
    /// `Connect failure detail ... domain=SidecarErrorDomain code=-101`. This is the error that
    /// a replug produces while Sidecar is still settling; the same call succeeds seconds later.
    ///
    /// An earlier revision guessed `-201` here, so the real error was classified as a refusal,
    /// latched the gate on the first failure, and the transient retry never ran.
    static let deviceDisconnectedErrorCode: Int = -101
    /// The message Sidecar attaches to the settling errors. Used as a secondary signal so a
    /// future code change on Apple's side cannot silently re-break the classification.
    static let transportSettlingMessageTokens = ["was disconnected", "was not found", "not reachable"]
    static let knownSidecarDomains: Set<String> = ["SidecarErrorDomain", "com.maccar.sidecar"]
    static let nonEscalatingFailureSeconds: TimeInterval = 20.0
    static let defaultSeconds: TimeInterval = 4.0
    static let reconnectSeconds: TimeInterval = 2.0
    /// How long to let Sidecar settle before the first automatic attempt after an active
    /// session ends. The field log shows that attempt running 120 ms after "Active Sidecar
    /// session ended" and failing 43 ms later; the manual path already waits via
    /// `postDisconnectSettleSeconds`, the automatic path waited for nothing.
    static let sessionEndSettleSeconds: TimeInterval = 1.0
    /// Extra automatic attempts granted to *transport-settling* failures only.
    ///
    /// Each failed `connect()` raises a Sidecar popup, so this is a budget to absorb a slow
    /// start, not a retry loop. It was 1 (two attempts total) until the field log of
    /// 2026-11-19 showed that is not enough after a long idle: a single insertion at 15:59:57
    /// failed at 6.5 s **and** at 11.8 s, then the app gave up — while a manual press at 37 s
    /// succeeded in 0.85 s. On a headless Mac the only way back was a remote session, which is
    /// the situation Maccar exists to avoid.
    ///
    /// Three attempts with an escalating wait reach ~35 s, the measured warm-up point. The
    /// worst case costs one extra popup when the device is genuinely gone; `attemptReachableConnect`
    /// still gates every attempt on physical presence, so an unplugged iPad spends no budget.
    static let transientRetryBudget: Int = 3

    /// Wait before the first retry. Short, because a replug that only needed a moment should
    /// not feel slow.
    static let transientRetrySeconds: TimeInterval = 5.0

    /// Wait before the *last* retry, when the budget is nearly spent.
    ///
    /// The measured Sidecar warm-up after a long idle is ~35 s; 15 s here lands the final attempt
    /// near that point instead of 5 s later, which the log already proved too early.
    static let transientRetrySecondsFinal: TimeInterval = 15.0
    /// How long to wait after a USB attach before the first `connect()`.
    ///
    /// This does **not** need to outlast Sidecar's slowest start. The decisive factor turned out
    /// to be the *absence* of a preceding `disconnect()`, not elapsed time: with a teardown the
    /// first connect failed even at 23 s, and without one it succeeded at 9.4 s. Four seconds is
    /// simply long enough for the USB enumeration to settle; `transientRetryBudget` covers the
    /// rest if it is not.
    static let usbAttachSettleSeconds: TimeInterval = 4.0

    struct FailureOutcome: Equatable, Sendable {
        let interval: TimeInterval
        let consecutiveNotFoundCount: Int
        /// Whether this failure latches the auto-connect gate shut.
        let isAutoRetryPaused: Bool
    }

    /// The auto-connect gate. Under the strict zero-popup policy (DD-6) a failed
    /// `connect()` normally latches the gate shut: `SidecarDisplayAgent` raises a popup on
    /// *every* failed connect, so retrying an unconnectable device can only add popups.
    ///
    /// The one exception is a *transport-settling* failure (`The device was not found` /
    /// `The device was disconnected`): those clear themselves within a few seconds, and
    /// latching on them turned a sub-second hiccup into a manual intervention. They are
    /// granted a small fixed budget (`transientRetryBudget`) and latch once it is spent.
    struct Tracker: Sendable {
        private(set) var lastAttemptTime: Date = .distantPast
        private(set) var interval: TimeInterval = DeviceWatcherBackoff.defaultSeconds
        private(set) var consecutiveNotFoundCount: Int = 0
        private(set) var isAutoRetryPaused: Bool = false
        private(set) var transientFailuresRemaining: Int = DeviceWatcherBackoff.transientRetryBudget

        static func isDeviceNotFoundError(_ error: Error) -> Bool {
            let nsError = error as NSError
            return DeviceWatcherBackoff.knownSidecarDomains.contains(nsError.domain)
                && nsError.code == DeviceWatcherBackoff.deviceNotFoundErrorCode
        }

        /// Whether the device is merely still settling rather than genuinely refusing.
        /// Only errors in our own Sidecar domains qualify: a matching code from a foreign
        /// domain is not ours to interpret, and treating it as retryable would spend the
        /// budget on a bug we do not understand.
        static func isTransportSettlingError(_ error: Error) -> Bool {
            let nsError = error as NSError
            guard DeviceWatcherBackoff.knownSidecarDomains.contains(nsError.domain) else { return false }
            if nsError.code == DeviceWatcherBackoff.deviceNotFoundErrorCode
                || nsError.code == DeviceWatcherBackoff.deviceDisconnectedErrorCode {
                return true
            }
            // Secondary signal, scoped to Sidecar's own domain. The codes above were once
            // guessed (-201 instead of the measured -101) and the consequence was a
            // permanently latched gate, so matching Sidecar's wording keeps the bounded retry
            // working if Apple renumbers. It deliberately cannot match another domain's error.
            let message = nsError.localizedDescription.lowercased()
            return DeviceWatcherBackoff.transportSettlingMessageTokens.contains { message.contains($0) }
        }

        /// Every failure either spends transient budget or latches. A refusal latches
        /// immediately and unconditionally; only transport-settling errors may defer it.
        static func evaluateFailure(
            error: Error,
            previousNotFoundCount: Int,
            transientFailuresRemaining: Int
        ) -> FailureOutcome {
            let isSettling = isTransportSettlingError(error)
            let canRetry = isSettling && transientFailuresRemaining > 0
            // The last retry waits much longer: after a long idle Sidecar was measurably not
            // ready until ~35 s, so a short final wait only spends the budget on a doomed
            // attempt. Earlier retries stay short so an ordinary replug still feels quick.
            let attemptsLeftAfterThis = transientFailuresRemaining - 1
            let retryInterval = attemptsLeftAfterThis <= 0
                ? DeviceWatcherBackoff.transientRetrySecondsFinal
                : DeviceWatcherBackoff.transientRetrySeconds
            return FailureOutcome(
                interval: canRetry
                    ? retryInterval
                    : DeviceWatcherBackoff.nonEscalatingFailureSeconds,
                consecutiveNotFoundCount: isDeviceNotFoundError(error) ? max(0, previousNotFoundCount) + 1 : 0,
                isAutoRetryPaused: !canRetry
            )
        }

        func canAutoConnect(at currentTime: Date) -> Bool {
            currentTime.timeIntervalSince(lastAttemptTime) >= interval
        }

        /// Pushes the earliest allowed automatic attempt out by `seconds` without recording a
        /// failure. Used when an active session ends: Sidecar needs the device to settle, and
        /// attempting during that window produces "The device was not found" every time.
        ///
        /// `currentTime` is a parameter rather than `Date()` so the injected clock stays the
        /// single source of time in tests.
        mutating func deferNextAutoConnect(by seconds: TimeInterval, from currentTime: Date) {
            let earliest = max(lastAttemptTime.addingTimeInterval(interval), currentTime)
            lastAttemptTime = earliest.addingTimeInterval(seconds - interval)
        }

        mutating func recordAttempt(at currentTime: Date) {
            lastAttemptTime = currentTime
        }

        mutating func recordFailure(error: Error, at currentTime: Date) -> FailureOutcome {
            let outcome = Self.evaluateFailure(
                error: error,
                previousNotFoundCount: consecutiveNotFoundCount,
                transientFailuresRemaining: transientFailuresRemaining
            )
            lastAttemptTime = currentTime
            interval = outcome.interval
            consecutiveNotFoundCount = outcome.consecutiveNotFoundCount
            isAutoRetryPaused = outcome.isAutoRetryPaused
            if Self.isTransportSettlingError(error), transientFailuresRemaining > 0 {
                transientFailuresRemaining -= 1
            }
            return outcome
        }

        mutating func resetForReconnect() {
            resetClearedState(interval: DeviceWatcherBackoff.reconnectSeconds, preserveLastAttempt: false)
        }

        mutating func resetForConnected() {
            resetClearedState(interval: DeviceWatcherBackoff.defaultSeconds, preserveLastAttempt: true)
        }

        mutating func resetForUSBAttach() {
            resetClearedState(interval: DeviceWatcherBackoff.reconnectSeconds, preserveLastAttempt: false)
        }

        mutating func resetForTargetOrToggleClear() {
            resetClearedState(interval: DeviceWatcherBackoff.defaultSeconds, preserveLastAttempt: false)
        }

        private mutating func resetClearedState(interval: TimeInterval, preserveLastAttempt: Bool) {
            if !preserveLastAttempt {
                lastAttemptTime = .distantPast
            }
            self.interval = interval
            consecutiveNotFoundCount = 0
            isAutoRetryPaused = false
            transientFailuresRemaining = DeviceWatcherBackoff.transientRetryBudget
        }
    }
}
