import Foundation
import Testing
@testable import MaccarKit

@Suite("MaccarLogger Tests")
struct LoggerTests {
    private func withTempDirectory(_ body: (URL) throws -> Void) throws {
        let folderName = "maccar-logger-tests-\(UUID().uuidString)"
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try body(tempDir)
    }

    @Test("Concurrent burst strictly caps in-memory ring buffer at 500 entries")
    func concurrentBurstCapsRingBufferAtFiveHundred() throws {
        try withTempDirectory { tempDir in
            let logger = MaccarLogger(
                logDirectory: tempDir,
                maxBufferEntries: 500,
                maxFileSizeBytes: 512 * 1024
            )

            DispatchQueue.concurrentPerform(iterations: 1_200) { index in
                logger.info("Burst", "message-\(index)")
            }

            #expect(logger.flush(timeout: 5.0))
            let retained = logger.recentEntries()
            #expect(retained.count == 500)

            let uniqueMessages = Set(retained.map(\.message))
            #expect(uniqueMessages.count == 500)
            #expect(retained.allSatisfy { $0.category == "Burst" && $0.level == .info })
        }
    }

    @Test("Ring buffer evicts oldest entries in FIFO order")
    func ringBufferEvictsOldestEntriesInFIFOOrder() throws {
        try withTempDirectory { tempDir in
            let logger = MaccarLogger(
                logDirectory: tempDir,
                maxBufferEntries: 500,
                maxFileSizeBytes: 512 * 1024
            )

            for index in 0..<750 {
                logger.debug("Order", "seq-\(index)")
            }

            let retained = logger.recentEntries()
            #expect(retained.count == 500)
            #expect(retained.first?.message == "seq-250")
            #expect(retained.last?.message == "seq-749")
            #expect(logger.flush(timeout: 5.0))
        }
    }

    @Test("Log rotation creates maccar.log.1 and keeps active file bounded")
    func logRotationCreatesBackupAndBoundsActiveFile() throws {
        try withTempDirectory { tempDir in
            let maxBytes: UInt64 = 2_048
            let logger = MaccarLogger(
                logDirectory: tempDir,
                maxBufferEntries: 500,
                maxFileSizeBytes: maxBytes
            )
            let payload = String(repeating: "A", count: 72)

            for index in 0..<60 {
                logger.warning("Rotation", "entry-\(index)-\(payload)")
            }

            #expect(logger.flush(timeout: 5.0))
            let fileManager = FileManager.default
            #expect(fileManager.fileExists(atPath: logger.logFileURL.path))
            #expect(fileManager.fileExists(atPath: logger.rotatedLogFileURL.path))

            let activeAttrs = try fileManager.attributesOfItem(atPath: logger.logFileURL.path)
            let activeSize = (activeAttrs[.size] as? NSNumber)?.uint64Value ?? 0
            #expect(activeSize > 0)
            #expect(activeSize <= maxBytes)

            let rotatedAttrs = try fileManager.attributesOfItem(atPath: logger.rotatedLogFileURL.path)
            let rotatedSize = (rotatedAttrs[.size] as? NSNumber)?.uint64Value ?? 0
            #expect(rotatedSize > 0)
            #expect(rotatedSize <= maxBytes)
        }
    }

    @Test("Clear memory buffer resets ring buffer while preserving disk log and future formatting")
    func clearMemoryBufferAndFormattedLogs() throws {
        try withTempDirectory { tempDir in
            let logger = MaccarLogger(
                logDirectory: tempDir,
                maxBufferEntries: 500,
                maxFileSizeBytes: 8_192
            )

            logger.info("Session", "First entry")
            logger.warning("Session", "Second entry")

            let beforeClear = logger.formattedLogs()
            #expect(beforeClear.contains("[INFO] [Session] First entry"))
            #expect(beforeClear.contains("[WARN] [Session] Second entry"))
            #expect(logger.recentEntries().count == 2)

            logger.clearMemoryBuffer()
            #expect(logger.recentEntries().isEmpty)
            #expect(logger.formattedLogs().isEmpty)

            logger.error("Session", "After clear")
            #expect(logger.flush(timeout: 5.0))

            #expect(logger.recentEntries().count == 1)
            #expect(logger.formattedLogs().contains("[ERROR] [Session] After clear"))

            let persisted = try String(contentsOf: logger.logFileURL, encoding: .utf8)
            #expect(persisted.contains("First entry"))
            #expect(persisted.contains("After clear"))
        }
    }

