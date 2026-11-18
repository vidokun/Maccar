import AppKit
import MaccarKit

/// Menu composition lives apart from `MenuBarController`'s lifecycle and state so
/// neither file drifts past the project LOC ceiling. Every helper here is pure
/// rendering: it reads the values it is given and adds items to `menu`.
extension MenuBarController {
    func addUpdateItem(isChecking: Bool, availableVersion: String?) {
        let enabled = !isOperationBusy && !isChecking
        if let version = availableVersion {
            menu.addItem(makeItem("Update Ready: v\(version)", action: #selector(checkForUpdatesTapped), isEnabled: enabled))
        } else if isChecking {
            menu.addItem(makeDisabledItem("Checking for Updates..."))
        } else {
            menu.addItem(makeItem("Check for Updates...", action: #selector(checkForUpdatesTapped), isEnabled: enabled))
        }
    }

    func addConnectionSection(status: DeviceWatcherStatus, registered: String?, shortcutEnabled: Bool, shortcutLabel: String) {
        let keyEquiv = shortcutEnabled ? "r" : ""
        let keyMask: NSEvent.ModifierFlags? = shortcutEnabled ? activeShortcutModifiers(shortcutLabel: shortcutLabel) : nil
        let enabled = !isOperationBusy

        switch status {
        case .connected(let name, _, _):
            menu.addItem(makeItem("Disconnect '\(name)'", action: #selector(disconnectTapped), key: "d", isEnabled: enabled))
            menu.addItem(makeItem("Reconnect '\(name)' (Reset)", action: #selector(reconnectTapped), key: keyEquiv, modifiers: keyMask, isEnabled: enabled))
        case .connecting(let name):
            menu.addItem(makeDisabledItem("Connecting to '\(name)'..."))
            menu.addItem(makeItem("Force Disconnect '\(name)'", action: #selector(disconnectTapped), key: "d", isEnabled: enabled))
        case .disconnectedManually, .waitingForDevice, .autoRetryPaused, .stopped, .error:
            if let targetName = registered {
                menu.addItem(makeItem("Reconnect to '\(targetName)' Now", action: #selector(reconnectTapped), key: keyEquiv, modifiers: keyMask, isEnabled: enabled))
            } else {
                // No "Register iPad to Connect..." item: registration happens by scanning the
                // attached iPad, not by typing a name that cannot be matched to a device identity.
                menu.addItem(makeItem("Register Connected iPad...", action: #selector(scanForAttachedDeviceTapped), isEnabled: enabled))
            }
        }
    }

    func addResolutionSubmenu(currentResolutionKey: String) {
        let resMenu = NSMenu()
        resMenu.autoenablesItems = false
        let enabled = !isOperationBusy
        resMenu.addItem(makeItem("Auto (Match iPad - Crisp & Full Screen)", action: #selector(resolutionTapped(_:)), representedObject: "auto", isOn: currentResolutionKey == "auto", isEnabled: enabled))

        let supportedKeys = MenuBarResolutionSupport.supportedKeys(from: cachedAvailableModes)
        if supportedKeys == nil {
            resMenu.addItem(NSMenuItem.separator())
            resMenu.addItem(makeDisabledItem("Virtual display inactive - showing all presets"))
        }

        for group in MenuBarResolutionSupport.resolutionGroups {
            let visibleOptions = group.options.filter { supportedKeys?.contains($0.resolution.key) ?? true }
            guard !visibleOptions.isEmpty else { continue }
            resMenu.addItem(NSMenuItem.separator())
            resMenu.addItem(makeDisabledItem(group.header))
            for option in visibleOptions {
                let checked = option.matchingKeys.contains(currentResolutionKey)
                resMenu.addItem(makeItem(option.title, action: #selector(resolutionTapped(_:)), representedObject: option.resolution.key, isOn: checked, isEnabled: enabled))
            }
        }

        let parentItem = NSMenuItem(title: "Virtual Display Resolution", action: nil, keyEquivalent: "")
        parentItem.submenu = resMenu
        menu.addItem(parentItem)
    }

    /// Pre-registry fallback, now only a signpost.
    ///
    /// This used to offer "Select '<name>'" entries plus "Set Custom iPad Name..." and
    /// "Unregister iPad". Both actions wrote `MaccarSettings.registeredDeviceName`, a store the
    /// menu no longer reads, and a hand-typed name could not be matched to a device identity. So
    /// it now explains how registration actually happens instead of offering a path that cannot
    /// work. Kept as a named function because `DeviceRegistry` being empty is a real state (fresh
    /// install, or after Forget).
    func addTargetDeviceSubmenu(registered: String?, reachableDevices: [String]) {
        let targetMenu = NSMenu()
        targetMenu.autoenablesItems = false
        targetMenu.addItem(makeDisabledItem(registered.map { "Target: \($0)" } ?? "No iPad Registered"))
        targetMenu.addItem(NSMenuItem.separator())
        targetMenu.addItem(makeItem("Register Connected iPad...", action: #selector(scanForAttachedDeviceTapped), isEnabled: !isOperationBusy))

        let targetParent = NSMenuItem(title: "Target iPad Device", action: nil, keyEquivalent: "")
        targetParent.submenu = targetMenu
        menu.addItem(targetParent)
    }

    /// Renders the registry-backed device menu (Wave 3.3).
    ///
    /// The rows come from `TargetDeviceMenuBuilder` in `MaccarKit`, which is where the behaviour is
    /// tested — `Package.swift` has no `MaccarAppTests` target, so anything worth asserting has to
    /// live in the library. This method only translates those rows into `NSMenuItem`s.
    ///
    /// Device switching is deliberately an explicit action: every `connect()` can raise an Apple
    /// popup, so adopting a device automatically on attach would produce a stream of them.
    func addRegistryDeviceSubmenu(
        devices: [SidecarDevice],
        activeIdentifier: String?,
        reachableIdentifiers: Set<String>? = nil,
        fallbackRegisteredName: String? = nil
    ) {
        let items = TargetDeviceMenuBuilder.items(
            registryDevices: devices,
            activeIdentifier: activeIdentifier,
            reachableIdentifiers: reachableIdentifiers,
            isEnabled: !isOperationBusy,
            fallbackRegisteredName: fallbackRegisteredName
        )

        let targetMenu = NSMenu()
        targetMenu.autoenablesItems = false
        for item in items {
            switch item.kind {
            case .separator:
                targetMenu.addItem(NSMenuItem.separator())
            case .info:
                targetMenu.addItem(makeDisabledItem(item.title))
            case .select:
                targetMenu.addItem(makeItem(
                    item.title,
                    action: #selector(registryDeviceSelectedTapped(_:)),
                    representedObject: item.identifier,
                    isOn: item.isActive,
                    isEnabled: item.isEnabled
                ))
            case .forget:
                targetMenu.addItem(makeItem(
                    item.title,
                    action: #selector(registryDeviceForgetTapped(_:)),
                    representedObject: item.identifier,
                    isEnabled: item.isEnabled
                ))
            }
        }

        let targetParent = NSMenuItem(title: "Target iPad Device", action: nil, keyEquivalent: "")
        targetParent.submenu = targetMenu
        menu.addItem(targetParent)
    }

    func addSettingsSection(
        autoConnect: Bool,
        autoMirror: Bool,
        launchAtLogin: LaunchAtLoginMenuItem,
        shortcutEnabled: Bool,
        shortcutLabel: String,
        shortcutConflictLabel: String?,
        autoCheckUpdates: Bool
    ) {
        menu.addItem(makeItem("Auto-Connect on USB", action: #selector(toggleAutoConnect), isOn: autoConnect))
        menu.addItem(makeItem("Auto-Mirroring", action: #selector(toggleAutoMirror), isOn: autoMirror))
        menu.addItem(makeItem(launchAtLogin.title, action: #selector(toggleLaunchAtLogin), isOn: launchAtLogin.isOn))
        menu.addItem(makeItem("Global Shortcut (\(shortcutLabel))", action: #selector(toggleGlobalShortcut), isOn: shortcutEnabled))
        if let conflictLabel = shortcutConflictLabel {
            menu.addItem(makeDisabledItem("Shortcut \(conflictLabel) unavailable (claimed by another app)"))
        }
        menu.addItem(makeItem("Auto-Check Updates", action: #selector(toggleAutoCheckUpdates), isOn: autoCheckUpdates))
    }

    func makeItem(
        _ title: String,
        action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags? = nil,
        representedObject: Any? = nil,
        isOn: Bool = false,
        isEnabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if let modifiers, !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        item.representedObject = representedObject
        item.state = isOn ? .on : .off
        item.isEnabled = isEnabled
        item.target = self
        return item
    }

    func makeDisabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func activeShortcutModifiers(shortcutLabel: String) -> NSEvent.ModifierFlags {
        shortcutLabel == HotKeyManager.fallbackShortcutLabel
            ? [.control, .option, .shift, .command]
            : [.control, .option, .command]
    }
}
