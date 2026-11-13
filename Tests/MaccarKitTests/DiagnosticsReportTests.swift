import Foundation
import Testing
@testable import MaccarKit

@Suite("DiagnosticsReport Tests")
struct DiagnosticsReportTests {
    private func makeSnapshot(
        appVersion: String = "1.4.1",
        appBuild: String? = "7",
        operatingSystemVersion: String = "Version 15.2 (Build 24C101)",
        registeredDeviceName: String? = "VPad",
        autoConnectEnabled: Bool = true,
        autoMirrorEnabled: Bool = true,
        shortcutLabel: String? = "⌃⌥⌘R",
        startAtLoginIntent: Bool = true,
        loginItemStatus: String = "enabled",
        logFilePath: String = "~/Library/Logs/Maccar/maccar.log",
        reachableDevices: [String] = ["VPad"],
        reachableDevicesError: String? = nil,
        connectedDevices: [String] = ["VPad"],
        mirrorStatus: String = "Mirrored (DisplayID: 48)"
    ) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            appVersion: appVersion,
            appBuild: appBuild,
            operatingSystemVersion: operatingSystemVersion,
            registeredDeviceName: registeredDeviceName,
            autoConnectEnabled: autoConnectEnabled,
            autoMirrorEnabled: autoMirrorEnabled,
            shortcutLabel: shortcutLabel,
            startAtLoginIntent: startAtLoginIntent,
            loginItemStatus: loginItemStatus,
            logFilePath: logFilePath,
            reachableDevices: reachableDevices,
            reachableDevicesError: reachableDevicesError,
            connectedDevices: connectedDevices,
            mirrorStatus: mirrorStatus
        )
    }

    @Test("Report carries the version, build, and registered iPad")
    func reportCarriesCoreFacts() {
        let report = DiagnosticsReport.render(makeSnapshot())

        #expect(report.contains("1.4.1"))
        #expect(report.contains("7"))
        #expect(report.contains("VPad"))
    }

    @Test("Report never leaks an absolute home directory path")
    func reportHidesHomeDirectory() {
        // A pasted-in-issue report is public. `~/` is readable; `/Users/<name>` identifies
        // the person who filed it.
        let snapshot = makeSnapshot(logFilePath: NSHomeDirectory() + "/Library/Logs/Maccar/maccar.log")
        let report = DiagnosticsReport.render(snapshot)

        #expect(!report.contains("/Users/"))
        #expect(report.contains("~/Library/Logs/Maccar/maccar.log"))
    }

    @Test("Absent device and failed discovery are stated, not omitted")
    func reportStatesAbsenceExplicitly() {
        let snapshot = makeSnapshot(
            registeredDeviceName: nil,
            reachableDevices: [],
            reachableDevicesError: "SidecarCore unavailable",
            connectedDevices: [],
            mirrorStatus: "No active virtual display"
        )
        let report = DiagnosticsReport.render(snapshot)

        // An empty value is ambiguous: "none configured" and "lookup failed" must not
        // render identically, or the report cannot be acted on.
        #expect(report.contains("(None configured)"))
        #expect(report.contains("SidecarCore unavailable"))
        #expect(report.contains("No active virtual display"))
    }

    @Test("Report distinguishes the user's intent from the macOS grant")
    func reportSeparatesIntentFromGrant() {
        let awaitingApproval = DiagnosticsReport.render(
            makeSnapshot(startAtLoginIntent: true, loginItemStatus: "requiresApproval")
        )
        let declinedByUser = DiagnosticsReport.render(
            makeSnapshot(startAtLoginIntent: false, loginItemStatus: "notRegistered")
        )

        // This is the D4 ambiguity: the user asked, macOS has not confirmed. A report that
        // shows only one side of that pair cannot diagnose the bug it was written for.
        #expect(awaitingApproval.contains("requiresApproval"))
        #expect(awaitingApproval.contains("requested"))
        #expect(declinedByUser.contains("not registered"))
        #expect(awaitingApproval != declinedByUser)
    }

    @Test("A missing build number is omitted rather than reported as build 0")
    func reportOmitsUnknownBuild() {
        // The debug binary has no Info.plist. Rendering "build 0" would read as the first
        // build of the release and send a bug report chasing the wrong artifact.
        let report = DiagnosticsReport.render(makeSnapshot(appBuild: nil))

        #expect(report.contains("1.4.1"))
        #expect(!report.contains("build 0"))
        #expect(!report.contains("build nil"))
    }

    @Test("Report includes every section heading so a partial paste is detectable")
    func reportHasStableSections() {
        let report = DiagnosticsReport.render(makeSnapshot())

        for heading in ["Maccar", "macOS", "Launch at Login", "Devices", "Mirror"] {
            #expect(report.contains(heading))
        }
    }
}
