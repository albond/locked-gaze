import Foundation

/// Optional softer correction: most of the way to the camera, with brief glances away.
enum NaturalGaze {
    static let defaultsKey = "naturalGaze"
    /// Share of the gaze offset that is corrected while Natural Gaze is on.
    static let strength = 0.8
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
    static func strength(enabled: Bool) -> Double { enabled ? strength : 1 }
}
