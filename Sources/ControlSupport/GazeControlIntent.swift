import AppIntents
import AppKit
import WidgetKit

// Shared between host and WidgetKit extension. Only the host changes camera state.
enum GazeControlState {
    static let kind = "local.lockedgaze.app.eye-contact"
    static var defaults: UserDefaults? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "LGAppGroup") as? String else { return nil }
        return UserDefaults(suiteName: group)
    }
    static var isActive: Bool {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "local.lockedgaze.app").contains(where: { !$0.isTerminated }) else { return false }
        return defaults?.bool(forKey: "cameraActive") ?? false
    }
    @MainActor static var setActive: ((Bool) async throws -> Void)?
    @MainActor static func publish(_ active: Bool) {
        defaults?.set(active, forKey: "cameraActive")
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
