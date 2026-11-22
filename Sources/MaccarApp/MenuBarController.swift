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
    /// Session-scoped memory of which unregistered iPads have already been offered (Wave 4).
    private let unknownDeviceCoordinator = UnknownDeviceCoordinator()
    var cachedAvailableModes: [DisplayModeInfo] = []
    private var isDisconnectInFlight: Bool = false
    private var isResolutionSwitchInFlight: Bool = false
    private var isCacheRefreshInFlight: Bool = false
    private var isMenuOpen: Bool = false
    private var pendingMenuRebuild: Bool = false

    /// Exposed so `ScreenshotExporter` can render the live menu without a status item.
    /// The exporter is DEBUG-only, but the property is not: gating it here would couple
    /// this controller to a build flag for no gain, and `isPreview` is used in release too.
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
        // Its own channel: the watcher is already in `.waitingForDevice` when the cable goes in, so
        // no status change fires. Without this, launching first and plugging in second never
        // offered the iPad at all.
        DeviceWatcher.shared.onUSBDeviceAttached = { [weak self] in
            Task { @MainActor [weak self] in self?.handleUSBReattach() }
        }
    }

    private func handleWatcherStatusChange(_ status: DeviceWatcherStatus) {
        updateTitle(for: status)
        rebuildMenuSafely()
        if case .connected = status { refreshCachesInBackground(); return }
        // The reachable-devices callback fires only when that list *changes*, and at launch it
        // usually changes while a connect is in flight — when the prompt is deliberately skipped.
        // Re-evaluating on every status transition gives it the chance it otherwise never gets.
        promptForUnknownDeviceIfNeeded()
        if cachedAvailableModes.isEmpty { refreshCachesInBackground() }
    }

    /// A cable came back. Any "Not Now" from before it is stale, so the prompt may ask again.
    ///
    /// Called from the same attach notification that wakes the reconnect path, which is what makes
    /// "dismiss lasts for the session" true — the previous build checked an `offered` mark that
    /// never expired, so one decline silenced the iPad until the app was restarted.
    private func handleUSBReattach() {
        unknownDeviceCoordinator.noteUSBReattach()
        promptForUnknownDeviceIfNeeded()
    }

    private func handleReachableDevicesChange(_ devices: [String]) {
        guard devices != cachedReachableDevices else { return }
        cachedReachableDevices = devices
        rebuildMenuSafely()
        promptForUnknownDeviceIfNeeded()
    }

    /// Offers to register an iPad Maccar has never seen (Wave 4 / DD-4).
    ///
    /// Deliberately not tied to a `connect()`: registering changes only the registry, so this
    /// cannot raise an Apple popup. `UnknownDeviceCoordinator` guarantees each device is offered at
    /// most once per session, and "Not Now" is remembered for the session only so a later replug
    /// may ask again.
    private func promptForUnknownDeviceIfNeeded() {
        guard !isOperationBusy else { return }
        // A headless Mac has no screen to answer a pairing dialog on, and `connect(wired:)` refuses
        // without a cable anyway — so asking about an iPad that is not plugged in is noise at best
        // and a dead end at worst. Same presence source as the connect gate, so the two cannot
        // disagree about whether an iPad is there.
        guard DeviceWatcher.shared.isIPadAttached else { return }
        guard let reachable = try? SidecarService.shared.reachableDevicesWithIdentity() else { return }

        let registry = DeviceRegistry.shared
        // Sidecar lists what it has *paired with*, which includes Wi-Fi devices, and it exposes no
        // per-device transport, so the app cannot say which reachable identity is on the cable —
        // only whether *some* iPad is. That boolean is the gate above; passing the reachable set
        // here is therefore all the filtering this layer can honestly do. Naming it
        // `attachedIdentifiers` when the list is reachable would be a lie inside the call site.
        guard let candidate = unknownDeviceCoordinator.nextUnknownDevice(
            reachable: reachable,
            registeredIdentifiers: Set(registry.devices.map(\.identifier)),
            currentTargetName: MaccarSettings.shared.registeredDeviceName,
            attachedIdentifiers: Set(reachable.map(\.identifier))
        ) else { return }

        MaccarLogger.shared.info("MenuBar", "Offering to register a newly detected iPad.")

        let alert = NSAlert()
        alert.messageText = "New iPad detected"
        alert.informativeText = "Register '\(candidate.name)' so Maccar can connect to it? You can switch between registered iPads from the Menu Bar."
        alert.addButton(withTitle: "Register")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            // Scoped to this attach: a replug is a new decision point, and the menu also offers
            // "Register Connected iPad..." so a decline is never a dead end.
            unknownDeviceCoordinator.dismiss(identifier: candidate.identifier)
            MaccarLogger.shared.info("MenuBar", "Declined to register a newly detected iPad for this attach.")
            return
        }

        register(candidate)
    }

    /// Menu action: register whatever iPad is on the cable right now.
    ///
    /// This is the manual door the prompt cannot always provide — the prompt fires once per attach
    /// and stands down while a connect is in flight, so without this a user who missed it had no
    /// way back. It scans rather than asking for a name: the registry is keyed by Sidecar's stable
    /// identifier, and only the device itself can supply that.
    @objc func scanForAttachedDeviceTapped() {
        guard !isOperationBusy else { return }
        guard DeviceWatcher.shared.isIPadAttached else {
            showAlert(title: "No iPad Connected",
                      message: "Plug your iPad in with a USB-C cable, then try again. Maccar only registers an iPad it can actually connect to.")
            return
        }
        guard let reachable = try? SidecarService.shared.reachableDevicesWithIdentity(), !reachable.isEmpty else {
            showAlert(title: "No iPad Found",
                      message: "macOS has no paired iPad to register. Connect the iPad once over USB-C and make sure Sidecar can see it.")
            return
        }

        let registry = DeviceRegistry.shared
        let known = Set(registry.devices.map(\.identifier))
        let candidates = ScanCandidates.unknown(reachable: reachable, registeredIdentifiers: known)

        guard !candidates.isEmpty else {
            let names = registry.devices.map(\.name).joined(separator: ", ")
            showAlert(title: "Already Registered",
                      message: names.isEmpty
                        ? "No iPad is available to register."
                        : "Every reachable iPad is already registered (\(names)). Choose one from Target iPad Device.")
            return
        }

        // Always show what can be registered, even when there is only one — the user asked to see
        // the list rather than have a single device registered silently. With two or more this is
        // also what keeps the choice explicit instead of guessing.
        let picker = NSAlert()
        picker.messageText = "Register iPad"
        picker.informativeText = candidates.count == 1
            ? "This iPad is connected. Register it for Maccar to use?"
            : "More than one iPad is available. Pick the one you are using."
        for candidate in candidates { picker.addButton(withTitle: candidate.name) }
        picker.addButton(withTitle: "Cancel")
        let index = picker.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard index >= 0, index < candidates.count else { return }
        register(candidates[index])
    }

    /// The one place a device is adopted into the registry, whichever door led here.
    private func register(_ device: SidecarDevice) {
        let registry = DeviceRegistry.shared
        registry.register(device)
        DeviceRegistryStore.shared.save(registry)
        unknownDeviceCoordinator.clearDismissal(identifier: device.identifier)
        MaccarLogger.shared.info("MenuBar", "Registered iPad '\(device.name)' (\(device.identifier)).")
        setupMenu()
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
            return "Maccar - Connected to \(name)\(mirrored ? " (Mirrored)" : " (Not mirrored - click Reconnect)")"
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
            registered: resolvedTargetName(),
            reachableDevices: cachedReachableDevices,
            autoConnect: settings.autoConnect,
            launchAtLogin: settings.launchAtLoginMenuItem,
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
        launchAtLogin: LaunchAtLoginMenuItem,
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
        // Physical presence decides the reported transport: Sidecar does not expose it, and a
        // session that survives the cable coming out is exactly what "on Wi-Fi" means here.
        let onCable = DeviceWatcher.shared.isIPadAttached
        addConnectionSection(
            status: status, registered: registered,
            shortcutEnabled: shortcutEnabled, shortcutLabel: shortcutLabel,
            isOnCable: onCable
        )
        addResolutionSubmenu(currentResolutionKey: preferredResolution)
        // Wave 3.3: once the registry knows about devices, the menu is registry-backed and
        // identifier-keyed. Before that it falls back to the legacy typed-name submenu, so an
        // upgrading user keeps working exactly as before until a device is registered.
        let registryDevices = DeviceRegistry.shared.devices
        if registryDevices.isEmpty {
            addTargetDeviceSubmenu(registered: registered, reachableDevices: reachableDevices)
        } else {
            addRegistryDeviceSubmenu(
                devices: registryDevices,
                activeIdentifier: DeviceRegistry.shared.activeDevice?.identifier,
                reachableIdentifiers: registryReachableIdentifiers(),
                fallbackRegisteredName: registered
            )
        }
        menu.addItem(NSMenuItem.separator())
        addSettingsSection(
            autoConnect: autoConnect,
            wirelessEnabled: WirelessSession.shared.isEnabled,
            canEnableWireless: onCable,
            isOnWiFi: DeviceWatcher.shared.isConnectedOverWiFi,
            launchAtLogin: launchAtLogin,
            shortcutEnabled: shortcutEnabled,
            shortcutLabel: shortcutLabel,
            shortcutConflictLabel: shortcutConflictLabel,
            autoCheckUpdates: autoCheckUpdates
        )
        menu.addItem(NSMenuItem.separator())
        addUpdateItem(isChecking: isCheckingForUpdates, availableVersion: availableUpdateVersion)
        menu.addItem(makeItem("Copy Diagnostics", action: #selector(copyDiagnosticsTapped)))
        menu.addItem(makeItem("Diagnostics & Logs...", action: #selector(logsTapped), key: "l"))
        menu.addItem(makeItem("About Maccar...", action: #selector(aboutTapped)))
        menu.addItem(NSMenuItem.separator())
        // Version belongs in the menu: with no CLI `--version`, opening About was the only
        // way to read it, and a support conversation starts with "which build are you on?".
        menu.addItem(makeDisabledItem(diagnosticsVersionLine()))
        menu.addItem(makeItem("Quit Maccar", action: #selector(quitTapped), key: "q"))
    }

    /// Identifiers Sidecar reports right now, or `nil` when the query fails — in which case the
    /// menu must not claim a device is "(not detected)" on the strength of an error.
    private func registryReachableIdentifiers() -> Set<String>? {
        guard let devices = try? SidecarService.shared.reachableDevicesWithIdentity() else { return nil }
        return Set(devices.map(\.identifier))
    }

    /// The one place the menu layer decides which iPad it is talking about.
    ///
    /// Every caller — the status line, Reconnect, Disconnect — goes through this, so they cannot
    /// disagree with each other the way the status line and the submenu once did.
    private func resolvedTargetName() -> String? {
        MenuTargetResolver.targetName(
            registryActiveName: DeviceRegistry.shared.activeDevice?.name,
            legacyName: MaccarSettings.shared.registeredDeviceName,
            registryHasDevices: !DeviceRegistry.shared.devices.isEmpty
        )
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
        // Same resolved target the menu displays, so the button cannot act on a device the menu
        // is not showing. Nothing to reconnect means nothing to do — the menu only offers this
        // item when a target exists, and there is no longer a "register by typing" fallback.
        guard let reg = resolvedTargetName() else { return }
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
        // "Unregister iPad" must mean *forgotten*, not merely "name cleared". Leaving the registry
        // entry behind made the action useless: the app still considered the iPad known, so it was
        // never offered for registration again and the Wave-4 prompt could not fire.
        let registry = DeviceRegistry.shared
        if let active = registry.activeDevice {
            registry.forget(identifier: active.identifier)
            unknownDeviceCoordinator.clearDismissal(identifier: active.identifier)
            DeviceRegistryStore.shared.save(registry)
        }
        // The legacy name is cleared too, so the migration path cannot silently re-adopt the device
        // the user just forgot.
        MaccarSettings.shared.registeredDeviceName = nil
        DeviceWatcher.shared.clearTargetState()
        MaccarLogger.shared.info("MenuBar", "Unregistered the iPad and removed it from the device registry.")
        updateTitle(for: DeviceWatcher.shared.status)
        setupMenu()
    }

    @objc func disconnectTapped() {
        guard !isOperationBusy else { return }
        let status = DeviceWatcher.shared.status
        let registered = resolvedTargetName()
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

    /// Selects a registered device by identifier (Wave 3.3).
    ///
    /// Identifier-keyed, so a rename between sessions cannot retarget the app at a different iPad.
    /// The selection is persisted immediately: the user's choice must survive a crash before the
    /// next connect completes.
    @objc func registryDeviceSelectedTapped(_ sender: NSMenuItem) {
        guard !isOperationBusy, let identifier = sender.representedObject as? String else { return }
        let registry = DeviceRegistry.shared
        registry.setActive(identifier: identifier)
        DeviceRegistryStore.shared.save(
            devices: registry.devices,
            activeIdentifier: registry.activeDevice?.identifier
        )
        MaccarLogger.shared.info("MenuBar", "Selected registered iPad by identifier.")
        setupMenu()
        guard canDispatchReconnect(source: "device selection") else { return }
        DeviceWatcher.shared.reconnectNow()
    }

    /// Removes a device from the registry by identifier.
    ///
    /// If it was the active device, the registry promotes the next one, so the app is never left
    /// pointing at a device it no longer knows. No connect is issued here: forgetting a device is
    /// not a request to connect to another one.
    @objc func registryDeviceForgetTapped(_ sender: NSMenuItem) {
        guard !isOperationBusy, let identifier = sender.representedObject as? String else { return }
        let registry = DeviceRegistry.shared
        registry.forget(identifier: identifier)
        // Forgetting is the inverse of registering, so the prompt must be able to ask about this
        // device again rather than staying silent for the rest of the session.
        unknownDeviceCoordinator.clearDismissal(identifier: identifier)
        DeviceRegistryStore.shared.save(registry)
        MaccarLogger.shared.info("MenuBar", "Forgot registered iPad.")
        DeviceWatcher.shared.clearTargetState()
        updateTitle(for: DeviceWatcher.shared.status)
        setupMenu()
    }

    @objc func changeDeviceNameTapped() {
        // Registration is no longer typed by hand: the "New iPad detected" prompt knows the
        // device's real name and identifier, which a typed string cannot. Kept as a no-op guard
        // rather than removed outright so an older build's menu action (or a stale selector
        // dispatch) cannot crash on a missing method.
        MaccarLogger.shared.info("MenuBar", "Ignoring typed-name registration; plug in an iPad to register it.")
    }

    @objc func toggleAutoConnect() {
        let enabled = !MaccarSettings.shared.autoConnect
        MaccarSettings.shared.autoConnect = enabled
        DeviceWatcher.shared.setAutoConnectEnabled(enabled)
        MaccarLogger.shared.info("MenuBar", "Auto-Connect set to \(enabled).")
        updateTitle(for: DeviceWatcher.shared.status)
        setupMenu()
    }

    @objc func toggleWirelessMode() {
        let session = WirelessSession.shared
        let enabling = !session.isEnabled

        if enabling {
            // Enabling requires a cable: the iPad must be provably present before Maccar takes
            // the risk of a Wi-Fi failure whose popup would appear on a screen nobody can see.
            guard DeviceWatcher.shared.isIPadAttached else {
                MaccarLogger.shared.info("MenuBar", "Wi-Fi Mode needs a cable connection to be enabled.")
                NSSound.beep()
                setupMenu()
                return
            }
            session.enable()
            MaccarLogger.shared.info("MenuBar", "Wi-Fi Mode enabled.")

            // A live session cannot be re-armed in place — Sidecar rejects a second connect with
            // `-100 already in use` (measured 2026-11-21) — so the permission takes effect on a
            // fresh connect. Afterwards Sidecar moves the session between transports on its own.
            DeviceWatcher.shared.reconnectNow()
            setupMenu()
            return
        }

        session.disable()
        MaccarLogger.shared.info("MenuBar", "Wi-Fi Mode disabled.")

        // Turning it off must actually end a Wi-Fi session, otherwise the toggle is decorative:
        // the permission is revoked but the picture keeps arriving over Wi-Fi.
        //
        // This deliberately does NOT go through `disconnectManually()`: that also installs the
        // manual-disconnect hold, which suppresses auto-connect until a replug. Observed on
        // 2026-11-22 — after turning Wi-Fi Mode off, plugging the cable in did nothing, and the
        // log filled with "while manual disconnect hold is active; preserving hold". Disabling a
        // permission is not the same instruction as "leave me disconnected".
        if DeviceWatcher.shared.isConnectedOverWiFi {
            let target = resolvedTargetName()
            if let target {
                do {
                    try SidecarService.shared.disconnect(deviceName: target, ignoreNotConnected: true)
                    MaccarLogger.shared.info("MenuBar", "Closed the Wi-Fi session for '\(target)'.")
                } catch {
                    MaccarLogger.shared.error("MenuBar", "Could not close the Wi-Fi session: \(error.localizedDescription)")
                }
            }
            // Reconnect on whatever transport is available now — the cable if it is attached.
            DeviceWatcher.shared.reconnectNow()
        }
        setupMenu()
    }

    @objc func toggleLaunchAtLogin() {
        let settings = MaccarSettings.shared
        // Flip from the rendered state, not from `startAtLogin`: that getter reports the grant,
        // so with approval pending it would read `false` and send this straight back into a
        // second registration instead of turning the feature off.
        settings.startAtLogin = !settings.launchAtLoginMenuItem.isOn
        MaccarLogger.shared.info(
            "MenuBar",
            "Launch at Login intent set to \(settings.startAtLoginIntent) (macOS reports \(settings.loginItemStatus.rawValue))."
        )
        if settings.shouldPromptForApproval {
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
        // A Wi-Fi session outlives the process that created it — proved on 2026-11-21, where
        // the session stayed connected with Maccar not running. Leaving it alive after a quit
        // would contradict "quitting Maccar turns Wi-Fi off", so it is closed explicitly. The
        // disconnect is unconditional: when the session is wired it is the normal teardown,
        // and when it is on Wi-Fi it is the requirement.
        if WirelessSession.shared.isEnabled {
            let target = resolvedTargetName()
            if let target {
                do {
                    try SidecarService.shared.disconnect(deviceName: target, ignoreNotConnected: true)
                    MaccarLogger.shared.info("App", "Closed the Wi-Fi session for '\(target)' on shutdown.")
                } catch {
                    MaccarLogger.shared.warning("App", "Could not close the Wi-Fi session: \(error.localizedDescription)")
                }
            }
            WirelessSession.shared.disable()
        }
        DeviceWatcher.shared.stop()
        HotKeyManager.shared.unregister()
        VirtualDisplayService.shared.destroy()
        MaccarLogger.shared.info("App", "Maccar shutting down cleanly.")
        _ = MaccarLogger.shared.flush(timeout: 1.0)
    }

    @objc private func quitTapped() {
        // Teardown runs from the AppDelegate's `applicationWillTerminate`, which fires for every
        // exit route. Doing it here too would destroy the display twice; the delegate's guard
        // makes a double call harmless, but the single owner is clearer.
        NSApplication.shared.terminate(nil)
    }
}
