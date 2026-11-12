import AppKit
import MaccarKit

/// Owns every user-visible update interaction: the 24h background check, the
/// confirmation alert, and the download/install hand-off. All state is main-actor
/// isolated because it drives NSMenuItem titles and NSAlert windows.
@MainActor
public final class UpdateController {
    public enum Phase: Equatable {
        case idle
        case checking
        case available(version: String)
        case failed(message: String)
    }

    public static let shared = UpdateController()

    /// Automatic checks run at most once per day.
    private static let autoCheckInterval: TimeInterval = 86_400
    /// A stored timestamp further ahead than this is treated as clock skew, not as a recent check.
    private static let maximumClockSkew: TimeInterval = 3_600

    private let settings: any UpdateSettingsProviding
    private let updater: any UpdateChecking
    private let isUnpinnedBuild: Bool
    private var isCheckInFlight = false

    public private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onChange?() } }
    }

    /// Fired whenever `phase` changes so the menu can relabel its update item.
    public var onChange: (() -> Void)?
    /// Injected by `MenuBarController` so an install can tear the app down cleanly.
    public var performShutdown: (() -> Void)?

    public convenience init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let publicKey = (info["MaccarUpdatePublicKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(settings: MaccarSettings.shared, updater: ReleaseUpdater(), isUnpinnedBuild: publicKey.isEmpty)
    }

    public init(settings: any UpdateSettingsProviding, updater: any UpdateChecking, isUnpinnedBuild: Bool) {
        self.settings = settings
        self.updater = updater
        self.isUnpinnedBuild = isUnpinnedBuild
    }

    public var isChecking: Bool { phase == .checking }

    public var availableUpdateVersion: String? {
        guard case .available(let version) = phase else { return nil }
        return version
    }

    /// Runs the daily background check when one is due, honouring the auto-check toggle.
    public func autoCheckIfDue() {
        guard settings.autoCheckUpdates, !isCheckInFlight else { return }
        let now = Date().timeIntervalSince1970
        let lastCheck = settings.lastUpdateCheckTimestamp
        let skewAdjustedLast = lastCheck > now + Self.maximumClockSkew ? 0 : lastCheck
        guard now - skewAdjustedLast >= Self.autoCheckInterval else { return }
        checkForUpdates(userInitiated: false)
    }

    public func checkForUpdates(userInitiated: Bool = true) {
        guard !isCheckInFlight else { return }
        isCheckInFlight = true
        phase = .checking
        Task { @MainActor in
            do {
                let availability = try await updater.checkForUpdates()
                self.isCheckInFlight = false
                self.settings.lastUpdateCheckTimestamp = Date().timeIntervalSince1970
                self.handle(availability: availability, userInitiated: userInitiated)
            } catch {
                self.isCheckInFlight = false
                self.handleFailure(error, userInitiated: userInitiated)
            }
        }
    }

    private func handle(availability: UpdateAvailability, userInitiated: Bool) {
        switch availability {
        case .upToDate:
            phase = .idle
            if userInitiated { presentUpToDateAlert() }
        case .available(let candidate):
            guard let version = AppVersion(versionString: candidate.manifest.version, build: candidate.manifest.build) else {
                phase = .failed(message: ReleaseUpdateError.invalidManifest("Unparsable version.").localizedDescription)
                return
            }
            if !userInitiated, isSkipped(candidate.manifest.version) { phase = .idle; return }
            phase = .available(version: version.formatted)
            presentAvailableAlert(candidate, version: version)
        }
    }

    private func handleFailure(_ error: Error, userInitiated: Bool) {
        let message = error.localizedDescription
        MaccarLogger.shared.warning("Updater", "Update check failed: \(message)")
        phase = .failed(message: message)
        guard userInitiated else { return }
        let alert = NSAlert()
        alert.messageText = "Could Not Check for Updates"
        alert.informativeText = "\(message)\n\nYou can download the latest release manually."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Releases Page")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/vidokun/Maccar/releases")!)
        }
    }

    private func presentUpToDateAlert() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let alert = NSAlert()
        alert.messageText = "You Are Up to Date"
        alert.informativeText = "Maccar v\(current) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentAvailableAlert(_ candidate: UpdateCandidate, version: AppVersion) {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let trust = trustDescription(for: candidate.trustLevel)
        let notes = candidate.manifest.releaseNotesSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = notes.isEmpty ? "No release notes summary was provided." : notes

        let alert = NSAlert()
        alert.messageText = "Maccar v\(version.formatted) is Available"
        alert.informativeText = "You are running v\(current).\nVerified via \(trust).\n\n\(summary)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download & Install")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            install(candidate)
        case .alertThirdButtonReturn:
            settings.skippedVersion = candidate.manifest.version
            phase = .idle
        default:
            phase = .idle
        }
    }

    /// Ad-hoc builds cannot prove publisher identity, so the user must confirm before replacing the app.
    private func trustDescription(for level: UpdateTrustLevel) -> String {
        switch level {
        case .ed25519Pinned: return "Ed25519 signature + SHA-256"
        case .teamIdVerified: return "Team ID continuity + SHA-256"
        case .sha256Unpinned:
            return isUnpinnedBuild ? "SHA-256 only (ad-hoc build; confirmation required)" : "SHA-256 + codesign"
        }
    }

    private func install(_ candidate: UpdateCandidate) {
        if candidate.trustLevel == .sha256Unpinned {
            let alert = NSAlert()
            alert.messageText = "Ad-Hoc Build: SHA-256 Verified Only"
            alert.informativeText = "This build carries no signature pinning, so macOS cannot confirm who published the update. "
                + "Maccar verified the SHA-256 digest and code signature only. Continue with the install?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        phase = .checking
        Task { @MainActor in
            do {
                let staged = try await updater.downloadAndStageUpdate(candidate)
                try updater.installStagedUpdate(staged)
                MaccarLogger.shared.info("Updater", "Staged Maccar v\(candidate.manifest.version) and handed off to the swap helper.")
                if let performShutdown { performShutdown() } else { NSApplication.shared.terminate(nil) }
            } catch {
                let message = error.localizedDescription
                MaccarLogger.shared.error("Updater", "Update install failed: \(message)")
                phase = .failed(message: message)
                presentInstallFailure(message, candidate: candidate)
            }
        }
    }

    private func presentInstallFailure(_ message: String, candidate: UpdateCandidate) {
        let alert = NSAlert()
        alert.messageText = "Update Could Not Be Installed"
        alert.informativeText = "\(message)\n\nYou can download v\(candidate.manifest.version) manually."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Release Notes")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        openReleaseNotes(for: candidate)
    }

    /// Only allowlisted HTTPS destinations reach the browser.
    private func openReleaseNotes(for candidate: UpdateCandidate) {
        guard let url = URL(string: candidate.manifest.releaseNotesUrl),
              (try? TrustedReleaseURLValidator.validateURL(url)) != nil else {
            MaccarLogger.shared.warning("Updater", "Refused to open an untrusted release notes URL.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func isSkipped(_ version: String) -> Bool {
        guard let skipped = settings.skippedVersion else { return false }
        return AppVersion(versionString: skipped, build: 0) == AppVersion(versionString: version, build: 0)
    }
}
