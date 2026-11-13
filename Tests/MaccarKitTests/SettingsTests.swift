import Foundation
import os
import Testing
@testable import MaccarKit

@Suite("MaccarSettings Tests", .serialized)
struct SettingsTests {
    private enum MockLoginError: LocalizedError, Sendable {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let message):
                return message
            }
        }
    }

    private final class MockLoginItemManager: LoginItemManaging, @unchecked Sendable {
        private struct State: Sendable {
            var status: LoginItemStatus
            var statusAfterRegister: LoginItemStatus
            var statusAfterUnregister: LoginItemStatus
            var registerError: Error?
            var unregisterError: Error?
            var registerCalls: Int = 0
            var unregisterCalls: Int = 0
            var statusAccessCount: Int = 0
        }

        private let lock: OSAllocatedUnfairLock<State>

        init(status: LoginItemStatus = .notRegistered, statusAfterRegister: LoginItemStatus = .enabled, statusAfterUnregister: LoginItemStatus = .notRegistered) {
            self.lock = OSAllocatedUnfairLock(initialState: State(status: status, statusAfterRegister: statusAfterRegister, statusAfterUnregister: statusAfterUnregister))
        }

        var status: LoginItemStatus { lock.withLock { $0.statusAccessCount += 1; return $0.status } }
        var statusAccessCount: Int { lock.withLock { $0.statusAccessCount } }
        var registerCalls: Int { lock.withLock { $0.registerCalls } }
        var unregisterCalls: Int { lock.withLock { $0.unregisterCalls } }
        var registerError: Error? { get { lock.withLock { $0.registerError } } set { lock.withLock { $0.registerError = newValue } } }
        var unregisterError: Error? { get { lock.withLock { $0.unregisterError } } set { lock.withLock { $0.unregisterError = newValue } } }

        func register() throws {
            try lock.withLock { state in
                state.registerCalls += 1
                if let error = state.registerError { throw error }
                state.status = state.statusAfterRegister
            }
        }

        func unregister() throws {
            try lock.withLock { state in
                state.unregisterCalls += 1
                if let error = state.unregisterError { throw error }
                state.status = state.statusAfterUnregister
            }
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "com.maccar.tests.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    @Test("Fresh settings expose honest defaults across non-app and app-bundle modes")
    func freshDefaultsAreAccurate() throws {
        try withIsolatedDefaults { defaults in
            let cliSettings = MaccarSettings(defaults: defaults, isAppBundle: false, loginItemManager: MockLoginItemManager())
            #expect(cliSettings.startAtLogin == false)
            #expect(cliSettings.autoCheckUpdates == true)
            #expect(cliSettings.skippedVersion == nil)
            #expect(cliSettings.lastUpdateCheckTimestamp == 0)
            #expect(cliSettings.autoConnect == true)
            #expect(cliSettings.autoMirror == true)
            #expect(cliSettings.preferredResolution == "auto")
            #expect(cliSettings.globalShortcutEnabled == true)
            #expect(cliSettings.isConfigured == false)
            #expect(cliSettings.lastLoginItemError == nil)

            let _: any SettingsProviding = cliSettings
            let _: any LoginItemManaging = SystemLoginItemManager()
        }

        try withIsolatedDefaults { defaults in
            let appSettings = MaccarSettings(defaults: defaults, isAppBundle: true, loginItemManager: MockLoginItemManager(status: .notRegistered))
            #expect(appSettings.startAtLogin == false)
            #expect(appSettings.loginItemStatus == .notRegistered)
            #expect(appSettings.autoCheckUpdates == true)
            #expect(appSettings.skippedVersion == nil)
            #expect(appSettings.lastUpdateCheckTimestamp == 0)
            #expect(appSettings.autoConnect == true)
        }
    }

    @Test("Updater preferences persist, trim skippedVersion whitespace, and clear on nil or blank")
    func updaterPreferencesPersistTrimAndClear() throws {
        try withIsolatedDefaults { defaults in
            let settings = MaccarSettings(defaults: defaults, isAppBundle: false, loginItemManager: MockLoginItemManager())
            settings.autoCheckUpdates = false
            settings.lastUpdateCheckTimestamp = 1_762_000_123.5
            settings.skippedVersion = "  v1.3.1 \n"

            #expect(settings.autoCheckUpdates == false)
            #expect(settings.lastUpdateCheckTimestamp == 1_762_000_123.5)
            #expect(settings.skippedVersion == "v1.3.1")

            let reloaded = MaccarSettings(defaults: defaults, isAppBundle: false, loginItemManager: MockLoginItemManager())
            #expect(reloaded.autoCheckUpdates == false)
            #expect(reloaded.lastUpdateCheckTimestamp == 1_762_000_123.5)
            #expect(reloaded.skippedVersion == "v1.3.1")

            reloaded.skippedVersion = "   \t\n "
            #expect(reloaded.skippedVersion == nil)
            #expect(defaults.object(forKey: "maccar_skipped_version") == nil)

            reloaded.skippedVersion = "v1.3.2"
            #expect(reloaded.skippedVersion == "v1.3.2")

            reloaded.skippedVersion = nil
            #expect(reloaded.skippedVersion == nil)
            #expect(defaults.object(forKey: "maccar_skipped_version") == nil)
        }
    }

    @Test("Non-app bundle mode isolates UserDefaults and never invokes LoginItemManaging")
    func nonAppBundleModeIsolatesLoginItemManager() throws {
        try withIsolatedDefaults { defaults in
            let manager = MockLoginItemManager(status: .notRegistered)
            let settings = MaccarSettings(defaults: defaults, isAppBundle: false, loginItemManager: manager)

            #expect(settings.loginItemStatus == .notApplicable)
            #expect(settings.startAtLogin == false)

            settings.startAtLogin = true
            #expect(settings.startAtLogin == true)
            settings.syncLoginItemOnLaunch()
            settings.startAtLogin = false
            #expect(settings.startAtLogin == false)

            #expect(settings.loginItemStatus == .notApplicable)
            #expect(manager.registerCalls == 0)
            #expect(manager.unregisterCalls == 0)
            #expect(manager.statusAccessCount == 0)
        }
    }

    @Test("App bundle mode reflects status and calls register/unregister with intent persistence")
    func appBundleLoginItemReadWriteSync() throws {
        try withIsolatedDefaults { defaults in
            let manager = MockLoginItemManager(status: .notRegistered)
            let settings = MaccarSettings(defaults: defaults, isAppBundle: true, loginItemManager: manager)

            #expect(settings.startAtLogin == false)
            #expect(settings.loginItemStatus == .notRegistered)

            settings.startAtLogin = true
            #expect(manager.registerCalls == 1)
            #expect(manager.unregisterCalls == 0)
            #expect(settings.startAtLogin == true)
            #expect(settings.loginItemStatus == .enabled)
            #expect(settings.lastLoginItemError == nil)
            #expect(defaults.bool(forKey: "maccar_start_at_login") == true)

            settings.startAtLogin = false
            #expect(manager.unregisterCalls == 1)
            #expect(settings.startAtLogin == false)
            #expect(settings.loginItemStatus == .notRegistered)
            #expect(settings.lastLoginItemError == nil)
            #expect(defaults.bool(forKey: "maccar_start_at_login") == false)
        }
    }

    @Test("Requires-approval login item status keeps startAtLogin false and exposes status")
    func requiresApprovalStatusKeepsStartAtLoginFalse() throws {
        try withIsolatedDefaults { defaults in
            let manager = MockLoginItemManager(status: .notRegistered, statusAfterRegister: .requiresApproval)
            let settings = MaccarSettings(defaults: defaults, isAppBundle: true, loginItemManager: manager)

            settings.startAtLogin = true

            #expect(manager.registerCalls == 1)
            #expect(settings.loginItemStatus == .requiresApproval)
            #expect(settings.startAtLogin == false)
            #expect(defaults.bool(forKey: "maccar_start_at_login") == false)
            // The user's intent survives even though the system has not granted it yet:
            // approval can arrive later, in System Settings, without Maccar running.
            #expect(defaults.object(forKey: "maccar_start_at_login_intent") as? Bool == true)
        }
    }

    @Test("An absent intent key means the user never opted in, and launch sync honours that")
    func syncLoginItemOnLaunchDoesNotRegisterWithoutIntent() throws {
        try withIsolatedDefaults { defaults in
            let manager = MockLoginItemManager(status: .notRegistered)
            let settings = MaccarSettings(defaults: defaults, isAppBundle: true, loginItemManager: manager)

            settings.syncLoginItemOnLaunch()
            #expect(manager.registerCalls == 0)
            #expect(manager.unregisterCalls == 0)
            #expect(settings.loginItemStatus == .notRegistered)
            #expect(settings.startAtLogin == false)
        }
    }

    @Test("Launch sync registers when the user's intent is present, even if the item is missing")
    func syncLoginItemOnLaunchRegistersPersistedIntent() throws {
        try withIsolatedDefaults { defaults in
            // This is the D4 bug: intent was recorded but the login item was absent, so
            // nothing registered and Maccar never started after a reboot.
            defaults.set(true, forKey: "maccar_start_at_login_intent")
            let manager = MockLoginItemManager(status: .notRegistered)
            let settings = MaccarSettings(defaults: defaults, isAppBundle: true, loginItemManager: manager)

            settings.syncLoginItemOnLaunch()
            #expect(manager.registerCalls == 1)
            #expect(settings.loginItemStatus == .enabled)
            #expect(settings.startAtLogin == true)

            // Idempotent: a second launch must not register again.
            settings.syncLoginItemOnLaunch()
            #expect(manager.registerCalls == 1)
        }
    }

    @Test("Launch sync never overrides a login item awaiting approval")
    func syncLoginItemOnLaunchLeavesRequiresApprovalAlone() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(true, forKey: "maccar_start_at_login_intent")
            let manager = MockLoginItemManager(status: .requiresApproval)
            let settings = MaccarSettings(defaults: defaults, isAppBundle: true, loginItemManager: manager)

            settings.syncLoginItemOnLaunch()
            #expect(manager.registerCalls == 0)
            #expect(settings.loginItemStatus == .requiresApproval)
            #expect(settings.startAtLogin == false)
            #expect(defaults.object(forKey: "maccar_start_at_login_intent") as? Bool == true)
        }
    }

    @Test("A legacy start-at-login flag migrates to the intent key on launch sync")
    func launchSyncMigratesLegacyOptInKey() throws {
        try withIsolatedDefaults { defaults in
            // Shipped builds wrote these two keys; the old opt-in key is the closest
            // available record of what the user asked for.
            defaults.set(true, forKey: "maccar_start_at_login")
            defaults.set(true, forKey: "maccar_launch_at_login_opt_in")
            let manager = MockLoginItemManager(status: .notRegistered)
            let settings = MaccarSettings(defaults: defaults, isAppBundle: true, loginItemManager: manager)

            settings.syncLoginItemOnLaunch()
            #expect(manager.registerCalls == 1)
            #expect(defaults.object(forKey: "maccar_start_at_login_intent") as? Bool == true)
        }
    }

    @Test("The menu shows the user's intent, not the granted status, when approval is pending")
    func menuItemReflectsIntentWhileAwaitingApproval() throws {
        try withIsolatedDefaults { defaults in
            let manager = MockLoginItemManager(status: .notRegistered, statusAfterRegister: .requiresApproval)
            let settings = MaccarSettings(defaults: defaults, isAppBundle: true, loginItemManager: manager)

            settings.startAtLogin = true

            // macOS granted nothing, but the user *did* opt in. Showing an unchecked item
            // would invite a second press that re-registers instead of switching the feature
            // off — the exact trap that made D4 look unfixable.
            let item = settings.launchAtLoginMenuItem
            #expect(item.isOn == true)
            #expect(item.needsApproval == true)
            #expect(item.title.contains("Approve"))

            // Toggling from the menu must therefore turn the feature *off*, not re-register.
            settings.startAtLogin = !item.isOn
            #expect(manager.registerCalls == 1)
            #expect(manager.unregisterCalls == 1)
            #expect(settings.startAtLoginIntent == false)
            #expect(settings.launchAtLoginMenuItem.isOn == false)
        }
    }

    @Test("The menu item is checked only when the user opted in, and never claims a grant it lacks")
    func menuItemStatesFollowIntentAndGrant() throws {
        try withIsolatedDefaults { defaults in
            let enabled = MaccarSettings(
                defaults: defaults, isAppBundle: true, loginItemManager: MockLoginItemManager(status: .enabled)
            )
            defaults.set(true, forKey: "maccar_start_at_login_intent")
            #expect(enabled.launchAtLoginMenuItem == LaunchAtLoginMenuItem(isOn: true, title: "Launch at Login", needsApproval: false))
        }

        try withIsolatedDefaults { defaults in
            // Intent recorded, item missing: launch sync will register it, so the menu must
            // already read as "on" rather than flickering off for one menu build.
            defaults.set(true, forKey: "maccar_start_at_login_intent")
            let pendingRegister = MaccarSettings(
                defaults: defaults, isAppBundle: true, loginItemManager: MockLoginItemManager(status: .notRegistered)
            )
            #expect(pendingRegister.launchAtLoginMenuItem.isOn == true)
            #expect(pendingRegister.launchAtLoginMenuItem.needsApproval == false)
        }

        try withIsolatedDefaults { defaults in
            let untouched = MaccarSettings(
                defaults: defaults, isAppBundle: true, loginItemManager: MockLoginItemManager(status: .notRegistered)
            )
            #expect(untouched.launchAtLoginMenuItem == LaunchAtLoginMenuItem(isOn: false, title: "Launch at Login", needsApproval: false))
        }

        try withIsolatedDefaults { defaults in
            // The CLI has no login item at all and must never render an actionable toggle.
            defaults.set(true, forKey: "maccar_start_at_login_intent")
            let cli = MaccarSettings(
                defaults: defaults, isAppBundle: false, loginItemManager: MockLoginItemManager(status: .notRegistered)
            )
            #expect(cli.launchAtLoginMenuItem.isOn == false)
        }
    }

    @Test("Register and unregister failures record error, log warning, and sync defaults to actual status")
    func registerAndUnregisterErrorsAreCaughtLoggedAndSynced() throws {
        try withIsolatedDefaults { defaults in
            let registerToken = "register-err-\(UUID().uuidString)"
            let registerManager = MockLoginItemManager(status: .notRegistered)
            registerManager.registerError = MockLoginError.failed(registerToken)

            let settings = MaccarSettings(
                defaults: defaults,
                isAppBundle: true,
                loginItemManager: registerManager
            )
            // Seed stale true in defaults to prove rollback syncs back to actual .notRegistered status.
            defaults.set(true, forKey: "maccar_start_at_login")

            settings.startAtLogin = true

            #expect(settings.lastLoginItemError == registerToken)
            #expect(settings.startAtLogin == false)
            #expect(defaults.bool(forKey: "maccar_start_at_login") == false)
            #expect(MaccarLogger.shared.recentEntries().contains {
                $0.level == .warning && $0.category == "Settings" && $0.message.contains(registerToken)
            })
        }

        try withIsolatedDefaults { defaults in
            let unregisterToken = "unregister-err-\(UUID().uuidString)"
            let unregisterManager = MockLoginItemManager(status: .enabled)
            unregisterManager.unregisterError = MockLoginError.failed(unregisterToken)

            let settings = MaccarSettings(
                defaults: defaults,
                isAppBundle: true,
                loginItemManager: unregisterManager
            )
            defaults.set(false, forKey: "maccar_start_at_login")

            settings.startAtLogin = false

            #expect(settings.lastLoginItemError == unregisterToken)
            #expect(settings.startAtLogin == true)
            #expect(defaults.bool(forKey: "maccar_start_at_login") == true)
            #expect(MaccarLogger.shared.recentEntries().contains {
                $0.level == .warning && $0.category == "Settings" && $0.message.contains(unregisterToken)
            })

            // Recovery clears previous error.
            unregisterManager.unregisterError = nil
            settings.startAtLogin = false
            #expect(settings.lastLoginItemError == nil)
            #expect(settings.startAtLogin == false)
            #expect(defaults.bool(forKey: "maccar_start_at_login") == false)
        }
    }
}
