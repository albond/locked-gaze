import AppIntents
import AppKit
import WidgetKit
import OSLog

// Shared between host and WidgetKit extension. Only the host changes camera state.
enum GazeControlState {
    static let kind = "local.lockedgaze.app.eye-contact"
    private static var store: ControlStateStore? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "LGAppGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return ControlStateStore(url: container.appendingPathComponent("camera-control-state.json"))
    }
    /// Active only while the publishing host process is still running.
    static var isActive: Bool {
        store?.isActive { pid in
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "local.lockedgaze.app"
        } ?? false
    }
    @MainActor static var setActive: ((Bool) async throws -> Void)?
    @MainActor static func publish(_ active: Bool) {
        do {
            guard let store else { throw CocoaError(.fileNoSuchFile) }
            try store.publish(active: active, processID: ProcessInfo.processInfo.processIdentifier)
        } catch {
            Logger(subsystem: "local.lockedgaze.app", category: "ControlState").error("Cannot publish camera control state: \(error.localizedDescription, privacy: .public)")
        }
        reload()
    }
    static func reload() {
        if #available(macOS 26.0, *) { ControlCenter.shared.reloadControls(ofKind: kind) }
    }
}

@available(macOS 26.0, *)
struct SetGazeEnabledIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Set Eye Contact"
    static var description = IntentDescription("Activate or deactivate Locked Gaze on this Mac.")
    static var supportedModes: IntentModes { .foreground }
    @Parameter(title: "Eye Contact Enabled") var value: Bool
    @MainActor func perform() async throws -> some IntentResult {
        // Foreground execution routes this intent to the containing application.
        // The system reloads the control when perform() returns.
        guard let setActive = GazeControlState.setActive else {
            throw ControlError.hostUnavailable
        }
        try await setActive(value)
        return .result()
    }
    enum ControlError: LocalizedError {
        case hostUnavailable
        var errorDescription: String? { "Open Locked Gaze and try again." }
    }
}
