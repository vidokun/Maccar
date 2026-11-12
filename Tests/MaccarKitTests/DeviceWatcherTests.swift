import Foundation
import Testing
@testable import MaccarKit

@Suite("DeviceWatcher Tests", .serialized)
struct DeviceWatcherTests {
    private struct WatcherHarness {
        let sidecar: MockSidecarService
        let virtualDisplay: MockVirtualDisplayService
        let mirror: MockDisplayMirrorManager
        let settings: MockSettings
        let clock: ManualTestClock
        let watcher: DeviceWatcher
    }

    private func makeHarness(
        registeredDeviceName: String? = "VPad",
        autoConnect: Bool = true,
        autoMirror: Bool = true,
        dispatchesReconnectTicks: Bool = false,
        sleep: @escaping @Sendable (TimeInterval) -> Void = { _ in }
    ) -> WatcherHarness {
        let sidecar = MockSidecarService()
        let virtualDisplay = MockVirtualDisplayService()
        let mirror = MockDisplayMirrorManager()
        let settings = MockSettings(
            registeredDeviceName: registeredDeviceName,
            autoConnect: autoConnect,
            autoMirror: autoMirror
        )
        let clock = ManualTestClock()
        let watcher = DeviceWatcher(
            sidecar: sidecar,
            virtualDisplay: virtualDisplay,
            mirrorManager: mirror,
            settings: settings,
            dispatchesReconnectTicks: dispatchesReconnectTicks,
            registersSystemObservers: false,
            now: { clock.now() },
            sleep: sleep
        )
        return WatcherHarness(
            sidecar: sidecar,
            virtualDisplay: virtualDisplay,
            mirror: mirror,
            settings: settings,
            clock: clock,
            watcher: watcher
        )
    }

    private func makeIsolatedWatcher() -> DeviceWatcher {
        makeHarness().watcher
    }

    @Test("Manual disconnect hold blocks and unblocks auto-connect")
    func manualDisconnectHoldBlocksAndUnblocksAutoConnect() {
        let watcher = makeIsolatedWatcher()
        defer {
            watcher.setManualDisconnectHold(false)
        }

        #expect(!watcher.isManualDisconnectHold)
        #expect(watcher.shouldAttemptAutoConnect(autoConnectEnabled: true))
        #expect(!watcher.shouldAttemptAutoConnect(autoConnectEnabled: false))

        watcher.setManualDisconnectHold(true)
        #expect(watcher.isManualDisconnectHold)
        #expect(!watcher.shouldAttemptAutoConnect(autoConnectEnabled: true))

        watcher.setManualDisconnectHold(false)
        #expect(!watcher.isManualDisconnectHold)
        #expect(watcher.shouldAttemptAutoConnect(autoConnectEnabled: true))
    }

    @Test("reconnectNow clears manual hold and overrides disabled auto-connect once")
    func reconnectNowClearsHoldAndOverridesDisabledAutoConnectOnce() {
        let watcher = makeIsolatedWatcher()
        var reconfigDepth = 0
        defer {
            while reconfigDepth > 0 {
                watcher.endDisplayReconfiguration()
                reconfigDepth -= 1
            }
            watcher.setManualDisconnectHold(false)
        }

        watcher.setManualDisconnectHold(true)
        #expect(!watcher.shouldAttemptAutoConnect(autoConnectEnabled: false))

        watcher.reconnectNow()
        #expect(!watcher.isManualDisconnectHold)
        #expect(watcher.shouldAttemptAutoConnect(autoConnectEnabled: false))

        watcher.beginDisplayReconfiguration()
        reconfigDepth += 1
        #expect(!watcher.shouldAttemptAutoConnect(autoConnectEnabled: false))

        watcher.endDisplayReconfiguration()
        reconfigDepth -= 1
        #expect(watcher.consumeConnectPermission(autoConnectEnabled: false))
        #expect(!watcher.consumeConnectPermission(autoConnectEnabled: false))
    }

