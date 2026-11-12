import Foundation

public struct DisplayModeInfo: Sendable, Equatable {
    public let width: UInt32
    public let height: UInt32
    public let pixelWidth: UInt32
    public let pixelHeight: UInt32
    public let refreshRate: Double
    public let usableForDesktop: Bool

    public var isHiDPI: Bool {
        pixelWidth >= width * 2 && pixelHeight >= height * 2
    }

    public init(
        width: UInt32,
        height: UInt32,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        refreshRate: Double,
        usableForDesktop: Bool
    ) {
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.usableForDesktop = usableForDesktop
    }

    public init?(dictionary: [String: NSNumber]) {
        guard let width = dictionary["width"]?.uint32Value,
              let height = dictionary["height"]?.uint32Value,
              let pixelWidth = dictionary["pixelWidth"]?.uint32Value,
              let pixelHeight = dictionary["pixelHeight"]?.uint32Value,
              let refreshRate = dictionary["refreshRate"]?.doubleValue,
              let usableForDesktop = dictionary["usableForDesktop"]?.boolValue,
              width > 0, height > 0
        else {
            return nil
        }

        self.init(
            width: width,
            height: height,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            refreshRate: refreshRate,
            usableForDesktop: usableForDesktop
        )
    }
}

public enum VirtualDisplayError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedRuntime
    case creationFailed(String)
    case unsupportedResolution(DisplayResolution)
    case modeSwitchFailed(DisplayResolution)

    public var errorDescription: String? {
        switch self {
        case .unsupportedRuntime:
            return "CGVirtualDisplay APIs are unavailable on this macOS version."
        case .creationFailed(let reason):
            return "Failed to create virtual display: \(reason)"
        case .unsupportedResolution(let resolution):
            return "Resolution '\(resolution.name)' (\(resolution.width)x\(resolution.height)) has no desktop-usable mode on the active virtual display."
        case .modeSwitchFailed(let resolution):
            return "Failed to switch active display mode to \(resolution.width)x\(resolution.height) within the WindowServer settle window."
        }
    }
}

public struct DisplayResolution: Sendable, Equatable {
    public let key: String
    public let name: String
    public let width: UInt32         // Logical UI point width
    public let height: UInt32        // Logical UI point height
    public let backingWidth: UInt32  // Backing pixel width (2x for HiDPI Retina)
    public let backingHeight: UInt32 // Backing pixel height (2x for HiDPI Retina)
    public let refreshRate: Double
    public let hiDPI: Bool

    public init(
        key: String = "custom",
        name: String,
        width: UInt32,
        height: UInt32,
        backingWidth: UInt32? = nil,
        backingHeight: UInt32? = nil,
        refreshRate: Double = 60.0,
        hiDPI: Bool = true
    ) {
        self.key = key
        self.name = name
        self.width = width
        self.height = height
        self.backingWidth = backingWidth ?? (hiDPI ? width * 2 : width)
        self.backingHeight = backingHeight ?? (hiDPI ? height * 2 : height)
        self.refreshRate = refreshRate
        self.hiDPI = hiDPI
    }

    // MARK: - iPad Mini 6 / 7 Presets (Aspect Ratio ~1.52:1, Physical: 2266x1488)
    public static let ipadMiniComfortable = DisplayResolution(
        key: "ipad_mini_comfortable", name: "iPad Mini 6/7 — Comfortable (1440x946)", width: 1440, height: 946
    )
    public static let ipadMiniBalanced = DisplayResolution(
        key: "ipad_mini_balanced", name: "iPad Mini 6/7 — Balanced (1600x1050)", width: 1600, height: 1050
    )
    public static let ipadMiniLarge = DisplayResolution(
        key: "ipad_mini_large", name: "iPad Mini 6/7 — Large Text (1280x840)", width: 1280, height: 840
    )
    public static let ipadMiniNative = DisplayResolution(
        key: "ipad_mini_native", name: "iPad Mini 6/7 — Max Space (2266x1488)", width: 2266, height: 1488, hiDPI: false
    )
    public static let ipadMini = ipadMiniComfortable

    // MARK: - iPad Air / 10th Gen Presets (Aspect Ratio ~1.44:1, Physical: 2360x1640)
    public static let ipadAirComfortable = DisplayResolution(
        key: "ipad_air_comfortable", name: "iPad Air / 10th — Comfortable (1440x1000)", width: 1440, height: 1000
    )
    public static let ipadAirNative = DisplayResolution(
        key: "ipad_air_native", name: "iPad Air / 10th — Max Space (2360x1640)", width: 2360, height: 1640, hiDPI: false
    )
    public static let ipadAir = ipadAirComfortable

