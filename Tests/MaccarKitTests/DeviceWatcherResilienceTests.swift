import Foundation
import os
import Testing
@testable import MaccarKit

@Suite("DeviceWatcher Resilience Tests", .serialized)
struct DeviceWatcherResilienceTests {
    private final class MockUSBAttachMonitor: USBAttachMonitoring, @unchecked Sendable {
        private struct State: Sendable { var startCount = 0; var stopCount = 0; var handler: (@Sendable () -> Void)? }
        private let lock = OSAllocatedUnfairLock(initialState: State())
        var startCount: Int { lock.withLock { $0.startCount } }
        var stopCount: Int { lock.withLock { $0.stopCount } }
        init(handler: @escaping @Sendable () -> Void) { lock.withLock { $0.handler = handler } }
        func start() { lock.withLock { $0.startCount += 1 } }
        func stop() { lock.withLock { $0.stopCount += 1 } }
        func emitAttach() { lock.withLock { $0.handler }?() }
    }

    private struct ResilienceHarness {
        let sidecar: MockSidecarService; let virtualDisplay: MockVirtualDisplayService
        let mirror: MockDisplayMirrorManager; let settings: MockSettings
        let clock: ManualTestClock; let watcher: DeviceWatcher
    }

    private func makeHarness(
        autoConnect: Bool = true, dispatchesReconnectTicks: Bool = false,
        clock: ManualTestClock = ManualTestClock(), sleep: @escaping @Sendable (TimeInterval) -> Void = { _ in }
    ) -> ResilienceHarness {
        let sidecar = MockSidecarService(), vd = MockVirtualDisplayService(), mirror = MockDisplayMirrorManager()
        let settings = MockSettings(registeredDeviceName: "VPad", autoConnect: autoConnect, autoMirror: true)
        let watcher = DeviceWatcher(
            sidecar: sidecar, virtualDisplay: vd, mirrorManager: mirror, settings: settings,
            // These tests exercise retry policy, not the presence gate. A fixed "present"
            // keeps them deterministic: the default `SystemUSBDevicePresence` would make the
            // result depend on whether an iPad happens to be plugged into the test machine.
            usbPresence: MockUSBDevicePresence(isPresent: true),
            dispatchesReconnectTicks: dispatchesReconnectTicks, registersSystemObservers: false,
            now: { clock.now() }, sleep: sleep
        )
        return ResilienceHarness(sidecar: sidecar, virtualDisplay: vd, mirror: mirror, settings: settings, clock: clock, watcher: watcher)
    }

    /// Drive the watcher into the latched state.
    ///
    /// Uses a refusal (-300), not -200: since Wave 2B a transport-settling error is worth one
    /// bounded retry, so it no longer latches on the first failure. A refusal still does.
    private func driveMinus200ToAutoRetryPaused(_ harness: ResilienceHarness) {
        harness.sidecar.reachableDevicesResult = .success(["VPad"])
        harness.sidecar.connectError = NSError(domain: "SidecarErrorDomain", code: -300, userInfo: nil)
        harness.watcher.performTickForTesting()
        #expect(harness.watcher.status == .autoRetryPaused(targetName: "VPad"))
    }

    private func connectVPad(_ harness: ResilienceHarness) {
        harness.sidecar.reachableDevicesResult = .success(["VPad"])
        harness.sidecar.connectedDeviceNames = ["VPad"]
        harness.virtualDisplay.activeDisplayID = 100
        harness.mirror.ipadDisplayID = 53
        harness.watcher.performTickForTesting()
    }

