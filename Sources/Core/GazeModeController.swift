/// Maps the modes onto the camera lifecycle. Off stops the camera; Pass-through
/// and Locked Gaze share one running session and switch by flipping correction only.
/// Browser keeps the virtual camera session stopped: the browser starts its own session
/// on demand while a site holds the Locked Gaze camera.
@MainActor
final class GazeModeController {
    private let lifecycle: CameraLifecycle
    private let applyCorrection: (Bool) -> Void
    /// Correction for the running or starting session; kept while the camera is off.
    private(set) var correcting = true
    /// Browser mode: the lifecycle stays idle and browsers get corrected frames on demand.
    private(set) var browsing = false
    var onChange: (() -> Void)?

    init(lifecycle: CameraLifecycle, applyCorrection: @escaping (Bool) -> Void) {
        self.lifecycle = lifecycle
        self.applyCorrection = applyCorrection
        applyCorrection(correcting)
    }

    /// The mode the camera is in or is moving to.
    var target: GazeMode {
        switch lifecycle.state {
        case .idle, .stopping: browsing ? .browser : .off
        case .starting, .active: correcting ? .lockedGaze : .passThrough
        }
    }

    func set(_ mode: GazeMode) async throws {
        if mode == .browser {
            switch lifecycle.state {
            case .idle: break
            case .active: try await lifecycle.setEnabled(false)
            case .starting, .stopping: throw GazeError.message("The camera is changing state. Try again in a moment.")
            }
            if !browsing { browsing = true; onChange?() }
            return
        }
        if browsing { browsing = false; onChange?() }
        guard mode != .off else { return try await lifecycle.setEnabled(false) }
        guard lifecycle.state != .stopping else { throw GazeError.message("The camera is changing state. Try again in a moment.") }
        let correcting = mode == .lockedGaze
        if correcting != self.correcting {
            self.correcting = correcting
            applyCorrection(correcting)
            onChange?()
        }
        // A starting session picks up the new correction when its first frame arrives.
        if lifecycle.state == .idle { try await lifecycle.setEnabled(true) }
    }
}
