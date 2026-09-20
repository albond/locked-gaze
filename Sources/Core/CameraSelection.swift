import Foundation

struct CameraChoice: Equatable {
    let id: String
    let name: String
    let connected: Bool
}

enum CameraSelection {
    static func available(_ cameras: [CameraChoice], virtualID: String) -> [CameraChoice] {
        var seen = Set<String>()
        return cameras.filter { $0.connected && $0.id != virtualID && $0.name != "Locked Gaze" && seen.insert($0.id).inserted }
    }
    static func select(_ cameras: [CameraChoice], requested: String?, preferred: [String]) throws -> String {
        if let requested {
            guard cameras.contains(where: { $0.id == requested }) else {
                throw GazeError.message("The selected camera is unavailable. Reconnect it or choose another source camera.")
            }
            return requested
        }
        for id in preferred where cameras.contains(where: { $0.id == id }) { return id }
        guard let first = cameras.first else { throw GazeError.message("Connect a webcam or an iPhone using Continuity Camera.") }
        return first.id
    }
}
