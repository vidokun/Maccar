import CryptoKit
import Foundation
import os

public struct AppVersion: Comparable, Hashable, Sendable {
    public let major: Int, minor: Int, patch: Int, build: Int
    public var formatted: String { "\(major).\(minor).\(patch)" }
    public init?(versionString: String, build: Int = 0) {
        guard build >= 0 else { return nil }
        var raw = versionString.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("v") || raw.hasPrefix("V") { raw.removeFirst() }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.major = major; self.minor = minor; self.patch = patch; self.build = build
    }
    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch, lhs.build) < (rhs.major, rhs.minor, rhs.patch, rhs.build)
    }
}

public struct ReleaseManifest: Codable, Sendable, Equatable {
    public struct Artifact: Codable, Sendable, Equatable {
        public let url: String, sha256: String, sizeBytes: Int64
        public init(url: String, sha256: String, sizeBytes: Int64) { self.url = url; self.sha256 = sha256; self.sizeBytes = sizeBytes }
    }
    public struct Artifacts: Codable, Sendable, Equatable {
        public let zip: Artifact, dmg: Artifact
        public init(zip: Artifact, dmg: Artifact) { self.zip = zip; self.dmg = dmg }
    }
    public struct UpdateSignature: Codable, Sendable, Equatable {
        public let algorithm: String, keyId: String, zipSignatureBase64: String
        public init(algorithm: String, keyId: String, zipSignatureBase64: String) {
            self.algorithm = algorithm; self.keyId = keyId; self.zipSignatureBase64 = zipSignatureBase64
        }
    }
    public let schemaVersion: Int, product: String, bundleIdentifier: String, version: String, build: Int
    public let publishedAt: String, minimumSystemVersion: String, releaseNotesUrl: String, releaseNotesSummary: String
    public let artifacts: Artifacts, signature: UpdateSignature?
    public init(schemaVersion: Int, product: String, bundleIdentifier: String, version: String, build: Int, publishedAt: String,
                minimumSystemVersion: String, releaseNotesUrl: String, releaseNotesSummary: String, artifacts: Artifacts, signature: UpdateSignature?) {
        self.schemaVersion = schemaVersion; self.product = product; self.bundleIdentifier = bundleIdentifier; self.version = version; self.build = build
        self.publishedAt = publishedAt; self.minimumSystemVersion = minimumSystemVersion; self.releaseNotesUrl = releaseNotesUrl
        self.releaseNotesSummary = releaseNotesSummary; self.artifacts = artifacts; self.signature = signature
    }
}

public typealias UpdateSignature = ReleaseManifest.UpdateSignature
public enum UpdateTrustLevel: String, Sendable, Equatable { case ed25519Pinned, teamIdVerified, sha256Unpinned }
public enum UpdateAvailability: Sendable, Equatable { case upToDate(currentVersion: AppVersion), available(UpdateCandidate) }

public struct UpdateCandidate: Sendable, Equatable {
    public let manifest: ReleaseManifest, version: AppVersion, trustLevel: UpdateTrustLevel, sourceManifestURL: URL
    public init(manifest: ReleaseManifest, version: AppVersion, trustLevel: UpdateTrustLevel, sourceManifestURL: URL) {
        self.manifest = manifest; self.version = version; self.trustLevel = trustLevel; self.sourceManifestURL = sourceManifestURL
    }
}

public struct StagedUpdate: Sendable, Equatable {
    public let candidate: UpdateCandidate, stagingDirectoryURL: URL, stagedBundleURL: URL, targetBundleURL: URL
    public init(candidate: UpdateCandidate, stagingDirectoryURL: URL, stagedBundleURL: URL, targetBundleURL: URL) {
        self.candidate = candidate; self.stagingDirectoryURL = stagingDirectoryURL; self.stagedBundleURL = stagedBundleURL; self.targetBundleURL = targetBundleURL
    }
}

public protocol HTTPFetching: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func download(for request: URLRequest) async throws -> (URL, URLResponse)
}

public protocol UpdateSettingsProviding: AnyObject, Sendable {
    var autoCheckUpdates: Bool { get set }; var lastUpdateCheckTimestamp: TimeInterval { get set }; var skippedVersion: String? { get set }
}
extension MaccarSettings: UpdateSettingsProviding {}

