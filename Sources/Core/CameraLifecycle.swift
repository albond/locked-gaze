import Foundation

/// Serializes menu/Control Center requests and waits for cleanup before restart.
@MainActor
final class CameraLifecycle {
    enum State { case idle, starting, active, stopping }
    private(set) var state: State = .idle { didSet { onChange?() } }
    private(set) var closing = false
    var onChange: (() -> Void)?
    private let prepare: () async throws -> Void
    private let start: () async throws -> Void
    private let stop: () async -> Void
    private var transition: Task<Void, Error>?
    private var startupFailure: Error?
    private var operation = 0

    init(prepare: @escaping () async throws -> Void, start: @escaping () async throws -> Void,
         stop: @escaping () async -> Void) {
        self.prepare = prepare; self.start = start; self.stop = stop
    }
    func setEnabled(_ enabled: Bool) async throws {
        guard !closing else { throw GazeError.message("Locked Gaze is closing.") }
        if (enabled && state == .active) || (!enabled && state == .idle) { return }
        try await change(to: enabled ? .starting : .stopping)
    }
    /// Restarts an active session in place, e.g. after the source camera changes.
    /// Observers see `starting`, never `idle`, so indicators stay enabled.
    func restart() async throws {
        guard !closing else { throw GazeError.message("Locked Gaze is closing.") }
        guard state == .active else { return }
        try await change(to: .starting, restarting: true)
    }
    private func change(to next: State, restarting: Bool = false) async throws {
        guard state == .idle || state == .active else { throw GazeError.message("The camera is changing state. Try again in a moment.") }
        operation += 1
        let token = operation
        state = next
        startupFailure = nil
        let job = Task { @MainActor in
            if next == .stopping { await stop(); state = .idle; return }
            do {
                if restarting { await stop() }
                try await prepare()
                try Task.checkCancellation()
                try await start()
                if let startupFailure { throw startupFailure }
                try Task.checkCancellation()
                state = .active
            } catch {
                await stop()
                state = .idle
                throw startupFailure ?? error
            }
        }
        transition = job
        defer { if operation == token { transition = nil } }
        try await job.value
    }
    /// Returns true only when the active session was stopped by this failure.
    func failed(_ error: Error) async -> Bool {
        if state == .starting { startupFailure = startupFailure ?? error; return false }
        guard state == .active && !closing else { return false }
        try? await setEnabled(false)
        return true
    }
    func shutdown() async {
        closing = true
        transition?.cancel()
        if let transition { _ = await transition.result }
        if state == .active { state = .stopping; await stop() }
        state = .idle
    }
}
