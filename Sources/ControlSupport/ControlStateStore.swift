import Foundation

/// A small, atomically replaced snapshot shared by the app and its control.
/// Unlike a cached preferences value, a read observes the last completed write
/// before WidgetKit was asked to reload. The host remains the only writer.
struct ControlStateStore {
    let url: URL

    private struct Snapshot: Codable {
        let active: Bool
        let processID: Int32
    }

    func publish(active: Bool, processID: Int32) throws {
        let data = try JSONEncoder().encode(Snapshot(active: active, processID: processID))
        try data.write(to: url, options: .atomic)
    }

    func isActive(hostIsRunning: (Int32) -> Bool) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.active else { return false }
        return hostIsRunning(snapshot.processID)
    }
}
