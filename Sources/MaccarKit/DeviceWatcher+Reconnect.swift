import Foundation
import CoreGraphics
import os

extension DeviceWatcher {
    internal func performForceReconnect() {
        guard acquireWorkSlot(respectReconfig: false) else {
            // A manual press must not evaporate because an auto-connect tick happened
            // to own the slot. Record the intent; the slot owner serves it on release.
            // `isReconnectPending` stays set deliberately: the intent is still live and
            // the serving attempt will clear it through its own defer.
            stateLock.withLock { $0.pendingManualReconnect = true }
            MaccarLogger.shared.info("DeviceWatcher", "Reconnect deferred: another attempt holds the work slot; will run on release.")
            return
        }
        defer {
            stateLock.withLock { $0.isReconnectPending = false }
            releaseWorkSlot()
        }
        runReconnectAttempt()
    }

    /// Frees the single work slot and serves any reconnect that was deferred
    /// while it was held. Every slot owner must release through here, otherwise a
    /// manual press recorded mid-attempt waits for an unrelated event.
    internal func releaseWorkSlot() {
        stateLock.withLock { $0.isWorking = false }
        serveDeferredReconnectIfNeeded()
    }

    /// Serves a manual reconnect recorded while the work slot was busy.
    private func serveDeferredReconnectIfNeeded() {
        let deferred = stateLock.withLock { state -> Bool in
            guard state.pendingManualReconnect, !state.isStopped, !state.isManualDisconnectHold else {
                // The deferred press is being abandoned. `isReconnectPending` was set by
                // `reconnectNow()` and is normally cleared by the serving attempt's defer,
                // so clearing it here is what keeps the dedupe guard from latching on and
                // coalescing every later press forever.
                if state.pendingManualReconnect { state.isReconnectPending = false }
                state.pendingManualReconnect = false
                return false
            }
            state.pendingManualReconnect = false
            return true
        }
        guard deferred else { return }
        MaccarLogger.shared.info("DeviceWatcher", "Running reconnect that was deferred while the work slot was busy.")
        workQueue.async { [weak self] in self?.performForceReconnect() }
    }

    /// The reconnect attempt itself. The caller must already hold the work slot.
    internal func runReconnectAttempt() {

        let snapshot = stateLock.withLock { state -> (wasConnected: Bool, generation: UInt64, shouldAbort: Bool) in
            guard !state.isManualDisconnectHold, !state.isStopped else {
                return (false, state.reconnectGeneration, true)
            }
            state.manualReconnectRequested = false
            if case .connected = state.status {
                return (true, state.reconnectGeneration, false)
            }
            return (false, state.reconnectGeneration, false)
        }
        guard !snapshot.shouldAbort else { return }
        guard let target = resolvedTargetName() else {
            _ = fetchAndCacheReachableDevices()
            updateStatus(.waitingForDevice(targetName: nil))
            return
        }
        updateStatus(.connecting(targetName: target))
        teardownSessionBeforeReconnect(
            target: target,
            wasConnected: snapshot.wasConnected,
            capturedGeneration: snapshot.generation
        )
        guard !shouldAbortConnectAttempt(capturedGeneration: snapshot.generation) else { return }
        executeConnectAndMirror(
            deviceName: target,
            autoMirror: settings.autoMirror,
            capturedGeneration: snapshot.generation
        )
    }

    internal func settleAfterDisconnect(duration: TimeInterval, step: TimeInterval, capturedGeneration: UInt64) {
        let maxSteps = max(1, Int((duration / step).rounded(.up)))
        let deadline = now().addingTimeInterval(duration)
        for _ in 0..<maxSteps {
            guard !shouldAbortConnectAttempt(capturedGeneration: capturedGeneration) else { return }
            let remaining = deadline.timeIntervalSince(now())
            guard remaining > 0 else { break }
            sleep(min(step, remaining))
        }
    }