public protocol UpdateChecking: AnyObject, Sendable {
    func checkForUpdates(manifestURLs: [URL]) async throws -> UpdateAvailability
    func downloadAndStageUpdate(_ candidate: UpdateCandidate, targetBundleURL: URL) async throws -> StagedUpdate
    func installStagedUpdate(_ staged: StagedUpdate) throws
}
public extension UpdateChecking {
    func checkForUpdates() async throws -> UpdateAvailability { try await checkForUpdates(manifestURLs: [ReleaseUpdater.primaryManifestURL, ReleaseUpdater.fallbackManifestURL]) }
    func downloadAndStageUpdate(_ candidate: UpdateCandidate) async throws -> StagedUpdate { try await downloadAndStageUpdate(candidate, targetBundleURL: Bundle.main.bundleURL) }
}

public enum ReleaseUpdateError: LocalizedError, Sendable, Equatable {
    case invalidURL(String), httpError(Int), invalidResponse, invalidManifest(String)
    case unsupportedOS(required: String), signatureInvalid(String), checksumMismatch
    case sizeMismatch(expected: Int64, actual: Int64), codesignFailed(String), teamIdentifierMismatch
    case unsafeInstallLocation(String), stagingFailed(String), installFailed(String)
    public var errorDescription: String? {
        switch self {
        case .invalidURL(let msg): return "Untrusted or invalid update URL: \(msg)"
        case .httpError(let code): return "Update server returned HTTP \(code)."
        case .invalidResponse: return "Invalid response from update server."
        case .invalidManifest(let msg): return "Invalid release manifest: \(msg)"
        case .unsupportedOS(let req): return "This update requires macOS \(req) or newer."
        case .signatureInvalid(let msg): return "Update signature check failed: \(msg)"
        case .checksumMismatch: return "Downloaded update SHA-256 checksum mismatch."
        case .sizeMismatch(let exp, let act): return "Downloaded size \(act) differs from manifest \(exp)."
        case .codesignFailed(let msg): return "Code signature verification failed: \(msg)"
        case .teamIdentifierMismatch: return "Update Team Identifier does not match current app."
        case .unsafeInstallLocation(let msg): return "Cannot auto-update at current location: \(msg)"
        case .stagingFailed(let msg): return "Failed to stage update archive: \(msg)"
        case .installFailed(let msg): return "Failed to install staged update: \(msg)"
        }
    }
}

public enum TrustedReleaseURLValidator {
    private static let cdnHosts: Set<String> = ["objects.githubusercontent.com", "release-assets.githubusercontent.com", "github-releases.githubusercontent.com"]
    public static func validateURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), !host.isEmpty, !url.pathComponents.contains("..") else { throw ReleaseUpdateError.invalidURL(url.absoluteString) }
        let path = url.path.lowercased()
        let allowed: Bool = switch host {
        case "github.com": path == "/vidokun/maccar" || path.hasPrefix("/vidokun/maccar/")
        case "vidokun.github.io": path == "/maccar" || path.hasPrefix("/maccar/")
        default: cdnHosts.contains(host)
        }
        guard allowed else { throw ReleaseUpdateError.invalidURL(url.absoluteString) }
    }
    public static func validateRedirect(from origin: URL, to destination: URL) throws { try validateURL(origin); try validateURL(destination) }
}

public enum StageAndInstallGuard {
    public static func validateInstallTarget(_ targetBundleURL: URL) throws {
        let path = targetBundleURL.path, stdPath = targetBundleURL.standardizedFileURL.path
        guard targetBundleURL.pathExtension == "app", !path.hasPrefix("/Volumes/"), !stdPath.hasPrefix("/Volumes/"),
              !path.contains("/AppTranslocation/"), !stdPath.contains("/AppTranslocation/") else { throw ReleaseUpdateError.unsafeInstallLocation(path) }
        let parentURL = targetBundleURL.deletingLastPathComponent(); var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentURL.path, isDirectory: &isDir), isDir.boolValue,
              FileManager.default.isWritableFile(atPath: parentURL.path),
              !FileManager.default.fileExists(atPath: path) || FileManager.default.isWritableFile(atPath: path)
        else { throw ReleaseUpdateError.unsafeInstallLocation(path) }
    }
}

