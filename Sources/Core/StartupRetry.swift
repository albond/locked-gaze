import Foundation

enum CameraConnectionError: LocalizedError {
    case notReady
    var errorDescription: String? {
        "macOS has not connected the virtual camera yet. Wait a moment and choose the mode again."
    }
}

/// Retry only device discovery, never permission, model, or arbitrary I/O errors.
/// The deadline also counts slow attempts, so a stalled Core Media I/O system cannot
/// keep activation waiting for minutes.
@MainActor
enum StartupRetry {
    static func run(attempts: Int = 41, deadline: TimeInterval = 10,
                    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                    delay: () async throws -> Void = { try await Task.sleep(nanoseconds: 250_000_000) },
                    connect: () async throws -> Void) async throws {
        precondition(attempts > 0)
        let start = now()
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            do { try await connect(); return }
            catch is CameraConnectionError {
                guard attempt + 1 < attempts, now() - start < deadline else { throw CameraConnectionError.notReady }
                try await delay()
            }
        }
    }
}
