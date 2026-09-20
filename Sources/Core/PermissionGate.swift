import Foundation

/// The probe is authoritative, including after a system prompt or Settings.
@MainActor
enum PermissionGate {
    enum Status { case authorized, notDetermined, denied, restricted }
    static func ensure(probe: () -> Status, request: () async -> Void,
                       prompt: (Status) async -> Bool) async throws {
        var requested = false
        while true {
            try Task.checkCancellation()
            switch probe() {
            case .authorized: return
            case .notDetermined where !requested:
                requested = true
                await request()
            case let status:
                guard await prompt(status) else { throw CancellationError() }
            }
        }
    }
}
