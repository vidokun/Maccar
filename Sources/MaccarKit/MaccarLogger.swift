import Foundation
import os

public enum LogLevel: String, Sendable, CaseIterable, Comparable {
    case debug
    case info
    case warning
    case error

    private var severity: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.severity < rhs.severity
    }

    public var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }
}

public struct LogEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String
    public let formattedLine: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        category: String,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.formattedLine = Self.formatLine(
            timestamp: timestamp,
            level: level,
            category: category,
            message: message
        )
    }

    private static func formatLine(
        timestamp: Date,
        level: LogLevel,
        category: String,
        message: String
    ) -> String {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: timestamp
        )
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        let millisecond = (components.nanosecond ?? 0) / 1_000_000

        let timePrefix = String(
            format: "%04d-%02d-%02d %02d:%02d:%02d.%03d",
            year, month, day, hour, minute, second, millisecond
        )
        return "\(timePrefix) [\(level.label)] [\(category)] \(message)"
    }
}

public final class MaccarLogger: @unchecked Sendable {
    public static let shared = MaccarLogger()

    public let logDirectoryURL: URL
    public let logFileURL: URL

    public var rotatedLogFileURL: URL {
        logDirectoryURL.appendingPathComponent("maccar.log.1")
    }

    private struct State: Sendable {
        var buffer: [LogEntry] = []
        var onNewEntry: (@Sendable (LogEntry) -> Void)?
    }

    private let maxBufferEntries: Int
    private let maxFileSizeBytes: UInt64
    private let stateLock = OSAllocatedUnfairLock(initialState: State())
    private let writerQueue = DispatchQueue(label: "com.maccar.logger.writer", qos: .background)

    public init(
        logDirectory: URL? = nil,
        maxBufferEntries: Int = 500,
        maxFileSizeBytes: UInt64 = 512 * 1024
    ) {
        let resolvedDirectory = logDirectory ?? Self.resolveDefaultLogDirectory()
        self.logDirectoryURL = resolvedDirectory
        self.logFileURL = resolvedDirectory.appendingPathComponent("maccar.log")
        self.maxBufferEntries = max(1, maxBufferEntries)
        self.maxFileSizeBytes = max(256, maxFileSizeBytes)
    }

    internal static func resolveDefaultLogDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        processName: String = ProcessInfo.processInfo.processName,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        hasXCTestClass: Bool = NSClassFromString("XCTestCase") != nil,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let trimmedOverride = environment["MACCAR_LOG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedOverride.isEmpty {
            return URL(fileURLWithPath: trimmedOverride, isDirectory: true)
        }

        let isRunningUnderTestRunner = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || hasXCTestClass
            || bundleURL.pathExtension == "xctest"
            || bundleURL.lastPathComponent.hasSuffix(".xctest")
            || processName == "xctest"
            || processName == "swiftpm-testing-helper"

        if isRunningUnderTestRunner {
            return temporaryDirectory.appendingPathComponent("maccar-test-logs-\(processID)", isDirectory: true)
        }

        return homeDirectory.appendingPathComponent("Library/Logs/Maccar", isDirectory: true)
    }

    public var onNewEntry: (@Sendable (LogEntry) -> Void)? {
        get { stateLock.withLock { $0.onNewEntry } }
        set { stateLock.withLock { $0.onNewEntry = newValue } }
    }

    public func setOnNewEntry(_ handler: (@Sendable (LogEntry) -> Void)?) {
        stateLock.withLock { $0.onNewEntry = handler }
    }

    public func log(_ level: LogLevel, category: String, message: String) {
        let entry = LogEntry(level: level, category: category, message: message)

        let subscriber: (@Sendable (LogEntry) -> Void)? = stateLock.withLock { state in
            state.buffer.append(entry)
            if state.buffer.count > maxBufferEntries {
                state.buffer.removeFirst(state.buffer.count - maxBufferEntries)
            }
            return state.onNewEntry
        }

        // Invoke subscriber outside the lock to prevent re-entrant lock deadlocks.
        subscriber?(entry)

        let lineData = Data((entry.formattedLine + "\n").utf8)
        let directory = logDirectoryURL
        let file = logFileURL
        let rotated = rotatedLogFileURL
        let maxSize = maxFileSizeBytes

        writerQueue.async {
            Self.writeLine(
                lineData,
                directory: directory,
                logFile: file,
                rotatedFile: rotated,
                maxFileSizeBytes: maxSize
            )
        }
    }

    public func debug(_ category: String, _ message: String) {
        log(.debug, category: category, message: message)
    }

    public func info(_ category: String, _ message: String) {
        log(.info, category: category, message: message)
    }

    public func warning(_ category: String, _ message: String) {
        log(.warning, category: category, message: message)
    }

    public func error(_ category: String, _ message: String) {
        log(.error, category: category, message: message)
    }

    public func recentEntries() -> [LogEntry] {
        stateLock.withLock { $0.buffer }
    }

    public func formattedLogs() -> String {
        recentEntries().map(\.formattedLine).joined(separator: "\n")
    }

    public func clearMemoryBuffer() {
        stateLock.withLock { $0.buffer.removeAll() }
    }

    @discardableResult
    public func flush(timeout: TimeInterval = 2.0) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        writerQueue.async {
            semaphore.signal()
        }
        let clampedTimeout = max(0.0, timeout)
        return semaphore.wait(timeout: .now() + clampedTimeout) == .success
    }

    private static func writeLine(
        _ data: Data,
        directory: URL,
        logFile: URL,
        rotatedFile: URL,
        maxFileSizeBytes: UInt64
    ) {
        let fileManager = FileManager.default
        do {
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            rotateIfNeeded(
                fileManager: fileManager,
                logFile: logFile,
                rotatedFile: rotatedFile,
                incomingByteCount: UInt64(data.count),
                maxFileSizeBytes: maxFileSizeBytes
            )

            if !fileManager.fileExists(atPath: logFile.path) {
                fileManager.createFile(atPath: logFile.path, contents: nil)
            }

            let handle = try FileHandle(forWritingTo: logFile)
            defer {
                try? handle.close()
            }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Avoid recursive logger feedback; in-memory ring buffer retains the entry.
            fputs("[MaccarLogger] Disk write error: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func rotateIfNeeded(
        fileManager: FileManager,
        logFile: URL,
        rotatedFile: URL,
        incomingByteCount: UInt64,
        maxFileSizeBytes: UInt64
    ) {
        guard fileManager.fileExists(atPath: logFile.path),
              let attributes = try? fileManager.attributesOfItem(atPath: logFile.path),
              let currentSize = (attributes[.size] as? NSNumber)?.uint64Value,
              currentSize > 0
        else {
            return
        }

        let exceedsLimit = currentSize >= maxFileSizeBytes || (currentSize + incomingByteCount) > maxFileSizeBytes
        guard exceedsLimit else { return }

        do {
            if fileManager.fileExists(atPath: rotatedFile.path) {
                try fileManager.removeItem(at: rotatedFile)
            }
            try fileManager.moveItem(at: logFile, to: rotatedFile)
        } catch {
            fputs("[MaccarLogger] Log rotation error: \(error.localizedDescription)\n", stderr)
        }
    }
}
