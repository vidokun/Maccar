import Foundation
import CoreGraphics
import CMaccarBridge

public final class VirtualDisplayService: @unchecked Sendable {
    public static let shared = VirtualDisplayService()

    private static let initialSettleMaxAttempts = 5
    private static let switchSettleMaxAttempts = 10
    private static let modeSettlePollInterval: TimeInterval = 0.05

    private let lock = NSRecursiveLock()
    private var activeDisplay: MaccarVirtualDisplay?
    private var _currentResolution: DisplayResolution?

    public var activeDisplayID: CGDirectDisplayID? {
        lock.lock()
        defer { lock.unlock() }
        guard let disp = activeDisplay, disp.isValid else { return nil }
        return disp.displayID
    }

    public var currentResolution: DisplayResolution? {
        lock.lock()
        defer { lock.unlock() }
        return _currentResolution
    }

    public var isSupported: Bool {
        MaccarVirtualDisplay.isSupported()
    }

    private init() {}

    deinit {
        destroy()
    }

    public func availableModes() -> [DisplayModeInfo] {
        lock.lock()
        defer { lock.unlock() }
        guard let display = activeDisplay, display.isValid else {
            return []
        }
        return CGDisplayConfigBridge
            .availableDisplayModes(forDisplay: display.displayID)
            .compactMap(DisplayModeInfo.init(dictionary:))
    }

    public func isResolutionSupported(_ resolution: DisplayResolution) -> Bool {
        let modes = availableModes()
        guard !modes.isEmpty else { return false }
        return !DisplayResolution.supportedPresets(presets: [resolution], availableModes: modes).isEmpty
    }

    @discardableResult
    public func create(resolution: DisplayResolution = .ipadMiniComfortable) throws -> CGDirectDisplayID {
        lock.lock()
        defer { lock.unlock() }

        guard isSupported else {
            MaccarLogger.shared.error("VirtualDisplay", "CGVirtualDisplay private classes unavailable on this macOS host.")
            throw VirtualDisplayError.unsupportedRuntime
        }

        if let existing = activeDisplay, existing.isValid {
            return try reuseOrReconfigure(existing: existing, to: resolution)
        }

        let display = try instantiateVirtualDisplay(for: resolution)
        self.activeDisplay = display
        self._currentResolution = resolution
        MaccarLogger.shared.info(
            "VirtualDisplay",
            "Created virtual display \(display.displayID) targeting \(resolution.width)x\(resolution.height) (\(resolution.name))."
        )

        settleInitialMode(on: display.displayID, target: resolution)
        return display.displayID
    }

    public func apply(resolution: DisplayResolution) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let display = activeDisplay, display.isValid else {
            _ = try create(resolution: resolution)
            return
        }

        let modes = availableModes()
        try validateSupportedResolution(resolution, on: display.displayID, availableModes: modes)

        if isDisplayActive(displayID: display.displayID, matching: resolution, availableModes: modes) {
            self._currentResolution = resolution
            return
        }

        let initialSwitched = triggerModeChange(on: display, target: resolution, availableModes: modes)
        if waitForModeSettle(on: display.displayID, target: resolution, initiallySwitched: initialSwitched) {
            return
        }

