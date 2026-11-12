import Foundation
import AppKit
import MaccarKit

@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    private static let fallbackDeviceName = "iPad"

    private var statusItem: NSStatusItem?
    let menu = NSMenu()
    private let isPreview: Bool
    private var updateController: UpdateController?
    private var cachedReachableDevices: [String] = []
    var cachedAvailableModes: [DisplayModeInfo] = []
    private var isDisconnectInFlight: Bool = false
    private var isResolutionSwitchInFlight: Bool = false
    private var isCacheRefreshInFlight: Bool = false
    private var isMenuOpen: Bool = false
    private var pendingMenuRebuild: Bool = false

    /// Exposed so `ScreenshotExporter` can render the live menu without a status item.
    internal var previewMenu: NSMenu { menu }

    var isOperationBusy: Bool { isDisconnectInFlight || isResolutionSwitchInFlight }

    public override convenience init() { self.init(isPreview: false) }

    internal init(isPreview: Bool) {
        self.isPreview = isPreview
        super.init()
        cachedReachableDevices = DeviceWatcher.shared.cachedReachableDevices
        guard !isPreview else { return }
        setupStatusItem()
        wireUpdateController()
        HotKeyManager.shared.syncWithSettings { [weak self] in
            Task { @MainActor [weak self] in self?.triggerReconnectFromHotKey() }
        }
        updateTitle(for: DeviceWatcher.shared.status)
        setupMenu()
        observeWatcher()
        refreshCachesInBackground()
        UpdateController.shared.autoCheckIfDue()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = MaccarIconRenderer.renderMenuBarIcon(connected: false)
            button.imagePosition = .imageOnly
            button.toolTip = "Maccar - Headless Virtual Display & Sidecar Manager"
            button.setAccessibilityTitle("Maccar")
        }
        menu.autoenablesItems = false
        item.menu = menu
        menu.delegate = self
        statusItem = item
    }

    private func wireUpdateController() {
        let controller = UpdateController.shared
        controller.onChange = { [weak self] in
            Task { @MainActor [weak self] in self?.rebuildMenuSafely() }
        }
        controller.performShutdown = { [weak self] in
            self?.performCleanShutdown()
            NSApplication.shared.terminate(nil)
        }
        updateController = controller
    }

    private func observeWatcher() {
        DeviceWatcher.shared.onStatusChange = { [weak self] status in
            Task { @MainActor [weak self] in self?.handleWatcherStatusChange(status) }
        }
        DeviceWatcher.shared.onReachableDevicesChange = { [weak self] devices in
            Task { @MainActor [weak self] in self?.handleReachableDevicesChange(devices) }
        }
    }

    private func handleWatcherStatusChange(_ status: DeviceWatcherStatus) {
        updateTitle(for: status)
        rebuildMenuSafely()
        if case .connected = status { refreshCachesInBackground(); return }
        if cachedAvailableModes.isEmpty { refreshCachesInBackground() }
    }

    private func handleReachableDevicesChange(_ devices: [String]) {
        guard devices != cachedReachableDevices else { return }
        cachedReachableDevices = devices
        rebuildMenuSafely()
    }

    private func updateTitle(for status: DeviceWatcherStatus) {
        guard let button = statusItem?.button else { return }
        let isConnected = { if case .connected = status { return !isDisconnectInFlight }; return false }()
        let isConnecting = { if case .connecting = status { return true }; return false }()
        let showBusyEllipsis = isOperationBusy || isConnecting

        button.image = MaccarIconRenderer.renderMenuBarIcon(connected: isConnected)
        button.title = showBusyEllipsis ? "…" : ""
        button.imagePosition = showBusyEllipsis ? .imageLeading : .imageOnly

        let baseTooltip = tooltipText(for: status)
        if case .conflict(let conflictLabel) = HotKeyManager.shared.state {
            button.toolTip = "\(baseTooltip)\nGlobal shortcut conflict: \(conflictLabel) is claimed by another app."
        } else {
            button.toolTip = baseTooltip
        }
    }

    private func tooltipText(for status: DeviceWatcherStatus) -> String {
        if isDisconnectInFlight { return "Maccar - Disconnecting..." }
        if isResolutionSwitchInFlight { return "Maccar - Switching virtual display resolution..." }
        switch status {
        case .connected(let name, _, let mirrored):
            return "Maccar - Connected to \(name)\(mirrored ? " (Mirrored)" : " (Mirror pending - click Reconnect to retry)")"
        case .connecting(let name):
            return "Maccar - Connecting to \(name)..."
        case .disconnectedManually(let target):
            return "Maccar - Disconnected ('\(target)' paused; press \(HotKeyManager.shared.currentShortcutLabel) to reconnect)"
        case .waitingForDevice, .autoRetryPaused, .stopped, .error:
            return "Maccar - \(status.displayText)"
        }
    }

    public func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        setupMenu()
        refreshCachesInBackground()
    }

    public func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        guard pendingMenuRebuild else { return }
        pendingMenuRebuild = false
        setupMenu()
    }

    private func rebuildMenuSafely() {
        if isMenuOpen { pendingMenuRebuild = true; return }
        setupMenu()
    }

    private func refreshCachesInBackground() {
        guard !isPreview, !isCacheRefreshInFlight else { return }
        isCacheRefreshInFlight = true
        // Only the Sendable snapshot crosses isolation; `self` stays main-actor isolated.
        Task { @MainActor [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                MenuBarResolutionSupport.fetchCacheSnapshot()
            }.value
            guard let self else { return }
            self.isCacheRefreshInFlight = false
            let devicesChanged = snapshot.reachableDevices != self.cachedReachableDevices
            let modesChanged = snapshot.availableModes != self.cachedAvailableModes
            guard devicesChanged || modesChanged else { return }
            if devicesChanged { self.cachedReachableDevices = snapshot.reachableDevices }
            if modesChanged { self.cachedAvailableModes = snapshot.availableModes }
            self.rebuildMenuSafely()
        }
    }

    public func setupMenu() {
        let settings = MaccarSettings.shared
        let hotKey = HotKeyManager.shared
        var conflictLabel: String?
        if case .conflict(let label) = hotKey.state { conflictLabel = label }
        populateMenu(
            status: DeviceWatcher.shared.status,
            registered: normalizedRegisteredName(settings.registeredDeviceName),
            reachableDevices: cachedReachableDevices,
            autoConnect: settings.autoConnect,
            autoMirror: settings.autoMirror,
            startAtLogin: settings.startAtLogin,
            shortcutEnabled: settings.globalShortcutEnabled,
            shortcutLabel: hotKey.currentShortcutLabel,
            shortcutConflictLabel: conflictLabel,
            preferredResolution: settings.preferredResolution,
            autoCheckUpdates: settings.autoCheckUpdates,
            isCheckingForUpdates: updateController?.isChecking ?? false,
            availableUpdateVersion: updateController?.availableUpdateVersion
        )
    }

    internal func populateMenu(
        status: DeviceWatcherStatus,
        registered: String?,
        reachableDevices: [String] = [],
        autoConnect: Bool,
        autoMirror: Bool,
        startAtLogin: Bool,
        shortcutEnabled: Bool,
        shortcutLabel: String,
        shortcutConflictLabel: String? = nil,
        preferredResolution: String,
        autoCheckUpdates: Bool = true,
        isCheckingForUpdates: Bool = false,
        availableUpdateVersion: String? = nil
    ) {
        menu.removeAllItems()
        let statusTitle = isDisconnectInFlight
            ? "Status: Disconnecting '\(activeTargetName(status: status, registered: registered))'..."
            : "Status: \(status.displayText)"

        menu.addItem(makeDisabledItem(statusTitle))
        menu.addItem(NSMenuItem.separator())
        addConnectionSection(status: status, registered: registered, shortcutEnabled: shortcutEnabled, shortcutLabel: shortcutLabel)
        addResolutionSubmenu(currentResolutionKey: preferredResolution)
        addTargetDeviceSubmenu(registered: registered, reachableDevices: reachableDevices)
        menu.addItem(NSMenuItem.separator())
        addSettingsSection(
            autoConnect: autoConnect,
            autoMirror: autoMirror,
            startAtLogin: startAtLogin,
            shortcutEnabled: shortcutEnabled,
            shortcutLabel: shortcutLabel,
            shortcutConflictLabel: shortcutConflictLabel,
            autoCheckUpdates: autoCheckUpdates
        )
        menu.addItem(NSMenuItem.separator())
        addUpdateItem(isChecking: isCheckingForUpdates, availableVersion: availableUpdateVersion)
        menu.addItem(makeItem("Diagnostics & Logs...", action: #selector(logsTapped), key: "l"))
        menu.addItem(makeItem("About Maccar...", action: #selector(aboutTapped)))
        menu.addItem(makeItem("Quit Maccar", action: #selector(quitTapped), key: "q"))
    }

    private func normalizedRegisteredName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func activeTargetName(status: DeviceWatcherStatus, registered: String?) -> String {
        if case .connected(let name, _, _) = status { return name }
        if case .connecting(let name) = status { return name }
        return registered ?? Self.fallbackDeviceName
    }

    private func canDispatchReconnect(source: String) -> Bool {
        guard !isOperationBusy else {
            MaccarLogger.shared.debug("MenuBar", "Ignoring \(source) reconnect while another operation is in flight.")
            return false
        }
        if case .connecting = DeviceWatcher.shared.status {
            MaccarLogger.shared.debug("MenuBar", "Coalesced \(source) reconnect while connection attempt is already in progress.")
            return false
        }
        return true
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func aboutTapped() { AboutWindowController.shared.show() }

    @objc private func logsTapped() {
        MaccarLogger.shared.info("MenuBar", "Opened Diagnostics & Logs window.")
        LogWindowController.shared.show()
    }

    @objc func checkForUpdatesTapped() { updateController?.checkForUpdates() }

    @objc func reconnectTapped() {
        guard canDispatchReconnect(source: "menu") else { return }
        guard let reg = normalizedRegisteredName(MaccarSettings.shared.registeredDeviceName) else {
            changeDeviceNameTapped()
            return
        }
        MaccarLogger.shared.info("MenuBar", "User triggered Reconnect for '\(reg)'.")
        DeviceWatcher.shared.reconnectNow()
        rebuildMenuSafely()
    }

    private func triggerReconnectFromHotKey() {
        guard canDispatchReconnect(source: "hotkey") else { return }
        DeviceWatcher.shared.reconnectNow()
        rebuildMenuSafely()
    }

    @objc func clearDeviceNameTapped() {
        guard !isOperationBusy else { return }
        MaccarSettings.shared.registeredDeviceName = nil
        DeviceWatcher.shared.clearTargetState()
        MaccarLogger.shared.info("MenuBar", "Cleared registered iPad device name.")
        updateTitle(for: DeviceWatcher.shared.status)
        setupMenu()
    }

    @objc func disconnectTapped() {
        guard !isOperationBusy else { return }
        let status = DeviceWatcher.shared.status
        let registered = normalizedRegisteredName(MaccarSettings.shared.registeredDeviceName)
        let targetName = activeTargetName(status: status, registered: registered)

        isDisconnectInFlight = true
        updateTitle(for: status)
        setupMenu()

        // Only the Sendable error text crosses isolation; `self` stays main-actor isolated.
        Task { @MainActor [weak self] in
            let errorMessage = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try DeviceWatcher.shared.disconnectManually(deviceName: targetName)
                    return nil
                } catch {
                    MaccarLogger.shared.error("MenuBar", "Failed to disconnect '\(targetName)': \(error.localizedDescription)")
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            self.isDisconnectInFlight = false
            self.updateTitle(for: DeviceWatcher.shared.status)
            self.rebuildMenuSafely()
            if let errorMessage { self.showAlert(title: "Failed to Disconnect", message: errorMessage) }
        }
    }

    @objc func resolutionTapped(_ sender: NSMenuItem) {
        guard !isOperationBusy, let resKey = sender.representedObject as? String else { return }
        let previousKey = MaccarSettings.shared.preferredResolution
        isResolutionSwitchInFlight = true
        updateTitle(for: DeviceWatcher.shared.status)
        setupMenu()

        // Only the Sendable outcome crosses isolation; `self` stays main-actor isolated.
        Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                MenuBarResolutionSupport.executeResolutionSwitch(resKey: resKey, previousKey: previousKey)
            }.value
            guard let self else { return }
            self.isResolutionSwitchInFlight = false
            self.cachedAvailableModes = outcome.availableModes
            self.updateTitle(for: DeviceWatcher.shared.status)
            self.rebuildMenuSafely()
            if let errorMessage = outcome.errorMessage { self.showAlert(title: "Failed to Switch Display Resolution", message: errorMessage) }
        }
    }

    @objc func deviceSelectedTapped(_ sender: NSMenuItem) {
        guard let dev = sender.representedObject as? String else { return }
        MaccarSettings.shared.registeredDeviceName = dev
        MaccarLogger.shared.info("MenuBar", "Selected target iPad device '\(dev)'.")
        setupMenu()
        guard canDispatchReconnect(source: "device selection") else { return }
        DeviceWatcher.shared.reconnectNow()
    }

    @objc func changeDeviceNameTapped() {
        let alert = NSAlert()
        alert.messageText = "Register iPad Device Name"
        alert.informativeText = "Enter the exact name of your iPad as shown in iOS Settings > General > About (e.g., 'VPad'):"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = MaccarSettings.shared.registeredDeviceName ?? "VPad"
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        MaccarSettings.shared.registeredDeviceName = text
        MaccarLogger.shared.info("MenuBar", "Registered target iPad '\(text)'.")
        setupMenu()
        if canDispatchReconnect(source: "device registration") { DeviceWatcher.shared.reconnectNow() }
    }

    @objc func toggleAutoConnect() {
        let enabled = !MaccarSettings.shared.autoConnect
        MaccarSettings.shared.autoConnect = enabled
        DeviceWatcher.shared.setAutoConnectEnabled(enabled)
        MaccarLogger.shared.info("MenuBar", "Auto-Connect set to \(enabled).")
        updateTitle(for: DeviceWatcher.shared.status)
        setupMenu()
    }

    @objc func toggleAutoMirror() {
        MaccarSettings.shared.autoMirror.toggle()
        MaccarLogger.shared.info("MenuBar", "Auto-Mirror set to \(MaccarSettings.shared.autoMirror).")
        setupMenu()
    }

    @objc func toggleLaunchAtLogin() {
        let settings = MaccarSettings.shared
        settings.startAtLogin.toggle()
        MaccarLogger.shared.info("MenuBar", "Launch at Login set to \(settings.startAtLogin).")
        if settings.loginItemStatus == .requiresApproval {
            showAlert(
                title: "Approve Launch at Login",
                message: "macOS needs your approval. Open System Settings > General > Login Items and enable Maccar."
            )
        }
        setupMenu()
    }

    @objc func toggleGlobalShortcut() {
        MaccarSettings.shared.globalShortcutEnabled.toggle()
        HotKeyManager.shared.syncWithSettings()
        updateTitle(for: DeviceWatcher.shared.status)
        setupMenu()
    }

    @objc func toggleAutoCheckUpdates() {
        let settings = MaccarSettings.shared
        settings.autoCheckUpdates.toggle()
        MaccarLogger.shared.info("MenuBar", "Auto-Check Updates set to \(settings.autoCheckUpdates).")
        if settings.autoCheckUpdates { updateController?.autoCheckIfDue() }
        setupMenu()
    }

    internal func performCleanShutdown() {
        DeviceWatcher.shared.stop()
        HotKeyManager.shared.unregister()
        VirtualDisplayService.shared.destroy()
        MaccarLogger.shared.info("App", "Maccar shutting down cleanly.")
        _ = MaccarLogger.shared.flush(timeout: 1.0)
    }

    @objc private func quitTapped() {
        performCleanShutdown()
        NSApplication.shared.terminate(nil)
    }
}
