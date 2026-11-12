import Foundation
import os
import ServiceManagement

public enum LoginItemStatus: String, Sendable, Equatable {
    case enabled, requiresApproval, notRegistered, notApplicable
}

public protocol LoginItemManaging: Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

public struct SystemLoginItemManager: LoginItemManaging {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }
}

public final class MaccarSettings: @unchecked Sendable {
    public static let shared = MaccarSettings(
        defaults: .standard,
        isAppBundle: Bundle.main.bundleURL.pathExtension == "app",
        loginItemManager: SystemLoginItemManager()
    )

    private enum Key {
        static let registeredDeviceName = "maccar_registered_device_name"
        static let autoConnect = "maccar_auto_connect"
        static let autoMirror = "maccar_auto_mirror"
        static let startAtLogin = "maccar_start_at_login"
        static let launchAtLoginOptIn = "maccar_launch_at_login_opt_in"
        static let preferredResolution = "maccar_preferred_resolution"
        static let globalShortcutEnabled = "maccar_global_shortcut_enabled"
        static let autoCheckUpdates = "maccar_auto_check_updates"
        static let lastUpdateCheckTimestamp = "maccar_last_update_check_timestamp"
        static let skippedVersion = "maccar_skipped_version"
    }

    private let defaults: UserDefaults
    private let isAppBundle: Bool
    private let loginItemManager: any LoginItemManaging
    private let loginErrorLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    internal init(defaults: UserDefaults, isAppBundle: Bool, loginItemManager: any LoginItemManaging) {
        self.defaults = defaults
        self.isAppBundle = isAppBundle
        self.loginItemManager = loginItemManager
        defaults.register(defaults: [
            Key.autoConnect: true,
            Key.autoMirror: true,
            Key.startAtLogin: false,
            Key.launchAtLoginOptIn: false,
            Key.preferredResolution: "auto",
            Key.globalShortcutEnabled: true,
            Key.autoCheckUpdates: true,
            Key.lastUpdateCheckTimestamp: 0.0
        ])
    }

    public private(set) var lastLoginItemError: String? {
        get { loginErrorLock.withLock { $0 } }
        set { loginErrorLock.withLock { $0 = newValue } }
    }

    public var loginItemStatus: LoginItemStatus {
        guard isAppBundle else { return .notApplicable }
        return loginItemManager.status
    }

    public var registeredDeviceName: String? {
        get { defaults.string(forKey: Key.registeredDeviceName) }
        set {
            if let val = newValue, !val.trimmingCharacters(in: .whitespaces).isEmpty {
                defaults.set(val, forKey: Key.registeredDeviceName)
            } else {
                defaults.removeObject(forKey: Key.registeredDeviceName)
            }
        }
    }

    public var autoConnect: Bool {
        get { defaults.bool(forKey: Key.autoConnect) }
        set { defaults.set(newValue, forKey: Key.autoConnect) }
    }

    public var autoMirror: Bool {
        get { defaults.bool(forKey: Key.autoMirror) }
        set { defaults.set(newValue, forKey: Key.autoMirror) }
    }

    public var startAtLogin: Bool {
        get {
            guard isAppBundle else { return defaults.bool(forKey: Key.startAtLogin) }
            return loginItemManager.status == .enabled
        }
        set {
            guard isAppBundle else { defaults.set(newValue, forKey: Key.startAtLogin); return }
            defaults.set(newValue, forKey: Key.launchAtLoginOptIn)
            applyLoginItemChange(enable: newValue)
        }
    }

    public var preferredResolution: String {
        get { defaults.string(forKey: Key.preferredResolution) ?? "auto" }
        set { defaults.set(newValue, forKey: Key.preferredResolution) }
    }

    public var globalShortcutEnabled: Bool {
        get { defaults.bool(forKey: Key.globalShortcutEnabled) }
        set { defaults.set(newValue, forKey: Key.globalShortcutEnabled) }
    }

    public var autoCheckUpdates: Bool {
        get { defaults.bool(forKey: Key.autoCheckUpdates) }
        set { defaults.set(newValue, forKey: Key.autoCheckUpdates) }
    }

    public var lastUpdateCheckTimestamp: TimeInterval {
        get { defaults.double(forKey: Key.lastUpdateCheckTimestamp) }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheckTimestamp) }
    }

    public var skippedVersion: String? {
        get {
            let trimmed = defaults.string(forKey: Key.skippedVersion)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty { defaults.set(trimmed, forKey: Key.skippedVersion) }
            else { defaults.removeObject(forKey: Key.skippedVersion) }
        }
    }

    public var isConfigured: Bool {
        guard let name = registeredDeviceName else { return false }
        return !name.isEmpty
    }

    public func syncLoginItemOnLaunch() {
        guard isAppBundle, defaults.bool(forKey: Key.launchAtLoginOptIn) else { return }
        let status = loginItemManager.status
        guard status == .notRegistered else { defaults.set(status == .enabled, forKey: Key.startAtLogin); return }
        applyLoginItemChange(enable: true)
    }

    private func applyLoginItemChange(enable: Bool) {
        do {
            if enable { try loginItemManager.register() } else { try loginItemManager.unregister() }
            lastLoginItemError = nil
        } catch {
            let detail = error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription
            lastLoginItemError = detail
            MaccarLogger.shared.warning("Settings", "Launch at Login update failed: \(detail)")
        }
        defaults.set(loginItemManager.status == .enabled, forKey: Key.startAtLogin)
    }
}
