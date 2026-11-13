import Foundation
import os
import Testing
import CMaccarBridge
@testable import MaccarKit

@Suite("SidecarService Tests")
struct SidecarServiceTests {
    private static let sidecarDomain = "SidecarErrorDomain"
    private static let bridgeDomain = "com.maccar.sidecar"
    /// How many racing `invalidate()` calls the token test fires.
    private static let concurrentInvalidateAttempts = 16
    /// Generous by design: this bounds a hung lock, not the scheduling latency of
    /// the racing blocks. A tight bound turns a slow CI runner into a false failure.
    private static let concurrentInvalidateWaitTimeout: DispatchTimeInterval = .seconds(30)

    private static var concurrentInvalidateDeadline: DispatchTime {
        DispatchTime.now() + concurrentInvalidateWaitTimeout
    }

    private func makeError(_ domain: String, _ code: Int, _ message: String) -> NSError {
        NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func makeBridge(
        isAvailable: @escaping @Sendable () -> Bool = { true },
        reachableDeviceNames: @escaping @Sendable () throws -> [String] = { ["VPad"] },
        connectedDeviceNames: @escaping @Sendable () -> [String] = { [] },
        isDeviceConnected: @escaping @Sendable (String) -> Bool = { _ in false },
        connectDevice: @escaping @Sendable (String, Bool) throws -> Void = { _, _ in },
        disconnectDevice: @escaping @Sendable (String) throws -> Void = { _ in },
        isNotConnectedError: @escaping @Sendable (Error) -> Bool = { SidecarCoreIsNotConnectedError($0 as NSError) },
        startObservingNotifications: @escaping @Sendable (@escaping @Sendable (String) -> Void) -> SidecarObserverToken? = { _ in nil },
        sleepInterval: @escaping @Sendable (TimeInterval) -> Void = { _ in },
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onCancellationBumped: (@Sendable () -> Void)? = nil
    ) -> SidecarService.Bridge {
        SidecarService.Bridge(
            isAvailable: isAvailable,
            reachableDeviceNames: reachableDeviceNames,
            connectedDeviceNames: connectedDeviceNames,
            isDeviceConnected: isDeviceConnected,
            connectDevice: connectDevice,
            disconnectDevice: disconnectDevice,
            isNotConnectedError: isNotConnectedError,
            startObservingNotifications: startObservingNotifications,
            sleepInterval: sleepInterval,
            now: now,
            onCancellationBumped: onCancellationBumped
        )
    }

    @Test("Service singletons conform to Sendable DI protocols")
    func protocolConformancesCompileAndExposeSingletons() {
        let sidecar: any SidecarControlling = SidecarService.shared
        let virtualDisplay: any VirtualDisplayControlling = VirtualDisplayService.shared
        let displayMirror: any DisplayMirroring = DisplayMirrorManager.shared
        let settings: any SettingsProviding = MaccarSettings.shared

        let verifySendable: @Sendable () -> Bool = {
            _ = sidecar.connectedDevices()
            _ = virtualDisplay.activeDisplayID
            _ = displayMirror.mirroredIPadDisplayID
            _ = settings.isConfigured
            return sidecar === SidecarService.shared
                && virtualDisplay === VirtualDisplayService.shared
                && displayMirror === DisplayMirrorManager.shared
                && settings === MaccarSettings.shared
        }

        #expect(verifySendable())
    }

    @Test("SidecarCoreIsNotConnectedError matches only SidecarErrorDomain not-connected errors")
    func notConnectedErrorClassificationMatchesOnlySidecarDomainNotConnected() {
        let lowerNotConnected = makeError(Self.sidecarDomain, -101, "The device is not connected.")
        let upperNotConnected = makeError(Self.sidecarDomain, -101, "DEVICE NOT CONNECTED")
        let alreadyInUse = makeError(Self.sidecarDomain, -100, "Service is already in use")
        let bridgeTimeout = makeError(Self.bridgeDomain, -300, "Sidecar connection timed out after 10s")
        let foreignDomain = makeError("com.example.foreign", -1, "The device is not connected")

        #expect(SidecarCoreIsNotConnectedError(lowerNotConnected))
        #expect(SidecarCoreIsNotConnectedError(upperNotConnected))
        #expect(!SidecarCoreIsNotConnectedError(alreadyInUse))
        #expect(!SidecarCoreIsNotConnectedError(bridgeTimeout))
        #expect(!SidecarCoreIsNotConnectedError(foreignDomain))
        #expect(!SidecarCoreIsNotConnectedError(nil))
    }

    @Test("disconnect honors ignoreNotConnected flag and verifies live connection state")
    func disconnectHonorsIgnoreNotConnectedWhenDeviceIsNotConnected() throws {
        let connectedState = OSAllocatedUnfairLock(initialState: false)
        let notConnectedErr = makeError(Self.sidecarDomain, -101, "The device is not connected")
        let service = SidecarService(
            bridge: makeBridge(
                isDeviceConnected: { _ in connectedState.withLock { $0 } },
                disconnectDevice: { _ in throw notConnectedErr }
            )
        )

        try service.disconnect(deviceName: "VPad", ignoreNotConnected: true)
        #expect(throws: NSError.self) {
            try service.disconnect(deviceName: "VPad", ignoreNotConnected: false)
        }

        connectedState.withLock { $0 = true }
        #expect(throws: NSError.self) {
            try service.disconnect(deviceName: "VPad", ignoreNotConnected: true)
        }
    }

    @Test("Error -100 recovery polls isDeviceConnected in 100ms increments and exits early")
    func recoveryFromErrorMinus100PollsAndExitsEarlyWhenDisconnected() throws {
        let state = OSAllocatedUnfairLock(initialState: (connectCalls: 0, sleepCalls: [TimeInterval](), connectedChecks: 0))
        let connectionResponses = [true, true, false]
        let alreadyInUseErr = makeError(Self.sidecarDomain, -100, "Service is already in use")
        let service = SidecarService(
            bridge: makeBridge(
                isDeviceConnected: { _ in
                    state.withLock { current in
                        let idx = min(current.connectedChecks, connectionResponses.count - 1)
                        current.connectedChecks += 1
                        return connectionResponses[idx]
                    }
                },
                connectDevice: { _, _ in
                    let attempt = state.withLock { current -> Int in
                        current.connectCalls += 1
                        return current.connectCalls
                    }
                    if attempt == 1 { throw alreadyInUseErr }
                },
                sleepInterval: { interval in
                    state.withLock { $0.sleepCalls.append(interval) }
                }
            ),
            postDisconnectSettleDelay: 0
        )

        try service.connect(deviceName: "VPad", wired: true)

        let snapshot = state.withLock { $0 }
        #expect(snapshot.connectCalls == 2)
        #expect(snapshot.connectedChecks == 3)
        #expect(snapshot.sleepCalls == [0.1, 0.1])
    }

    private func runAlreadyInUseSettleCase(
        postDisconnectSettleDelay: TimeInterval? = nil,
        connectionResponses: [Bool],
        now: @escaping @Sendable () -> TimeInterval = { 100.0 },
        onSleep: (@Sendable (TimeInterval) -> Void)? = nil
    ) throws -> (connectCalls: Int, connectedChecks: Int, sleepCalls: [TimeInterval]) {
        let state = OSAllocatedUnfairLock(
            initialState: (connectCalls: 0, connectedChecks: 0, sleepCalls: [TimeInterval]())
        )
        let alreadyInUseErr = makeError(Self.sidecarDomain, -100, "Service is already in use")
        let bridge = makeBridge(
            isDeviceConnected: { _ in
                state.withLock { current in
                    let idx = min(current.connectedChecks, connectionResponses.count - 1)
                    current.connectedChecks += 1
                    return connectionResponses[idx]
                }
            },
            connectDevice: { _, _ in
                let attempt = state.withLock { current -> Int in
                    current.connectCalls += 1
                    return current.connectCalls
                }
                if attempt == 1 { throw alreadyInUseErr }
            },
            sleepInterval: { interval in
                state.withLock { $0.sleepCalls.append(interval) }
                onSleep?(interval)
            },
            now: now
        )
        let service = postDisconnectSettleDelay.map {
            SidecarService(bridge: bridge, postDisconnectSettleDelay: $0)
        } ?? SidecarService(bridge: bridge)
        try service.connect(deviceName: "VPad", wired: true)
        return state.withLock { $0 }
    }

    @Test("Error -100 recovery waits default 0.4s post-disconnect settle under static clock")
    func recoveryFromErrorMinus100WaitsDefaultPostDisconnectSettle() throws {
        let result = try runAlreadyInUseSettleCase(connectionResponses: [true, true, false])

        #expect(result.connectCalls == 2)
        #expect(result.connectedChecks == 3)
        #expect(result.sleepCalls == [0.1, 0.1, 0.1, 0.1, 0.1, 0.1])
    }

    @Test("Negative postDisconnectSettleDelay clamps to zero without extra settle sleeps")
    func recoveryFromErrorMinus100ClampsNegativeSettleDelayToZero() throws {
        let result = try runAlreadyInUseSettleCase(
            postDisconnectSettleDelay: -1.0,
            connectionResponses: [true, true, false]
        )

        #expect(result.connectCalls == 2)
        #expect(result.connectedChecks == 3)
        #expect(result.sleepCalls == [0.1, 0.1])
    }

    @Test("Concurrent disconnect during post-disconnect settle throws -302 without reconnecting")
    func recoveryFromErrorMinus100InterruptedDuringSettleThrowsMinus302() {
        let enteredSettleSleep = DispatchSemaphore(value: 0)
        let cancelReady = DispatchSemaphore(value: 0)
        let disconnectDone = DispatchGroup()
        let counts = OSAllocatedUnfairLock(
            initialState: (connect: 0, disconnect: 0, sleepCalls: [TimeInterval](), disconnectErr: nil as Error?)
        )
        let alreadyInUseErr = makeError(Self.sidecarDomain, -100, "Service is already in use")
        let service = SidecarService(
            bridge: makeBridge(
                isDeviceConnected: { _ in false },
                connectDevice: { _, _ in
                    counts.withLock { $0.connect += 1 }
                    throw alreadyInUseErr
                },
                disconnectDevice: { _ in counts.withLock { $0.disconnect += 1 } },
                sleepInterval: { interval in
                    counts.withLock { $0.sleepCalls.append(interval) }
                    enteredSettleSleep.signal()
                    _ = cancelReady.wait(timeout: .now() + 2.0)
                },
                now: { 100.0 },
                onCancellationBumped: { cancelReady.signal() }
            )
        )

        disconnectDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { disconnectDone.leave() }
            guard enteredSettleSleep.wait(timeout: .now() + 2.0) == .success else { return }
            do { try service.disconnect(deviceName: "VPad") } catch { counts.withLock { $0.disconnectErr = error } }
        }

        var caughtCode: Int?
        do { try service.connect(deviceName: "VPad", wired: true) } catch let error as NSError { caughtCode = error.code }

        #expect(disconnectDone.wait(timeout: .now() + 2.0) == .success)
        let snapshot = counts.withLock { $0 }
        #expect(caughtCode == -302)
        #expect(snapshot.connect == 1)
        #expect(snapshot.disconnect == 2)
        #expect(snapshot.sleepCalls == [0.1])
        #expect(snapshot.disconnectErr == nil)
    }

    @Test("Advancing clock past settle deadline breaks immediately without remaining sleeps")
    func recoveryFromErrorMinus100BreaksWhenClockAdvancesPastSettleDeadline() throws {
        let clock = OSAllocatedUnfairLock(initialState: 100.0)
        let result = try runAlreadyInUseSettleCase(
            connectionResponses: [false],
            now: { clock.withLock { $0 } },
            onSleep: { _ in clock.withLock { $0 += 0.5 } }
        )

        #expect(result.connectCalls == 2)
        #expect(result.connectedChecks == 1)
        #expect(result.sleepCalls == [0.1])
    }

    @Test("Error -100 recovery aborts cleanly when concurrent disconnect bumps generation")
    func recoveryFromErrorMinus100IsInterruptedByConcurrentDisconnect() {
        let enteredSleep = DispatchSemaphore(value: 0)
        let cancelReady = DispatchSemaphore(value: 0)
        let disconnectDone = DispatchGroup()
        let counts = OSAllocatedUnfairLock(initialState: (connect: 0, disconnect: 0, disconnectErr: nil as Error?))
        let alreadyInUseErr = makeError(Self.sidecarDomain, -100, "Service is already in use")
        let service = SidecarService(
            bridge: makeBridge(
                isDeviceConnected: { _ in true },
                connectDevice: { _, _ in
                    counts.withLock { $0.connect += 1 }
                    throw alreadyInUseErr
                },
                disconnectDevice: { _ in counts.withLock { $0.disconnect += 1 } },
                sleepInterval: { _ in
                    enteredSleep.signal()
                    _ = cancelReady.wait(timeout: .now() + 2.0)
                },
                onCancellationBumped: { cancelReady.signal() }
            )
        )

        disconnectDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { disconnectDone.leave() }
            guard enteredSleep.wait(timeout: .now() + 2.0) == .success else { return }
            do { try service.disconnect(deviceName: "VPad") } catch { counts.withLock { $0.disconnectErr = error } }
        }

        var caughtCode: Int?
        do { try service.connect(deviceName: "VPad", wired: true) } catch let error as NSError { caughtCode = error.code }

        #expect(disconnectDone.wait(timeout: .now() + 2.0) == .success)
        let snapshot = counts.withLock { $0 }
        #expect(caughtCode == -302)
        #expect(snapshot.connect == 1)
        #expect(snapshot.disconnect == 2)
        #expect(snapshot.disconnectErr == nil)
    }

    @Test("Connect and disconnect serialize operations without blocking read queries")
    func connectAndDisconnectSerializeOperationsWithoutBlockingReads() throws {
        let connectEntered = DispatchSemaphore(value: 0)
        let allowConnectFinish = DispatchSemaphore(value: 0)
        let disconnectQueued = DispatchSemaphore(value: 0)
        let connectFinished = DispatchSemaphore(value: 0)
        let disconnectFinished = DispatchSemaphore(value: 0)
        let events = OSAllocatedUnfairLock(initialState: [String]())

        let service = SidecarService(
            bridge: makeBridge(
                reachableDeviceNames: { ["VPad"] },
                connectedDeviceNames: { ["VPad"] },
                isDeviceConnected: { _ in true },
                connectDevice: { _, _ in
                    events.withLock { $0.append("connect:begin") }
                    connectEntered.signal()
                    _ = allowConnectFinish.wait(timeout: .now() + 2.0)
                    events.withLock { $0.append("connect:end") }
                },
                disconnectDevice: { _ in events.withLock { $0.append("disconnect:exec") } },
                onCancellationBumped: { disconnectQueued.signal() }
            )
        )

        DispatchQueue.global(qos: .userInitiated).async {
            try? service.connect(deviceName: "VPad", wired: true)
            connectFinished.signal()
        }
        #expect(connectEntered.wait(timeout: .now() + 2.0) == .success)
        #expect(try service.reachableDevices() == ["VPad"])
        #expect(service.connectedDevices() == ["VPad"])
        #expect(service.isDeviceConnected(deviceName: "VPad"))
        #expect(service.startObservingNotifications { _ in } == nil)

        DispatchQueue.global(qos: .userInitiated).async {
            try? service.disconnect(deviceName: "VPad")
            disconnectFinished.signal()
        }
        #expect(disconnectQueued.wait(timeout: .now() + 2.0) == .success)
        #expect(disconnectFinished.wait(timeout: .now() + 0.02) == .timedOut)

        allowConnectFinish.signal()
        #expect(connectFinished.wait(timeout: .now() + 2.0) == .success)
        #expect(disconnectFinished.wait(timeout: .now() + 2.0) == .success)
        #expect(events.withLock { $0 } == ["connect:begin", "connect:end", "disconnect:exec"])
    }

    @Test("Notification token cleanup and invalid token stop are safe and idempotent")
    func stopObservingNotificationsWithZeroOrInvalidTokenIsSafe() {
        SidecarCoreStopObservingNotifications(0)
        SidecarCoreStopObservingNotifications(999_999)

        let invalidationCount = OSAllocatedUnfairLock(initialState: 0)
        do {
            let token = SidecarObserverToken {
                invalidationCount.withLock { $0 += 1 }
            }
            // A dedicated concurrent queue keeps the race isolated from the global
            // pool, which the rest of this suite saturates in parallel.
            let queue = DispatchQueue(label: "maccar.tests.observer-token-race", attributes: .concurrent)
            let group = DispatchGroup()
            for _ in 0..<Self.concurrentInvalidateAttempts {
                group.enter()
                queue.async {
                    token.invalidate()
                    group.leave()
                }
            }
            #expect(group.wait(timeout: Self.concurrentInvalidateDeadline) == .success)
            token.invalidate()
        }
        #expect(invalidationCount.withLock { $0 } == 1)

        let deinitOnlyCount = OSAllocatedUnfairLock(initialState: 0)
        do {
            _ = SidecarObserverToken {
                deinitOnlyCount.withLock { $0 += 1 }
            }
        }
        #expect(deinitOnlyCount.withLock { $0 } == 1)
    }
}
