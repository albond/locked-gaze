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
        print("PASS: immediate/delayed discovery, bounded timeout, fatal errors, cancellation during/before wait")
    }
}