public final class SystemHTTPFetcher: HTTPFetching, Sendable {
    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let origin = task.currentRequest?.url ?? task.originalRequest?.url, let dest = request.url,
                  (try? TrustedReleaseURLValidator.validateRedirect(from: origin, to: dest)) != nil else { completionHandler(nil); return }
            completionHandler(request)
        }
    }
    public init() {}
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (session, timed) = try makeSession(for: request, timeout: 10); defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: timed); try Self.validateHTTPResponse(response); return (data, response)
    }
    public func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        let (session, timed) = try makeSession(for: request, timeout: 60); defer { session.finishTasksAndInvalidate() }
        let (fileURL, response) = try await session.download(for: timed); try Self.validateHTTPResponse(response); return (fileURL, response)
    }
    private func makeSession(for request: URLRequest, timeout: TimeInterval) throws -> (URLSession, URLRequest) {
        guard let url = request.url else { throw ReleaseUpdateError.invalidURL("Missing URL") }
        try TrustedReleaseURLValidator.validateURL(url)
        var timed = request; timed.timeoutInterval = timeout
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        return (URLSession(configuration: config, delegate: RedirectDelegate(), delegateQueue: nil), timed)
    }
    fileprivate static func validateHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ReleaseUpdateError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ReleaseUpdateError.httpError(http.statusCode) }
        if let finalURL = http.url { try TrustedReleaseURLValidator.validateURL(finalURL) }
    }
}

public final class ReleaseUpdater: UpdateChecking, @unchecked Sendable {
    public static let primaryManifestURL = URL(string: "https://github.com/vidokun/Maccar/releases/latest/download/manifest.json")!
    public static let fallbackManifestURL = URL(string: "https://vidokun.github.io/Maccar/manifest.json")!
    private let currentVersion: AppVersion, bundleIdentifier: String, operatingSystemVersion: OperatingSystemVersion
    private let publicKeyBase64: String, expectedKeyId: String, runningTeamIdentifierProvider: @Sendable () -> String?, httpFetcher: any HTTPFetching