    @Test("MACCAR_LOG_DIR trims non-empty override and takes precedence over test signals")
    func envOverrideTrimsNonEmptyValue() {
        let customTemp = URL(fileURLWithPath: "/tmp/maccar-custom-temp", isDirectory: true)
        let customHome = URL(fileURLWithPath: "/tmp/maccar-custom-home", isDirectory: true)
        let appBundle = URL(fileURLWithPath: "/Applications/Maccar.app", isDirectory: true)

        let overridden = MaccarLogger.resolveDefaultLogDirectory(
            environment: [
                "MACCAR_LOG_DIR": "  /tmp/maccar-override-logs \n",
                "XCTestConfigurationFilePath": "/tmp/Test.xctestconfiguration"
            ],
            bundleURL: appBundle,
            processName: "xctest",
            processID: 1234,
            hasXCTestClass: true,
            temporaryDirectory: customTemp,
            homeDirectory: customHome
        )
        #expect(
            overridden.standardizedFileURL
                == URL(fileURLWithPath: "/tmp/maccar-override-logs", isDirectory: true).standardizedFileURL
        )
    }

    @Test("Whitespace-only MACCAR_LOG_DIR falls through to test or production directory")
    func whitespaceEnvOverrideFallsThrough() {
        let customTemp = URL(fileURLWithPath: "/tmp/maccar-custom-temp", isDirectory: true)
        let customHome = URL(fileURLWithPath: "/tmp/maccar-custom-home", isDirectory: true)
        let appBundle = URL(fileURLWithPath: "/Applications/Maccar.app", isDirectory: true)

        let whitespaceFallbackToProd = MaccarLogger.resolveDefaultLogDirectory(
            environment: ["MACCAR_LOG_DIR": "   \n"],
            bundleURL: appBundle,
            processName: "maccar",
            processID: 1234,
            hasXCTestClass: false,
            temporaryDirectory: customTemp,
            homeDirectory: customHome
        )
        #expect(
            whitespaceFallbackToProd.standardizedFileURL
                == customHome.appendingPathComponent("Library/Logs/Maccar", isDirectory: true).standardizedFileURL
        )

        let whitespaceFallbackToTest = MaccarLogger.resolveDefaultLogDirectory(
            environment: [
                "MACCAR_LOG_DIR": "   \n",
                "XCTestSessionIdentifier": "session-1"
            ],
            bundleURL: appBundle,
            processName: "maccar",
            processID: 5678,
            hasXCTestClass: false,
            temporaryDirectory: customTemp,
            homeDirectory: customHome
        )
        #expect(
            whitespaceFallbackToTest.standardizedFileURL
                == customTemp.appendingPathComponent("maccar-test-logs-5678", isDirectory: true).standardizedFileURL
        )
    }

    @Test("Test runner signals isolate log directory to process-scoped temp folder")
    func testRunnerSignalsIsolateToTempDirectory() {
        let customTemp = URL(fileURLWithPath: "/tmp/maccar-isolated-temp", isDirectory: true)
        let customHome = URL(fileURLWithPath: "/tmp/maccar-isolated-home", isDirectory: true)
        let appBundle = URL(fileURLWithPath: "/Applications/Maccar.app", isDirectory: true)
        let expected = customTemp.appendingPathComponent("maccar-test-logs-9001", isDirectory: true).standardizedFileURL

        let cases: [(environment: [String: String], bundleURL: URL, processName: String, hasXCTestClass: Bool)] = [
            (["XCTestConfigurationFilePath": "/tmp/Unit.xctestconfiguration"], appBundle, "maccar", false),
            (["XCTestSessionIdentifier": "UUID-SESSION"], appBundle, "maccar", false),
            ([:], URL(fileURLWithPath: "/tmp/MaccarTests.xctest", isDirectory: true), "maccar", false),
            ([:], URL(fileURLWithPath: "/tmp/MaccarTests.xctest", isDirectory: false), "maccar", false),
            ([:], appBundle, "xctest", false),
            ([:], appBundle, "swiftpm-testing-helper", false),
            ([:], appBundle, "maccar", true)
        ]

        for testCase in cases {
            let resolved = MaccarLogger.resolveDefaultLogDirectory(
                environment: testCase.environment,
                bundleURL: testCase.bundleURL,
                processName: testCase.processName,
                processID: 9001,
                hasXCTestClass: testCase.hasXCTestClass,
                temporaryDirectory: customTemp,
                homeDirectory: customHome
            )
            #expect(resolved.standardizedFileURL == expected)
        }
    }

    @Test("Clean non-test process resolves to Library/Logs/Maccar under home directory")
    func cleanNonTestResolutionUsesHomeLibraryLogs() {
        let customTemp = URL(fileURLWithPath: "/tmp/maccar-prod-temp", isDirectory: true)
        let customHome = URL(fileURLWithPath: "/tmp/maccar-prod-home", isDirectory: true)

        let resolved = MaccarLogger.resolveDefaultLogDirectory(
            environment: [:],
            bundleURL: URL(fileURLWithPath: "/Applications/Maccar.app", isDirectory: true),
            processName: "maccar",
            processID: 4242,
            hasXCTestClass: false,
            temporaryDirectory: customTemp,
            homeDirectory: customHome
        )

        let expected = customHome.appendingPathComponent("Library/Logs/Maccar", isDirectory: true)
        #expect(resolved.standardizedFileURL == expected.standardizedFileURL)
    }

    @Test("MaccarLogger.shared does not resolve under ~/Library/Logs/Maccar during test runs")
    func sharedLoggerIsIsolatedFromLiveLogDirectory() {
        let liveDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Maccar", isDirectory: true)
            .standardizedFileURL
        let sharedDirectory = MaccarLogger.shared.logDirectoryURL.standardizedFileURL

        #expect(sharedDirectory != liveDirectory)
        #expect(!sharedDirectory.path.hasPrefix(liveDirectory.path + "/"))
        #expect(sharedDirectory.lastPathComponent == "maccar-test-logs-\(ProcessInfo.processInfo.processIdentifier)")
    }
}
