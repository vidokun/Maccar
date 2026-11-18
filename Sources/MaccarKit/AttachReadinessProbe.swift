import Foundation

/// Research probe: when does Sidecar actually become connectable after a USB attach?
///
/// This exists to settle one question with measurements instead of guesses. The connect path
/// currently waits a fixed `usbAttachSettleSeconds` (4 s) after attach, which in the field reads as
/// a 15–20 s recovery because a failed attempt costs `transientRetrySeconds` on top. The hypothesis
/// is that a *signal* from Sidecar would let the first attempt start sooner — without adding
/// popups, which every failed `connect()` raises.
///
/// What this probe does **not** do: change any production behaviour. It is opt-in, records to the
/// log only, and every entry it writes is prefixed `[AttachProbe]` so it can be filtered out.
///
/// Measurements per attach, relative to the attach timestamp:
///   - every `SidecarDevicesChangedNotification` / `ConnectedDevicesChanged` Sidecar emits
///   - when `reachableDevices()` and `connectedDevices()` start reporting the iPad
///   - the outcome of probe `connect()` attempts at chosen offsets
///
/// Reading the result: if a signal consistently precedes a successful connect, that signal is a
/// candidate readiness trigger. If connects fail regardless of offset, the fixed settle time is
/// hiding something other than readiness and no timer tuning will help.
public final class AttachReadinessProbe: @unchecked Sendable {

    /// Offsets after the attach at which to attempt a connect, in seconds.
    ///
    /// Chosen around the evidence already in the codebase: attempts at 0.8 s and 1.9 s failed on
    /// hardware, while one at 6.5 s succeeded. 1.2 / 3.0 / 5.0 straddle that boundary so the probe
    /// finds where it actually flips rather than repeating a known failure.
    public static let defaultProbeOffsets: [TimeInterval] = [1.2, 3.0, 5.0]

    /// How long to keep recording signals after an attach.
    public static let observationWindow: TimeInterval = 30

    private let sidecar: any SidecarControlling
    private let log: @Sendable (String) -> Void
    private let sleep: @Sendable (TimeInterval) -> Void
    private let now: @Sendable () -> TimeInterval

    private let lock = NSLock()
    private var runID: UInt64 = 0
    private var observerToken: SidecarObserverToken?

    public init(
        sidecar: any SidecarControlling,
        log: @escaping @Sendable (String) -> Void,
        sleep: @escaping @Sendable (TimeInterval) -> Void,
        now: @escaping @Sendable () -> TimeInterval
    ) {
        self.sidecar = sidecar
        self.log = log
        self.sleep = sleep
        self.now = now
    }

    public convenience init(sidecar: any SidecarControlling) {
        self.init(
            sidecar: sidecar,
            log: { MaccarLogger.shared.info("AttachProbe", $0) },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            now: { ProcessInfo.processInfo.systemUptime }
        )
    }

    /// Starts recording for one attach. Repeat calls supersede the previous run.
    ///
    /// - Parameter target: the device name to probe. Probes issue real `connect()` calls, so a
    ///   missing name means nothing to probe and the run is skipped rather than guessed.
    public func begin(deviceName target: String?, probeOffsets: [TimeInterval] = AttachReadinessProbe.defaultProbeOffsets) {
        guard let target, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log("skipped: no registered iPad to probe")
            return
        }

        let start = now()
        let startWallClock = Date()
        let id = lock.withLock { () -> UInt64 in
            runID &+= 1
            return runID
        }
        log("t0=0.000 attach observed; probing '\(target)' at \(probeOffsets.map { String(format: "%.1f", $0) }.joined(separator: "/"))s")

        stopObserving()
        let token = sidecar.startObservingNotifications { [weak self] name in
            guard let self else { return }
            let elapsed = self.now() - start
            // Runs on Sidecar's posting queue; the log is the only shared state and is thread-safe.
            self.log(String(format: "t0=%.3f notification %@", elapsed, name))
        }
        lock.withLock { observerToken = token }

        // State snapshots, interleaved with the connect probes.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var elapsed: TimeInterval = 0
            let step: TimeInterval = 0.5
            while elapsed < Self.observationWindow {
                self.sleep(step)
                elapsed = self.now() - start
                if self.isCurrent(id) == false { return }
                // In tests `sleep` is a no-op and the injected clock never advances, so this loop
                // would spin for the full 30 s of real CPU time. The window is measured in wall
                // clock, so stop as soon as the deadline has provably passed either way.
                if Date().timeIntervalSince(startWallClock) >= Self.observationWindow { break }
                let reachable = (try? self.sidecar.reachableDevices()) ?? []
                let connected = self.sidecar.connectedDevices()
                self.log(String(
                    format: "t0=%.3f state reachable=%d connected=%d includesTarget=%@",
                    elapsed, reachable.count, connected.count,
                    reachable.contains { $0.caseInsensitiveCompare(target) == .orderedSame } ? "yes" : "no"
                ))
            }
            self.log(String(format: "t0=%.3f window closed", elapsed))
            self.stopObserving()
        }

        for offset in probeOffsets {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                self.sleep(offset)
                guard self.isCurrent(id) else { return }
                let began = self.now() - start
                self.log(String(format: "t0=%.3f probe connect start", began))
                do {
                    // A real connect: this is what makes the measurement meaningful, and also
                    // what raises an Apple popup when Sidecar is not ready.
                    try self.sidecar.connect(deviceName: target, wired: true)
                    let took = self.now() - start
                    self.log(String(format: "t0=%.3f probe connect SUCCESS", took))
                    self.log("RESULT: first successful offset >= \(String(format: "%.1f", offset))s")
                } catch {
                    let took = self.now() - start
                    self.log(String(format: "t0=%.3f probe connect failed: %@", took, error.localizedDescription))
                }
            }
        }
    }

    /// Stops recording and cancels any pending probe.
    public func end() {
        lock.withLock { runID &+= 1 }
        stopObserving()
        log("ended")
    }

    private func stopObserving() {
        let token: SidecarObserverToken? = lock.withLock {
            let current = observerToken
            observerToken = nil
            return current
        }
        if let token { token.invalidate() }
    }

    private func isCurrent(_ id: UInt64) -> Bool {
        lock.withLock { runID == id }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
