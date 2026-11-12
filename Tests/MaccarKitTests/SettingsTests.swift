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

    @Test("App bundle mode reflects status and calls register/unregister with opt-in persistence")
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
            #expect(defaults.bool(forKey: "maccar_launch_at_login_opt_in") == true)

            settings.startAtLogin = false
            #expect(manager.unregisterCalls == 1)
            #expect(settings.startAtLogin == false)
            #expect(settings.loginItemStatus == .notRegistered)
            #expect(settings.lastLoginItemError == nil)
            #expect(defaults.bool(forKey: "maccar_start_at_login") == false)
            #expect(defaults.bool(forKey: "maccar_launch_at_login_opt_in") == false)
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
        }
    }

    @Test("syncLoginItemOnLaunch registers only when opt-in is true and status is notRegistered")
    func syncLoginItemOnLaunchRespectsOptIn() throws {
        try withIsolatedDefaults { defaults in
            let freshManager = MockLoginItemManager(status: .notRegistered)
            let freshSettings = MaccarSettings(defaults: defaults, isAppBundle: true, loginItemManager: freshManager)

            freshSettings.syncLoginItemOnLaunch()
            #expect(freshManager.registerCalls == 0)
            #expect(freshManager.unregisterCalls == 0)
            #expect(freshSettings.loginItemStatus == .notRegistered)
            #expect(freshSettings.startAtLogin == false)
        }

        try withIsolatedDefaults { defaults in
            defaults.set(true, forKey: "maccar_launch_at_login_opt_in")
            let optedInManager = MockLoginItemManager(status: .notRegistered)
            let optedInSettings = MaccarSettings(defaults: defaults, isAppBundle: true, loginItemManager: optedInManager)

            optedInSettings.syncLoginItemOnLaunch()
            #expect(optedInManager.registerCalls == 1)
            #expect(optedInSettings.loginItemStatus == .enabled)
            #expect(optedInSettings.startAtLogin == true)
            #expect(defaults.bool(forKey: "maccar_start_at_login") == true)

            optedInSettings.syncLoginItemOnLaunch()
            #expect(optedInManager.registerCalls == 1)
        }

        try withIsolatedDefaults { defaults in
            defaults.set(true, forKey: "maccar_launch_at_login_opt_in")
            let approvalManager = MockLoginItemManager(status: .requiresApproval)
            let approvalSettings = MaccarSettings(defaults: defaults, isAppBundle: true, loginItemManager: approvalManager)

            approvalSettings.syncLoginItemOnLaunch()
            #expect(approvalManager.registerCalls == 0)
            #expect(approvalSettings.loginItemStatus == .requiresApproval)
            #expect(approvalSettings.startAtLogin == false)
            #expect(defaults.bool(forKey: "maccar_start_at_login") == false)
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