    @Test("A persistent -200 spends the transient budget then latches, never looping")
    func minus200SpendsTransientBudgetThenLatches() {
        let harness = makeHarness()
        harness.sidecar.reachableDevicesResult = .success(["VPad"])
        harness.sidecar.connectError = NSError(domain: "SidecarErrorDomain", code: -200, userInfo: nil)
        harness.watcher.performTickForTesting()
        #expect(harness.sidecar.connectCalls.count == 1)
        // -200 is transport-settling: the device is present but still coming up. One
        // bounded retry is granted rather than latching a sub-second hiccup forever.
        #expect(harness.watcher.status == .waitingForDevice(targetName: "VPad"))

        // Let the retry cadence elapse once per granted attempt. The budget is 3 after the
        // 2026-11-19 field log: two attempts could not survive a long idle, where Sidecar
        // needed ~35 s to become connectable.
        let budget = DeviceWatcherBackoff.transientRetryBudget
        for _ in 0..<budget {
            harness.clock.advance(by: DeviceWatcherBackoff.transientRetrySecondsFinal)
            harness.watcher.performTickForTesting()
        }
        #expect(harness.sidecar.connectCalls.count == 1 + budget,
                "one attempt plus one per granted retry")
        #expect(harness.watcher.status == .autoRetryPaused(targetName: "VPad"))

