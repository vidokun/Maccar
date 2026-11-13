import Foundation
import AppKit
import MaccarKit

private let defaultAppVersion = "1.3.0"

func printUsage() {
    print("""
    Maccar — Native Headless Virtual Display & Sidecar Manager for macOS

    Usage:
        maccar
            Run as a native Menu Bar application (default).

        maccar status
            Check virtual display & Sidecar capabilities and discover devices.

        maccar virtual [mini | air | pro11 | pro13 | ipad | 1080p | 1440p | 4k | off]
            Create, configure, or destroy a virtual display.

        maccar mirror [on | off]
            Configure display mirroring to the iPad.

        maccar connect [device_name] [-wireless]
            Connect to an iPad via Sidecar (defaults to wired + auto-recovery).

        maccar disconnect [device_name]
            Disconnect from an iPad.

        maccar daemon
            Run in headless daemon mode keeping the virtual display and auto-connect active.

        maccar --version
            Print the running Maccar version and exit.

        maccar --export-screenshots <dir>
            Render the release screenshots offscreen into <dir> and exit.
    """)
}

@MainActor
func handleStatus() {
    print("=== Maccar System Status ===")
    let vdSupported = VirtualDisplayService.shared.isSupported
    print("Virtual Display API: \(vdSupported ? "Available" : "Unavailable")")

    let scSupported = SidecarService.shared.isSupported
    print("SidecarCore API:     \(scSupported ? "Available" : "Unavailable")")

    let settings = MaccarSettings.shared
    print("Registered iPad:     \(settings.registeredDeviceName ?? "(None configured)")")
    print("Auto-Connect:        \(settings.autoConnect ? "Enabled" : "Disabled")")
    print("Auto-Mirror:         \(settings.autoMirror ? "Enabled" : "Disabled")")
    let shortcutStatus = settings.globalShortcutEnabled ? "Enabled (\(HotKeyManager.primaryShortcutLabel))" : "Disabled"
    print("Global Shortcut:     \(shortcutStatus)")
    print("Log File:            \(MaccarLogger.shared.logFileURL.path)")

    if scSupported {
        do {
            let devices = try SidecarService.shared.reachableDevices()
            let summary = devices.isEmpty ? "None detected" : devices.joined(separator: ", ")
            print("Reachable iPads:     \(summary)")
        } catch {
            print("Reachable iPads:     Error (\(error.localizedDescription))")
        }
        let connected = SidecarService.shared.connectedDevices()
        print("Connected iPads:     \(connected.isEmpty ? "None" : connected.joined(separator: ", "))")
    }

    let online = DisplayMirrorManager.shared.onlineDisplays()
    print("Online Display IDs:  \(online.map { String($0) }.joined(separator: ", "))")

    if let vdID = VirtualDisplayService.shared.activeDisplayID {
        if let ipadID = DisplayMirrorManager.shared.findIPadDisplay(excludingVirtualDisplayID: vdID),
           DisplayMirrorManager.shared.isMirrored(ipadDisplay: ipadID, toVirtualDisplay: vdID) {
            print("Mirror Status:       Mirrored (DisplayID: \(ipadID))")
        } else {
            print("Mirror Status:       Not mirrored (Virtual DisplayID: \(vdID))")
        }
    } else {
        print("Mirror Status:       No active virtual display in CLI process")
    }
}

private let supportedVirtualAliases: Set<String> = [
    "mini", "ipad_mini", "ipad_mini_comfortable", "ipad_mini_balanced",
    "ipad_mini_large", "ipad_mini_native", "ipad_mini_max",
    "air", "ipad_air", "ipad_air_comfortable", "ipad_air_native",
    "pro11", "ipad_pro_11", "ipad_pro_11_comfortable", "ipad_pro_11_native",
    "pro13", "ipad_pro_13", "ipad_pro_13_comfortable", "ipad_pro_13_native",
    "1080p", "1440p", "4k",
    "ipad", "ipad_4_3", "ipad_4_3_comfortable", "ipad_4_3_native"
]

