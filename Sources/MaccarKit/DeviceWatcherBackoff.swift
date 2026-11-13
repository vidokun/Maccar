import Foundation

internal enum DeviceWatcherBackoff {
    static let deviceNotFoundErrorCode: Int = -200
    static let knownSidecarDomains: Set<String> = ["SidecarErrorDomain", "com.maccar.sidecar"]
    static let nonEscalatingFailureSeconds: TimeInterval = 20.0
    static let defaultSeconds: TimeInterval = 4.0
    static let reconnectSeconds: TimeInterval = 2.0

    struct FailureOutcome: Equatable, Sendable {
        let interval: TimeInterval
        let consecutiveNotFoundCount: Int
    }

    /// The auto-connect gate. Under the strict zero-popup policy (DD-6) a single failed
    /// `connect()` latches the gate shut: `SidecarDisplayAgent` raises a popup on *every*
    /// failed connect, so retrying an unconnectable device can only add popups. Only a
    /// physical replug or an explicit manual reconnect re-arms it.
    struct Tracker: Sendable {
        private(set) var lastAttemptTime: Date = .distantPast
        private(set) var interval: TimeInterval = DeviceWatcherBackoff.defaultSeconds
        private(set) var consecutiveNotFoundCount: Int = 0
        private(set) var isAutoRetryPaused: Bool = false

        static func isDeviceNotFoundError(_ error: Error) -> Bool {
            let nsError = error as NSError
            return DeviceWatcherBackoff.knownSidecarDomains.contains(nsError.domain)
                && nsError.code == DeviceWatcherBackoff.deviceNotFoundErrorCode
        }

        /// Every failure latches the gate. There is deliberately no "should we pause" flag:
        /// the answer is always yes, and a flag would let that invariant drift back open.
        static func evaluateFailure(error: Error, previousNotFoundCount: Int) -> FailureOutcome {
            FailureOutcome(
                interval: DeviceWatcherBackoff.nonEscalatingFailureSeconds,
                consecutiveNotFoundCount: isDeviceNotFoundError(error) ? max(0, previousNotFoundCount) + 1 : 0
            )
        }

        func canAutoConnect(at currentTime: Date) -> Bool {
            currentTime.timeIntervalSince(lastAttemptTime) >= interval
        }

        mutating func recordAttempt(at currentTime: Date) {
            lastAttemptTime = currentTime
        }

        mutating func recordFailure(error: Error, at currentTime: Date) -> FailureOutcome {
            let outcome = Self.evaluateFailure(error: error, previousNotFoundCount: consecutiveNotFoundCount)
            lastAttemptTime = currentTime
            interval = outcome.interval
            consecutiveNotFoundCount = outcome.consecutiveNotFoundCount
            isAutoRetryPaused = true
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
        }
    }
}
