import SwiftUI
import WidgetKit

@main
struct LockedGazeControls: WidgetBundle {
    var body: some Widget { EyeContactControl() }
}

struct EyeContactControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: GazeControlState.kind, provider: Provider()) { enabled in
            ControlWidgetToggle("Eye Contact", isOn: enabled, action: SetGazeEnabledIntent()) { active in
                Label(active ? "Active" : "Inactive", systemImage: active ? "eye.fill" : "eye")
            }.tint(.cyan)
        }
        .displayName("Locked Gaze")
        .description("Turn on-device eye contact correction on or off.")
    }
    struct Provider: ControlValueProvider {
        var previewValue: Bool { false }
        func currentValue() async throws -> Bool { GazeControlState.isActive }
    }
}
