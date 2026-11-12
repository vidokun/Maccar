import Foundation
import CoreGraphics
import os
@testable import MaccarKit

struct MockConnectCall: Equatable, Sendable {
    let deviceName: String
    let wired: Bool
}

struct MockDisconnectCall: Equatable, Sendable {
    let deviceName: String
    let ignoreNotConnected: Bool
}

final class ManualTestClock: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Date>

    init(initialDate: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.lock = OSAllocatedUnfairLock(initialState: initialDate)
    }

    var current: Date { get { lock.withLock { $0 } } set { lock.withLock { $0 = newValue } } }
    func now() -> Date { lock.withLock { $0 } }
    func advance(by seconds: TimeInterval) { lock.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

final class MockSidecarService: SidecarControlling, @unchecked Sendable {
    private struct State: Sendable {
        var isSupported: Bool = true
        var reachableDevicesResult: Result<[String], Error> = .success([])
        var connectedDeviceNames: [String] = []
        var connectError: Error?
        var disconnectError: Error?
        var automaticallyUpdatesConnectedState: Bool = true
        var onConnect: (@Sendable (String, Bool) throws -> Void)?
        var onDisconnect: (@Sendable (String, Bool) throws -> Void)?
        var connectCalls: [MockConnectCall] = []
        var disconnectCalls: [MockDisconnectCall] = []
        var operationTimeline: [String] = []
        var notificationHandlers: [UUID: @Sendable (String) -> Void] = [:]
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var isSupported: Bool { get { lock.withLock { $0.isSupported } } set { lock.withLock { $0.isSupported = newValue } } }
    var reachableDevicesResult: Result<[String], Error> { get { lock.withLock { $0.reachableDevicesResult } } set { lock.withLock { $0.reachableDevicesResult = newValue } } }
    var connectedDeviceNames: [String] { get { lock.withLock { $0.connectedDeviceNames } } set { lock.withLock { $0.connectedDeviceNames = newValue } } }
    var connectError: Error? { get { lock.withLock { $0.connectError } } set { lock.withLock { $0.connectError = newValue } } }
    var disconnectError: Error? { get { lock.withLock { $0.disconnectError } } set { lock.withLock { $0.disconnectError = newValue } } }
    var automaticallyUpdatesConnectedState: Bool { get { lock.withLock { $0.automaticallyUpdatesConnectedState } } set { lock.withLock { $0.automaticallyUpdatesConnectedState = newValue } } }
    var onConnect: (@Sendable (String, Bool) throws -> Void)? { get { lock.withLock { $0.onConnect } } set { lock.withLock { $0.onConnect = newValue } } }
    var onDisconnect: (@Sendable (String, Bool) throws -> Void)? { get { lock.withLock { $0.onDisconnect } } set { lock.withLock { $0.onDisconnect = newValue } } }
    var connectCalls: [MockConnectCall] { lock.withLock { $0.connectCalls } }
    var disconnectCalls: [MockDisconnectCall] { lock.withLock { $0.disconnectCalls } }
    var operationTimeline: [String] { lock.withLock { $0.operationTimeline } }

    func reachableDevices() throws -> [String] { try lock.withLock { try $0.reachableDevicesResult.get() } }
    func connectedDevices() -> [String] { lock.withLock { $0.connectedDeviceNames } }
    func isDeviceConnected(deviceName: String) -> Bool {
        lock.withLock { $0.connectedDeviceNames.contains { $0.caseInsensitiveCompare(deviceName) == .orderedSame } }
    }

    func connect(deviceName: String, wired: Bool) throws {
        let (hook, fallbackError) = lock.withLock { state -> ((@Sendable (String, Bool) throws -> Void)?, Error?) in
            state.connectCalls.append(MockConnectCall(deviceName: deviceName, wired: wired))
            state.operationTimeline.append("connect:\(deviceName)")
            return (state.onConnect, state.connectError)
        }
        if let hook { try hook(deviceName, wired) } else if let fallbackError { throw fallbackError }
        lock.withLock { state in
            guard state.automaticallyUpdatesConnectedState else { return }
            if !state.connectedDeviceNames.contains(where: { $0.caseInsensitiveCompare(deviceName) == .orderedSame }) {
                state.connectedDeviceNames.append(deviceName)
            }
        }
    }

    func disconnect(deviceName: String, ignoreNotConnected: Bool) throws {
        let (hook, fallbackError) = lock.withLock { state -> ((@Sendable (String, Bool) throws -> Void)?, Error?) in
            state.disconnectCalls.append(MockDisconnectCall(deviceName: deviceName, ignoreNotConnected: ignoreNotConnected))
            state.operationTimeline.append("disconnect:\(deviceName)")
            return (state.onDisconnect, state.disconnectError)
        }
        if let hook { try hook(deviceName, ignoreNotConnected) } else if let fallbackError { throw fallbackError }
        lock.withLock { state in
            guard state.automaticallyUpdatesConnectedState else { return }
            state.connectedDeviceNames.removeAll { $0.caseInsensitiveCompare(deviceName) == .orderedSame }
        }
    }

    func startObservingNotifications(_ handler: @escaping @Sendable (String) -> Void) -> SidecarObserverToken? {
        let id = UUID()
        lock.withLock { $0.notificationHandlers[id] = handler }
        return SidecarObserverToken { [weak self] in
            self?.lock.withLock { _ = $0.notificationHandlers.removeValue(forKey: id) }
        }
    }

    func emitNotification(_ name: String) {
        let handlers = lock.withLock { Array($0.notificationHandlers.values) }
        for handler in handlers { handler(name) }
    }
}

final class MockVirtualDisplayService: VirtualDisplayControlling, @unchecked Sendable {
    private struct State: Sendable {
        var activeDisplayID: CGDirectDisplayID?
        var currentResolution: DisplayResolution?
        var isSupported: Bool = true
        var modes: [DisplayModeInfo] = []
        var createCalls: [DisplayResolution] = []
        var applyCalls: [DisplayResolution] = []
        var destroyCalls: Int = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var activeDisplayID: CGDirectDisplayID? { get { lock.withLock { $0.activeDisplayID } } set { lock.withLock { $0.activeDisplayID = newValue } } }
    var currentResolution: DisplayResolution? { get { lock.withLock { $0.currentResolution } } set { lock.withLock { $0.currentResolution = newValue } } }
    var isSupported: Bool { get { lock.withLock { $0.isSupported } } set { lock.withLock { $0.isSupported = newValue } } }
    var modes: [DisplayModeInfo] { get { lock.withLock { $0.modes } } set { lock.withLock { $0.modes = newValue } } }
    var createCalls: [DisplayResolution] { lock.withLock { $0.createCalls } }
    var applyCalls: [DisplayResolution] { lock.withLock { $0.applyCalls } }
    var destroyCalls: Int { lock.withLock { $0.destroyCalls } }

    func availableModes() -> [DisplayModeInfo] { lock.withLock { $0.modes } }
    func isResolutionSupported(_ resolution: DisplayResolution) -> Bool {
        lock.withLock { state in
            guard !state.modes.isEmpty else { return true }
            return state.modes.contains { $0.usableForDesktop && $0.width == resolution.width && $0.height == resolution.height }
        }
    }

    @discardableResult
    func create(resolution: DisplayResolution) throws -> CGDirectDisplayID {
        lock.withLock { state in
            state.createCalls.append(resolution)
            state.currentResolution = resolution
            let id = state.activeDisplayID ?? 100
            state.activeDisplayID = id
            return id
        }
    }

    func apply(resolution: DisplayResolution) throws {
        lock.withLock { $0.applyCalls.append(resolution); $0.currentResolution = resolution }
    }

    func destroy() {
        lock.withLock { $0.destroyCalls += 1; $0.activeDisplayID = nil; $0.currentResolution = nil }
    }
}

final class MockDisplayMirrorManager: DisplayMirroring, @unchecked Sendable {
    private struct State: Sendable {
        var onlineDisplayIDs: [CGDirectDisplayID] = []
        var ipadDisplayID: CGDirectDisplayID?
        var mirroredIPadDisplayID: CGDirectDisplayID?
        var mirroredState: Bool = false
        var resolutionResult: (width: UInt32, height: UInt32) = (2266, 1488)
        var autoMatchResult: CGDirectDisplayID?
        var autoMatchError: Error?
        var disableMirroringError: Error?
        var disableMirroringCalls: [CGDirectDisplayID] = []
        var autoMatchAndMirrorCalls: [CGDirectDisplayID] = []
        var mirrorCalls: [(ipad: CGDirectDisplayID, virtual: CGDirectDisplayID)] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var onlineDisplayIDs: [CGDirectDisplayID] { get { lock.withLock { $0.onlineDisplayIDs } } set { lock.withLock { $0.onlineDisplayIDs = newValue } } }
    var ipadDisplayID: CGDirectDisplayID? { get { lock.withLock { $0.ipadDisplayID } } set { lock.withLock { $0.ipadDisplayID = newValue } } }
    var mirroredIPadDisplayID: CGDirectDisplayID? { get { lock.withLock { $0.mirroredIPadDisplayID } } set { lock.withLock { $0.mirroredIPadDisplayID = newValue } } }
    var mirroredState: Bool { get { lock.withLock { $0.mirroredState } } set { lock.withLock { $0.mirroredState = newValue } } }
    var resolutionResult: (width: UInt32, height: UInt32) { get { lock.withLock { $0.resolutionResult } } set { lock.withLock { $0.resolutionResult = newValue } } }
    var autoMatchResult: CGDirectDisplayID? { get { lock.withLock { $0.autoMatchResult } } set { lock.withLock { $0.autoMatchResult = newValue } } }
    var autoMatchError: Error? { get { lock.withLock { $0.autoMatchError } } set { lock.withLock { $0.autoMatchError = newValue } } }
    var disableMirroringError: Error? { get { lock.withLock { $0.disableMirroringError } } set { lock.withLock { $0.disableMirroringError = newValue } } }
    var disableMirroringCalls: [CGDirectDisplayID] { lock.withLock { $0.disableMirroringCalls } }
    var autoMatchAndMirrorCalls: [CGDirectDisplayID] { lock.withLock { $0.autoMatchAndMirrorCalls } }
    var mirrorCalls: [(ipad: CGDirectDisplayID, virtual: CGDirectDisplayID)] { lock.withLock { $0.mirrorCalls } }

    func onlineDisplays() -> [CGDirectDisplayID] { lock.withLock { $0.onlineDisplayIDs } }
    func resolution(of displayID: CGDirectDisplayID) -> (width: UInt32, height: UInt32) { lock.withLock { $0.resolutionResult } }
    func isMirrored(ipadDisplay: CGDirectDisplayID, toVirtualDisplay: CGDirectDisplayID) -> Bool { lock.withLock { $0.mirroredState } }

    func findIPadDisplay(excludingVirtualDisplayID: CGDirectDisplayID) -> CGDirectDisplayID? {
        lock.withLock { state in
            if let ipad = state.ipadDisplayID, ipad != excludingVirtualDisplayID { return ipad }
            return state.onlineDisplayIDs.first { $0 != 0 && $0 != excludingVirtualDisplayID }
        }
    }

    func mirror(ipadDisplay: CGDirectDisplayID, toVirtualDisplay: CGDirectDisplayID) throws {
        lock.withLock { state in
            state.mirrorCalls.append((ipad: ipadDisplay, virtual: toVirtualDisplay))
            state.mirroredState = true
            state.mirroredIPadDisplayID = ipadDisplay
        }
    }

    func disableMirroring(ipadDisplay: CGDirectDisplayID) throws {
        try lock.withLock { state in
            state.disableMirroringCalls.append(ipadDisplay)
            if let error = state.disableMirroringError { throw error }
            state.mirroredState = false
            if state.mirroredIPadDisplayID == ipadDisplay { state.mirroredIPadDisplayID = nil }
        }
    }

    @discardableResult
    func autoMatchAndMirror(virtualDisplayID: CGDirectDisplayID) throws -> CGDirectDisplayID? {
        try lock.withLock { state in
            state.autoMatchAndMirrorCalls.append(virtualDisplayID)
            if let error = state.autoMatchError { throw error }
            guard let matched = state.autoMatchResult ?? state.ipadDisplayID else { return nil }
            state.mirroredIPadDisplayID = matched
            state.mirroredState = true
            return matched
        }
    }
}

final class MockSettings: SettingsProviding, @unchecked Sendable {
    private struct State: Sendable {
        var registeredDeviceName: String?
        var autoConnect: Bool = true
        var autoMirror: Bool = true
        var startAtLogin: Bool = false
        var preferredResolution: String = "auto"
        var globalShortcutEnabled: Bool = true
    }

    private let lock: OSAllocatedUnfairLock<State>

    init(registeredDeviceName: String? = nil, autoConnect: Bool = true, autoMirror: Bool = true) {
        self.lock = OSAllocatedUnfairLock(initialState: State(
            registeredDeviceName: registeredDeviceName,
            autoConnect: autoConnect,
            autoMirror: autoMirror
        ))
    }

    var registeredDeviceName: String? { get { lock.withLock { $0.registeredDeviceName } } set { lock.withLock { $0.registeredDeviceName = newValue } } }
    var autoConnect: Bool { get { lock.withLock { $0.autoConnect } } set { lock.withLock { $0.autoConnect = newValue } } }
    var autoMirror: Bool { get { lock.withLock { $0.autoMirror } } set { lock.withLock { $0.autoMirror = newValue } } }
    var startAtLogin: Bool { get { lock.withLock { $0.startAtLogin } } set { lock.withLock { $0.startAtLogin = newValue } } }
    var preferredResolution: String { get { lock.withLock { $0.preferredResolution } } set { lock.withLock { $0.preferredResolution = newValue } } }
    var globalShortcutEnabled: Bool { get { lock.withLock { $0.globalShortcutEnabled } } set { lock.withLock { $0.globalShortcutEnabled = newValue } } }
    var isConfigured: Bool {
        !(registeredDeviceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
