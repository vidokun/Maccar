import Testing
@testable import MaccarKit

@Suite("Resolution Tests")
struct ResolutionTests {
    private static let forbiddenIndonesianTokens = [
        "nyaman", "enak", "teks besar", "luas", "sedang",
        "cocokkan", "pilih", "layar", "terhubung", "putuskan"
    ]

    @Test("All DisplayResolution presets use English naming and unique keys")
    func allPresetsAreEnglishAndWellFormed() {
        let presets = DisplayResolution.allPresets
        #expect(!presets.isEmpty)

        var seenKeys = Set<String>()
        for preset in presets {
            #expect(!preset.key.isEmpty)
            #expect(!preset.name.isEmpty)
            #expect(preset.width > 0)
            #expect(preset.height > 0)
            #expect(seenKeys.insert(preset.key).inserted, "Duplicate preset key: \(preset.key)")

            let lowerName = preset.name.lowercased()
            for token in Self.forbiddenIndonesianTokens {
                #expect(!lowerName.contains(token), "Preset '\(preset.name)' contains Indonesian token '\(token)'")
            }
        }
    }

    @Test("supportedPresets includes 1280x840 when only a 1x desktop-usable mode is present")
    func supportedPresetsIncludes1280x840WhenOnly1xModeIsUsable() {
        let modes = [
            DisplayModeInfo(
                width: 1440, height: 946,
                pixelWidth: 2880, pixelHeight: 1892,
                refreshRate: 60.0, usableForDesktop: true
            ),
            DisplayModeInfo(
                width: 1280, height: 840,
                pixelWidth: 2560, pixelHeight: 1680,
                refreshRate: 60.0, usableForDesktop: false
            ),
            DisplayModeInfo(
                width: 1280, height: 840,
                pixelWidth: 1280, pixelHeight: 840,
                refreshRate: 60.0, usableForDesktop: true
            )
        ]

        let supported = DisplayResolution.supportedPresets(availableModes: modes)
        #expect(supported.contains(.ipadMiniComfortable))
        #expect(supported.contains(.ipadMiniLarge))
        #expect(!DisplayResolution.hasUsableHiDPIMode(for: .ipadMiniLarge, in: modes))
        #expect(DisplayResolution.hasUsableHiDPIMode(for: .ipadMiniComfortable, in: modes))
    }

    @Test("supportedPresets excludes unusable and missing modes")
    func supportedPresetsExcludesUnusableAndMissingModes() {
        let modes = [
            DisplayModeInfo(
                width: 1440, height: 946,
                pixelWidth: 2880, pixelHeight: 1892,
                refreshRate: 60.0, usableForDesktop: true
            ),
            DisplayModeInfo(
                width: 1280, height: 840,
                pixelWidth: 2560, pixelHeight: 1680,
                refreshRate: 60.0, usableForDesktop: false
            ),
            DisplayModeInfo(
                width: 3840, height: 2160,
                pixelWidth: 3840, pixelHeight: 2160,
                refreshRate: 60.0, usableForDesktop: false
            )
        ]

        let supported = DisplayResolution.supportedPresets(availableModes: modes)
        #expect(supported == [.ipadMiniComfortable])
        #expect(!supported.contains(.ipadMiniLarge))
        #expect(!supported.contains(.ipad43Comfortable))
        #expect(!supported.contains(.ipadPro13Native))
        #expect(!supported.contains(.fourK))
    }

    @Test("from(key:) resolves all documented aliases and falls back safely")
    func fromKeyResolvesAllDocumentedAliasesAndFallback() {
        let expected: [(String, DisplayResolution)] = [
            ("ipad_mini_comfortable", .ipadMiniComfortable), ("ipad_mini", .ipadMiniComfortable),
            ("ipadmini", .ipadMiniComfortable), ("mini", .ipadMiniComfortable), ("auto", .ipadMiniComfortable),
            ("ipad_mini_balanced", .ipadMiniBalanced), ("ipad_mini_large", .ipadMiniLarge),
            ("ipad_mini_native", .ipadMiniNative), ("ipad_mini_max", .ipadMiniNative),
            ("ipad_air_comfortable", .ipadAirComfortable), ("ipad_air", .ipadAirComfortable),
            ("air", .ipadAirComfortable), ("ipad_air_native", .ipadAirNative), ("ipad_air_max", .ipadAirNative),
            ("ipad_4_3_comfortable", .ipad43Comfortable), ("ipad_4_3", .ipad43Comfortable),
            ("ipad", .ipad43Comfortable), ("ipad9", .ipad43Comfortable),
            ("ipad_4_3_native", .ipad43Native), ("ipad_4_3_max", .ipad43Native),
            ("ipad_pro_11_comfortable", .ipadPro11Comfortable), ("ipad_pro_11", .ipadPro11Comfortable),
            ("pro11", .ipadPro11Comfortable), ("ipad_pro_11_native", .ipadPro11Native),
            ("ipad_pro_11_max", .ipadPro11Native), ("ipad_pro_13_comfortable", .ipadPro13Comfortable),
            ("ipad_pro_13", .ipadPro13Comfortable), ("pro13", .ipadPro13Comfortable),
            ("ipad_pro_13_native", .ipadPro13Native), ("ipad_pro_13_max", .ipadPro13Native),
            ("1080p", .fullHD), ("fhd", .fullHD), ("1440p", .quadHD), ("qhd", .quadHD),
            ("4k", .fourK), ("uhd", .fourK),
            ("IPAD_MINI_LARGE", .ipadMiniLarge), ("nonexistent_preset", .ipadMiniComfortable)
        ]

        for (key, resolution) in expected {
            #expect(DisplayResolution.from(key: key) == resolution, "Unexpected resolution for key '\(key)'")
        }
    }
}
