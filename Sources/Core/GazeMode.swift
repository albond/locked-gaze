/// What Locked Gaze sends: nothing, the original camera or the corrected view through the
/// virtual camera, or the corrected view to browsers only (for Macs whose device management
/// blocks the virtual camera).
enum GazeMode: String, CaseIterable, Codable, Sendable {
    case off, passThrough, lockedGaze, browser

    var title: String {
        switch self {
        case .off: "Off"
        case .passThrough: "Pass-through"
        case .lockedGaze: "Locked Gaze"
        case .browser: "Browser"
        }
    }
    /// Pass-through and Locked Gaze need the virtual camera; Off and Browser do not.
    var usesVirtualCamera: Bool { self == .passThrough || self == .lockedGaze }
}
