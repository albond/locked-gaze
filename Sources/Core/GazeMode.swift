/// What the Locked Gaze camera sends: nothing, the original camera, or the corrected view.
enum GazeMode: String, CaseIterable, Codable, Sendable {
    case off, passThrough, lockedGaze

    var title: String {
        switch self {
        case .off: "Off"
        case .passThrough: "Pass-through"
        case .lockedGaze: "Locked Gaze"
        }
    }
}