        // Exhausted budget means no further automatic attempts, ever.
        for gap in [20.0, 60.0, 180.0, 600.0] {
            harness.clock.advance(by: gap)
            harness.watcher.performTickForTesting()
        }
        #expect(harness.sidecar.connectCalls.count == 1 + budget,
                "the transient budget is not a retry loop")
        #expect(harness.watcher.status == .autoRetryPaused(targetName: "VPad"))
    }

    @Test("Non--200 errors also latch, and Control Center Sidecar adoption still succeeds while paused")
    func non200ErrorsStayAt20sAndControlCenterAdoptsDuringPause() {
        let harnessA = makeHarness()
        harnessA.sidecar.reachableDevicesResult = .success(["VPad"])
        harnessA.sidecar.connectError = NSError(domain: "SidecarErrorDomain", code: -202, userInfo: nil)
        harnessA.watcher.performTickForTesting()
        #expect(harnessA.sidecar.connectCalls.count == 1)
        // Every failed connect() raised a popup, so DD-6 makes no exception for the code.
        #expect(harnessA.watcher.status == .autoRetryPaused(targetName: "VPad"))

        for gap in [19.0, 1.0, 20.0, 20.0, 20.0] {
            harnessA.clock.advance(by: gap)
            harnessA.watcher.performTickForTesting()
        }
        #expect(harnessA.sidecar.connectCalls.count == 1, "no automatic retry for non--200 errors either")
        #expect(harnessA.watcher.status == .autoRetryPaused(targetName: "VPad"))

        // Adopting a session the user started in Control Center must still work.
        let harnessB = makeHarness()
        driveMinus200ToAutoRetryPaused(harnessB)
        harnessB.sidecar.connectError = nil
        connectVPad(harnessB)
        #expect(harnessB.watcher.status == .connected(deviceName: "VPad", displayID: 53, mirrored: true))
    }

    @Test("USB attach wakes autoRetryPaused synchronously, retries on flush, and never clears manual hold")
    func usbAttachWakesPausedWatcherAndPreservesManualHold() throws {
        let syncHarness = makeHarness(dispatchesReconnectTicks: false)
        driveMinus200ToAutoRetryPaused(syncHarness)
        syncHarness.watcher.notifyUSBDeviceAttached()
        #expect(syncHarness.watcher.status == .waitingForDevice(targetName: "VPad"))

        let asyncHarness = makeHarness(dispatchesReconnectTicks: true)
        driveMinus200ToAutoRetryPaused(asyncHarness)
        asyncHarness.sidecar.connectError = nil
        asyncHarness.virtualDisplay.activeDisplayID = 100
        asyncHarness.mirror.ipadDisplayID = 53
        asyncHarness.watcher.notifyUSBDeviceAttached()
        asyncHarness.watcher.flushQueueForTesting()
        // D6d: the attach itself no longer connects — Sidecar needs ~4 s after the USB node
        // appears, and attempting earlier raises a popup for nothing. The tick that runs on
        // the attach is therefore a no-op.
        #expect(asyncHarness.sidecar.connectCalls.count == 1)

        // Once the settle window has elapsed, the retry runs and connects.
        asyncHarness.clock.advance(by: DeviceWatcherBackoff.usbAttachSettleSeconds)
        asyncHarness.watcher.performTickForTesting()
        #expect(asyncHarness.sidecar.connectCalls.count == 2)
        #expect(asyncHarness.watcher.status == .connected(deviceName: "VPad", displayID: 53, mirrored: true))

        let holdHarness = makeHarness(autoConnect: false, dispatchesReconnectTicks: true)
        holdHarness.sidecar.reachableDevicesResult = .success(["VPad"])
        holdHarness.watcher.performTickForTesting()
        try holdHarness.watcher.disconnectManually(deviceName: "VPad")
        holdHarness.sidecar.reachableDevicesResult = .success([])
        holdHarness.watcher.notifyUSBDeviceAttached()
        holdHarness.watcher.notifyUSBDeviceAttached()
        holdHarness.watcher.flushQueueForTesting()
        #expect(holdHarness.watcher.isManualDisconnectHold)
        #expect(holdHarness.watcher.status == .disconnectedManually(targetName: "VPad"))
        #expect(holdHarness.watcher.cachedReachableDevices == ["VPad"])
        #expect(holdHarness.sidecar.connectCalls.isEmpty)
    }

    @Test("autoRetryPaused requires two consecutive reachableDevices misses to clear")
    func autoRetryPausedClearsOnlyAfterTwoConsecutiveReachableMisses() {
        let harness = makeHarness()
        driveMinus200ToAutoRetryPaused(harness)
        harness.sidecar.connectError = nil
        harness.sidecar.reachableDevicesResult = .success([])

        harness.watcher.performTickForTesting()
        #expect(harness.watcher.status == .autoRetryPaused(targetName: "VPad"))
        harness.watcher.performTickForTesting()
        #expect(harness.watcher.status == .waitingForDevice(targetName: "VPad"))
        // Clearing the latch on detach does not itself attempt a connection.
        #expect(harness.sidecar.connectCalls.count == 1)
    }

    @Test("setAutoConnectEnabled preserves manual hold while clearTargetState resets both pause and hold")
    func autoConnectToggleAndClearTargetStateSyncTransitions() throws {
        let harnessA = makeHarness()
        driveMinus200ToAutoRetryPaused(harnessA)
        harnessA.watcher.setAutoConnectEnabled(false)
        #expect(harnessA.watcher.status == .waitingForDevice(targetName: "VPad"))
        #expect(!harnessA.watcher.isManualDisconnectHold)

        try harnessA.watcher.disconnectManually(deviceName: "VPad")
        harnessA.watcher.setAutoConnectEnabled(true)
        #expect(harnessA.watcher.isManualDisconnectHold)
        #expect(harnessA.watcher.status == .disconnectedManually(targetName: "VPad"))

        harnessA.watcher.clearTargetState()
        #expect(!harnessA.watcher.isManualDisconnectHold)
        #expect(harnessA.watcher.status == .waitingForDevice(targetName: "VPad"))

        let harnessB = makeHarness()
        driveMinus200ToAutoRetryPaused(harnessB)
        harnessB.settings.registeredDeviceName = nil
        harnessB.watcher.clearTargetState()
        #expect(!harnessB.watcher.isManualDisconnectHold)
        #expect(harnessB.watcher.status == .waitingForDevice(targetName: nil))
    }

    @Test("performForceReconnect runs 0.4s settle and aborts cleanly on manual disconnect mid-settle")
    func forceReconnectSettlesZeroPointFourSecondsAndAbortsMidSettle() throws {
        let clockA = ManualTestClock(), sleepsA = OSAllocatedUnfairLock<[TimeInterval]>(initialState: [])
        let harnessA = makeHarness(dispatchesReconnectTicks: true, clock: clockA) { duration in
            sleepsA.withLock { $0.append(duration) }; clockA.advance(by: duration)
        }
        connectVPad(harnessA)
        harnessA.watcher.reconnectNow()
        harnessA.watcher.flushQueueForTesting()
        let recordedA = sleepsA.withLock { $0 }
        #expect(recordedA.count == 4)
        #expect(recordedA.allSatisfy { abs($0 - 0.1) < 0.001 })
        #expect(recordedA.reduce(0, +) >= 0.399)
        #expect(harnessA.sidecar.operationTimeline == ["disconnect:VPad", "connect:VPad"])
        #expect(harnessA.watcher.status == .connected(deviceName: "VPad", displayID: 53, mirrored: true))

        let clockB = ManualTestClock(), sleepsB = OSAllocatedUnfairLock<[TimeInterval]>(initialState: [])
        let enteredSleep = DispatchSemaphore(value: 0), releaseSleep = DispatchSemaphore(value: 0)
        let harnessB = makeHarness(dispatchesReconnectTicks: true, clock: clockB) { duration in
            sleepsB.withLock { $0.append(duration) }; enteredSleep.signal()
            _ = releaseSleep.wait(timeout: .now() + 2.0); clockB.advance(by: duration)
        }
        connectVPad(harnessB)
        harnessB.watcher.reconnectNow()
        #expect(enteredSleep.wait(timeout: .now() + 2.0) == .success)
        try harnessB.watcher.disconnectManually(deviceName: "VPad")
        releaseSleep.signal()
        harnessB.watcher.flushQueueForTesting()
        #expect(sleepsB.withLock { $0 }.count == 1)
        #expect(harnessB.sidecar.connectCalls.isEmpty)
        #expect(harnessB.watcher.isManualDisconnectHold)
        #expect(harnessB.watcher.status == .disconnectedManually(targetName: "VPad"))
    }

    @Test("consumeAutoConnectGate preserves manualReconnectRequested during cooldown and consumes once")
    func consumeAutoConnectGatePreservesManualReconnectDuringCooldown() {
        let harness = makeHarness(autoConnect: false)
        let baseTime = harness.clock.now()
        harness.watcher.reconnectNow()
        harness.watcher.stateLock.withLock { $0.backoff.recordAttempt(at: baseTime) }

        #expect(!harness.watcher.consumeAutoConnectGate(autoConnectEnabled: false, at: baseTime.addingTimeInterval(1.0)))
        #expect(harness.watcher.shouldAttemptAutoConnect(autoConnectEnabled: false))
        #expect(harness.watcher.consumeAutoConnectGate(autoConnectEnabled: false, at: baseTime.addingTimeInterval(2.0)))
        #expect(!harness.watcher.consumeAutoConnectGate(autoConnectEnabled: false, at: baseTime.addingTimeInterval(3.0)))
        #expect(!harness.watcher.shouldAttemptAutoConnect(autoConnectEnabled: false))
    }

    @Test("DeviceWatcherObserver debounces USB attach bursts into one callback and cancels on stop")
    func observerDebouncesUSBAttachBurstAndCancelsOnStop() {
        let queue = DispatchQueue(label: "com.maccar.tests.observer.usb")
        let monitorLock = OSAllocatedUnfairLock<MockUSBAttachMonitor?>(initialState: nil)
        let callbackCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let fired = DispatchSemaphore(value: 0)
        let observer = DeviceWatcherObserver(
            queue: queue, usbAttachDebounceMilliseconds: 80, sidecar: MockSidecarService(),
            isReconfiguring: { false },
            usbAttachMonitorFactory: { _, handler in
                let monitor = MockUSBAttachMonitor(handler: handler)
                monitorLock.withLock { $0 = monitor }
                return monitor
            },
            onDebouncedEvent: {},
            onUSBDeviceAttached: { callbackCount.withLock { $0 += 1 }; fired.signal() }
        )

        observer.start()
        let monitor = monitorLock.withLock { $0 }
        #expect(monitor?.startCount == 1)
        for _ in 0..<3 { monitor?.emitAttach() }
        #expect(fired.wait(timeout: .now() + 2.0) == .success)
        #expect(callbackCount.withLock { $0 } == 1)

        monitor?.emitAttach(); monitor?.emitAttach()
        observer.stop()
        #expect(monitor?.stopCount == 1)
        Thread.sleep(forTimeInterval: 0.15)
        queue.sync {}
        #expect(callbackCount.withLock { $0 } == 1)
    }
}
