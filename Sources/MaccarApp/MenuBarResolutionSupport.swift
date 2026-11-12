import Foundation
import CoreGraphics
import MaccarKit

internal struct ResolutionOption: Sendable {
    let title: String
    let resolution: DisplayResolution
    let matchingKeys: Set<String>
}

internal struct ResolutionGroup: Sendable {
    let header: String
    let options: [ResolutionOption]
}

internal struct CacheRefreshSnapshot: Sendable {
    let reachableDevices: [String]
    let availableModes: [DisplayModeInfo]
}

internal struct ResolutionSwitchOutcome: Sendable {
    let errorMessage: String?
    let availableModes: [DisplayModeInfo]
}

internal enum MenuBarResolutionSupport {
    static let resolutionGroups: [ResolutionGroup] = [
        ResolutionGroup(header: "iPad Mini 6 / 7 (8.3\" Display):", options: [
            ResolutionOption(title: "Comfortable (1440x946) [Recommended]", resolution: .ipadMiniComfortable, matchingKeys: ["ipad_mini_comfortable", "ipad_mini"]),
            ResolutionOption(title: "Balanced (1600x1050)", resolution: .ipadMiniBalanced, matchingKeys: ["ipad_mini_balanced"]),
            ResolutionOption(title: "Large Text (1280x840)", resolution: .ipadMiniLarge, matchingKeys: ["ipad_mini_large"]),
            ResolutionOption(title: "Max Space (2266x1488 Raw)", resolution: .ipadMiniNative, matchingKeys: ["ipad_mini_native"])
        ]),
        ResolutionGroup(header: "iPad Air / 10th Gen (10.9\" Display):", options: [
            ResolutionOption(title: "Comfortable (1440x1000)", resolution: .ipadAirComfortable, matchingKeys: ["ipad_air_comfortable", "ipad_air"]),
            ResolutionOption(title: "Max Space (2360x1640 Raw)", resolution: .ipadAirNative, matchingKeys: ["ipad_air_native"])
        ]),
        ResolutionGroup(header: "iPad Pro 11\" Display:", options: [
            ResolutionOption(title: "Comfortable (1440x1006)", resolution: .ipadPro11Comfortable, matchingKeys: ["ipad_pro_11_comfortable", "ipad_pro_11"]),
            ResolutionOption(title: "Max Space (2388x1668 Raw)", resolution: .ipadPro11Native, matchingKeys: ["ipad_pro_11_native"])
        ]),
        ResolutionGroup(header: "iPad Pro 12.9\" / 13\" Display:", options: [
            ResolutionOption(title: "Comfortable (1600x1200)", resolution: .ipadPro13Comfortable, matchingKeys: ["ipad_pro_13_comfortable", "ipad_pro_13"]),
            ResolutionOption(title: "Max Space (2732x2048 Raw)", resolution: .ipadPro13Native, matchingKeys: ["ipad_pro_13_native"])
        ]),
        ResolutionGroup(header: "iPad 4:3 (9.7\" / Mini 1-5):", options: [
            ResolutionOption(title: "Comfortable (1366x1024)", resolution: .ipad43Comfortable, matchingKeys: ["ipad_4_3_comfortable", "ipad_4_3", "ipad"]),
            ResolutionOption(title: "Max Space (2048x1536 Raw)", resolution: .ipad43Native, matchingKeys: ["ipad_4_3_native"])
        ]),
        ResolutionGroup(header: "Standard 16:9 Displays:", options: [
            ResolutionOption(title: "1080p Full HD (1920x1080)", resolution: .fullHD, matchingKeys: ["1080p"]),
            ResolutionOption(title: "1440p Quad HD (2560x1440)", resolution: .quadHD, matchingKeys: ["1440p"]),
            ResolutionOption(title: "4K UHD (3840x2160)", resolution: .fourK, matchingKeys: ["4k"])
        ])
    ]

    static func supportedKeys(from availableModes: [DisplayModeInfo]) -> Set<String>? {
        guard !availableModes.isEmpty else { return nil }
        return Set(DisplayResolution.supportedPresets(availableModes: availableModes).map(\.key))
    }

    static func fetchCacheSnapshot() -> CacheRefreshSnapshot {
        let reachableDevices = (try? SidecarService.shared.reachableDevices()) ?? []
        let availableModes = VirtualDisplayService.shared.availableModes()
        return CacheRefreshSnapshot(reachableDevices: reachableDevices, availableModes: availableModes)
    }

    static func resolveTargetResolution(for resKey: String) -> DisplayResolution {
        guard resKey == "auto" else { return DisplayResolution.from(key: resKey) }
        guard let virtualDisplayID = VirtualDisplayService.shared.activeDisplayID,
              let ipadDisplayID = DisplayMirrorManager.shared.findIPadDisplay(excludingVirtualDisplayID: virtualDisplayID)
        else { return .ipadMiniComfortable }

        let (width, height) = DisplayMirrorManager.shared.resolution(of: ipadDisplayID)
        if (width == 2266 && height == 1488) || (width == 1488 && height == 2266) { return .ipadMiniComfortable }
        if (width == 2360 && height == 1640) || (width == 1640 && height == 2360) { return .ipadAirComfortable }
        if (width == 2388 && height == 1668) || (width == 1668 && height == 2388) { return .ipadPro11Comfortable }
        if (width == 2732 && height == 2048) || (width == 2048 && height == 2732) { return .ipadPro13Comfortable }
        if (width == 2048 && height == 1536) || (width == 1536 && height == 2048) { return .ipad43Comfortable }
        if width > 0 && height > 0 {
            return DisplayResolution(name: "iPad Native (\(width)x\(height))", width: width, height: height, refreshRate: 60.0, hiDPI: true)
        }
        return .ipadMiniComfortable
    }

    static func executeResolutionSwitch(resKey: String, previousKey: String) -> ResolutionSwitchOutcome {
        DeviceWatcher.shared.beginDisplayReconfiguration()
        defer { DeviceWatcher.shared.endDisplayReconfiguration() }

        let targetResolution = resolveTargetResolution(for: resKey)
        let currentVirtualDisplayID = VirtualDisplayService.shared.activeDisplayID ?? 0
        let ipadDisplayID = DisplayMirrorManager.shared.mirroredIPadDisplayID
            ?? DisplayMirrorManager.shared.findIPadDisplay(excludingVirtualDisplayID: currentVirtualDisplayID)

        if let ipad = ipadDisplayID {
            try? DisplayMirrorManager.shared.disableMirroring(ipadDisplay: ipad)
        }

        let errorMessage: String?
        do {
            try VirtualDisplayService.shared.apply(resolution: targetResolution)
            MaccarSettings.shared.preferredResolution = resKey
            MaccarLogger.shared.info("MenuBar", "Switched virtual display resolution to '\(targetResolution.name)'.")
            errorMessage = nil
        } catch {
            MaccarSettings.shared.preferredResolution = previousKey
            MaccarLogger.shared.error("MenuBar", "Failed to apply resolution '\(targetResolution.name)': \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }

        if let updatedVirtualDisplayID = VirtualDisplayService.shared.activeDisplayID,
           let ipad = ipadDisplayID ?? DisplayMirrorManager.shared.findIPadDisplay(excludingVirtualDisplayID: updatedVirtualDisplayID) {
            try? DisplayMirrorManager.shared.mirror(ipadDisplay: ipad, toVirtualDisplay: updatedVirtualDisplayID)
        }

        let updatedModes = VirtualDisplayService.shared.availableModes()
        return ResolutionSwitchOutcome(errorMessage: errorMessage, availableModes: updatedModes)
    }
}