func resolveVirtualResolution(for arg: String) -> DisplayResolution? {
    switch arg.lowercased() {
    case "ipad_pro11":
        return .ipadPro11Comfortable
    case "ipad_pro13":
        return .ipadPro13Comfortable
    case let key where supportedVirtualAliases.contains(key):
        return DisplayResolution.from(key: key)
    default:
        return nil
    }
}

func handleVirtual(arg: String) {
    let service = VirtualDisplayService.shared
    if arg.lowercased() == "off" {
        service.destroy()
        _ = MaccarLogger.shared.flush(timeout: 0.5)
        print("Virtual display destroyed.")
        return
    }

    guard let res = resolveVirtualResolution(for: arg) else {
        print("Unknown resolution: \(arg). Choose mini, air, pro11, pro13, 1080p, 1440p, 4k, ipad, or off.")
        exit(1)
    }

    do {
        let id = try service.create(resolution: res)
        print("Created \(res.name) virtual display (DisplayID: \(id))")
        print("Maccar is keeping the virtual display active in memory. Press Ctrl+C to stop.")
        RunLoop.current.run()
    } catch {
        print("Failed to create virtual display: \(error.localizedDescription)")
        exit(1)
    }
}

func handleMirror(arg: String) {
    guard let vdID = VirtualDisplayService.shared.activeDisplayID else {
        print("No active virtual display found.")
        exit(1)
    }

    if arg.lowercased() == "off" {
        guard let ipad = DisplayMirrorManager.shared.findIPadDisplay(excludingVirtualDisplayID: vdID) else {
            print("No secondary display found to unmirror.")
            exit(1)
        }
        do {
            try DisplayMirrorManager.shared.disableMirroring(ipadDisplay: ipad)
            _ = MaccarLogger.shared.flush(timeout: 0.5)
            print("Mirroring disabled for display \(ipad).")
        } catch {
            print("Failed to disable mirroring: \(error.localizedDescription)")
            exit(1)
        }
        return
    }

    do {
        if let ipad = try DisplayMirrorManager.shared.autoMatchAndMirror(virtualDisplayID: vdID) {
            _ = MaccarLogger.shared.flush(timeout: 0.5)
            print("Mirrored iPad display (ID: \(ipad)) to virtual display (ID: \(vdID)).")
        } else {
            print("No iPad display detected to mirror.")
        }
    } catch {
        print("Failed to configure mirroring: \(error.localizedDescription)")
        exit(1)
    }
}

func resolveConnectTarget(from args: [String]) -> (device: String, wired: Bool) {
    var targetDevice: String?
    var wired = true

    for arg in args {
        if arg == "-wireless" {
            wired = false
        } else if !arg.hasPrefix("-") && targetDevice == nil {
            targetDevice = arg
        }
    }

    if let explicit = targetDevice {
        return (explicit, wired)
    }
    if let reg = MaccarSettings.shared.registeredDeviceName, !reg.isEmpty {
        return (reg, wired)
    }

    do {
        let devices = try SidecarService.shared.reachableDevices()
        guard let first = devices.first else {
            print("No reachable iPad detected. Ensure iPad is unlocked and connected via USB or same Wi-Fi.")
            exit(2)
        }
        print("Auto-selected iPad: '\(first)'")
        return (first, wired)
    } catch {
        print("Device discovery failed: \(error.localizedDescription)")
        exit(2)
    }
}

func handleConnect(args: [String]) {
    let target = resolveConnectTarget(from: args)
    print("Connecting to '\(target.device)' (\(target.wired ? "Wired" : "Wireless"))...")

    do {
        try SidecarService.shared.connect(deviceName: target.device, wired: target.wired)
        print("Connected to '\(target.device)' successfully.")

        if let vdID = VirtualDisplayService.shared.activeDisplayID {
            Thread.sleep(forTimeInterval: 1.0)
            if let ipad = try? DisplayMirrorManager.shared.autoMatchAndMirror(virtualDisplayID: vdID) {
                print("Auto-mirrored to iPad display (ID: \(ipad)).")
            }
        }
        _ = MaccarLogger.shared.flush(timeout: 0.5)
    } catch {
        _ = MaccarLogger.shared.flush(timeout: 0.5)
        print("Connection failed: \(error.localizedDescription)")
        exit(4)
    }
}

