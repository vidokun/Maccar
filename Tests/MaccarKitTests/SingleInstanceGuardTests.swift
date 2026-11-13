import Foundation
import Testing

@testable import MaccarKit

@Suite("Single Instance Guard Tests", .serialized)
struct SingleInstanceGuardTests {
    private static let lockFileName = "instance.lock"

    private func makeIsolatedDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("maccar-guard-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeGuard(in directory: URL) -> SingleInstanceGuard {
        SingleInstanceGuard(directory: directory, fileName: Self.lockFileName)
    }

    @Test("acquire() succeeds on a fresh directory and creates the lock file")
    func acquireSucceedsOnFreshPath() {
        let directory = makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let guardInstance = makeGuard(in: directory)
        defer { guardInstance.release() }

        #expect(guardInstance.acquire() == true)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.lockFileName).path))
    }

    @Test("A second guard on the same path is refused while the first holds the lock")
    func secondGuardIsRefused() {
        let directory = makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = makeGuard(in: directory)
        defer { first.release() }
        #expect(first.acquire() == true)

        let second = makeGuard(in: directory)
        defer { second.release() }
        #expect(second.acquire() == false)
    }

    @Test("Releasing the first guard lets a third guard acquire")
    func releaseFreesTheLock() {
        let directory = makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = makeGuard(in: directory)
        #expect(first.acquire() == true)
        first.release()

        let third = makeGuard(in: directory)
        defer { third.release() }
        #expect(third.acquire() == true)
    }

    @Test("Acquiring twice on one instance is idempotent and still blocks another instance")
    func doubleAcquireIsIdempotent() {
        let directory = makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = makeGuard(in: directory)
        defer { first.release() }
        #expect(first.acquire() == true)
        #expect(first.acquire() == true)

        let second = makeGuard(in: directory)
        defer { second.release() }
        #expect(second.acquire() == false)

        first.release()
        #expect(second.acquire() == true)
    }

    @Test("release() without acquire does not crash and does not throw")
    func releaseWithoutAcquireIsSafe() {
        let directory = makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let guardInstance = makeGuard(in: directory)
        guardInstance.release()
        guardInstance.release()

        // The directory was never created by a no-op release path, so a real
        // acquire afterwards must still work.
        defer { guardInstance.release() }
        #expect(guardInstance.acquire() == true)
    }

    @Test("makeApplicationGuard() produces a usable guard")
    func applicationGuardFactoryProducesGuard() {
        let guardInstance = SingleInstanceGuard.makeApplicationGuard()
        #expect(guardInstance.lockFilePath.contains("Maccar"))
    }
}
