import Foundation
import AppKit
import MaccarKit

func printUsage() {
    print("""
    Maccar — Native Headless Virtual Display & Sidecar Manager for macOS

    Maccar is a Menu Bar application. Every display, connection, and device
    setting lives in its menu; there are no command-line subcommands.

    Usage:
        maccar
            Launch the Menu Bar application (default).

        maccar --version
            Print the running Maccar version and exit.

        maccar help
            Show this message.
    """)
}


/// Retained for the whole process lifetime: `SingleInstanceGuard` releases its
/// kernel lock in `deinit`, so a local-only reference would silently void it.
private var retainedInstanceGuard: SingleInstanceGuard?

/// Ensures only one process ever runs a `DeviceWatcher`.
///
/// Two instances would each issue `connect()` into the same Sidecar session
/// manager, which produces `-100` rejections and one stacked system alert per
/// failed call. Scoped to the paths that start a watcher — never to `MaccarKit`
/// itself — so the test runner stays unaffected.
@MainActor
private func requireSingleInstance() {
    let guardInstance = SingleInstanceGuard.makeApplicationGuard()
    guard guardInstance.acquire() else {
        activateRunningInstance()
        MaccarLogger.shared.info("App", "Another Maccar instance already owns the device watcher; exiting this launch.")
        _ = MaccarLogger.shared.flush(timeout: 1.0)
        exit(0)
    }
    retainedInstanceGuard = guardInstance
}

@MainActor
private func activateRunningInstance() {
    let bundleIdentifier = Bundle.main.bundleIdentifier
    let peers = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier ?? "")
    let existing = peers.first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    existing?.activate()
}

@MainActor
func runMenuBarApp() {
    requireSingleInstance()

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let version = MaccarAppInfo.shortVersion
    MaccarLogger.shared.info("App", "Maccar v\(version) Menu Bar application starting.")
    // Runs before the menu is built, so the "Launch at Login" checkbox reflects a login item
    // that was just reconciled rather than one from the previous session.
    MaccarSettings.shared.syncLoginItemOnLaunch()
    MaccarLogger.shared.info(
        "App",
        "Launch at Login: intent \(MaccarSettings.shared.startAtLoginIntent), macOS reports \(MaccarSettings.shared.loginItemStatus.rawValue)."
    )

    let preferredKey = MaccarSettings.shared.preferredResolution
    let initialRes = (preferredKey == "auto") ? DisplayResolution.ipadMiniComfortable : DisplayResolution.from(key: preferredKey)
    do {
        let displayID = try VirtualDisplayService.shared.create(resolution: initialRes)
        MaccarLogger.shared.info("App", "Headless virtual display active: ID \(displayID) (\(initialRes.name)).")
    } catch {
        MaccarLogger.shared.warning("App", "Virtual display creation warning: \(error.localizedDescription)")
    }

    let controller = MenuBarController()
    _ = controller

    DeviceWatcher.shared.start()
    MaccarLogger.shared.info("App", "Menu Bar application ready (shortcut: \(HotKeyManager.shared.currentShortcutLabel)).")
    app.run()
}

// Entrypoint
let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty {
    runMenuBarApp()
} else {
    let command = args.first!.lowercased()
    let subArgs = Array(args.dropFirst())

    switch command {
    case "app", "menubar", "gui":
        runMenuBarApp()
    case "version", "-v", "--version":
        print("Maccar \(MaccarAppInfo.shortVersion)")
    #if DEBUG
    // Release-asset tooling, not a user feature. `scripts/package_app.sh` builds with
    // `-c release`, so this branch and the exporter it calls are absent from the app
    // that ships. Regenerate screenshots with a debug build: `maccar.sh build` then
    // `.build/debug/maccar --export-screenshots assets/screenshots`.
    case "--export-screenshots", "export-screenshots":
        let outputPath = subArgs.first ?? "assets/screenshots"
        do {
            try MainActor.assumeIsolated { try ScreenshotExporter.export(to: URL(fileURLWithPath: outputPath)) }
            print("Screenshots written to \(outputPath)")
        } catch {
            FileHandle.standardError.write(Data("Screenshot export failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    #endif
    case "help", "-h", "--help":
        printUsage()
    default:
        // Maccar has no subcommands: every control lives in the Menu Bar. Saying so
        // plainly beats printing a usage list the caller was already looking at.
        print("Unknown command: '\(command)'. Maccar is a Menu Bar application — open it and use the menu.")
        printUsage()
        exit(1)
    }
}
