import AppKit
import MaccarKit

/// Builds the "Copy Diagnostics" payload from live state.
///
/// Kept apart from `MenuBarController` for the same reason as `MenuBarMenuBuilder`: the
/// controller owns lifecycle, this owns the one-time read of every subsystem, and the
/// report formatting itself stays in `MaccarKit` where it is unit-tested.
extension MenuBarController {
    func currentDiagnosticsSnapshot() -> DiagnosticsSnapshot {
        let settings = MaccarSettings.shared
        return DiagnosticsSnapshot(
            appVersion: MaccarAppInfo.shortVersion,
            appBuild: MaccarAppInfo.buildNumber,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            registeredDeviceName: settings.registeredDeviceName,
            autoConnectEnabled: settings.autoConnect,
            autoMirrorEnabled: settings.autoMirror,
            shortcutLabel: settings.globalShortcutEnabled ? HotKeyManager.shared.currentShortcutLabel : nil,
            startAtLoginIntent: settings.startAtLoginIntent,
            loginItemStatus: settings.loginItemStatus.rawValue,
            logFilePath: MaccarLogger.shared.logFileURL.path,
            reachableDevices: reachableDeviceNames(),
            reachableDevicesError: reachableDevicesErrorText(),
            connectedDevices: SidecarService.shared.connectedDevices(),
            mirrorStatus: mirrorStatusText()
        )
    }

    /// The menu rebuilds on every status change, so this must not touch a subsystem.
    func diagnosticsVersionLine() -> String {
        "Version \(MaccarAppInfo.displayString)"
    }

    @objc func copyDiagnosticsTapped() {
        let pasted = NSPasteboard.general
        pasted.clearContents()
        pasted.setString(DiagnosticsReport.render(currentDiagnosticsSnapshot()), forType: .string)
        MaccarLogger.shared.info("MenuBar", "Copied diagnostics report to the clipboard.")
    }

    private func reachableDeviceNames() -> [String] {
        (try? SidecarService.shared.reachableDevices()) ?? []
    }

    /// A failed lookup and an empty list mean different things, so the failure is carried
    /// into the report instead of collapsing both into "none found".
    private func reachableDevicesErrorText() -> String? {
        guard SidecarService.shared.isSupported else { return "SidecarCore unavailable" }
        do {
            _ = try SidecarService.shared.reachableDevices()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func mirrorStatusText() -> String {
        guard let virtualDisplayID = VirtualDisplayService.shared.activeDisplayID else {
            return "No active virtual display"
        }
        guard let iPadDisplayID = DisplayMirrorManager.shared.mirroredIPadDisplayID else {
            return "Virtual display \(virtualDisplayID) active, no iPad mirrored"
        }
        return "Mirrored (Virtual \(virtualDisplayID) <- iPad \(iPadDisplayID))"
    }
}
