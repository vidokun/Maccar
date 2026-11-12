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
            dispatchesReconnectTicks: dispatchesReconnectTicks, registersSystemObservers: false,
            now: { clock.now() }, sleep: sleep
        )
        return ResilienceHarness(sidecar: sidecar, virtualDisplay: vd, mirror: mirror, settings: settings, clock: clock, watcher: watcher)
    }

    private func driveMinus200ToAutoRetryPaused(_ harness: ResilienceHarness) {
        harness.sidecar.reachableDevicesResult = .success(["VPad"])
        harness.sidecar.connectError = NSError(domain: "SidecarErrorDomain", code: -200, userInfo: nil)
        for gap in [0.0, 20.0, 60.0, 180.0] {
            if gap > 0 { harness.clock.advance(by: gap) }
            harness.watcher.performTickForTesting()
        }
        #expect(harness.watcher.status == .autoRetryPaused(targetName: "VPad"))
    }

    private func connectVPad(_ harness: ResilienceHarness) {
        harness.sidecar.reachableDevicesResult = .success(["VPad"])
        harness.sidecar.connectedDeviceNames = ["VPad"]
        harness.virtualDisplay.activeDisplayID = 100
        harness.mirror.ipadDisplayID = 53
        harness.watcher.performTickForTesting()
    }

    @Test("Sidecar -200 escalates 0s -> +20s -> +80s -> +260s -> autoRetryPaused with zero later retries")
    func minus200EscalatesAndPausesAutoRetry() {
        let harness = makeHarness()
        harness.sidecar.reachableDevicesResult = .success(["VPad"])
        harness.sidecar.connectError = NSError(domain: "SidecarErrorDomain", code: -200, userInfo: nil)
        harness.watcher.performTickForTesting()
        #expect(harness.sidecar.connectCalls.count == 1)
        #expect(harness.watcher.status == .waitingForDevice(targetName: "VPad"))
        for (step, count, paused) in [(20.0, 2, false), (60.0, 3, false), (180.0, 4, true)] {
            harness.clock.advance(by: step)
            harness.watcher.performTickForTesting()
            #expect(harness.sidecar.connectCalls.count == count)
            #expect(harness.watcher.status == (paused ? .autoRetryPaused(targetName: "VPad") : .waitingForDevice(targetName: "VPad")))
        }
        harness.clock.advance(by: 600.0)
        harness.watcher.performTickForTesting()
        #expect(harness.sidecar.connectCalls.count == 4)
        #expect(harness.watcher.status == .autoRetryPaused(targetName: "VPad"))
    }

    @Test("Non-200 errors keep 20s retry and Control Center Sidecar adoption succeeds while paused")
    func non200ErrorsStayAt20sAndControlCenterAdoptsDuringPause() {
        let harnessA = makeHarness()
        harnessA.sidecar.reachableDevicesResult = .success(["VPad"])
        harnessA.sidecar.connectError = NSError(domain: "SidecarErrorDomain", code: -202, userInfo: nil)
        harnessA.watcher.performTickForTesting()
        harnessA.clock.advance(by: 19.0); harnessA.watcher.performTickForTesting()
        #expect(harnessA.sidecar.connectCalls.count == 1)
        harnessA.clock.advance(by: 1.0); harnessA.watcher.performTickForTesting()
        #expect(harnessA.sidecar.connectCalls.count == 2)
        harnessA.sidecar.connectError = NSError(domain: "com.maccar.sidecar", code: -300, userInfo: nil)
        for expected in 3...5 {
            harnessA.clock.advance(by: 20.0); harnessA.watcher.performTickForTesting()
            #expect(harnessA.sidecar.connectCalls.count == expected)
            #expect(harnessA.watcher.status == .waitingForDevice(targetName: "VPad"))
        }
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
        #expect(asyncHarness.sidecar.connectCalls.count == 5)
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
        #expect(harness.sidecar.connectCalls.count == 4)
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
