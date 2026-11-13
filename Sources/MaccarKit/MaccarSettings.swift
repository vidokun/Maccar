import Foundation
import os
import ServiceManagement

public enum LoginItemStatus: String, Sendable, Equatable {
    case enabled, requiresApproval, notRegistered, notApplicable
}

/// How the "Launch at Login" toggle should render.
///
/// The checkbox follows the user's *intent*, never `SMAppService.status`. When approval is
/// pending macOS reports `requiresApproval` while the user has already said yes; rendering that
/// as unchecked invites a second press that registers again instead of switching the feature
/// off, which is the trap D4 got stuck in.
public struct LaunchAtLoginMenuItem: Sendable, Equatable {
    public let isOn: Bool
    public let title: String
    public let needsApproval: Bool

    public init(isOn: Bool, title: String, needsApproval: Bool) {
        self.isOn = isOn
        self.title = title
        self.needsApproval = needsApproval
    }

    public static let defaultTitle = "Launch at Login"
    public static let needsApprovalTitle = "Launch at Login (Approve in System Settings)"
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
        /// The user's standing wish, independent of what macOS has granted. Kept apart from
        /// `startAtLogin` (a mirror of `SMAppService.status`) because approval can arrive
        /// later in System Settings, while Maccar is not running.
        static let startAtLoginIntent = "maccar_start_at_login_intent"
        /// Written by v1.3.0 and earlier on the toggle path. Now only read, for migration.
        static let legacyLaunchAtLoginOptIn = "maccar_launch_at_login_opt_in"
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
            Key.preferredResolution: "auto",
            Key.globalShortcutEnabled: true,
            Key.autoCheckUpdates: true,
            Key.lastUpdateCheckTimestamp: 0.0
        ])
        // `startAtLoginIntent` is deliberately NOT registered. `register(defaults:)` would make
        // `bool(forKey:)` return false for an absent key, erasing the difference between "the
        // user never opted in" and "the user opted out" — the exact ambiguity that caused D4.
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

    /// Whether the login item is actually enabled right now. This mirrors macOS, not the
    /// user's wish: `.requiresApproval` means the user asked but System Settings has not
    /// granted it yet, so this stays `false` while `startAtLoginIntent` stays `true`.
    public var startAtLogin: Bool {
        get {
            guard isAppBundle else { return defaults.bool(forKey: Key.startAtLogin) }
            return loginItemManager.status == .enabled
        }
        set {
            guard isAppBundle else { defaults.set(newValue, forKey: Key.startAtLogin); return }
            defaults.set(newValue, forKey: Key.startAtLoginIntent)
            applyLoginItemChange(enable: newValue)
        }
    }

    /// The user's standing request, independent of what macOS has granted. Absent means the
    /// user never opted in — distinct from an explicit `false`.
    public var startAtLoginIntent: Bool {
        defaults.object(forKey: Key.startAtLoginIntent) as? Bool ?? false
    }

    /// What the "Launch at Login" checkbox should show and say.
    ///
    /// `isOn` traces intent, not the grant: `.requiresApproval` means the user already asked and
    /// macOS has merely not confirmed yet. The title, by contrast, does surface the pending
    /// approval, so the menu explains itself instead of looking broken.
    public var launchAtLoginMenuItem: LaunchAtLoginMenuItem {
        // A process running outside an app bundle (the test runner) has no login item;
        // offering a toggle it cannot honour would be a lie.
        guard isAppBundle else {
            return LaunchAtLoginMenuItem(isOn: false, title: LaunchAtLoginMenuItem.defaultTitle, needsApproval: false)
        }
        let needsApproval = loginItemManager.status == .requiresApproval
        return LaunchAtLoginMenuItem(
            isOn: startAtLoginIntent,
            title: needsApproval ? LaunchAtLoginMenuItem.needsApprovalTitle : LaunchAtLoginMenuItem.defaultTitle,
            needsApproval: needsApproval
        )
    }

    /// Whether the menu should tell the user to approve the login item in System Settings.
    ///
    /// Gated on intent as well as status: immediately after the user switches the feature *off*,
    /// macOS can still report `.requiresApproval`, and prompting then would instruct someone to
    /// enable a feature they just disabled.
    public var shouldPromptForApproval: Bool {
        isAppBundle && startAtLoginIntent && loginItemManager.status == .requiresApproval
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

    /// Reconciles the login item with the user's stored intent, once per launch. Returns
    /// without side effects when the user never opted in, so a fresh install registers nothing.
    public func syncLoginItemOnLaunch() {
        guard isAppBundle else { return }
        migrateLegacyLoginItemKeys()
        guard startAtLoginIntent else { return }
        let before = loginItemManager.status
        guard before == .notRegistered else {
            // Already registered or awaiting approval: record what macOS actually holds,
            // but never register a second time.
            defaults.set(before == .enabled, forKey: Key.startAtLogin)
            MaccarLogger.shared.info("Settings", "Launch at Login already \(before.rawValue); nothing to register.")
            return
        }
        // `applyLoginItemChange` already logs the transition and re-syncs
        // `Key.startAtLogin` from what macOS actually reports.
        applyLoginItemChange(enable: true)
    }

    /// Carries a v1.3.0-era opt-in forward. The old key was written only by the menu toggle,
    /// and `maccar_start_at_login` was the last-known actual state; either being `true` means
    /// the user asked for this feature and should not have to ask again.
    private func migrateLegacyLoginItemKeys() {
        guard defaults.object(forKey: Key.startAtLoginIntent) == nil else { return }
        let legacyOptIn = defaults.object(forKey: Key.legacyLaunchAtLoginOptIn) as? Bool ?? false
        let lastKnownState = defaults.object(forKey: Key.startAtLogin) as? Bool ?? false
        guard legacyOptIn || lastKnownState else { return }
        defaults.set(true, forKey: Key.startAtLoginIntent)
        MaccarLogger.shared.info("Settings", "Migrated legacy Launch at Login opt-in to the intent key.")
    }

    private func applyLoginItemChange(enable: Bool) {
        let before = loginItemManager.status
        do {
            if enable { try loginItemManager.register() } else { try loginItemManager.unregister() }
            lastLoginItemError = nil
        } catch {
            let detail = error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription
            lastLoginItemError = detail
            MaccarLogger.shared.warning("Settings", "Launch at Login update failed: \(detail)")
        }
        let after = loginItemManager.status
        defaults.set(after == .enabled, forKey: Key.startAtLogin)
        if before != after {
            MaccarLogger.shared.info("Settings", "Launch at Login \(before.rawValue) -> \(after.rawValue) (\(enable ? "register" : "unregister")).")
        }
    }
}
