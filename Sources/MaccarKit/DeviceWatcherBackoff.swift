import Foundation

internal enum DeviceWatcherBackoff {
    static let deviceNotFoundErrorCode: Int = -200
    static let knownSidecarDomains: Set<String> = ["SidecarErrorDomain", "com.maccar.sidecar"]
    static let escalatingSchedule: [TimeInterval] = [20.0, 60.0, 180.0]
    static let nonEscalatingFailureSeconds: TimeInterval = 20.0
    static let defaultSeconds: TimeInterval = 4.0
    static let reconnectSeconds: TimeInterval = 2.0

    struct FailureOutcome: Equatable, Sendable {
        let interval: TimeInterval
        let shouldPauseAutoRetry: Bool
        let consecutiveNotFoundCount: Int
    }

    struct Tracker: Sendable {
        private(set) var lastAttemptTime: Date = .distantPast
        private(set) var interval: TimeInterval = DeviceWatcherBackoff.defaultSeconds
        private(set) var isActiveAfterFailure: Bool = false
        private(set) var consecutiveNotFoundCount: Int = 0
        private(set) var isAutoRetryPaused: Bool = false

        static func isDeviceNotFoundError(_ error: Error) -> Bool {
            let nsError = error as NSError
            return DeviceWatcherBackoff.knownSidecarDomains.contains(nsError.domain)
                && nsError.code == DeviceWatcherBackoff.deviceNotFoundErrorCode
        }

        static func evaluateFailure(error: Error, previousNotFoundCount: Int) -> FailureOutcome {
            guard isDeviceNotFoundError(error) else {
                return FailureOutcome(
                    interval: DeviceWatcherBackoff.nonEscalatingFailureSeconds,
                    shouldPauseAutoRetry: false,
                    consecutiveNotFoundCount: 0
                )
            }
            let nextCount = max(0, previousNotFoundCount) + 1
            let schedule = DeviceWatcherBackoff.escalatingSchedule
            if nextCount <= schedule.count {
                return FailureOutcome(
                    interval: schedule[nextCount - 1],
                    shouldPauseAutoRetry: false,
                    consecutiveNotFoundCount: nextCount
                )
            }
            return FailureOutcome(
                interval: schedule[schedule.count - 1],
                shouldPauseAutoRetry: true,
                consecutiveNotFoundCount: nextCount
            )
        }

        func canAutoConnect(at currentTime: Date) -> Bool {
            currentTime.timeIntervalSince(lastAttemptTime) >= interval
        }

        func shouldSuppressPassiveAdoption(manualReconnectRequested: Bool, at currentTime: Date) -> Bool {
            if isAutoRetryPaused || consecutiveNotFoundCount > 0 || manualReconnectRequested || !isActiveAfterFailure {
                return false
            }
            return currentTime.timeIntervalSince(lastAttemptTime) <= interval
        }

        mutating func recordAttempt(at currentTime: Date) {
            lastAttemptTime = currentTime
        }

        mutating func recordFailure(error: Error, at currentTime: Date) -> FailureOutcome {
            let outcome = Self.evaluateFailure(error: error, previousNotFoundCount: consecutiveNotFoundCount)
            lastAttemptTime = currentTime
            interval = outcome.interval
            isActiveAfterFailure = true
            consecutiveNotFoundCount = outcome.consecutiveNotFoundCount
            isAutoRetryPaused = outcome.shouldPauseAutoRetry
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
            isActiveAfterFailure = false
            consecutiveNotFoundCount = 0
            isAutoRetryPaused = false
        }
    }
}