    internal func executeConnectAndMirror(deviceName: String, autoMirror: Bool, capturedGeneration: UInt64) {
        let attemptTime = now()
        stateLock.withLock { $0.backoff.recordAttempt(at: attemptTime) }
        do {
            try sidecar.connect(deviceName: deviceName, wired: true)
        } catch {
            handleConnectFailure(target: deviceName, error: error, capturedGeneration: capturedGeneration)
            return
        }
        if abortAndCleanupOrphanIfNeeded(deviceName: deviceName, capturedGeneration: capturedGeneration) { return }
        if let vdID = virtualDisplay.activeDisplayID {
            pollUntil(
                timeout: Timing.displayReadyTimeoutSeconds,
                step: Timing.displayReadyStepSeconds,
                capturedGeneration: capturedGeneration
            ) {
                self.mirrorManager.findIPadDisplay(excludingVirtualDisplayID: vdID) != nil
            }
        }
        if abortAndCleanupOrphanIfNeeded(deviceName: deviceName, capturedGeneration: capturedGeneration) { return }
        stateLock.withLock {
            $0.backoff.resetForConnected()
            $0.consecutiveDetachMisses = 0
        }
        _ = fetchAndCacheReachableDevices()
        let (mirrored, ipadDisplayID) = syncMirrorIfNeeded(autoMirror: autoMirror)
        if abortAndCleanupOrphanIfNeeded(deviceName: deviceName, capturedGeneration: capturedGeneration) { return }
        updateStatus(.connected(deviceName: deviceName, displayID: ipadDisplayID, mirrored: mirrored))
        MaccarLogger.shared.info("DeviceWatcher", "Successfully connected and configured '\(deviceName)' (mirrored: \(mirrored)).")
    }

    internal func pollUntil(
        timeout: TimeInterval,
        step: TimeInterval,
        capturedGeneration: UInt64,
        condition: () -> Bool
    ) {
        let maxSteps = max(1, Int((timeout / step).rounded(.up)))
        let deadline = now().addingTimeInterval(timeout)
        for _ in 0..<maxSteps {
            guard !shouldAbortConnectAttempt(capturedGeneration: capturedGeneration) else { return }
            if condition() { return }
            guard now() < deadline else { break }
            sleep(step)
        }
    }

    internal func shouldAbortConnectAttempt(capturedGeneration: UInt64) -> Bool {
        stateLock.withLock { $0.isManualDisconnectHold || $0.isStopped || $0.reconnectGeneration != capturedGeneration }
    }

    internal func abortAndCleanupOrphanIfNeeded(deviceName: String, capturedGeneration: UInt64) -> Bool {
        guard shouldAbortConnectAttempt(capturedGeneration: capturedGeneration) else { return false }
        MaccarLogger.shared.info("DeviceWatcher", "Aborted connect attempt for '\(deviceName)'; cleaning up orphan session.")
        try? sidecar.disconnect(deviceName: deviceName, ignoreNotConnected: true)
        return true
    }

    internal func syncMirrorIfNeeded(autoMirror: Bool) -> (mirrored: Bool, displayID: CGDirectDisplayID?) {
        guard autoMirror, let vdID = virtualDisplay.activeDisplayID else { return (false, nil) }
        guard let ipad = mirrorManager.findIPadDisplay(excludingVirtualDisplayID: vdID) else { return (false, nil) }
        if mirrorManager.isMirrored(ipadDisplay: ipad, toVirtualDisplay: vdID) { return (true, ipad) }
        do {
            let matchedID = try mirrorManager.autoMatchAndMirror(virtualDisplayID: vdID)
            return (matchedID != nil, matchedID)
        } catch {
            MaccarLogger.shared.warning("DeviceWatcher", "Auto-mirror failed for display \(ipad): \(error.localizedDescription)")
            return (false, ipad)
        }
    }

    private func teardownSessionBeforeReconnect(target: String, wasConnected: Bool, capturedGeneration: UInt64) {
        guard wasConnected || sidecar.isDeviceConnected(deviceName: target) else { return }
        disableActiveMirrorBeforeDisconnect()
        try? sidecar.disconnect(deviceName: target, ignoreNotConnected: true)
        pollUntil(
            timeout: Timing.teardownPollTimeoutSeconds,
            step: Timing.teardownPollStepSeconds,
            capturedGeneration: capturedGeneration
        ) {
            !self.sidecar.isDeviceConnected(deviceName: target)
        }
        settleAfterDisconnect(
            duration: Timing.postDisconnectSettleSeconds,
            step: Timing.teardownPollStepSeconds,
            capturedGeneration: capturedGeneration
        )
    }

    private func disableActiveMirrorBeforeDisconnect() {
        let activeDisplayID = mirrorManager.mirroredIPadDisplayID
            ?? virtualDisplay.activeDisplayID.flatMap { mirrorManager.findIPadDisplay(excludingVirtualDisplayID: $0) }
        guard let ipadDisplay = activeDisplayID else { return }
        try? mirrorManager.disableMirroring(ipadDisplay: ipadDisplay)
    }
}
