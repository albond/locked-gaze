import AppIntents
import SwiftUI
import WidgetKit

@main
struct LockedGazeControls: WidgetBundle {
    var body: some Widget {
        ModeWidget()
        if #available(macOS 26.0, *) {
            ModePanelControl()
            LockedGazeControl()
            PassThroughControl()
            OffControl()
        }
    }
}

/// The large control: the current mode, and a panel with the mode switch and source cameras.
@available(macOS 26.0, *)
struct ModePanelControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        // Starts wide, like the other panel buttons in Control Center; people can still resize
        // it. WidgetKit has this API without publishing it (scripts/widgetkit-spi.swiftinterface),
        // so older systems take the plain branch and never load the symbol.
        if #available(macOS 26.5, *) {
            return configuration.preferredControlSize(.medium)
        } else {
            return configuration
        }
    }

    private var configuration: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: GazeControlState.panelKind, provider: Provider()) { mode in
            ControlWidgetButton(action: ShowModePanelIntent()) {
                // The chevron says the button opens a panel, as Control Center modules do.
                // Control Center drops images inside text, so it is a character.
                Label {
                    Text("Locked Gaze \u{203A}")
                    Text(mode == .lockedGaze ? "On" : mode.title)
                } icon: {
                    Image(systemName: ModeControl.symbol(mode, on: mode != .off))
                }
            }
            .tint(ModeControl.tint(mode))
        }
        .displayName("Mode and Camera")
        .description("Open a panel to switch the mode and choose the source camera.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: GazeMode { .lockedGaze }
        func currentValue() async throws -> GazeMode { GazeControlState.mode }
    }
}

/// One Control Center toggle per mode. The lit one is the current mode; side by side
/// they work as a three-position switch, in any size Control Center offers.
@available(macOS 26.0, *)
struct LockedGazeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        ModeControl.configuration(kind: GazeControlState.kind, mode: .lockedGaze, action: SetLockedGazeIntent())
            .displayName("Locked Gaze")
            .description("Correct eye contact. Add Pass-through and Off next to it for a three-way switch.")
    }
}

@available(macOS 26.0, *)
struct PassThroughControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        ModeControl.configuration(kind: GazeControlState.passThroughKind, mode: .passThrough, action: SetPassThroughIntent())
            .displayName("Pass-through")
            .description("Send your original camera through the Locked Gaze camera.")
    }
}

@available(macOS 26.0, *)
struct OffControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        ModeControl.configuration(kind: GazeControlState.offKind, mode: .off, action: SetGazeOffIntent())
            .displayName("Locked Gaze Off")
            .description("Stop the Locked Gaze camera.")
    }
}

@available(macOS 26.0, *)
enum ModeControl {
    static func configuration<Action: SetValueIntent>(kind: String, mode: GazeMode, action: Action) -> some ControlWidgetConfiguration
    where Action.ValueType == Bool {
        StaticControlConfiguration(kind: kind, provider: Provider(mode: mode)) { selected in
            ControlWidgetToggle(mode.title, isOn: selected, action: action) { isOn in
                Label(isOn ? "On" : "Off", systemImage: symbol(mode, on: isOn))
            }
            .tint(tint(mode))
        }
    }

    struct Provider: ControlValueProvider {
        let mode: GazeMode
        var previewValue: Bool { mode == .lockedGaze }
        func currentValue() async throws -> Bool { GazeControlState.mode == mode }
    }

    static func symbol(_ mode: GazeMode, on: Bool) -> String {
        switch mode {
        case .off: on ? "eye.slash.fill" : "eye.slash"
        case .passThrough: on ? "video.fill" : "video"
        case .lockedGaze: on ? "eye.fill" : "eye"
        }
    }
    /// The widget's knob colour, so the three cells read as one switch.
    static func tint(_ mode: GazeMode) -> Color { Color(red: 0xF7 / 255, green: 0xA9 / 255, blue: 0x82 / 255) }
}
