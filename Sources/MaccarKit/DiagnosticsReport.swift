import Foundation

/// A plain-value snapshot of everything a support conversation needs.
///
/// Deliberately free of singletons: the menu controller collects the live values and the
/// renderer stays pure, so the report can be tested without an app, a window, or a device.
public struct DiagnosticsSnapshot: Sendable, Equatable {
    public let appVersion: String
    public let appBuild: String?
    public let operatingSystemVersion: String
    public let registeredDeviceName: String?
    public let autoConnectEnabled: Bool
    public let autoMirrorEnabled: Bool
    public let shortcutLabel: String?
    public let startAtLoginIntent: Bool
    public let loginItemStatus: String
    public let logFilePath: String
    public let reachableDevices: [String]
    public let reachableDevicesError: String?
    public let connectedDevices: [String]
    public let mirrorStatus: String

    public init(
        appVersion: String,
        appBuild: String?,
        operatingSystemVersion: String,
        registeredDeviceName: String?,
        autoConnectEnabled: Bool,
        autoMirrorEnabled: Bool,
        shortcutLabel: String?,
        startAtLoginIntent: Bool,
        loginItemStatus: String,
        logFilePath: String,
        reachableDevices: [String],
        reachableDevicesError: String?,
        connectedDevices: [String],
        mirrorStatus: String
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.operatingSystemVersion = operatingSystemVersion
        self.registeredDeviceName = registeredDeviceName
        self.autoConnectEnabled = autoConnectEnabled
        self.autoMirrorEnabled = autoMirrorEnabled
        self.shortcutLabel = shortcutLabel
        self.startAtLoginIntent = startAtLoginIntent
        self.loginItemStatus = loginItemStatus
        self.logFilePath = logFilePath
        self.reachableDevices = reachableDevices
        self.reachableDevicesError = reachableDevicesError
        self.connectedDevices = connectedDevices
        self.mirrorStatus = mirrorStatus
    }
}

/// Renders a `DiagnosticsSnapshot` as the text "Copy Diagnostics" puts on the pasteboard.
///
/// The output is meant to be pasted into a public issue, so two rules govern it:
/// it must never contain an absolute home directory, and it must never render an unknown
/// value as blank — "unknown" and "none" lead to different fixes.
public enum DiagnosticsReport {
    public static func render(_ snapshot: DiagnosticsSnapshot) -> String {
        var lines: [String] = []
        lines.append("=== Maccar Diagnostics ===")
        lines.append("Maccar:              \(versionDescription(snapshot))")
        lines.append("macOS:               \(snapshot.operatingSystemVersion)")
        lines.append("")
        lines.append("Registered iPad:     \(snapshot.registeredDeviceName ?? "(None configured)")")
        lines.append("Auto-Connect:        \(enabledWord(snapshot.autoConnectEnabled))")
        lines.append("Auto-Mirror:         \(enabledWord(snapshot.autoMirrorEnabled))")
        lines.append("Global Shortcut:     \(shortcutDescription(snapshot.shortcutLabel))")
        lines.append("")
        lines.append("Launch at Login:     \(launchAtLoginDescription(snapshot))")
        lines.append("Log File:            \(compactPath(snapshot.logFilePath))")
        lines.append("")
        lines.append("Devices:")
        lines.append("  Reachable iPads:   \(deviceList(snapshot.reachableDevices, error: snapshot.reachableDevicesError))")
        lines.append("  Connected iPads:   \(deviceList(snapshot.connectedDevices, error: nil))")
        lines.append("Mirror:              \(snapshot.mirrorStatus)")
        return lines.joined(separator: "\n")
    }

    /// A build number is omitted when the bundle has none, so a debug binary is not
    /// reported as `build 0` — which reads as the first build of the release.
    private static func versionDescription(_ snapshot: DiagnosticsSnapshot) -> String {
        guard let build = snapshot.appBuild, !build.isEmpty else { return snapshot.appVersion }
        return "\(snapshot.appVersion) (build \(build))"
    }

    private static func enabledWord(_ isEnabled: Bool) -> String {
        isEnabled ? "Enabled" : "Disabled"
    }

    private static func shortcutDescription(_ label: String?) -> String {
        guard let label, !label.isEmpty else { return "Disabled" }
        return "Enabled (\(label))"
    }

    /// Spells out both halves of the Login at Login state. Reporting only the grant is what
    /// made the D4 defect invisible: macOS says `requiresApproval` while the user's request
    /// stands, and reporting only `requiresApproval` reads as "off".
    private static func launchAtLoginDescription(_ snapshot: DiagnosticsSnapshot) -> String {
        let intent = snapshot.startAtLoginIntent ? "requested" : "not requested"
        let status = statusDescription(snapshot.loginItemStatus)
        return "\(intent) (macOS reports \(status))"
    }

    private static func statusDescription(_ rawStatus: String) -> String {
        switch rawStatus {
        case "notRegistered": return "not registered"
        case "requiresApproval": return "requiresApproval"
        case "notApplicable": return "not applicable"
        default: return rawStatus
        }
    }

    private static func deviceList(_ devices: [String], error: String?) -> String {
        if let error { return "Error (\(error))" }
        return devices.isEmpty ? "None detected" : devices.joined(separator: ", ")
    }

    /// Rewrites the home directory prefix as `~`. A pasted report is public, and the
    /// account name in `/Users/<name>` identifies the person who filed it.
    private static func compactPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty, path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