    // MARK: - iPad 9.7" / Mini 1-5 Presets (Aspect Ratio 4:3, Physical: 2048x1536)
    public static let ipad43Comfortable = DisplayResolution(
        key: "ipad_4_3_comfortable", name: "iPad 4:3 — Comfortable (1366x1024)", width: 1366, height: 1024
    )
    public static let ipad43Native = DisplayResolution(
        key: "ipad_4_3_native", name: "iPad 4:3 — Max Space (2048x1536)", width: 2048, height: 1536, hiDPI: false
    )
    public static let ipadPro = ipad43Comfortable

    // MARK: - iPad Pro 11" Presets (Aspect Ratio ~1.43:1, Physical: 2388x1668)
    public static let ipadPro11Comfortable = DisplayResolution(
        key: "ipad_pro_11_comfortable", name: "iPad Pro 11\" — Comfortable (1440x1006)", width: 1440, height: 1006
    )
    public static let ipadPro11Native = DisplayResolution(
        key: "ipad_pro_11_native", name: "iPad Pro 11\" — Max Space (2388x1668)", width: 2388, height: 1668, hiDPI: false
    )
    public static let ipadPro11 = ipadPro11Comfortable

    // MARK: - iPad Pro 12.9" / 13" Presets (Aspect Ratio 4:3, Physical: 2732x2048)
    public static let ipadPro13Comfortable = DisplayResolution(
        key: "ipad_pro_13_comfortable", name: "iPad Pro 12.9\"/13\" — Comfortable (1600x1200)", width: 1600, height: 1200
    )
    public static let ipadPro13Native = DisplayResolution(
        key: "ipad_pro_13_native", name: "iPad Pro 12.9\"/13\" — Max Space (2732x2048)", width: 2732, height: 2048, hiDPI: false
    )
    public static let ipadPro13 = ipadPro13Comfortable

    // MARK: - Standard 16:9 Displays
    public static let fullHD = DisplayResolution(
        key: "1080p", name: "1080p Full HD (1920x1080)", width: 1920, height: 1080, hiDPI: false
    )
    public static let quadHD = DisplayResolution(
        key: "1440p", name: "1440p Quad HD (2560x1440)", width: 2560, height: 1440, hiDPI: false
    )
    public static let fourK = DisplayResolution(
        key: "4k", name: "4K UHD (3840x2160)", width: 3840, height: 2160, hiDPI: false
    )

    public static let allPresets: [DisplayResolution] = [
        .ipadMiniComfortable, .ipadMiniBalanced, .ipadMiniLarge, .ipadMiniNative,
        .ipadAirComfortable, .ipadAirNative,
        .ipadPro11Comfortable, .ipadPro11Native,
        .ipadPro13Comfortable, .ipadPro13Native,
        .ipad43Comfortable, .ipad43Native,
        .fullHD, .quadHD, .fourK
    ]

    public static func hasUsableHiDPIMode(
        for resolution: DisplayResolution,
        in availableModes: [DisplayModeInfo]
    ) -> Bool {
        availableModes.contains { mode in
            mode.usableForDesktop &&
            mode.width == resolution.width &&
            mode.height == resolution.height &&
            mode.isHiDPI
        }
    }

    public static func supportedPresets(
        presets: [DisplayResolution] = allPresets,
        availableModes: [DisplayModeInfo]
    ) -> [DisplayResolution] {
        presets.filter { preset in
            availableModes.contains { mode in
                mode.usableForDesktop &&
                mode.width == preset.width &&
                mode.height == preset.height
            }
        }
    }

    public static func from(key: String) -> DisplayResolution {
        switch key.lowercased() {
        case "ipad_mini_comfortable", "ipad_mini", "ipadmini", "mini", "auto":
            return .ipadMiniComfortable
        case "ipad_mini_balanced":
            return .ipadMiniBalanced
        case "ipad_mini_large":
            return .ipadMiniLarge
        case "ipad_mini_native", "ipad_mini_max":
            return .ipadMiniNative
        case "ipad_air_comfortable", "ipad_air", "air":
            return .ipadAirComfortable
        case "ipad_air_native", "ipad_air_max":
            return .ipadAirNative
        case "ipad_4_3_comfortable", "ipad_4_3", "ipad", "ipad9":
            return .ipad43Comfortable
        case "ipad_4_3_native", "ipad_4_3_max":
            return .ipad43Native
        case "ipad_pro_11_comfortable", "ipad_pro_11", "pro11":
            return .ipadPro11Comfortable
        case "ipad_pro_11_native", "ipad_pro_11_max":
            return .ipadPro11Native
        case "ipad_pro_13_comfortable", "ipad_pro_13", "pro13":
            return .ipadPro13Comfortable
        case "ipad_pro_13_native", "ipad_pro_13_max":
            return .ipadPro13Native
        case "1080p", "fhd":
            return .fullHD
        case "1440p", "qhd":
            return .quadHD
        case "4k", "uhd":
            return .fourK
        default:
            return .ipadMiniComfortable
        }
    }
}