    public convenience init(httpFetcher: any HTTPFetching = SystemHTTPFetcher()) {
        let info = Bundle.main.infoDictionary ?? [:]
        let ver = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = (info["CFBundleVersion"] as? String).flatMap(Int.init) ?? (info["CFBundleVersion"] as? Int) ?? 0
        self.init(currentVersion: AppVersion(versionString: ver, build: build) ?? AppVersion(versionString: "0.0.0")!,
                  bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.maccar.app", operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion,
                  publicKeyBase64: (info["MaccarUpdatePublicKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                  expectedKeyId: (info["MaccarUpdateKeyId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                  runningTeamIdentifierProvider: { Self.readTeamIdentifier(for: Bundle.main.bundleURL) }, httpFetcher: httpFetcher)
    }
    internal init(currentVersion: AppVersion, bundleIdentifier: String, operatingSystemVersion: OperatingSystemVersion, publicKeyBase64: String,
                  expectedKeyId: String, runningTeamIdentifierProvider: @escaping @Sendable () -> String?, httpFetcher: any HTTPFetching) {
        self.currentVersion = currentVersion; self.bundleIdentifier = bundleIdentifier; self.operatingSystemVersion = operatingSystemVersion
        self.publicKeyBase64 = publicKeyBase64; self.expectedKeyId = expectedKeyId
        self.runningTeamIdentifierProvider = runningTeamIdentifierProvider; self.httpFetcher = httpFetcher
    }
    public func checkForUpdates(manifestURLs: [URL]) async throws -> UpdateAvailability {
        guard !manifestURLs.isEmpty else { throw ReleaseUpdateError.invalidURL("No manifest URLs provided") }
        var lastError: Error = ReleaseUpdateError.invalidResponse
        for url in manifestURLs {
            do { return try await evaluateManifest(at: url) } catch {
                lastError = error; MaccarLogger.shared.warning("Updater", "Manifest check failed for \(url.host ?? "unknown"): \(error.localizedDescription)")
            }
        }
        throw lastError
    }
    public func downloadAndStageUpdate(_ candidate: UpdateCandidate, targetBundleURL: URL) async throws -> StagedUpdate {
        try StageAndInstallGuard.validateInstallTarget(targetBundleURL)
        guard let zipURL = URL(string: candidate.manifest.artifacts.zip.url) else { throw ReleaseUpdateError.invalidURL(candidate.manifest.artifacts.zip.url) }
        try TrustedReleaseURLValidator.validateURL(zipURL)
        let (downloadedURL, response) = try await httpFetcher.download(for: URLRequest(url: zipURL))
        defer { try? FileManager.default.removeItem(at: downloadedURL) }
        try SystemHTTPFetcher.validateHTTPResponse(response)
        try Self.verifyFile(at: downloadedURL, sizeBytes: candidate.manifest.artifacts.zip.sizeBytes, sha256: candidate.manifest.artifacts.zip.sha256)
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent("maccar-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        var keepStaging = false; defer { if !keepStaging { try? FileManager.default.removeItem(at: stagingDir) } }
        let (dittoStatus, dittoStderr) = try Self.runProcess("/usr/bin/ditto", ["-x", "-k", downloadedURL.path, stagingDir.path])
        guard dittoStatus == 0 else { throw ReleaseUpdateError.stagingFailed(dittoStderr) }
        let items = try FileManager.default.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: [.isDirectoryKey])
        guard let stagedApp = items.first(where: { $0.pathExtension == "app" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
        else { throw ReleaseUpdateError.stagingFailed("No .app bundle found in archive.") }
        try verifyStagedAppBundle(at: stagedApp, trustLevel: candidate.trustLevel)
        keepStaging = true
        return StagedUpdate(candidate: candidate, stagingDirectoryURL: stagingDir, stagedBundleURL: stagedApp, targetBundleURL: targetBundleURL)
    }
    public func installStagedUpdate(_ staged: StagedUpdate) throws {
        try StageAndInstallGuard.validateInstallTarget(staged.targetBundleURL)
        guard FileManager.default.fileExists(atPath: staged.stagedBundleURL.path) else { throw ReleaseUpdateError.installFailed("Staged app bundle missing.") }
        let backupDir = FileManager.default.temporaryDirectory.appendingPathComponent("maccar-backup-\(UUID().uuidString)", isDirectory: true)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.swapHelperScript, "maccar-updater", String(ProcessInfo.processInfo.processIdentifier),
                             staged.stagedBundleURL.path, staged.targetBundleURL.path, backupDir.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
    }
    private func evaluateManifest(at url: URL) async throws -> UpdateAvailability {
        try TrustedReleaseURLValidator.validateURL(url)
        let (data, response) = try await httpFetcher.data(for: URLRequest(url: url))
        try SystemHTTPFetcher.validateHTTPResponse(response)
        let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: data)
        guard manifest.schemaVersion == 1, manifest.product == "Maccar", manifest.bundleIdentifier == bundleIdentifier,
              let version = AppVersion(versionString: manifest.version, build: manifest.build),
              let notesURL = URL(string: manifest.releaseNotesUrl), let zipURL = URL(string: manifest.artifacts.zip.url),
              manifest.artifacts.zip.sizeBytes > 0, manifest.artifacts.zip.sha256.count == 64, manifest.artifacts.zip.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit })
        else { throw ReleaseUpdateError.invalidManifest("Manifest failed structural checks.") }
        try TrustedReleaseURLValidator.validateURL(notesURL); try TrustedReleaseURLValidator.validateURL(zipURL)
        guard isCompatibleOS(minimumVersion: manifest.minimumSystemVersion) else { throw ReleaseUpdateError.unsupportedOS(required: manifest.minimumSystemVersion) }
        let trustLevel = try resolveTrustLevel(for: manifest)
        guard version > currentVersion else { return .upToDate(currentVersion: currentVersion) }
        return .available(UpdateCandidate(manifest: manifest, version: version, trustLevel: trustLevel, sourceManifestURL: url))
    }
    private func resolveTrustLevel(for manifest: ReleaseManifest) throws -> UpdateTrustLevel {
        guard !publicKeyBase64.isEmpty else { return (runningTeamIdentifierProvider()?.isEmpty == false) ? .teamIdVerified : .sha256Unpinned }
        guard let keyData = Data(base64Encoded: publicKeyBase64), let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let sig = manifest.signature, sig.algorithm.lowercased() == "ed25519", expectedKeyId.isEmpty || sig.keyId == expectedKeyId,
              let sigData = Data(base64Encoded: sig.zipSignatureBase64), !sigData.isEmpty
        else { throw ReleaseUpdateError.signatureInvalid("Missing or malformed Ed25519 signature.") }
        let payload = ["Maccar", manifest.bundleIdentifier, manifest.version, String(manifest.build), manifest.minimumSystemVersion,
                       manifest.artifacts.zip.url, manifest.artifacts.zip.sha256, String(manifest.artifacts.zip.sizeBytes), manifest.artifacts.dmg.sha256].joined(separator: "|")
        guard publicKey.isValidSignature(sigData, for: Data(payload.utf8)) else { throw ReleaseUpdateError.signatureInvalid("Ed25519 signature mismatch.") }
        return .ed25519Pinned
    }
    private func isCompatibleOS(minimumVersion: String) -> Bool {
        let parts = minimumVersion.split(separator: ".").compactMap { Int($0) }
        guard (2...3).contains(parts.count) else { return false }
        return (operatingSystemVersion.majorVersion, operatingSystemVersion.minorVersion, operatingSystemVersion.patchVersion) >= (parts[0], parts[1], parts.count == 3 ? parts[2] : 0)
    }
    private func verifyStagedAppBundle(at appURL: URL, trustLevel: UpdateTrustLevel) throws {
        guard let dict = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
              (dict["CFBundleIdentifier"] as? String) == bundleIdentifier else { throw ReleaseUpdateError.stagingFailed("Staged bundle identifier mismatch.") }
        let (status, stderr) = try Self.runProcess("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])
        guard status == 0 else { throw ReleaseUpdateError.codesignFailed(stderr) }
        if trustLevel == .teamIdVerified {
            guard let expected = runningTeamIdentifierProvider(), !expected.isEmpty, Self.readTeamIdentifier(for: appURL) == expected
            else { throw ReleaseUpdateError.teamIdentifierMismatch }
        }
    }
    internal static func parseTeamIdentifier(fromCodesignStderr output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("TeamIdentifier=") else { continue }
            let val = String(line.dropFirst("TeamIdentifier=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard val.count == 10, val.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
            return val
        }
        return nil
    }
    private static func readTeamIdentifier(for bundleURL: URL) -> String? {
        guard let (_, stderr) = try? runProcess("/usr/bin/codesign", ["-dvvv", bundleURL.path]) else { return nil }
        return parseTeamIdentifier(fromCodesignStderr: stderr)
    }
    private static func verifyFile(at url: URL, sizeBytes: Int64, sha256: String) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256(); var total: Int64 = 0
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty { hasher.update(data: chunk); total += Int64(chunk.count) }
        guard total == sizeBytes else { throw ReleaseUpdateError.sizeMismatch(expected: sizeBytes, actual: total) }
        guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == sha256.lowercased() else { throw ReleaseUpdateError.checksumMismatch }
    }
    private static func runProcess(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process(), stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = stderrPipe
        try process.run(); let data = stderrPipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    private static let swapHelperScript = #"""
    PID="$1"; STAGED="$2"; TARGET="$3"; BACKUP_DIR="$4"; BACKUP_APP="$BACKUP_DIR/Maccar.app"; elapsed=0
    while kill -0 "$PID" 2>/dev/null; do [ "$elapsed" -ge 150 ] && exit 1; sleep 0.1; elapsed=$((elapsed + 1)); done
    mkdir -p "$BACKUP_DIR" || exit 1
    if [ -e "$TARGET" ]; then mv "$TARGET" "$BACKUP_APP" || exit 1; fi
    if mv "$STAGED" "$TARGET"; then rm -rf "$BACKUP_DIR" "$(dirname "$STAGED")"; open -n "$TARGET"; exit 0; fi
    if [ -e "$BACKUP_APP" ]; then mv "$BACKUP_APP" "$TARGET"; fi; exit 1
    """#
}