    @Test("Nested display reconfiguration depth tracks accurately and does not underflow")
    func nestedDisplayReconfigurationDepthDoesNotUnderflow() {
        let watcher = makeIsolatedWatcher()
        var reconfigDepth = 0
        defer {
            while reconfigDepth > 0 {
                watcher.endDisplayReconfiguration()
                reconfigDepth -= 1
            }
        }

        #expect(!watcher.isReconfiguringDisplay)

        watcher.beginDisplayReconfiguration()
        reconfigDepth += 1
        watcher.beginDisplayReconfiguration()
        reconfigDepth += 1
        #expect(watcher.isReconfiguringDisplay)
        #expect(!watcher.shouldAttemptAutoConnect(autoConnectEnabled: true))

        watcher.endDisplayReconfiguration()
        reconfigDepth -= 1
        #expect(watcher.isReconfiguringDisplay)

        watcher.endDisplayReconfiguration()
        reconfigDepth -= 1
        #expect(!watcher.isReconfiguringDisplay)
        #expect(watcher.shouldAttemptAutoConnect(autoConnectEnabled: true))

        watcher.endDisplayReconfiguration()
        #expect(!watcher.isReconfiguringDisplay)
        watcher.beginDisplayReconfiguration()
        reconfigDepth += 1
        #expect(watcher.isReconfiguringDisplay)
    }

    @Test("All DeviceWatcherStatus cases provide English display text")
    func allStatusCasesProvideEnglishDisplayText() {
        let statuses: [DeviceWatcherStatus] = [
            .stopped,
            .waitingForDevice(targetName: nil),
            .waitingForDevice(targetName: "VPad"),
            .autoRetryPaused(targetName: "VPad"),
            .disconnectedManually(targetName: "VPad"),
            .connecting(targetName: "VPad"),
            .connected(deviceName: "VPad", displayID: 48, mirrored: true),
            .connected(deviceName: "VPad", displayID: nil, mirrored: false),
            .error(message: "Connection timed out")
        ]
        let forbiddenTokens = [
            "menunggu", "terhubung", "terputus", "sambung",
            "putuskan", "gagal", "belum", "perangkat"
        ]

        for status in statuses {
            let text = status.displayText
            #expect(!text.isEmpty)
            let lowered = text.lowercased()
            for token in forbiddenTokens {
                #expect(!lowered.contains(token), "Status '\(text)' contains Indonesian token '\(token)'")
            }
        }
    }

    @Test("reconnectNow while connected performs mirror disable, disconnect, fresh connect, and mirror")
    func reconnectNowWhileConnectedPerformsTeardownThenConnectAndMirrors() {
        let harness = makeHarness(autoMirror: false, dispatchesReconnectTicks: true)
        harness.sidecar.reachableDevicesResult = .success(["VPad"])
        harness.sidecar.connectedDeviceNames = ["VPad"]
        harness.virtualDisplay.activeDisplayID = 100
        harness.mirror.ipadDisplayID = 53
        harness.mirror.mirroredIPadDisplayID = nil

        harness.watcher.performTickForTesting()
        #expect(harness.watcher.status == .connected(deviceName: "VPad", displayID: nil, mirrored: false))
        #expect(harness.watcher.status.displayText.contains("Mirror pending"))

        harness.settings.autoMirror = true
        harness.mirror.mirroredIPadDisplayID = 53
        harness.mirror.autoMatchResult = 53
        harness.watcher.reconnectNow()
        harness.watcher.flushQueueForTesting()

        #expect(harness.mirror.disableMirroringCalls == [53])
        #expect(harness.sidecar.disconnectCalls == [MockDisconnectCall(deviceName: "VPad", ignoreNotConnected: true)])
        #expect(harness.sidecar.connectCalls == [MockConnectCall(deviceName: "VPad", wired: true)])
        #expect(harness.sidecar.operationTimeline == ["disconnect:VPad", "connect:VPad"])
        #expect(harness.mirror.autoMatchAndMirrorCalls == [100])
        #expect(harness.virtualDisplay.destroyCalls == 0)
        #expect(harness.watcher.status == .connected(deviceName: "VPad", displayID: 53, mirrored: true))
    }