func handleDisconnect(args: [String]) {
    let targetDevice = args.first ?? MaccarSettings.shared.registeredDeviceName ?? "iPad"
    guard SidecarService.shared.isDeviceConnected(deviceName: targetDevice) else {
        print("'\(targetDevice)' is not currently connected.")
        _ = MaccarLogger.shared.flush(timeout: 0.5)
        return
    }

    print("Disconnecting from '\(targetDevice)'...")

    do {
        try SidecarService.shared.disconnect(deviceName: targetDevice, ignoreNotConnected: false)
        _ = MaccarLogger.shared.flush(timeout: 0.5)
        print("Disconnected from '\(targetDevice)' successfully.")
    } catch {
        _ = MaccarLogger.shared.flush(timeout: 0.5)
        print("Disconnect failed: \(error.localizedDescription)")
        exit(1)
    }
}

@MainActor
func handleDaemon() {
    requireSingleInstance()

    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? defaultAppVersion
    MaccarLogger.shared.info("App", "Starting Maccar daemon v\(version).")
    print("Starting Maccar daemon v\(version)...")

    let preferredKey = MaccarSettings.shared.preferredResolution
    let initialRes = (preferredKey == "auto") ? DisplayResolution.ipadMiniComfortable : DisplayResolution.from(key: preferredKey)
    do {
        let displayID = try VirtualDisplayService.shared.create(resolution: initialRes)
        print("Active headless virtual display ID: \(displayID) (\(initialRes.name))")
    } catch {
        MaccarLogger.shared.warning("App", "Daemon virtual display creation warning: \(error.localizedDescription)")
        print("Warning: Could not create virtual display: \(error.localizedDescription)")
    }

    DeviceWatcher.shared.start()
    print("Maccar daemon running with auto-connect. Press Ctrl+C to exit.")
    RunLoop.current.run()
}

/// Retained for the whole process lifetime: `SingleInstanceGuard` releases its
/// kernel lock in `deinit`, so a local-only reference would silently void it.
private var retainedInstanceGuard: SingleInstanceGuard?

/// Ensures only one process ever runs a `DeviceWatcher`.
///
/// Two instances would each issue `connect()` into the same Sidecar session
/// manager, which produces `-100` rejections and one stacked system alert per
/// failed call. Scoped to the paths that start a watcher — never to `MaccarKit`
/// itself — so the test runner and read-only CLI subcommands stay unaffected.
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

    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? defaultAppVersion
    MaccarLogger.shared.info("App", "Maccar v\(version) Menu Bar application starting.")
    MaccarSettings.shared.syncLoginItemOnLaunch()

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
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? defaultAppVersion
        print("Maccar \(version)")
    case "--export-screenshots", "export-screenshots":
        let outputPath = subArgs.first ?? "assets/screenshots"
        do {
            try MainActor.assumeIsolated { try ScreenshotExporter.export(to: URL(fileURLWithPath: outputPath)) }
            print("Screenshots written to \(outputPath)")
        } catch {
            FileHandle.standardError.write(Data("Screenshot export failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    case "status":
        handleStatus()
    case "virtual":
        handleVirtual(arg: subArgs.first ?? "1080p")
    case "mirror":
        handleMirror(arg: subArgs.first ?? "on")
    case "connect":
        handleConnect(args: subArgs)
    case "disconnect":
        handleDisconnect(args: subArgs)
    case "daemon":
        handleDaemon()
    case "help", "-h", "--help":
        printUsage()
    default:
        print("Unknown command: '\(command)'")
        printUsage()
        exit(1)
    }
}
