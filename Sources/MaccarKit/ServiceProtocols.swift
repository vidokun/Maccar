import Foundation
import CoreGraphics
import os

public final class SidecarObserverToken: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    private let onInvalidate: @Sendable () -> Void

    public init(onInvalidate: @escaping @Sendable () -> Void) {
        self.onInvalidate = onInvalidate
    }

    public func invalidate() {
        let shouldStop = lock.withLock { invalidated -> Bool in
            guard !invalidated else { return false }
            invalidated = true
            return true
        }
        if shouldStop {
            onInvalidate()
        }
    }

    deinit {
        invalidate()
    }
}

public protocol SidecarControlling: AnyObject, Sendable {
    var isSupported: Bool { get }
    func reachableDevices() throws -> [String]
    func connectedDevices() -> [String]
    func isDeviceConnected(deviceName: String) -> Bool
    func connect(deviceName: String, wired: Bool) throws
    func disconnect(deviceName: String, ignoreNotConnected: Bool) throws
    func startObservingNotifications(
        _ handler: @escaping @Sendable (String) -> Void
    ) -> SidecarObserverToken?
}

public extension SidecarControlling {
    func connect(deviceName: String, wired: Bool = true) throws {
        try connect(deviceName: deviceName, wired: wired)
    }

    func disconnect(deviceName: String, ignoreNotConnected: Bool = true) throws {
        try disconnect(deviceName: deviceName, ignoreNotConnected: ignoreNotConnected)
    }
}

public protocol VirtualDisplayControlling: AnyObject, Sendable {
    var activeDisplayID: CGDirectDisplayID? { get }
    var currentResolution: DisplayResolution? { get }
    var isSupported: Bool { get }
    func availableModes() -> [DisplayModeInfo]
    func isResolutionSupported(_ resolution: DisplayResolution) -> Bool
    @discardableResult
    func create(resolution: DisplayResolution) throws -> CGDirectDisplayID
    func apply(resolution: DisplayResolution) throws
    func destroy()
}

public extension VirtualDisplayControlling {
    @discardableResult
    func create(resolution: DisplayResolution = .ipadMiniComfortable) throws -> CGDirectDisplayID {
        try create(resolution: resolution)
    }
}

public protocol DisplayMirroring: AnyObject, Sendable {
    var mirroredIPadDisplayID: CGDirectDisplayID? { get }
    func onlineDisplays() -> [CGDirectDisplayID]
    func findIPadDisplay(excludingVirtualDisplayID: CGDirectDisplayID) -> CGDirectDisplayID?
    func resolution(of displayID: CGDirectDisplayID) -> (width: UInt32, height: UInt32)
    func mirror(ipadDisplay: CGDirectDisplayID, toVirtualDisplay: CGDirectDisplayID) throws
    func disableMirroring(ipadDisplay: CGDirectDisplayID) throws
    func isMirrored(ipadDisplay: CGDirectDisplayID, toVirtualDisplay: CGDirectDisplayID) -> Bool
    @discardableResult
    func autoMatchAndMirror(virtualDisplayID: CGDirectDisplayID) throws -> CGDirectDisplayID?
}

public protocol SettingsProviding: AnyObject, Sendable {
    var registeredDeviceName: String? { get set }
    var autoConnect: Bool { get set }
    var autoMirror: Bool { get set }
    var startAtLogin: Bool { get set }
    var preferredResolution: String { get set }
    var globalShortcutEnabled: Bool { get set }
    var isConfigured: Bool { get }
}

// Extension SidecarService: SidecarControlling {} lives in SidecarManager.swift (Chunk 1.3)
// so Chunk 1.2 builds cleanly immediately before SidecarManager.swift is updated.
extension VirtualDisplayService: VirtualDisplayControlling {}
extension DisplayMirrorManager: DisplayMirroring {}
extension MaccarSettings: SettingsProviding {}
