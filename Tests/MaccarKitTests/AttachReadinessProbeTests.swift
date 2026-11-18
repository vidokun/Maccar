import Foundation
import Testing
@testable import MaccarKit

/// The probe is research instrumentation, so its own logic needs to be trustworthy: a probe that
/// records the wrong offsets or keeps running after it is cancelled would produce evidence that
/// looks authoritative and is not.
@Suite("Attach Readiness Probe Tests", .serialized)
struct AttachReadinessProbeTests {

    /// Collects log lines; the probe posts from several queues.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
        func contains(_ needle: String) -> Bool { all.contains { $0.contains(needle) } }
    }

    private func makeProbe(
        sidecar: MockSidecarService,
        log: Log,
        clock: ManualTestClock
    ) -> AttachReadinessProbe {
        AttachReadinessProbe(
            sidecar: sidecar,
            log: { log.append($0) },
            // No real sleeping: offsets collapse to zero and the assertions stay about order.
            sleep: { _ in },
            now: { clock.now().timeIntervalSince1970 }
        )
    }

    /// Waits for a log line instead of sleeping a fixed amount.
    ///
    /// A fixed 300 ms passed locally and failed on a GitHub runner: the probe posts its results
    /// from `DispatchQueue.global`, so completion depends on scheduling, not on elapsed time. CI
    /// caught this on the v1.5.0 release, which is exactly what a release gate is for — a timing
    /// assertion that only holds on a fast machine is a false pass, not a test.
    private func waitFor(
        _ needle: String,
        in log: Log,
        timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if log.contains(needle) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return log.contains(needle)
    }

    @Test("No registered iPad means no probing and no connect")
    func missingTargetSkipsProbe() {
        let sidecar = MockSidecarService()
        let log = Log()
        let probe = makeProbe(sidecar: sidecar, log: log, clock: ManualTestClock())

        probe.begin(deviceName: nil)

        #expect(log.contains("skipped: no registered iPad"))
        #expect(sidecar.connectCalls.isEmpty, "a probe must never connect without a target")
    }

    @Test("A probe issues exactly one connect per configured offset")
    func probeConnectsPerOffset() async throws {
        let sidecar = MockSidecarService()
        let log = Log()
        let probe = makeProbe(sidecar: sidecar, log: log, clock: ManualTestClock())

        probe.begin(deviceName: "VPad", probeOffsets: [0, 0, 0])
        _ = await waitFor("RESULT: first successful offset", in: log)

        #expect(sidecar.connectCalls.count == 3,
                "one attempt per offset; got \(sidecar.connectCalls.count)")
        #expect(sidecar.connectCalls.allSatisfy { $0.wired }, "Maccar only ever asks for wired")
    }

    @Test("A successful probe records the offset that worked")
    func successIsRecorded() async throws {
        let sidecar = MockSidecarService()
        let log = Log()
        let probe = makeProbe(sidecar: sidecar, log: log, clock: ManualTestClock())

        probe.begin(deviceName: "VPad", probeOffsets: [1.2])
        let recorded = await waitFor("probe connect SUCCESS", in: log)

        #expect(recorded, "the probe must report a successful connect")
        #expect(log.contains("RESULT: first successful offset"))
    }

    @Test("A failed probe records the error and does not claim success")
    func failureIsRecorded() async throws {
        let sidecar = MockSidecarService()
        sidecar.connectError = NSError(domain: "test", code: -101)
        let log = Log()
        let probe = makeProbe(sidecar: sidecar, log: log, clock: ManualTestClock())

        probe.begin(deviceName: "VPad", probeOffsets: [1.0])
        let recorded = await waitFor("probe connect failed", in: log)

        #expect(recorded, "a failed connect must be logged; got \(log.all)")
        #expect(!log.contains("SUCCESS"), "a failed attempt must not be reported as success")
    }

    @Test("end() cancels pending attempts so a cancelled run cannot connect later")
    func endCancelsPendingProbes() async throws {
        let sidecar = MockSidecarService()
        let log = Log()
        let probe = makeProbe(sidecar: sidecar, log: log, clock: ManualTestClock())

        probe.begin(deviceName: "VPad", probeOffsets: [5.0])
        probe.end()
        // The offset never elapses because sleep returns immediately, but the run id was bumped,
        // so the pending attempt must have bailed before connecting. Wait for the probe's own
        // "ended" line rather than guessing at a delay.
        _ = await waitFor("ended", in: log)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(sidecar.connectCalls.isEmpty, "a cancelled run must not connect")
    }

    @Test("The default offsets straddle the boundary the codebase already measured")
    func defaultOffsetsMatchKnownEvidence() {
        let offsets = AttachReadinessProbe.defaultProbeOffsets
        #expect(offsets.contains { $0 < 1.9 }, "must probe below the known 1.9 s failure")
        #expect(offsets.contains { $0 > 1.9 }, "must probe above it to find where it flips")
        #expect(offsets == offsets.sorted(), "offsets are probed in ascending order")
    }
}
