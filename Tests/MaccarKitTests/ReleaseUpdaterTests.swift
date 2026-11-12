import CryptoKit
import Foundation
import os
import Testing
@testable import MaccarKit

@Suite("ReleaseUpdater Tests")
struct ReleaseUpdaterTests {
    private final class MockHTTPFetcher: HTTPFetching, @unchecked Sendable {
        enum StubResponse: Sendable {
            case data(Data, Int), file(URL, Int), failure(Error)
        }
        private let lock = OSAllocatedUnfairLock<[URL: StubResponse]>(initialState: [:])
        private let requestedLock = OSAllocatedUnfairLock<[URL]>(initialState: [])

        init(_ responses: [URL: StubResponse] = [:]) { lock.withLock { $0 = responses } }
        var requestedURLs: [URL] { requestedLock.withLock { $0 } }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            requestedLock.withLock { $0.append(url) }
            guard let stub = lock.withLock({ $0[url] }) else { throw ReleaseUpdateError.httpError(404) }
            switch stub {
            case .data(let data, let status):
                return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            case .file: throw ReleaseUpdateError.invalidResponse
            case .failure(let error): throw error
            }
        }

        func download(for request: URLRequest) async throws -> (URL, URLResponse) {
            let url = try #require(request.url)
            requestedLock.withLock { $0.append(url) }
            guard let stub = lock.withLock({ $0[url] }) else { throw ReleaseUpdateError.httpError(404) }
            switch stub {
            case .file(let sourceURL, let status):
                let copyURL = FileManager.default.temporaryDirectory.appendingPathComponent("mock-dl-\(UUID().uuidString).zip")
                try FileManager.default.copyItem(at: sourceURL, to: copyURL)
                return (copyURL, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            case .data: throw ReleaseUpdateError.invalidResponse
            case .failure(let error): throw error
            }
        }
    }

    private static let primaryURL = URL(string: "https://github.com/vidokun/Maccar/releases/latest/download/manifest.json")!
    private static let mirrorURL = URL(string: "https://vidokun.github.io/Maccar/manifest.json")!
    private static let zipURL = "https://github.com/vidokun/Maccar/releases/download/v1.3.1/Maccar-v1.3.1.zip"
    private static let dmgURL = "https://github.com/vidokun/Maccar/releases/download/v1.3.1/Maccar-v1.3.1.dmg"
    private static let notesURL = "https://github.com/vidokun/Maccar/releases/tag/v1.3.1"
    private static let validSha = String(repeating: "a", count: 64)

    private func makeManifest(
        schemaVersion: Int = 1, product: String = "Maccar", bundleIdentifier: String = "com.maccar.app",
        version: String = "1.3.1", build: Int = 6, minimumSystemVersion: String = "14.0",
        releaseNotesUrl: String = notesURL, zipUrl: String = zipURL, zipSha256: String = validSha,
        zipSizeBytes: Int64 = 123_456, dmgSha256: String = validSha, signature: UpdateSignature? = nil
    ) -> ReleaseManifest {
        ReleaseManifest(
            schemaVersion: schemaVersion, product: product, bundleIdentifier: bundleIdentifier,
            version: version, build: build, publishedAt: "2026-11-11T00:00:00Z",
            minimumSystemVersion: minimumSystemVersion, releaseNotesUrl: releaseNotesUrl,
            releaseNotesSummary: "Release summary",
            artifacts: .init(zip: .init(url: zipUrl, sha256: zipSha256, sizeBytes: zipSizeBytes),
                             dmg: .init(url: Self.dmgURL, sha256: dmgSha256, sizeBytes: 234_567)),
            signature: signature
        )
    }

    private func signManifest(_ manifest: ReleaseManifest, privateKey: Curve25519.Signing.PrivateKey, keyId: String = "maccar-release-v1") throws -> ReleaseManifest {
        let canonical = ["Maccar", manifest.bundleIdentifier, manifest.version, String(manifest.build),
                         manifest.minimumSystemVersion, manifest.artifacts.zip.url, manifest.artifacts.zip.sha256,
                         String(manifest.artifacts.zip.sizeBytes), manifest.artifacts.dmg.sha256].joined(separator: "|")
        let signature = try privateKey.signature(for: Data(canonical.utf8))
        return ReleaseManifest(
            schemaVersion: manifest.schemaVersion, product: manifest.product, bundleIdentifier: manifest.bundleIdentifier,
            version: manifest.version, build: manifest.build, publishedAt: manifest.publishedAt,
            minimumSystemVersion: manifest.minimumSystemVersion, releaseNotesUrl: manifest.releaseNotesUrl,
            releaseNotesSummary: manifest.releaseNotesSummary, artifacts: manifest.artifacts,
            signature: .init(algorithm: "ed25519", keyId: keyId, zipSignatureBase64: signature.base64EncodedString())
        )
    }

