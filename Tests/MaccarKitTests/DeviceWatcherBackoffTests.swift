import Foundation
import Testing
@testable import MaccarKit

@Suite("DeviceWatcherBackoff Tests")
struct DeviceWatcherBackoffTests {
    private let baseTime = Date(timeIntervalSinceReferenceDate: 1_000.0)

    private func makeError(domain: String = "SidecarErrorDomain", code: Int) -> NSError {
        NSError(domain: domain, code: code, userInfo: nil)
    }

    @Test("isDeviceNotFoundError matches only -200 in known Sidecar domains")
    func isDeviceNotFoundErrorMatchesOnlyKnownDomainsAndCode() {
        #expect(DeviceWatcherBackoff.Tracker.isDeviceNotFoundError(
            makeError(domain: "SidecarErrorDomain", code: -200)
        ))
        #expect(DeviceWatcherBackoff.Tracker.isDeviceNotFoundError(
            makeError(domain: "com.maccar.sidecar", code: -200)
        ))
        #expect(!DeviceWatcherBackoff.Tracker.isDeviceNotFoundError(
            makeError(domain: "NSURLErrorDomain", code: -200)
        ))
        #expect(!DeviceWatcherBackoff.Tracker.isDeviceNotFoundError(
            makeError(domain: "SidecarErrorDomain", code: -201)
        ))
        #expect(!DeviceWatcherBackoff.Tracker.isDeviceNotFoundError(
            makeError(domain: "SidecarErrorDomain", code: -202)
        ))
        #expect(!DeviceWatcherBackoff.Tracker.isDeviceNotFoundError(
            makeError(domain: "com.maccar.sidecar", code: -300)
        ))
    }

    @Test("evaluateFailure escalates [20, 60, 180] on -200 attempts 1-3 and pauses on attempt 4")
    func evaluateFailureEscalatesMinus200AndPausesOnFourthAttempt() {
        let sidecarError = makeError(domain: "SidecarErrorDomain", code: -200)
        let maccarError = makeError(domain: "com.maccar.sidecar", code: -200)

        let first = DeviceWatcherBackoff.Tracker.evaluateFailure(error: sidecarError, previousNotFoundCount: 0)
        #expect(first == DeviceWatcherBackoff.FailureOutcome(interval: 20.0, shouldPauseAutoRetry: false, consecutiveNotFoundCount: 1))

        let second = DeviceWatcherBackoff.Tracker.evaluateFailure(error: maccarError, previousNotFoundCount: 1)
        #expect(second == DeviceWatcherBackoff.FailureOutcome(interval: 60.0, shouldPauseAutoRetry: false, consecutiveNotFoundCount: 2))

        let third = DeviceWatcherBackoff.Tracker.evaluateFailure(error: sidecarError, previousNotFoundCount: 2)
        #expect(third == DeviceWatcherBackoff.FailureOutcome(interval: 180.0, shouldPauseAutoRetry: false, consecutiveNotFoundCount: 3))

        let fourth = DeviceWatcherBackoff.Tracker.evaluateFailure(error: maccarError, previousNotFoundCount: 3)
        #expect(fourth == DeviceWatcherBackoff.FailureOutcome(interval: 180.0, shouldPauseAutoRetry: true, consecutiveNotFoundCount: 4))
    }

    @Test("evaluateFailure keeps non-matching errors at 20s without escalation or pause")
    func evaluateFailureIsolatesNonDeviceNotFoundErrors() {
        let nonMatchingErrors = [
            makeError(domain: "SidecarErrorDomain", code: -201),
            makeError(domain: "SidecarErrorDomain", code: -202),
            makeError(domain: "com.maccar.sidecar", code: -300),
            makeError(domain: "NSCocoaErrorDomain", code: -200)
        ]

        for error in nonMatchingErrors {
            let outcome = DeviceWatcherBackoff.Tracker.evaluateFailure(error: error, previousNotFoundCount: 2)
            #expect(outcome == DeviceWatcherBackoff.FailureOutcome(
                interval: 20.0,
                shouldPauseAutoRetry: false,
                consecutiveNotFoundCount: 0
            ))
        }
    }

    @Test("recordAttempt updates lastAttemptTime only and preserves escalation flags")
    func recordAttemptUpdatesOnlyLastAttemptTime() {
        var tracker = DeviceWatcherBackoff.Tracker()
        let firstFailureTime = baseTime.addingTimeInterval(10.0)
        _ = tracker.recordFailure(error: makeError(code: -200), at: firstFailureTime)
        _ = tracker.recordFailure(error: makeError(code: -200), at: firstFailureTime.addingTimeInterval(20.0))

        let nextAttemptTime = baseTime.addingTimeInterval(90.0)
        tracker.recordAttempt(at: nextAttemptTime)

        #expect(tracker.lastAttemptTime == nextAttemptTime)
        #expect(tracker.interval == 60.0)
        #expect(tracker.isActiveAfterFailure)
        #expect(tracker.consecutiveNotFoundCount == 2)
        #expect(!tracker.isAutoRetryPaused)
    }

    @Test("recordFailure drives 4-step -200 pause and -300 non-pausing active failure")
    func recordFailureDrivesMinus200EscalationAndMinus300Isolation() {
        var tracker = DeviceWatcherBackoff.Tracker()
        let offsets: [TimeInterval] = [0.0, 20.0, 80.0, 260.0]
        let expectedIntervals: [TimeInterval] = [20.0, 60.0, 180.0, 180.0]

        for index in offsets.indices {
            let attemptTime = baseTime.addingTimeInterval(offsets[index])
            let domain = index.isMultiple(of: 2) ? "SidecarErrorDomain" : "com.maccar.sidecar"
            let outcome = tracker.recordFailure(error: makeError(domain: domain, code: -200), at: attemptTime)
            #expect(tracker.lastAttemptTime == attemptTime)
            #expect(tracker.interval == expectedIntervals[index])
            #expect(tracker.isActiveAfterFailure)
            #expect(tracker.consecutiveNotFoundCount == index + 1)
            #expect(tracker.isAutoRetryPaused == (index == 3))
            #expect(outcome.shouldPauseAutoRetry == (index == 3))
        }

        let timeoutTime = baseTime.addingTimeInterval(500.0)
        let timeoutOutcome = tracker.recordFailure(error: makeError(domain: "com.maccar.sidecar", code: -300), at: timeoutTime)
        #expect(timeoutOutcome == DeviceWatcherBackoff.FailureOutcome(interval: 20.0, shouldPauseAutoRetry: false, consecutiveNotFoundCount: 0))
        #expect(tracker.lastAttemptTime == timeoutTime)
        #expect(tracker.interval == 20.0)
        #expect(tracker.isActiveAfterFailure)
        #expect(tracker.consecutiveNotFoundCount == 0)
        #expect(!tracker.isAutoRetryPaused)
    }

    @Test("canAutoConnect enforces exact >= interval boundary and allows distantPast")
    func canAutoConnectEnforcesExactGreaterOrEqualBoundary() {
        var tracker = DeviceWatcherBackoff.Tracker()
        #expect(tracker.canAutoConnect(at: baseTime))

        _ = tracker.recordFailure(error: makeError(code: -200), at: baseTime)
        #expect(!tracker.canAutoConnect(at: baseTime.addingTimeInterval(19.999)))
        #expect(tracker.canAutoConnect(at: baseTime.addingTimeInterval(20.0)))

        _ = tracker.recordFailure(error: makeError(code: -200), at: baseTime.addingTimeInterval(20.0))
        #expect(!tracker.canAutoConnect(at: baseTime.addingTimeInterval(79.999)))
        #expect(tracker.canAutoConnect(at: baseTime.addingTimeInterval(80.0)))
    }

    @Test("shouldSuppressPassiveAdoption gates only non-200 failure window <= interval")
    func shouldSuppressPassiveAdoptionGatesNon200FailureWindow() {
        var tracker = DeviceWatcherBackoff.Tracker()
        #expect(!tracker.shouldSuppressPassiveAdoption(manualReconnectRequested: false, at: baseTime))

        _ = tracker.recordFailure(error: makeError(domain: "com.maccar.sidecar", code: -300), at: baseTime)
        #expect(tracker.shouldSuppressPassiveAdoption(manualReconnectRequested: false, at: baseTime.addingTimeInterval(10.0)))
        #expect(tracker.shouldSuppressPassiveAdoption(manualReconnectRequested: false, at: baseTime.addingTimeInterval(20.0)))
        #expect(!tracker.shouldSuppressPassiveAdoption(manualReconnectRequested: false, at: baseTime.addingTimeInterval(20.001)))
        #expect(!tracker.shouldSuppressPassiveAdoption(manualReconnectRequested: true, at: baseTime.addingTimeInterval(5.0)))

        var notFoundTracker = DeviceWatcherBackoff.Tracker()
        for step in 0..<4 {
            _ = notFoundTracker.recordFailure(error: makeError(code: -200), at: baseTime.addingTimeInterval(TimeInterval(step) * 20.0))
            #expect(!notFoundTracker.shouldSuppressPassiveAdoption(
                manualReconnectRequested: false,
                at: baseTime.addingTimeInterval(TimeInterval(step) * 20.0 + 1.0)
            ))
        }
        #expect(notFoundTracker.isAutoRetryPaused)
    }

    @Test("resetForReconnect and resetForUSBAttach reset cooldown to 2s and clear flags")
    func resetForReconnectAndUSBAttachMatchContract() {
        var reconnectTracker = DeviceWatcherBackoff.Tracker()
        for step in 0..<4 {
            _ = reconnectTracker.recordFailure(error: makeError(code: -200), at: baseTime.addingTimeInterval(TimeInterval(step)))
        }
        reconnectTracker.resetForReconnect()
        #expect(reconnectTracker.lastAttemptTime == .distantPast)
        #expect(reconnectTracker.interval == 2.0)
        #expect(!reconnectTracker.isActiveAfterFailure)
        #expect(reconnectTracker.consecutiveNotFoundCount == 0)
        #expect(!reconnectTracker.isAutoRetryPaused)

        var usbTracker = DeviceWatcherBackoff.Tracker()
        for step in 0..<4 {
            _ = usbTracker.recordFailure(error: makeError(code: -200), at: baseTime.addingTimeInterval(TimeInterval(step)))
        }
        usbTracker.resetForUSBAttach()
        #expect(usbTracker.lastAttemptTime == .distantPast)
        #expect(usbTracker.interval == 2.0)
        #expect(!usbTracker.isActiveAfterFailure)
        #expect(usbTracker.consecutiveNotFoundCount == 0)
        #expect(!usbTracker.isAutoRetryPaused)
    }

    @Test("resetForConnected preserves lastAttemptTime while resetForTargetOrToggleClear resets it")
    func resetForConnectedAndTargetOrToggleClearMatchContract() {
        let lastTime = baseTime.addingTimeInterval(120.0)
        var connectedTracker = DeviceWatcherBackoff.Tracker()
        _ = connectedTracker.recordFailure(error: makeError(code: -200), at: lastTime)
        connectedTracker.resetForConnected()
        #expect(connectedTracker.lastAttemptTime == lastTime)
        #expect(connectedTracker.interval == 4.0)
        #expect(!connectedTracker.isActiveAfterFailure)
        #expect(connectedTracker.consecutiveNotFoundCount == 0)
        #expect(!connectedTracker.isAutoRetryPaused)

        var clearedTracker = DeviceWatcherBackoff.Tracker()
        for step in 0..<4 {
            _ = clearedTracker.recordFailure(error: makeError(code: -200), at: baseTime.addingTimeInterval(TimeInterval(step)))
        }
        clearedTracker.resetForTargetOrToggleClear()
        #expect(clearedTracker.lastAttemptTime == .distantPast)
        #expect(clearedTracker.interval == 4.0)
        #expect(!clearedTracker.isActiveAfterFailure)
        #expect(clearedTracker.consecutiveNotFoundCount == 0)
        #expect(!clearedTracker.isAutoRetryPaused)
    }
}