        MaccarLogger.shared.error(
            "VirtualDisplay",
            "Mode switch to \(resolution.width)x\(resolution.height) did not settle within 500ms on display \(display.displayID); keeping active display intact."
        )
        throw VirtualDisplayError.modeSwitchFailed(resolution)
    }

    public func destroy() {
        lock.lock()
        defer { lock.unlock() }
        if let disp = activeDisplay, disp.isValid {
            MaccarLogger.shared.info("VirtualDisplay", "Destroying virtual display \(disp.displayID).")
        }
        activeDisplay?.destroy()
        activeDisplay = nil
        _currentResolution = nil
    }

    private func reuseOrReconfigure(existing: MaccarVirtualDisplay, to resolution: DisplayResolution) throws -> CGDirectDisplayID {
        let modes = availableModes()
        if isDisplayActive(displayID: existing.displayID, matching: resolution, availableModes: modes) {
            self._currentResolution = resolution
            return existing.displayID
        }
        try apply(resolution: resolution)
        return activeDisplay?.displayID ?? existing.displayID
    }

    private func instantiateVirtualDisplay(for resolution: DisplayResolution) throws -> MaccarVirtualDisplay {
        guard let display = MaccarVirtualDisplay.create(
            withWidth: resolution.width,
            height: resolution.height,
            backingWidth: resolution.backingWidth,
            backingHeight: resolution.backingHeight,
            refreshRate: resolution.refreshRate,
            hiDPI: resolution.hiDPI
        ) else {
            let msg = MaccarVirtualDisplay.lastError() ?? "Failed to create virtual display"
            MaccarLogger.shared.error("VirtualDisplay", "Failed to create virtual display: \(msg)")
            throw VirtualDisplayError.creationFailed(msg)
        }
        return display
    }

    private func settleInitialMode(on displayID: CGDirectDisplayID, target resolution: DisplayResolution) {
        for attempt in 0..<Self.initialSettleMaxAttempts {
            if isDisplayActive(displayID: displayID, matching: resolution, availableModes: availableModes()) {
                return
            }
            let switched = setBridgeDisplayMode(displayID: displayID, target: resolution)
            if switched && isDisplayActive(displayID: displayID, matching: resolution, availableModes: availableModes()) {
                return
            }
            if attempt < Self.initialSettleMaxAttempts - 1 {
                Thread.sleep(forTimeInterval: Self.modeSettlePollInterval)
            }
        }
    }

    private func validateSupportedResolution(
        _ resolution: DisplayResolution,
        on displayID: CGDirectDisplayID,
        availableModes: [DisplayModeInfo]
    ) throws {
        guard !availableModes.isEmpty,
              DisplayResolution.supportedPresets(presets: [resolution], availableModes: availableModes).isEmpty
        else {
            return
        }
        MaccarLogger.shared.warning(
            "VirtualDisplay",
            "Rejected unsupported resolution '\(resolution.name)' (\(resolution.width)x\(resolution.height)) on display \(displayID)."
        )
        throw VirtualDisplayError.unsupportedResolution(resolution)
    }

    private func triggerModeChange(
        on display: MaccarVirtualDisplay,
        target resolution: DisplayResolution,
        availableModes: [DisplayModeInfo]
    ) -> Bool {
        let hasLogicalMode = availableModes.contains {
            $0.usableForDesktop && $0.width == resolution.width && $0.height == resolution.height
        }
        let directSwitched = hasLogicalMode ? setBridgeDisplayMode(displayID: display.displayID, target: resolution) : false
        guard !hasLogicalMode || !directSwitched else { return true }

        let settingsApplied = display.applyWidth(
            resolution.width,
            height: resolution.height,
            backingWidth: resolution.backingWidth,
            backingHeight: resolution.backingHeight,
            refreshRate: resolution.refreshRate,
            hiDPI: resolution.hiDPI
        )
        guard settingsApplied else { return false }

        Thread.sleep(forTimeInterval: Self.modeSettlePollInterval)
        return setBridgeDisplayMode(displayID: display.displayID, target: resolution)
    }

    private func waitForModeSettle(
        on displayID: CGDirectDisplayID,
        target resolution: DisplayResolution,
        initiallySwitched: Bool
    ) -> Bool {
        var switched = initiallySwitched
        for attempt in 0..<Self.switchSettleMaxAttempts {
            let modes = availableModes()
            if isDisplayActive(displayID: displayID, matching: resolution, availableModes: modes) {
                markSwitched(resolution, displayID: displayID)
                return true
            }
            if !switched {
                switched = setBridgeDisplayMode(displayID: displayID, target: resolution)
                if switched && isDisplayActive(displayID: displayID, matching: resolution, availableModes: modes) {
                    markSwitched(resolution, displayID: displayID)
                    return true
                }
            }
            if attempt < Self.switchSettleMaxAttempts - 1 {
                Thread.sleep(forTimeInterval: Self.modeSettlePollInterval)
            }
        }
        return false
    }

    private func markSwitched(_ resolution: DisplayResolution, displayID: CGDirectDisplayID) {
        self._currentResolution = resolution
        MaccarLogger.shared.info(
            "VirtualDisplay",
            "Switched display \(displayID) in-place to \(resolution.width)x\(resolution.height) (\(resolution.name))."
        )
    }

    private func setBridgeDisplayMode(displayID: CGDirectDisplayID, target resolution: DisplayResolution) -> Bool {
        CGDisplayConfigBridge.setDisplayMode(
            forDisplay: displayID,
            logicalWidth: resolution.width,
            logicalHeight: resolution.height,
            hiDPI: resolution.hiDPI,
            refreshRate: resolution.refreshRate
        )
    }

    private func isDisplayActive(
        displayID: CGDirectDisplayID,
        matching resolution: DisplayResolution,
        availableModes: [DisplayModeInfo]
    ) -> Bool {
        guard let mode = CGDisplayCopyDisplayMode(displayID),
              mode.isUsableForDesktopGUI()
        else {
            return false
        }

        let w = UInt32(mode.width)
        let h = UInt32(mode.height)
        let pw = UInt32(mode.pixelWidth)
        let ph = UInt32(mode.pixelHeight)
        guard w == resolution.width && h == resolution.height else {
            return false
        }

        let expectsHiDPI = resolution.hiDPI && DisplayResolution.hasUsableHiDPIMode(for: resolution, in: availableModes)
        return expectsHiDPI ? (pw >= resolution.width * 2 && ph >= resolution.height * 2) : true
    }
}