    private func makeUpdater(
        currentVersion: AppVersion = AppVersion(versionString: "1.3.0", build: 5)!,
        osVersion: OperatingSystemVersion = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 0),
        publicKeyBase64: String = "", expectedKeyId: String = "", teamID: String? = nil,
        fetcher: MockHTTPFetcher = MockHTTPFetcher()
    ) -> ReleaseUpdater {
        ReleaseUpdater(currentVersion: currentVersion, bundleIdentifier: "com.maccar.app", operatingSystemVersion: osVersion,
                       publicKeyBase64: publicKeyBase64, expectedKeyId: expectedKeyId,
                       runningTeamIdentifierProvider: { teamID }, httpFetcher: fetcher)
    }

    private func makeSignedTestAppArchive(in rootDir: URL) throws -> (zipURL: URL, sha256: String, sizeBytes: Int64) {
        let appURL = rootDir.appendingPathComponent("Maccar.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.maccar.app", "CFBundleExecutable": "maccar",
                                    "CFBundleName": "Maccar", "CFBundlePackageType": "APPL",
                                    "CFBundleShortVersionString": "1.3.1", "CFBundleVersion": "6"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contentsURL.appendingPathComponent("Info.plist"))
        let execURL = macOSURL.appendingPathComponent("maccar")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: execURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execURL.path)

        for (exe, args) in [("/usr/bin/codesign", ["--force", "--deep", "-s", "-", appURL.path]),
                            ("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", appURL.path,
                                                rootDir.appendingPathComponent("Maccar-v1.3.1.zip").path])] {
            let proc = Process(); proc.executableURL = URL(fileURLWithPath: exe); proc.arguments = args
            try proc.run(); proc.waitUntilExit(); #expect(proc.terminationStatus == 0)
        }
        let archiveURL = rootDir.appendingPathComponent("Maccar-v1.3.1.zip")
        let zipData = try Data(contentsOf: archiveURL)
        return (archiveURL, SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined(), Int64(zipData.count))
    }

    @Test("AppVersion parses SemVer + build, compares correctly, and rejects malformed strings")
    func appVersionParsingAndOrdering() throws {
        let v130b9 = try #require(AppVersion(versionString: "1.3.0", build: 9))
        let v131b5 = try #require(AppVersion(versionString: "v1.3.1", build: 5))
        let v130b5 = try #require(AppVersion(versionString: "1.3.0", build: 5))
        let v130b6 = try #require(AppVersion(versionString: "V1.3.0", build: 6))
        #expect(v131b5 > v130b9 && v130b6 > v130b5 && v131b5.formatted == "1.3.1")
        for bad in ["1.3", "1.3.0.1", "abc", "", "1.3.0-beta"] { #expect(AppVersion(versionString: bad) == nil) }
        #expect(AppVersion(versionString: "1.3.0", build: -1) == nil)
    }

    @Test("ReleaseManifest decodes strict primitives and rejects mismatched bundleId or product")
    func releaseManifestDecodingAndValidation() async throws {
        let decoded = try JSONDecoder().decode(ReleaseManifest.self, from: try JSONEncoder().encode(makeManifest()))
        #expect(decoded.schemaVersion == 1 && decoded.build == 6 && decoded.artifacts.zip.sizeBytes == 123_456 && decoded.signature == nil)
        for bad in [makeManifest(bundleIdentifier: "com.evil.app"), makeManifest(product: "OtherApp")] {
            let data = try JSONEncoder().encode(bad)
            let updater = makeUpdater(fetcher: MockHTTPFetcher([Self.primaryURL: .data(data, 200)]))
            await #expect(throws: ReleaseUpdateError.self) { try await updater.checkForUpdates(manifestURLs: [Self.primaryURL]) }
        }
    }

    @Test("TrustedReleaseURLValidator enforces HTTPS, host allowlist, repo path, and no userinfo")
    func trustedURLAllowlistValidation() throws {
        for raw in ["https://github.com/vidokun/Maccar/releases/latest/download/manifest.json",
                    "https://vidokun.github.io/Maccar/manifest.json",
                    "https://objects.githubusercontent.com/github-production-release-asset/123",
                    "https://release-assets.githubusercontent.com/abc",
                    "https://github-releases.githubusercontent.com/xyz"] {
            try TrustedReleaseURLValidator.validateURL(try #require(URL(string: raw)))
        }
        for raw in ["http://github.com/vidokun/Maccar/manifest.json", "https://evil.example/manifest.json",
                    "https://github.com/other/Maccar/releases/latest/download/manifest.json",
                    "https://user:pass@github.com/vidokun/Maccar/manifest.json", "https://vidokun.github.io/OtherRepo/manifest.json"] {
            #expect(throws: ReleaseUpdateError.self) { try TrustedReleaseURLValidator.validateURL(try #require(URL(string: raw))) }
        }
    }

    @Test("TrustedReleaseURLValidator.validateRedirect permits GitHub CDN and blocks downgrades/foreign hosts")
    func trustedRedirectValidation() throws {
        try TrustedReleaseURLValidator.validateRedirect(from: Self.primaryURL, to: try #require(URL(string: "https://objects.githubusercontent.com/asset/Maccar.zip")))
        for bad in ["http://objects.githubusercontent.com/asset/Maccar.zip", "https://evil.example/Maccar.zip"] {
            #expect(throws: ReleaseUpdateError.self) { try TrustedReleaseURLValidator.validateRedirect(from: Self.primaryURL, to: try #require(URL(string: bad))) }
        }
    }

    @Test("Unsafe releaseNotesUrl in manifest is rejected")
    func unsafeReleaseNotesURLRejected() async throws {
        let data = try JSONEncoder().encode(makeManifest(releaseNotesUrl: "https://evil.example/phish"))
        let updater = makeUpdater(fetcher: MockHTTPFetcher([Self.primaryURL: .data(data, 200)]))
        await #expect(throws: ReleaseUpdateError.self) { try await updater.checkForUpdates(manifestURLs: [Self.primaryURL]) }
    }

    @Test("minimumSystemVersion gating rejects newer OS requirement and accepts compatible OS")
    func minimumSystemVersionGating() async throws {
        let data = try JSONEncoder().encode(makeManifest(minimumSystemVersion: "15.0"))
        let older = makeUpdater(osVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 0),
                                fetcher: MockHTTPFetcher([Self.primaryURL: .data(data, 200)]))
        await #expect(throws: ReleaseUpdateError.unsupportedOS(required: "15.0")) {
            try await older.checkForUpdates(manifestURLs: [Self.primaryURL])
        }
        let newer = makeUpdater(osVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0),
                                fetcher: MockHTTPFetcher([Self.primaryURL: .data(data, 200)]))
        guard case .available(let candidate) = try await newer.checkForUpdates(manifestURLs: [Self.primaryURL]) else {
            Issue.record("Expected .available"); return
        }
        #expect(candidate.version.formatted == "1.3.1")
    }

    @Test("Same or lower version+build returns upToDate")
    func sameOrLowerVersionReturnsUpToDate() async throws {
        let current = try #require(AppVersion(versionString: "1.3.1", build: 6))
        for manifest in [makeManifest(version: "1.3.1", build: 6), makeManifest(version: "1.3.1", build: 5), makeManifest(version: "1.3.0", build: 99)] {
            let updater = makeUpdater(currentVersion: current, fetcher: MockHTTPFetcher([Self.primaryURL: .data(try JSONEncoder().encode(manifest), 200)]))
            #expect(try await updater.checkForUpdates(manifestURLs: [Self.primaryURL]) == .upToDate(currentVersion: current))
        }
    }

    @Test("MaccarSettings conforms to UpdateSettingsProviding cleanly")
    func maccarSettingsConformsToUpdateSettingsProviding() throws {
        let suite = "com.maccar.tests.updater.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings: any UpdateSettingsProviding = MaccarSettings(defaults: defaults, isAppBundle: false, loginItemManager: SystemLoginItemManager())
        #expect(settings.autoCheckUpdates)
        settings.autoCheckUpdates = false; settings.lastUpdateCheckTimestamp = 42.5; settings.skippedVersion = "1.3.1"
        #expect(!settings.autoCheckUpdates && settings.lastUpdateCheckTimestamp == 42.5 && settings.skippedVersion == "1.3.1")
    }

    @Test("Valid Curve25519 Ed25519 signature verifies with ed25519Pinned trust")
    func validEd25519SignaturePasses() async throws {
        let priv = Curve25519.Signing.PrivateKey()
        let pub = priv.publicKey.rawRepresentation.base64EncodedString()
        let data = try JSONEncoder().encode(try signManifest(makeManifest(), privateKey: priv, keyId: "maccar-release-v1"))
        let updater = makeUpdater(publicKeyBase64: pub, expectedKeyId: "maccar-release-v1", fetcher: MockHTTPFetcher([Self.primaryURL: .data(data, 200)]))
        guard case .available(let candidate) = try await updater.checkForUpdates(manifestURLs: [Self.primaryURL]) else {
            Issue.record("Expected .available"); return
        }
        #expect(candidate.trustLevel == .ed25519Pinned)
    }

    @Test("Tampered manifest fields fail Ed25519 verification closed")
    func tamperedEd25519ManifestFailsClosed() async throws {
        let priv = Curve25519.Signing.PrivateKey()
        let pub = priv.publicKey.rawRepresentation.base64EncodedString()
        let signed = try signManifest(makeManifest(), privateKey: priv)
        for tampered in [makeManifest(zipUrl: "https://github.com/vidokun/Maccar/releases/download/v1.3.1/evil.zip", signature: signed.signature),
                         makeManifest(zipSha256: String(repeating: "b", count: 64), signature: signed.signature),
                         makeManifest(dmgSha256: String(repeating: "c", count: 64), signature: signed.signature),
                         makeManifest(version: "1.3.2", signature: signed.signature)] {
            let updater = makeUpdater(publicKeyBase64: pub, fetcher: MockHTTPFetcher([Self.primaryURL: .data(try JSONEncoder().encode(tampered), 200)]))
            await #expect(throws: ReleaseUpdateError.self) { try await updater.checkForUpdates(manifestURLs: [Self.primaryURL]) }
        }
    }

    @Test("Null JSON signature and empty signature string fail closed when public key is pinned")
    func nullAndEmptySignatureFailClosed() async throws {
        let pub = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        for sig in [nil, UpdateSignature(algorithm: "ed25519", keyId: "maccar-release-v1", zipSignatureBase64: "")] {
            let updater = makeUpdater(publicKeyBase64: pub, fetcher: MockHTTPFetcher([Self.primaryURL: .data(try JSONEncoder().encode(makeManifest(signature: sig)), 200)]))
            await #expect(throws: ReleaseUpdateError.self) { try await updater.checkForUpdates(manifestURLs: [Self.primaryURL]) }
        }
    }

    @Test("Ed25519 keyId mismatch is rejected when expectedKeyId is non-empty")
    func keyIdMismatchRejected() async throws {
        let priv = Curve25519.Signing.PrivateKey()
        let data = try JSONEncoder().encode(try signManifest(makeManifest(), privateKey: priv, keyId: "legacy-key"))
        let updater = makeUpdater(publicKeyBase64: priv.publicKey.rawRepresentation.base64EncodedString(),
                                  expectedKeyId: "maccar-release-v1", fetcher: MockHTTPFetcher([Self.primaryURL: .data(data, 200)]))
        await #expect(throws: ReleaseUpdateError.self) { try await updater.checkForUpdates(manifestURLs: [Self.primaryURL]) }
    }

    @Test("Empty public key selects sha256Unpinned or teamIdVerified trust level")
    func emptyPublicKeyTrustLevelFallback() async throws {
        let data = try JSONEncoder().encode(makeManifest())
        let unpinned = makeUpdater(teamID: nil, fetcher: MockHTTPFetcher([Self.primaryURL: .data(data, 200)]))
        if case .available(let c1) = try await unpinned.checkForUpdates(manifestURLs: [Self.primaryURL]) {
            #expect(c1.trustLevel == .sha256Unpinned)
        } else { Issue.record("Expected .available") }

        let team = makeUpdater(teamID: "AB12CD34EF", fetcher: MockHTTPFetcher([Self.primaryURL: .data(data, 200)]))
        if case .available(let c2) = try await team.checkForUpdates(manifestURLs: [Self.primaryURL]) {
            #expect(c2.trustLevel == .teamIdVerified)
        } else { Issue.record("Expected .available") }
    }

    @Test("downloadAndStageUpdate verifies SHA-256 and sizeBytes, stages valid app, and cleans up on tamper")
    func downloadAndStageSuccessAndTamperCleanup() async throws {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("maccar-test-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let targetParent = workDir.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: targetParent, withIntermediateDirectories: true)
        let targetApp = targetParent.appendingPathComponent("Maccar.app", isDirectory: true)
        let archive = try makeSignedTestAppArchive(in: workDir)
        let archiveURL = try #require(URL(string: Self.zipURL))

        let validData = try JSONEncoder().encode(makeManifest(zipSha256: archive.sha256, zipSizeBytes: archive.sizeBytes))
        let updater = makeUpdater(fetcher: MockHTTPFetcher([Self.primaryURL: .data(validData, 200), archiveURL: .file(archive.zipURL, 200)]))
        guard case .available(let candidate) = try await updater.checkForUpdates(manifestURLs: [Self.primaryURL]) else {
            Issue.record("Expected .available"); return
        }
        let staged = try await updater.downloadAndStageUpdate(candidate, targetBundleURL: targetApp)
        defer { try? FileManager.default.removeItem(at: staged.stagingDirectoryURL) }
        #expect(FileManager.default.fileExists(atPath: staged.stagedBundleURL.path))

        let beforeStagingDirs = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?
                .filter { $0.hasPrefix("maccar-update-") } ?? []
        )
        let badSha = UpdateCandidate(manifest: makeManifest(zipSha256: String(repeating: "f", count: 64), zipSizeBytes: archive.sizeBytes),
                                     version: candidate.version, trustLevel: .sha256Unpinned, sourceManifestURL: Self.primaryURL)
        await #expect(throws: ReleaseUpdateError.checksumMismatch) { try await updater.downloadAndStageUpdate(badSha, targetBundleURL: targetApp) }

        let badSize = UpdateCandidate(manifest: makeManifest(zipSha256: archive.sha256, zipSizeBytes: archive.sizeBytes + 10),
                                      version: candidate.version, trustLevel: .sha256Unpinned, sourceManifestURL: Self.primaryURL)
        await #expect(throws: ReleaseUpdateError.sizeMismatch(expected: archive.sizeBytes + 10, actual: archive.sizeBytes)) {
            try await updater.downloadAndStageUpdate(badSize, targetBundleURL: targetApp)
        }
        let afterStagingDirs = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?
                .filter { $0.hasPrefix("maccar-update-") } ?? []
        )
        #expect(afterStagingDirs == beforeStagingDirs)
    }

    @Test("parseTeamIdentifier parses valid 10-char Team ID from codesign stderr and ignores not set")
    func parseTeamIdentifierFromCodesignStderr() {
        #expect(ReleaseUpdater.parseTeamIdentifier(fromCodesignStderr: "Identifier=com.maccar.app\nTeamIdentifier=AB12CD34EF\n") == "AB12CD34EF")
        #expect(ReleaseUpdater.parseTeamIdentifier(fromCodesignStderr: "Identifier=com.maccar.app\nTeamIdentifier=not set\n") == nil)
        #expect(ReleaseUpdater.parseTeamIdentifier(fromCodesignStderr: "Identifier=com.maccar.app\n") == nil)
    }

    @Test("StageAndInstallGuard rejects translocation, DMG volumes, non-.app, and non-writable targets")
    func stageAndInstallGuardRejectsUnsafeLocations() throws {
        for badPath in ["/private/var/folders/xx/AppTranslocation/1234/d/Maccar.app", "/Volumes/Maccar/Maccar.app", "/tmp/Maccar.txt"] {
            #expect(throws: ReleaseUpdateError.self) { try StageAndInstallGuard.validateInstallTarget(URL(fileURLWithPath: badPath)) }
        }
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("maccar-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workDir.path); try? FileManager.default.removeItem(at: workDir) }

        let lockedParent = workDir.appendingPathComponent("LockedApps", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedParent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedParent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedParent.path) }
        #expect(throws: ReleaseUpdateError.self) { try StageAndInstallGuard.validateInstallTarget(lockedParent.appendingPathComponent("Maccar.app")) }

        let writableParent = workDir.appendingPathComponent("WritableApps", isDirectory: true)
        let lockedApp = writableParent.appendingPathComponent("Maccar.app", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedApp, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedApp.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedApp.path) }
        #expect(throws: ReleaseUpdateError.self) { try StageAndInstallGuard.validateInstallTarget(lockedApp) }
    }

    @Test("HTTP 404/500 returns structured error and primary failure falls back to mirror URL")
    func httpErrorsAndMirrorFallback() async throws {
        let errorUpdater = makeUpdater(fetcher: MockHTTPFetcher([Self.primaryURL: .data(Data(), 500), Self.mirrorURL: .data(Data(), 404)]))
        await #expect(throws: ReleaseUpdateError.httpError(404)) {
            try await errorUpdater.checkForUpdates(manifestURLs: [Self.primaryURL, Self.mirrorURL])
        }
        let fallbackFetcher = MockHTTPFetcher([Self.primaryURL: .data(Data(), 500), Self.mirrorURL: .data(try JSONEncoder().encode(makeManifest()), 200)])
        guard case .available(let candidate) = try await makeUpdater(fetcher: fallbackFetcher).checkForUpdates(manifestURLs: [Self.primaryURL, Self.mirrorURL]) else {
            Issue.record("Expected mirror fallback"); return
        }
        #expect(candidate.sourceManifestURL == Self.mirrorURL && fallbackFetcher.requestedURLs == [Self.primaryURL, Self.mirrorURL])
    }
}