    @Test("Manual disconnect hold blocks 31s ghost bounce and clears only after two detached ticks")
    func manualDisconnectHoldBlocks31sGhostBounceAndNeverAutoClears() throws {
        let harness = makeHarness(autoConnect: true)
        harness.sidecar.reachableDevicesResult = .success(["VPad"])
        harness.sidecar.connectedDeviceNames = ["VPad"]

        try harness.watcher.disconnectManually(deviceName: "VPad")
        #expect(harness.watcher.isManualDisconnectHold)
        #expect(harness.watcher.status == .disconnectedManually(targetName: "VPad"))

        harness.clock.advance(by: 31.0)
        harness.sidecar.connectedDeviceNames = ["VPad"]
        harness.watcher.performTickForTesting()

        #expect(harness.watcher.isManualDisconnectHold)
        #expect(harness.watcher.status == .disconnectedManually(targetName: "VPad"))
        #expect(harness.sidecar.disconnectCalls.last == MockDisconnectCall(deviceName: "VPad", ignoreNotConnected: true))
        #expect(harness.sidecar.connectCalls.isEmpty)

        harness.sidecar.reachableDevicesResult = .success([])
        harness.sidecar.connectedDeviceNames = []
        harness.watcher.performTickForTesting()
        #expect(harness.watcher.isManualDisconnectHold)
        #expect(harness.watcher.status == .disconnectedManually(targetName: "VPad"))

        harness.watcher.performTickForTesting()
        #expect(!harness.watcher.isManualDisconnectHold)
        #expect(harness.watcher.status == .waitingForDevice(targetName: "VPad"))
    }

    @Test("Stale connected session recovers to waiting even when autoConnect is disabled and USB stays plugged")
    func staleConnectedSessionRecoversToWaitingEvenWhenAutoConnectDisabledAndUsbPlugged() {
        let harness = makeHarness(autoConnect: false, autoMirror: true)
        harness.sidecar.reachableDevicesResult = .success(["VPad"])
        harness.sidecar.connectedDeviceNames = ["VPad"]
        harness.virtualDisplay.activeDisplayID = 100
        harness.mirror.ipadDisplayID = 53
        harness.mirror.mirroredState = true

        harness.watcher.performTickForTesting()
        #expect(harness.watcher.status == .connected(deviceName: "VPad", displayID: 53, mirrored: true))

        harness.sidecar.connectedDeviceNames = []
        harness.watcher.performTickForTesting()
        #expect(harness.watcher.status == .waitingForDevice(targetName: "VPad"))
        #expect(harness.sidecar.connectCalls.isEmpty)
    }

