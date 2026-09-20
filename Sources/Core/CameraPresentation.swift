/// One snapshot drives the menu command, status icon, Dock badge and control.
struct CameraPresentation {
    let actionTitle: String
    let status: String
    let active: Bool
    let canToggle: Bool
    let dockBadge: String

    init(state: CameraLifecycle.State, closing: Bool = false) {
        let effective: CameraLifecycle.State = closing ? .stopping : state
        active = effective == .active
        canToggle = effective == .idle || effective == .active
        switch effective {
        case .idle: actionTitle = "Activate"; status = "Inactive"; dockBadge = "Off"
        case .starting: actionTitle = "Starting…"; status = "Starting…"; dockBadge = "…"
        case .active: actionTitle = "Deactivate"; status = "Active"; dockBadge = "On"
        case .stopping: actionTitle = "Stopping…"; status = "Stopping…"; dockBadge = "…"
        }
    }
}
