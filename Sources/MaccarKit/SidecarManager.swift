import Foundation
import os
import CMaccarBridge

public final class SidecarService: @unchecked Sendable {
    private static let errorCodeServiceAlreadyInUse = -100
    private static let errorCodeRecoveryInterrupted = -302
    private static let errorCodeUnknownFailure = -1
    private static let defaultRecoveryMaxWait: TimeInterval = 1.5
    private static let defaultRecoveryPollInterval: TimeInterval = 0.1
    private static let defaultPostDisconnectSettleDelay: TimeInterval = 0.4
    private static let bridgeErrorDomain = "com.maccar.sidecar"

    internal struct Bridge: Sendable {
        let isAvailable: @Sendable () -> Bool
        let reachableDeviceNames: @Sendable () throws -> [String]
        let connectedDeviceNames: @Sendable () -> [String]
        let isDeviceConnected: @Sendable (String) -> Bool
        let connectDevice: @Sendable (String, Bool) throws -> Void
        let disconnectDevice: @Sendable (String) throws -> Void
        let isNotConnectedError: @Sendable (Error) -> Bool
        let startObservingNotifications: @Sendable (@escaping @Sendable (String) -> Void) -> SidecarObserverToken?
        let sleepInterval: @Sendable (TimeInterval) -> Void
        let now: @Sendable () -> TimeInterval
        let onCancellationBumped: (@Sendable () -> Void)?

        init(
            isAvailable: @escaping @Sendable () -> Bool,
            reachableDeviceNames: @escaping @Sendable () throws -> [String],
            connectedDeviceNames: @escaping @Sendable () -> [String],
            isDeviceConnected: @escaping @Sendable (String) -> Bool,
            connectDevice: @escaping @Sendable (String, Bool) throws -> Void,
            disconnectDevice: @escaping @Sendable (String) throws -> Void,
            isNotConnectedError: @escaping @Sendable (Error) -> Bool,
            startObservingNotifications: @escaping @Sendable (@escaping @Sendable (String) -> Void) -> SidecarObserverToken?,
            sleepInterval: @escaping @Sendable (TimeInterval) -> Void,
            now: @escaping @Sendable () -> TimeInterval,
            onCancellationBumped: (@Sendable () -> Void)? = nil
        ) {
            self.isAvailable = isAvailable
            self.reachableDeviceNames = reachableDeviceNames
            self.connectedDeviceNames = connectedDeviceNames
            self.isDeviceConnected = isDeviceConnected
            self.connectDevice = connectDevice
            self.disconnectDevice = disconnectDevice
            self.isNotConnectedError = isNotConnectedError
            self.startObservingNotifications = startObservingNotifications
            self.sleepInterval = sleepInterval
            self.now = now
            self.onCancellationBumped = onCancellationBumped
        }

        static let live = Bridge(
            isAvailable: { SidecarCoreIsAvailable() },
            reachableDeviceNames: {
                var err: NSError?
                let devices = SidecarCoreGetReachableDeviceNames(&err)
                if let err {
                    throw err
                }
                return devices
            },
            connectedDeviceNames: { SidecarCoreGetConnectedDeviceNames() },
            isDeviceConnected: { SidecarCoreIsDeviceConnected($0) },
            connectDevice: { deviceName, wired in
                var err: NSError?
                let ok = SidecarCoreConnectDevice(deviceName, wired, &err)
                if ok { return }
                if let err { throw err }
                throw NSError(
                    domain: SidecarService.bridgeErrorDomain,
                    code: SidecarService.errorCodeUnknownFailure,
                    userInfo: [NSLocalizedDescriptionKey: "Unknown connect failure"]
                )
            },
            disconnectDevice: { deviceName in
                var err: NSError?
                let ok = SidecarCoreDisconnectDevice(deviceName, &err)
                if ok { return }
                if let err { throw err }
                throw NSError(
                    domain: SidecarService.bridgeErrorDomain,
                    code: SidecarService.errorCodeUnknownFailure,
                    userInfo: [NSLocalizedDescriptionKey: "Unknown disconnect failure"]
                )
            },
            isNotConnectedError: { SidecarCoreIsNotConnectedError($0 as NSError) },
            startObservingNotifications: { handler in
                let token = SidecarCoreStartObservingNotifications(handler)
                guard token != 0 else { return nil }
                return SidecarObserverToken {
                    SidecarCoreStopObservingNotifications(token)
                }
            },
            sleepInterval: { Thread.sleep(forTimeInterval: $0) },
            now: { ProcessInfo.processInfo.systemUptime }
        )
    }

    public static let shared = SidecarService()

    private let bridge: Bridge
    private let recoveryMaxWait: TimeInterval
    private let recoveryPollInterval: TimeInterval
    private let postDisconnectSettleDelay: TimeInterval
    private let operationLock = NSLock()
    private let cancellationState = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    internal init(
        bridge: Bridge = .live,
        recoveryMaxWait: TimeInterval = defaultRecoveryMaxWait,
        recoveryPollInterval: TimeInterval = defaultRecoveryPollInterval,
        postDisconnectSettleDelay: TimeInterval = defaultPostDisconnectSettleDelay
    ) {
        self.bridge = bridge
        self.recoveryMaxWait = max(0.01, recoveryMaxWait)
        self.recoveryPollInterval = max(0.001, recoveryPollInterval)
        self.postDisconnectSettleDelay = max(0.0, postDisconnectSettleDelay)
    }