    @Test("disconnectManually treats not-connected as idempotent success and surfaces transport failures")
    func disconnectManuallyTreatsNotConnectedAsIdempotentSuccess() throws {
        let harnessA = makeHarness()
        try harnessA.watcher.disconnectManually(deviceName: "VPad")
        #expect(harnessA.sidecar.disconnectCalls == [MockDisconnectCall(deviceName: "VPad", ignoreNotConnected: true)])
        #expect(harnessA.watcher.isManualDisconnectHold)
        #expect(harnessA.watcher.status == .disconnectedManually(targetName: "VPad"))

        let harnessB = makeHarness()
        harnessB.sidecar.disconnectError = NSError(
            domain: "com.maccar.sidecar",
            code: -301,
            userInfo: [NSLocalizedDescriptionKey: "Transport failed"]
        )
        #expect(throws: NSError.self) {
            try harnessB.watcher.disconnectManually(deviceName: "VPad")
        }
        #expect(!harnessB.watcher.isManualDisconnectHold)
        #expect(harnessB.watcher.status == .error(message: "Transport failed"))
    }

    @Test("Connect failure backoff blocks passive adoption of late orphan session until expired")
    func connectFailureBackoffBlocksPassiveSessionAdoptionUntilExpired() {
        let harness = makeHarness(autoConnect: true, autoMirror: true)
        harness.sidecar.reachableDevicesResult = .success(["VPad"])
        harness.sidecar.connectError = NSError(
            domain: "com.maccar.sidecar",
            code: -300,
            userInfo: [NSLocalizedDescriptionKey: "Timed out"]
        )

        harness.watcher.performTickForTesting()
        #expect(harness.watcher.status == .waitingForDevice(targetName: "VPad"))

        harness.sidecar.connectError = nil
        harness.sidecar.connectedDeviceNames = ["VPad"]
        harness.clock.advance(by: 5.0)
        harness.watcher.performTickForTesting()
        #expect(harness.watcher.status == .waitingForDevice(targetName: "VPad"))
        #expect(harness.sidecar.disconnectCalls == [MockDisconnectCall(deviceName: "VPad", ignoreNotConnected: true)])

        harness.clock.advance(by: 16.0)
        harness.sidecar.connectedDeviceNames = ["VPad"]
        harness.mirror.ipadDisplayID = 53
        harness.virtualDisplay.activeDisplayID = 100
        harness.watcher.performTickForTesting()
        #expect(harness.watcher.status == .connected(deviceName: "VPad", displayID: 53, mirrored: true))
    }

    @Test("Duplicate reconnectNow bursts while in flight are coalesced cleanly")
    func coalescedReconnectIgnoresDuplicateBurstWhileInFlight() {
        let harness = makeHarness(autoMirror: false, dispatchesReconnectTicks: true)
        harness.sidecar.reachableDevicesResult = .success(["VPad"])
        let enteredConnect = DispatchSemaphore(value: 0)
        let releaseConnect = DispatchSemaphore(value: 0)
        harness.sidecar.onConnect = { _, _ in
            enteredConnect.signal()
            _ = releaseConnect.wait(timeout: .now() + 2.0)
        }

        harness.watcher.reconnectNow()
        #expect(enteredConnect.wait(timeout: .now() + 2.0) == .success)
        harness.watcher.reconnectNow()
        harness.watcher.reconnectNow()
        releaseConnect.signal()
        harness.watcher.flushQueueForTesting()
        #expect(harness.sidecar.connectCalls.count == 1)

        harness.sidecar.onConnect = nil
        harness.watcher.reconnectNow()
        harness.watcher.flushQueueForTesting()
        #expect(harness.sidecar.connectCalls.count == 2)
    }

    @Test("disconnectManually during in-flight reconnect aborts, cleans up orphan, and preserves hold")
    func disconnectManuallyDuringInFlightReconnectAbortsAndPreservesHold() throws {
        let harness = makeHarness(autoMirror: true, dispatchesReconnectTicks: true)
        harness.virtualDisplay.activeDisplayID = 100
        harness.mirror.ipadDisplayID = 53
        harness.sidecar.reachableDevicesResult = .success(["VPad"])
        let enteredConnect = DispatchSemaphore(value: 0)
        let releaseConnect = DispatchSemaphore(value: 0)
        harness.sidecar.onConnect = { _, _ in
            enteredConnect.signal()
            _ = releaseConnect.wait(timeout: .now() + 2.0)
        }

        harness.watcher.reconnectNow()
        #expect(enteredConnect.wait(timeout: .now() + 2.0) == .success)

        try harness.watcher.disconnectManually(deviceName: "VPad")
        releaseConnect.signal()
        harness.watcher.flushQueueForTesting()

        #expect(harness.watcher.status == .disconnectedManually(targetName: "VPad"))
        #expect(harness.watcher.isManualDisconnectHold)
        #expect(harness.sidecar.operationTimeline == ["connect:VPad", "disconnect:VPad", "disconnect:VPad"])
        #expect(harness.sidecar.disconnectCalls.count == 2)
        #expect(harness.mirror.autoMatchAndMirrorCalls.isEmpty)
        #expect(harness.virtualDisplay.destroyCalls == 0)
    }
}
