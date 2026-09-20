import Foundation

enum CameraConnectionError: LocalizedError {
    case notReady
    var errorDescription: String? {
        "macOS has not connected the virtual camera yet. Wait a moment and activate again."
    }
}

/// Retry only device discovery, never permission, model, or arbitrary I/O errors.
@MainActor
enum StartupRetry {
    static func run(attempts: Int = 41,
                    delay: () async throws -> Void = { try await Task.sleep(nanoseconds: 250_000_000) },
                    connect: () async throws -> Void) async throws {
        precondition(attempts > 0)
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            do { try await connect(); return }
            catch is CameraConnectionError {
                guard attempt + 1 < attempts else { throw CameraConnectionError.notReady }
                try await delay()
            }
        }
    }
}
