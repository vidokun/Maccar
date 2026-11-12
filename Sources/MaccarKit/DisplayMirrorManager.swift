import Foundation
import CoreGraphics
import os
import CMaccarBridge

public final class DisplayMirrorManager: @unchecked Sendable {
    public static let shared = DisplayMirrorManager()

    private let mirrorStateLock = OSAllocatedUnfairLock<CGDirectDisplayID?>(initialState: nil)

    public var mirroredIPadDisplayID: CGDirectDisplayID? {
        mirrorStateLock.withLock { $0 }
    }

    private init() {}

    /// Returns all online display IDs currently recognized by macOS.
    public func onlineDisplays() -> [CGDirectDisplayID] {
        return CGDisplayConfigBridge.onlineDisplayIDs().map { $0.uint32Value }
    }

    /// Identifies the Sidecar/iPad display by finding an online non-builtin display that is NOT the virtual display.
    public func findIPadDisplay(excludingVirtualDisplayID: CGDirectDisplayID) -> CGDirectDisplayID? {
        onlineDisplays().first { id in
            id != 0
                && id != excludingVirtualDisplayID
                && CGDisplayIsBuiltin(id) == 0
        }
    }

    /// Reads the true hardware pixel resolution of a display by probing its modes.
    /// Normalizes to landscape orientation (width >= height) suitable for macOS desktop workspace.
    public func resolution(of displayID: CGDirectDisplayID) -> (width: UInt32, height: UInt32) {
        var bestWidth = UInt32(CGDisplayPixelsWide(displayID))
        var bestHeight = UInt32(CGDisplayPixelsHigh(displayID))

        if let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] {
            for mode in modes {
                let w = UInt32(mode.pixelWidth)
                let h = UInt32(mode.pixelHeight)
                if (w * h) > (bestWidth * bestHeight) {
                    bestWidth = w
                    bestHeight = h
                }
            }
        }

        // Normalize to landscape orientation for macOS desktop
        let landW = max(bestWidth, bestHeight)
        let landH = min(bestWidth, bestHeight)

        if landW == 0 || landH == 0 {
            // Fallback to iPad Mini 6/7 native resolution
            return (width: 2266, height: 1488)
        }

        return (width: landW, height: landH)
    }

    /// Configures the iPad display to mirror the virtual display.
    public func mirror(ipadDisplay: CGDirectDisplayID, toVirtualDisplay: CGDirectDisplayID) throws {
        var errStr: NSString?
        let success = CGDisplayConfigBridge.mirrorDisplay(ipadDisplay, toMasterDisplay: toVirtualDisplay, error: &errStr)
        if !success {
            let msg = errStr as String? ?? "Failed to configure display mirroring"
            MaccarLogger.shared.error(
                "DisplayMirror",
                "Failed to mirror display \(ipadDisplay) to virtual display \(toVirtualDisplay): \(msg)"
            )
            throw NSError(domain: "com.maccar.mirror", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        mirrorStateLock.withLock { $0 = ipadDisplay }
        MaccarLogger.shared.info(
            "DisplayMirror",
            "Configured display \(ipadDisplay) to mirror virtual display \(toVirtualDisplay)."
        )
    }

    /// Disables mirroring on the iPad display.
    public func disableMirroring(ipadDisplay: CGDirectDisplayID) throws {
        var errStr: NSString?
        let success = CGDisplayConfigBridge.disableMirroring(forDisplay: ipadDisplay, error: &errStr)
        if !success {
            let msg = errStr as String? ?? "Failed to disable display mirroring"
            MaccarLogger.shared.error(
                "DisplayMirror",
                "Failed to disable mirroring for display \(ipadDisplay): \(msg)"
            )
            throw NSError(domain: "com.maccar.mirror", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        mirrorStateLock.withLock {
            if $0 == ipadDisplay {
                $0 = nil
            }
        }
        MaccarLogger.shared.info("DisplayMirror", "Disabled mirroring on display \(ipadDisplay).")
    }

    /// Checks whether ipadDisplay is already actively mirroring toVirtualDisplay.
    public func isMirrored(ipadDisplay: CGDirectDisplayID, toVirtualDisplay: CGDirectDisplayID) -> Bool {
        return CGDisplayConfigBridge.primaryDisplay(forMirror: ipadDisplay) == toVirtualDisplay
    }

    /// Automatically adapts the virtual display resolution to match the iPad and enables mirroring.
    @discardableResult
    public func autoMatchAndMirror(virtualDisplayID: CGDirectDisplayID) throws -> CGDirectDisplayID? {
        guard let ipadDisplay = findIPadDisplay(excludingVirtualDisplayID: virtualDisplayID) else {
            return nil
        }

        let resolvedRes = resolvePreferredPreset(for: ipadDisplay)
        let targetRes = resolveUsableResolution(preferred: resolvedRes, virtualDisplayID: virtualDisplayID)

        do {
            try VirtualDisplayService.shared.apply(resolution: targetRes)
        } catch {
            MaccarLogger.shared.error(
                "DisplayMirror",
                "Failed to apply resolution '\(targetRes.name)' before mirroring iPad display \(ipadDisplay): \(error.localizedDescription)"
            )
            throw error
        }

        // Always use currently active virtual display ID
        let activeVdID = VirtualDisplayService.shared.activeDisplayID ?? virtualDisplayID

        // Mirror iPad to Virtual Display only if not already actively mirrored
        if !isMirrored(ipadDisplay: ipadDisplay, toVirtualDisplay: activeVdID) {
            try mirror(ipadDisplay: ipadDisplay, toVirtualDisplay: activeVdID)
        }
        return ipadDisplay
    }

    private func resolvePreferredPreset(for ipadDisplay: CGDirectDisplayID) -> DisplayResolution {
        let preferred = MaccarSettings.shared.preferredResolution
        if preferred != "auto" {
            return DisplayResolution.from(key: preferred)
        }

        let (w, h) = resolution(of: ipadDisplay)
        switch (max(w, h), min(w, h)) {
        case (2266, 1488): return .ipadMiniComfortable
        case (2360, 1640): return .ipadAirComfortable
        case (2388, 1668): return .ipadPro11Comfortable
        case (2732, 2048): return .ipadPro13Comfortable
        case (2048, 1536): return .ipad43Comfortable
        default:
            guard w > 0 && h > 0 else { return .ipadMiniComfortable }
            return DisplayResolution(name: "iPad Native (\(w)x\(h))", width: w, height: h, refreshRate: 60.0, hiDPI: true)
        }
    }

    private func resolveUsableResolution(
        preferred: DisplayResolution,
        virtualDisplayID: CGDirectDisplayID
    ) -> DisplayResolution {
        let availableModes = VirtualDisplayService.shared.availableModes()
        guard !availableModes.isEmpty && !VirtualDisplayService.shared.isResolutionSupported(preferred) else {
            return preferred
        }

        let fallback = DisplayResolution.supportedPresets(presets: [.ipadMiniComfortable], availableModes: availableModes).first
            ?? DisplayResolution.supportedPresets(availableModes: availableModes).first
            ?? .ipadMiniComfortable
        MaccarLogger.shared.warning(
            "DisplayMirror",
            "Resolution '\(preferred.name)' (\(preferred.width)x\(preferred.height)) has no desktop-usable mode on virtual display \(virtualDisplayID); falling back to '\(fallback.name)'."
        )
        return fallback
    }
}
