import AppIntents
import AppKit
import WidgetKit
import OSLog

// Shared between host and WidgetKit extension. Only the host changes camera state.
enum GazeControlState {
    /// The Locked Gaze control keeps the 1.0.x kind, so controls added earlier still work.
    static let kind = "local.lockedgaze.app.eye-contact"
    static let passThroughKind = "local.lockedgaze.app.mode.pass-through"
    static let offKind = "local.lockedgaze.app.mode.off"
    static let widgetKind = "local.lockedgaze.app.mode-widget"
    static let panelKind = "local.lockedgaze.app.mode-panel"
    private static var store: ControlStateStore? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "LGAppGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return ControlStateStore(url: container.appendingPathComponent("camera-control-state.json"))
    }
    /// Off unless the publishing host process is still running.
    static var mode: GazeMode {
        store?.mode { pid in
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "local.lockedgaze.app"
        } ?? .off
    }
    /// True once a host since 1.0.1 has launched on this Mac; read it before the first publish.
    static var hasPublishedState: Bool {
        store.map { FileManager.default.fileExists(atPath: $0.url.path) } ?? false
    }
    @MainActor static var setMode: ((GazeMode) async throws -> Void)?
    @MainActor static var showPanel: (() -> Void)?
    @MainActor static func publish(_ mode: GazeMode) {
        do {
            guard let store else { throw CocoaError(.fileNoSuchFile) }
            try store.publish(mode: mode, processID: ProcessInfo.processInfo.processIdentifier)
        } catch {
            Logger(subsystem: "local.lockedgaze.app", category: "ControlState").error("Cannot publish camera control state: \(error.localizedDescription, privacy: .public)")
        }
        reload()
    }
    static func reload() {
        if #available(macOS 26.0, *) { ControlCenter.shared.reloadAllControls() }
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }
    /// Turning a mode on selects it; turning the current one off switches Locked Gaze off.
    @MainActor static func select(_ mode: GazeMode, on: Bool) async throws {
        guard let setMode else { throw ControlError.hostUnavailable }
        try await setMode(on ? mode : .off)
    }
    enum ControlError: LocalizedError {
        case hostUnavailable
        var errorDescription: String? { "Open Locked Gaze and try again." }
    }
}

enum GazeModeOption: String, AppEnum {
    case off, passThrough, lockedGaze
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Mode"
    static var caseDisplayRepresentations: [GazeModeOption: DisplayRepresentation] = [
        .off: "Off", .passThrough: "Pass-through", .lockedGaze: "Locked Gaze"
    ]
    init(_ mode: GazeMode) { self = GazeModeOption(rawValue: mode.rawValue) ?? .off }
    var mode: GazeMode { GazeMode(rawValue: rawValue) ?? .off }
}

/// Desktop widget buttons. The host app owns the camera, so the intent runs there.
struct SelectGazeModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Choose Locked Gaze Mode"
    static var description = IntentDescription("Switch Locked Gaze off, to pass-through, or to eye contact correction on this Mac.")
    static var openAppWhenRun = true
    @Parameter(title: "Mode") var mode: GazeModeOption

    init() {}
    init(mode: GazeMode) { self.mode = GazeModeOption(mode) }

    @MainActor func perform() async throws -> some IntentResult {
        try await GazeControlState.select(mode.mode, on: true)
        return .result()
    }
}

// Control Center toggles. Each carries only its Bool value: Control Center cannot turn
// a toggle action with extra parameters into a link action (CHSErrorDomain 1107).
@available(macOS 26.0, *)
struct SetLockedGazeIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Set Locked Gaze"
    static var description = IntentDescription("Turn eye contact correction on, or switch Locked Gaze off.")
    static var supportedModes: IntentModes { .foreground }
    @Parameter(title: "Locked Gaze") var value: Bool
    @MainActor func perform() async throws -> some IntentResult {
        try await GazeControlState.select(.lockedGaze, on: value)
        return .result()
    }
}

@available(macOS 26.0, *)
struct SetPassThroughIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Set Pass-through"
    static var description = IntentDescription("Send the original camera through Locked Gaze, or switch Locked Gaze off.")
    static var supportedModes: IntentModes { .foreground }
    @Parameter(title: "Pass-through") var value: Bool
    @MainActor func perform() async throws -> some IntentResult {
        try await GazeControlState.select(.passThrough, on: value)
        return .result()
    }
}

@available(macOS 26.0, *)
struct SetGazeOffIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Switch Locked Gaze Off"
    static var description = IntentDescription("Stop the Locked Gaze camera.")
    static var supportedModes: IntentModes { .foreground }
    @Parameter(title: "Off") var value: Bool
    @MainActor func perform() async throws -> some IntentResult {
        try await GazeControlState.select(.off, on: value)
        return .result()
    }
}

/// The Control Center button. Control Center has no three-way control, so the host
/// shows its own panel with the mode switch and source cameras.
@available(macOS 26.0, *)
struct ShowModePanelIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Locked Gaze Mode and Camera"
    static var description = IntentDescription("Open a panel to switch the Locked Gaze mode and choose the source camera.")
    static var supportedModes: IntentModes { .foreground }
    @MainActor func perform() async throws -> some IntentResult {
        guard let showPanel = GazeControlState.showPanel else { throw GazeControlState.ControlError.hostUnavailable }
        showPanel()
        return .result()
    }
}
