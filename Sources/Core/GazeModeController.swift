/// Maps the three modes onto the camera lifecycle. Off stops the camera; Pass-through
/// and Locked Gaze share one running session and switch by flipping correction only.
@MainActor
final class GazeModeController {
    private let lifecycle: CameraLifecycle
    private let applyCorrection: (Bool) -> Void
    /// Correction for the running or starting session; kept while the camera is off.
    private(set) var correcting = true
    var onChange: (() -> Void)?

    init(lifecycle: CameraLifecycle, applyCorrection: @escaping (Bool) -> Void) {
        self.lifecycle = lifecycle
        self.applyCorrection = applyCorrection
        applyCorrection(correcting)
    }

    /// The mode the camera is in or is moving to.
    var target: GazeMode {
        switch lifecycle.state {
        case .idle, .stopping: .off
        case .starting, .active: correcting ? .lockedGaze : .passThrough
        }
    }

    func set(_ mode: GazeMode) async throws {
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
