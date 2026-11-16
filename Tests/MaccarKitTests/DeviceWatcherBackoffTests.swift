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

    @Test("evaluateFailure counts consecutive -200 misses and keeps a constant interval")
    func evaluateFailureCountsConsecutiveNotFoundMisses() {
        let sidecarError = makeError(domain: "SidecarErrorDomain", code: -200)
        let maccarError = makeError(domain: "com.maccar.sidecar", code: -200)

        // -200 is transport-settling, so it spends transient budget rather than latching.
        // The interval is the short retry cadence while budget remains.
        for previous in 0...3 {
            let outcome = DeviceWatcherBackoff.Tracker.evaluateFailure(
                error: previous.isMultiple(of: 2) ? sidecarError : maccarError,
                previousNotFoundCount: previous,
                transientFailuresRemaining: DeviceWatcherBackoff.transientRetryBudget
            )
            #expect(outcome.consecutiveNotFoundCount == previous + 1)
            #expect(outcome.interval == DeviceWatcherBackoff.transientRetrySeconds)
            #expect(!outcome.isAutoRetryPaused)
        }

        // Once the budget is gone, the same error latches at the non-escalating cadence.
        let exhausted = DeviceWatcherBackoff.Tracker.evaluateFailure(
            error: sidecarError, previousNotFoundCount: 0, transientFailuresRemaining: 0
        )
        #expect(exhausted == DeviceWatcherBackoff.FailureOutcome(
            interval: DeviceWatcherBackoff.nonEscalatingFailureSeconds,
            consecutiveNotFoundCount: 1,
            isAutoRetryPaused: true
        ))
    }

    @Test("evaluateFailure treats a non-device-not-found refusal as a break in the -200 streak")
    func evaluateFailureResetsCountOnOtherErrors() {
        // Refusals (-300 / -302 / -100) still produced a failed connect(), so they latch
        // immediately — but they are not a "-200 miss", so the streak resets.
        let refusals = [
            makeError(domain: "SidecarErrorDomain", code: -300),
            makeError(domain: "com.maccar.sidecar", code: -302),
            makeError(domain: "SidecarErrorDomain", code: -100)
        ]

        for error in refusals {
            #expect(DeviceWatcherBackoff.Tracker.evaluateFailure(
                error: error,
                previousNotFoundCount: 2,
                transientFailuresRemaining: DeviceWatcherBackoff.transientRetryBudget
            ) == DeviceWatcherBackoff.FailureOutcome(
                interval: DeviceWatcherBackoff.nonEscalatingFailureSeconds,
                consecutiveNotFoundCount: 0,
                isAutoRetryPaused: true
            ))
        }

        // A -200 from a foreign domain is not ours to interpret either: it latches and
        // does not count as a Sidecar miss.
        #expect(DeviceWatcherBackoff.Tracker.evaluateFailure(
            error: makeError(domain: "NSCocoaErrorDomain", code: -200),
            previousNotFoundCount: 2,
            transientFailuresRemaining: DeviceWatcherBackoff.transientRetryBudget
        ) == DeviceWatcherBackoff.FailureOutcome(
            interval: DeviceWatcherBackoff.nonEscalatingFailureSeconds,
            consecutiveNotFoundCount: 0,
            isAutoRetryPaused: true
        ))
    }

    @Test("recordAttempt updates lastAttemptTime only and leaves the latch untouched")
    func recordAttemptUpdatesOnlyLastAttemptTime() {
        var tracker = DeviceWatcherBackoff.Tracker()
        let firstFailureTime = baseTime.addingTimeInterval(10.0)
        _ = tracker.recordFailure(error: makeError(code: -200), at: firstFailureTime)
        _ = tracker.recordFailure(error: makeError(code: -200), at: firstFailureTime.addingTimeInterval(20.0))

        let nextAttemptTime = baseTime.addingTimeInterval(90.0)
        tracker.recordAttempt(at: nextAttemptTime)

        #expect(tracker.lastAttemptTime == nextAttemptTime)
        #expect(tracker.interval == 20.0)
        #expect(tracker.consecutiveNotFoundCount == 2)
        #expect(tracker.isAutoRetryPaused, "recording an attempt must not silently re-arm the gate")
    }

    @Test("recordFailure latches a refusal on the first failure and keeps later refusals latched")
    func recordFailureLatchesOnFirstFailure() {
        var tracker = DeviceWatcherBackoff.Tracker()
        let offsets: [TimeInterval] = [0.0, 20.0, 80.0, 260.0]

        // A refusal (-300) has nothing to settle: it latches on the first occurrence and
        // never re-arms, no matter how many more arrive.
        for index in offsets.indices {
            let attemptTime = baseTime.addingTimeInterval(offsets[index])
            let domain = index.isMultiple(of: 2) ? "SidecarErrorDomain" : "com.maccar.sidecar"
            _ = tracker.recordFailure(error: makeError(domain: domain, code: -300), at: attemptTime)
            #expect(tracker.lastAttemptTime == attemptTime)
            #expect(tracker.interval == DeviceWatcherBackoff.nonEscalatingFailureSeconds)
            #expect(tracker.isAutoRetryPaused, "refusal #\(index + 1) must leave the gate latched")
        }

        let finalOutcome = tracker.recordFailure(
            error: makeError(domain: "com.maccar.sidecar", code: -302),
            at: baseTime.addingTimeInterval(500.0)
        )
        #expect(finalOutcome == DeviceWatcherBackoff.FailureOutcome(
            interval: DeviceWatcherBackoff.nonEscalatingFailureSeconds,
            consecutiveNotFoundCount: 0,
            isAutoRetryPaused: true
        ))
        #expect(tracker.isAutoRetryPaused, "a later refusal must not re-arm the gate")
    }

    @Test("canAutoConnect enforces exact >= interval boundary and allows distantPast")
    func canAutoConnectEnforcesExactGreaterOrEqualBoundary() {
        var tracker = DeviceWatcherBackoff.Tracker()
        #expect(tracker.canAutoConnect(at: baseTime))

        // A refusal latches at the non-escalating cadence.
        _ = tracker.recordFailure(error: makeError(code: -300), at: baseTime)
        #expect(!tracker.canAutoConnect(at: baseTime.addingTimeInterval(19.999)))
        #expect(tracker.canAutoConnect(at: baseTime.addingTimeInterval(20.0)))

        // A transport-settling failure uses the shorter retry cadence instead.
        var settlingTracker = DeviceWatcherBackoff.Tracker()
        _ = settlingTracker.recordFailure(error: makeError(code: -200), at: baseTime)
        let retrySeconds = DeviceWatcherBackoff.transientRetrySeconds
        #expect(!settlingTracker.canAutoConnect(at: baseTime.addingTimeInterval(retrySeconds - 0.001)))
        #expect(settlingTracker.canAutoConnect(at: baseTime.addingTimeInterval(retrySeconds)))
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
        #expect(reconnectTracker.consecutiveNotFoundCount == 0)
        #expect(!reconnectTracker.isAutoRetryPaused)

        var usbTracker = DeviceWatcherBackoff.Tracker()
        for step in 0..<4 {
            _ = usbTracker.recordFailure(error: makeError(code: -200), at: baseTime.addingTimeInterval(TimeInterval(step)))
        }
        usbTracker.resetForUSBAttach()
        #expect(usbTracker.lastAttemptTime == .distantPast)
        #expect(usbTracker.interval == 2.0)
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
        #expect(connectedTracker.consecutiveNotFoundCount == 0)
        #expect(!connectedTracker.isAutoRetryPaused)

        var clearedTracker = DeviceWatcherBackoff.Tracker()
        for step in 0..<4 {
            _ = clearedTracker.recordFailure(error: makeError(code: -200), at: baseTime.addingTimeInterval(TimeInterval(step)))
        }
        clearedTracker.resetForTargetOrToggleClear()
        #expect(clearedTracker.lastAttemptTime == .distantPast)
        #expect(clearedTracker.interval == 4.0)
        #expect(clearedTracker.consecutiveNotFoundCount == 0)
        #expect(!clearedTracker.isAutoRetryPaused)
    }
}
