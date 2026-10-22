/// One snapshot drives the mode items, status icon, Dock badge and controls.
struct CameraPresentation {
    /// The checked mode: where the camera is or is going.
    let mode: GazeMode
    /// The mode the status icon shows; it changes only once a transition completes.
    let iconMode: GazeMode
    let status: String
    let canSwitch: Bool
    let dockBadge: String

    init(state: CameraLifecycle.State, correcting: Bool, closing: Bool = false) {
        let effective: CameraLifecycle.State = closing ? .stopping : state
        let running: GazeMode = correcting ? .lockedGaze : .passThrough
        canSwitch = effective == .idle || effective == .active
        switch effective {
        case .idle: mode = .off; iconMode = .off; status = "Off"; dockBadge = "Off"
        case .starting: mode = running; iconMode = .off; status = "Starting…"; dockBadge = "…"
        case .active: mode = running; iconMode = running; status = running.title; dockBadge = correcting ? "On" : "Pass"
        case .stopping: mode = .off; iconMode = .off; status = "Stopping…"; dockBadge = "…"
        }
    }
}
