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
                menu.addItem(makeItem("Register iPad to Connect...", action: #selector(changeDeviceNameTapped), isEnabled: enabled))
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

    func addTargetDeviceSubmenu(registered: String?, reachableDevices: [String]) {
        let targetMenu = NSMenu()
        targetMenu.autoenablesItems = false
        let enabled = !isOperationBusy
        targetMenu.addItem(makeDisabledItem(registered.map { "Target: \($0)" } ?? "No iPad Registered"))
        targetMenu.addItem(NSMenuItem.separator())

        if reachableDevices.isEmpty {
            targetMenu.addItem(makeDisabledItem("No reachable iPads detected"))
        } else {
            for device in reachableDevices {
                let selected = registered.map { device.caseInsensitiveCompare($0) == .orderedSame } ?? false
                targetMenu.addItem(makeItem("Select '\(device)'", action: #selector(deviceSelectedTapped(_:)), representedObject: device, isOn: selected, isEnabled: enabled))
            }
        }

        targetMenu.addItem(NSMenuItem.separator())
        targetMenu.addItem(makeItem("Set Custom iPad Name...", action: #selector(changeDeviceNameTapped), isEnabled: enabled))
        if registered != nil { targetMenu.addItem(makeItem("Unregister iPad", action: #selector(clearDeviceNameTapped), isEnabled: enabled)) }

        let targetParent = NSMenuItem(title: "Target iPad Device", action: nil, keyEquivalent: "")
        targetParent.submenu = targetMenu
        menu.addItem(targetParent)
    }

    func addSettingsSection(
        autoConnect: Bool,
        autoMirror: Bool,
        startAtLogin: Bool,
        shortcutEnabled: Bool,
        shortcutLabel: String,
        shortcutConflictLabel: String?,
        autoCheckUpdates: Bool
    ) {
        menu.addItem(makeItem("Auto-Connect on USB", action: #selector(toggleAutoConnect), isOn: autoConnect))
        menu.addItem(makeItem("Auto-Mirroring", action: #selector(toggleAutoMirror), isOn: autoMirror))
        menu.addItem(makeItem("Launch at Login", action: #selector(toggleLaunchAtLogin), isOn: startAtLogin))
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
