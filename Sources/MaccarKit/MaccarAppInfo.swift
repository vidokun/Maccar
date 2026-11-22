import Foundation

/// Single source for the app's version strings.
///
/// Three call sites format the version (About, the Menu Bar, `--version`), and each had its
/// own hard-coded fallback that had to be bumped in lockstep. They now share this one.
public enum MaccarAppInfo {
    /// Used when `Bundle.main` carries no version — true for the debug binary run from
    /// `.build/debug`, which has no `Info.plist`. Must be bumped in lockstep with
    /// `scripts/Info.plist`, or a debug build reports a version that was never released.
    public static let fallbackVersion = "1.5.4"

    public static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? fallbackVersion
    }

    /// `nil` outside an app bundle. A missing build is omitted rather than rendered as `0`,
    /// which a reader would mistake for the first build of the release.
    public static var buildNumber: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    /// `"1.4.2 (build 8)"` in a bundle, plain `"1.4.2"` otherwise.
    public static var displayString: String {
        guard let buildNumber else { return shortVersion }
        return "\(shortVersion) (build \(buildNumber))"
    }
}
