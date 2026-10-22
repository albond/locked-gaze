import AppIntents
import SwiftUI
import WidgetKit

struct ModeEntry: TimelineEntry {
    let date: Date
    let mode: GazeMode
}

/// A three-position switch for the desktop and Notification Center. It sits on the system
/// widget background like Apple's widgets; the peach accent marks the title and the knob.
struct ModeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GazeControlState.widgetKind, provider: Provider()) { entry in
            ModeWidgetView(mode: entry.mode)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Locked Gaze")
        .description("Switch between Off, Pass-through and Locked Gaze.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }

    struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> ModeEntry { ModeEntry(date: .now, mode: .lockedGaze) }
        func getSnapshot(in context: Context, completion: @escaping (ModeEntry) -> Void) {
            completion(ModeEntry(date: .now, mode: context.isPreview ? .lockedGaze : GazeControlState.mode))
        }
        // The host reloads this timeline whenever the mode changes.
        func getTimeline(in context: Context, completion: @escaping (Timeline<ModeEntry>) -> Void) {
            completion(Timeline(entries: [ModeEntry(date: .now, mode: GazeControlState.mode)], policy: .never))
        }
    }
}

struct WidgetPalette {
    let dark: Bool
    private func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    /// The peach of the orange AirPods Max, as in the app: a fill with dark symbols on it.
    var accent: Color { hex(0xF7A982) }
    /// The title's accent, deeper on the light background where the peach fill is too pale.
    var accentInk: Color { hex(dark ? 0xF7A982 : 0xE57B4F) }
    var track: Color { dark ? .white.opacity(0.1) : hex(0xFFF0E8) }
    var icon: Color { dark ? .white.opacity(0.7) : hex(0x6B625D) }
    var onKnob: Color { hex(0x1F1D1C) }
}

/// A small accent title, the current mode in large type, and a pill track whose knob sits on
/// that mode, laid out like Apple's widgets.
struct ModeWidgetView: View {
    let mode: GazeMode
    /// Overrides the environment family, for rendering outside WidgetKit.
    var familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var environmentFamily
    @Environment(\.widgetRenderingMode) private var rendering
    @Environment(\.colorScheme) private var scheme
    private var family: WidgetFamily { familyOverride ?? environmentFamily }
    private var small: Bool { family == .systemSmall }
    private var palette: WidgetPalette { WidgetPalette(dark: scheme == .dark) }
    private var fullColor: Bool { rendering == .fullColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "eye.fill")
                Text("Locked Gaze")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(fullColor ? palette.accentInk : .secondary)
            .widgetAccentable()
            .lineLimit(1)
            Text(mode == .lockedGaze ? "On" : mode.title)
                .font(.system(size: small ? 30 : 34, weight: .bold))
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.opacity)
                .padding(.top, 2)
            Spacer(minLength: 8)
            track
        }
    }

    private var track: some View {
        HStack(spacing: 0) {
            ForEach(GazeMode.allCases, id: \.self) { segment($0) }
        }
        .padding(3)
        .background(Capsule().fill(fullColor ? palette.track : Color.primary.opacity(0.14)))
    }

    private func segment(_ option: GazeMode) -> some View {
        let selected = option == mode
        return Button(intent: SelectGazeModeIntent(mode: option)) {
            Image(systemName: Self.symbol(option))
                .font(.system(size: small ? 15 : 18, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: small ? 34 : 40)
                .foregroundStyle(foreground(selected))
                .background { if selected { knob } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var knob: some View {
        switch rendering {
        case .fullColor: Capsule().fill(palette.accent)
        case .accented: Capsule().fill(Color.primary).widgetAccentable()
        default: Capsule().fill(Color.primary.opacity(0.32))
        }
    }

    private func foreground(_ selected: Bool) -> Color {
        if fullColor { return selected ? palette.onKnob.opacity(0.9) : palette.icon }
        if rendering == .accented { return selected ? .white : .primary.opacity(0.8) }
        return selected ? .primary : .primary.opacity(0.65)
    }

    static func symbol(_ mode: GazeMode) -> String {
        switch mode {
        case .off: "eye.slash"
        case .passThrough: "video"
        case .lockedGaze: "eye"
        }
    }
}
