import Foundation

/// A small, atomically replaced snapshot shared by the app and its control.
/// Unlike a cached preferences value, a read observes the last completed write
/// before WidgetKit was asked to reload. The host remains the only writer.
struct ControlStateStore {
    let url: URL

    private struct Snapshot: Codable {
        let mode: GazeMode
        let processID: Int32
        /// Device management blocks the virtual camera; absent in snapshots before 1.2.
        var virtualCameraBlocked: Bool?
    }

    func publish(mode: GazeMode, processID: Int32, virtualCameraBlocked: Bool = false) throws {
        let data = try JSONEncoder().encode(Snapshot(mode: mode, processID: processID, virtualCameraBlocked: virtualCameraBlocked))
        try data.write(to: url, options: .atomic)
    }

    /// Whether the last host found the virtual camera blocked; kept while the host is closed.
    var virtualCameraBlocked: Bool {
        guard let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return false }
        return snapshot.virtualCameraBlocked ?? false
    }

    /// Missing, older or corrupt snapshots and a stopped host all read as Off.
    func mode(hostIsRunning: (Int32) -> Bool) -> GazeMode {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.mode != .off else { return .off }
        return hostIsRunning(snapshot.processID) ? snapshot.mode : .off
    }
}
