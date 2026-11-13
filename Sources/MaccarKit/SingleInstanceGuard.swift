import Foundation
import os

/// Enforces "exactly one Maccar instance may own the device watcher".
///
/// Two live instances each run their own `DeviceWatcher` and independently call
/// `SidecarCoreConnectDevice`, which produces concurrent connects, `-100` session
/// rejections, and one stacked system alert per failed call. A per-user kernel
/// lock is the only reliable cross-process gate, so this uses `flock` rather than
/// an in-process flag.
public final class SingleInstanceGuard: @unchecked Sendable {
    private enum Constants {
        static let filePermissions: mode_t = 0o644
        static let applicationSupportSubdirectory = "Maccar"
        static let applicationLockFileName = "instance.lock"
    }

    private struct State: Sendable {
        var fileDescriptor: Int32 = -1
    }

    private let directory: URL
    private let fileName: String
    private let stateLock = OSAllocatedUnfairLock(initialState: State())

    public init(directory: URL, fileName: String) {
        self.directory = directory
        self.fileName = fileName
    }

    deinit { release() }

    public var lockFilePath: String { directory.appendingPathComponent(fileName).path }

    /// Claims the lock for this process. Idempotent while held: a repeat call
    /// returns `true` instead of opening a second descriptor.
    public func acquire() -> Bool {
        let alreadyHeld = stateLock.withLock { $0.fileDescriptor >= 0 }
        if alreadyHeld { return true }

        guard ensureDirectoryExists() else { return false }
        guard let descriptor = openLockFile() else { return false }

        // LOCK_NB so a second process fails fast instead of blocking its launch.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }

        // The descriptor must stay open for the lifetime of the lock: closing it
        // releases the flock and silently voids the guard.
        let claimed = stateLock.withLock { state -> Bool in
            guard state.fileDescriptor < 0 else { return false }
            state.fileDescriptor = descriptor
            return true
        }
        if !claimed { close(descriptor) }
        return claimed
    }

    public func release() {
        let descriptor = stateLock.withLock { state -> Int32 in
            let held = state.fileDescriptor
            state.fileDescriptor = -1
            return held
        }
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    public static func makeApplicationGuard() -> SingleInstanceGuard {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent(Constants.applicationSupportSubdirectory, isDirectory: true)
        return SingleInstanceGuard(directory: directory, fileName: Constants.applicationLockFileName)
    }

    private func ensureDirectoryExists() -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    /// O_CREAT without O_EXCL: the file legitimately already exists across launches,
    /// and the lock lives in the kernel's flock table, not in the file's contents.
    private func openLockFile() -> Int32? {
        let descriptor = open(lockFilePath, O_CREAT | O_RDWR, Constants.filePermissions)
        return descriptor >= 0 ? descriptor : nil
    }
}
