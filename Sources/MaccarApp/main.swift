import Foundation
import AppKit
import MaccarKit

/// Runs the app's teardown for every exit route macOS offers.
///
/// The Menu Bar item was the only caller of `performCleanShutdown`, so quitting any other way —
/// Cmd+Q, logout, a system restart, or a terminate from outside — left the virtual display
/// registered with WindowServer. A user reported the result on 2026-11-20: a phantom screen in
/// Displays settings that only a force quit cleared.
///
/// `applicationWillTerminate` is delivered for all of those routes, which is why the teardown
/// lives here rather than in the menu action: a menu action can only fire for the menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `runMenuBarApp` once the controller exists. Teardown is skipped when it is nil,
    /// so a very early terminate (before the app is fully up) cannot crash on missing state.
    var onTerminate: (() -> Void)?

    /// Guards against running twice: the menu item tears down and then calls `terminate`, which
    /// delivers this callback. Both must be safe in either order.
    private var didTearDown = false

    func applicationWillTerminate(_ notification: Notification) {
        guard !didTearDown else { return }
        didTearDown = true
        onTerminate?()
    }
}

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

/// Keeps the AppDelegate alive for the process lifetime.
///
/// `NSApplication.delegate` is a weak reference, so a delegate created inside `runMenuBarApp`
/// would be released as soon as that scope unwound and `applicationWillTerminate` would never
/// be delivered — reintroducing exactly the bug the delegate exists to fix. Held here rather
/// than in a file-level variable because `main.swift` is top-level code, where a global actor
/// annotation is not allowed.
extension AppDelegate {
    @MainActor private static var retainer: AppDelegate?

    @MainActor
    static func install(on app: NSApplication, teardown: @escaping () -> Void) -> AppDelegate {
        let delegate = AppDelegate()
        delegate.onTerminate = teardown
        app.delegate = delegate
        retainer = delegate
        return delegate
    }
}

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

    // Cover every exit route, not just the Menu Bar item. Without this, Cmd+Q and logout skip
    // teardown and leave the virtual display behind — the reported bug.
    _ = AppDelegate.install(on: app) { [weak controller] in controller?.performCleanShutdown() }

    DeviceWatcher.shared.start()
    // Populate the registry from what Sidecar already knows, so the Target iPad submenu shows
    // real devices on first launch instead of staying empty until something is plugged in.
    // Safe to call before start(): it only reads Sidecar and writes UserDefaults.
    //
    // Only the *active* device is adopted implicitly. Registering every device Sidecar has ever
    // paired with would pre-empt the Wave-4 "New iPad detected" prompt, and the user would never
    // be asked about an iPad they have not chosen.
    DeviceWatcher.shared.adoptActiveDeviceIfUnregistered()
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
