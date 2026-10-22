import Foundation

@main struct StartupRetryTests {
    @MainActor static func main() async throws {
        var calls = 0, delays = 0
        try await StartupRetry.run(delay: { delays += 1 }) { calls += 1 }
        precondition(calls == 1 && delays == 0)
        calls = 0
        try await StartupRetry.run(attempts: 4, delay: { delays += 1 }) {
            calls += 1
            if calls < 4 { throw CameraConnectionError.notReady }
        }
        precondition(calls == 4 && delays == 3, "Delayed discovery must recover without a permission prompt")
        calls = 0; delays = 0
        do {
            try await StartupRetry.run(attempts: 3, delay: { delays += 1 }) { calls += 1; throw CameraConnectionError.notReady }
            preconditionFailure("Must time out")
        } catch is CameraConnectionError {}
        precondition(calls == 3 && delays == 2)
        // Each attempt may itself wait for the service; the whole discovery still ends near the deadline.
        var clock: TimeInterval = 0
        calls = 0
        do {
            try await StartupRetry.run(deadline: 10, now: { clock }, delay: {}) {
                calls += 1; clock += 4; throw CameraConnectionError.notReady
            }
            preconditionFailure("Slow attempts must still time out")
        } catch is CameraConnectionError {}
        precondition(calls == 3, "Three 4 s attempts pass the 10 s deadline")
        calls = 0; delays = 0
        calls = 0; delays = 0
        do {
            try await StartupRetry.run(delay: { delays += 1 }) { calls += 1; throw GazeError.message("Authorization failed") }
            preconditionFailure()
        } catch { precondition(error.localizedDescription == "Authorization failed") }
        precondition(calls == 1 && delays == 0, "Do not hide unrelated failures")
        calls = 0
        do {
            try await StartupRetry.run(delay: { throw CancellationError() }) { calls += 1; throw CameraConnectionError.notReady }
            preconditionFailure()
        } catch is CancellationError {}
        precondition(calls == 1)
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await StartupRetry.run { preconditionFailure("Connected after cancellation") }
        }
        do { try await cancelled.value; preconditionFailure() } catch is CancellationError {}
        let window = CameraContract.publisherDiscoveryWindow
        var result = await firstActivation(window: 0, device: 0.8)
        precondition(result == (true, 10, 2), "One attempt per process waits out the launchd throttle")
        result = await firstActivation(window: window, device: 0.8)
        precondition(result == (true, 1, 1), "The first publisher process must wait for the new device")
        result = await firstActivation(window: window, device: 0.8, seenByFirstProcess: false)
        precondition(result == (true, 10, 2), "A process that never sees the device is still replaced before the deadline")
        result = await firstActivation(window: window, device: nil)
        precondition(!result.connected && result.elapsed <= 10 + window, "A missing device still fails in bounded time")
        print("PASS: immediate/delayed discovery, bounded attempts and deadline, fatal errors, cancellation during/before wait, publisher-side discovery before the launchd throttle")
    }

    /// First activation after a camera extension appears, as in the 2026-10-19 log: the
    /// publisher starts 0.8 s before the device, and launchd defers a relaunch until 10 s
    /// after the previous launch. The host and each publisher process retry as in production.
    @MainActor static func firstActivation(window: TimeInterval, device: TimeInterval?,
                                           seenByFirstProcess: Bool = true) async -> (connected: Bool, elapsed: TimeInterval, processes: Int) {
        var clock: TimeInterval = 0, launched = -TimeInterval.infinity, processes = 0
        do {
            try await StartupRetry.run(now: { clock }, delay: { clock += 0.25 }) {
                clock = max(clock, launched + 10); launched = clock; processes += 1
                let process = processes
                try await StartupRetry.run(deadline: window, now: { clock }, delay: { clock += 0.25 }) {
                    guard let device, clock >= device, seenByFirstProcess || process > 1 else { throw CameraConnectionError.notReady }
                }
            }
            return (true, clock, processes)
        } catch {
            precondition(error is CameraConnectionError)
            return (false, clock, processes)
        }
    }
}