    public var isSupported: Bool {
        bridge.isAvailable()
    }

    public func reachableDevices() throws -> [String] {
        try bridge.reachableDeviceNames()
    }

    public func connectedDevices() -> [String] {
        bridge.connectedDeviceNames()
    }

    public func isDeviceConnected(deviceName: String) -> Bool {
        bridge.isDeviceConnected(deviceName)
    }

    public func startObservingNotifications(
        _ handler: @escaping @Sendable (String) -> Void
    ) -> SidecarObserverToken? {
        bridge.startObservingNotifications(handler)
    }

    public func connect(deviceName: String, wired: Bool = true) throws {
        operationLock.lock()
        defer { operationLock.unlock() }

        // Capture generation after acquiring operationLock so prior disconnects do not cancel this call.
        let generation = cancellationState.withLock { $0 }
        MaccarLogger.shared.info("Sidecar", "Connecting to '\(deviceName)' (wired: \(wired))...")

        do {
            try bridge.connectDevice(deviceName, wired)
            MaccarLogger.shared.info("Sidecar", "Connected to '\(deviceName)'.")
        } catch let error as NSError where error.code == Self.errorCodeServiceAlreadyInUse {
            try recoverFromAlreadyInUse(
                deviceName: deviceName,
                wired: wired,
                generation: generation
            )
        } catch {
            MaccarLogger.shared.error("Sidecar", "Connect failed for '\(deviceName)': \(error.localizedDescription)")
            throw error
        }
    }

    public func disconnect(deviceName: String, ignoreNotConnected: Bool = true) throws {
        cancellationState.withLock { $0 &+= 1 }
        bridge.onCancellationBumped?()

        operationLock.lock()
        defer { operationLock.unlock() }

        MaccarLogger.shared.info("Sidecar", "Disconnecting from '\(deviceName)'...")
        do {
            try bridge.disconnectDevice(deviceName)
            MaccarLogger.shared.info("Sidecar", "Disconnected from '\(deviceName)'.")
        } catch {
            if ignoreNotConnected,
               bridge.isNotConnectedError(error),
               !bridge.isDeviceConnected(deviceName) {
                MaccarLogger.shared.info(
                    "Sidecar",
                    "Device '\(deviceName)' is already disconnected; treating disconnect as idempotent."
                )
                return
            }
            MaccarLogger.shared.error("Sidecar", "Disconnect failed for '\(deviceName)': \(error.localizedDescription)")
            throw error
        }
    }

    private func recoverFromAlreadyInUse(
        deviceName: String,
        wired: Bool,
        generation: UInt64
    ) throws {
        MaccarLogger.shared.warning(
            "Sidecar",
            "Session already in use (-100) for '\(deviceName)'. Recovering by disconnecting first..."
        )
        try? bridge.disconnectDevice(deviceName)
        try waitForDisconnectSettlement(deviceName: deviceName, generation: generation)
        try ensureNotCancelled(generation: generation, deviceName: deviceName)

        do {
            try bridge.connectDevice(deviceName, wired)
            MaccarLogger.shared.info("Sidecar", "Reconnected to '\(deviceName)' successfully after -100 recovery.")
        } catch {
            MaccarLogger.shared.error(
                "Sidecar",
                "Recovery connect failed for '\(deviceName)': \(error.localizedDescription)"
            )
            throw error
        }
    }

    private func waitForDisconnectSettlement(
        deviceName: String,
        generation: UInt64
    ) throws {
        let maxIterations = max(1, Int((recoveryMaxWait / recoveryPollInterval).rounded(.up)))
        let deadline = bridge.now() + recoveryMaxWait

        for _ in 0..<maxIterations {
            try ensureNotCancelled(generation: generation, deviceName: deviceName)
            if !bridge.isDeviceConnected(deviceName) {
                try waitPostDisconnectSettle(deviceName: deviceName, generation: generation)
                return
            }
            guard bridge.now() < deadline else {
                break
            }
            bridge.sleepInterval(recoveryPollInterval)
        }
    }

    private func waitPostDisconnectSettle(deviceName: String, generation: UInt64) throws {
        try ensureNotCancelled(generation: generation, deviceName: deviceName)
        guard postDisconnectSettleDelay > 0 else { return }
        let maxSteps = max(1, Int((postDisconnectSettleDelay / recoveryPollInterval).rounded(.up)))
        let deadline = bridge.now() + postDisconnectSettleDelay
        for _ in 0..<maxSteps {
            try ensureNotCancelled(generation: generation, deviceName: deviceName)
            let remaining = deadline - bridge.now()
            guard remaining > 0 else { break }
            bridge.sleepInterval(min(recoveryPollInterval, remaining))
            try ensureNotCancelled(generation: generation, deviceName: deviceName)
        }
    }

    private func ensureNotCancelled(generation: UInt64, deviceName: String) throws {
        let currentGeneration = cancellationState.withLock { $0 }
        guard currentGeneration == generation else {
            MaccarLogger.shared.info(
                "Sidecar",
                "Aborted -100 recovery for '\(deviceName)' due to concurrent disconnect."
            )
            throw NSError(
                domain: Self.bridgeErrorDomain,
                code: Self.errorCodeRecoveryInterrupted,
                userInfo: [NSLocalizedDescriptionKey: "Sidecar recovery interrupted by disconnect"]
            )
        }
    }
}

extension SidecarService: SidecarControlling {}
