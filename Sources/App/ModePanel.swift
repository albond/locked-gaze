import AppKit
import AVFoundation
import OSLog
import SwiftUI

/// Where the panel sits: below the menu bar at the right edge, where Control Center opens.
enum ModePanelLayout {
    static let width: CGFloat = 300
    static let rightMargin: CGFloat = 10
    static let topGap: CGFloat = 8

    static func origin(for size: NSSize, in visibleFrame: NSRect) -> NSPoint {
        NSPoint(x: visibleFrame.maxX - rightMargin - size.width, y: visibleFrame.maxY - topGap - size.height)
    }
}

struct PanelCamera: Identifiable, Equatable {
    let id: String
    /// The source camera setting this row selects; nil is the system preferred camera.
    let cameraID: String?
    let name: String
    let symbol: String
    let selectable: Bool
    let selected: Bool
}

/// The same choices as the Source Camera menu, as rows with device symbols.
enum PanelCameraList {
    static func rows(cameras: [CameraChoice], symbols: [String: String], selectedID: String?) -> [PanelCamera] {
        var rows = [PanelCamera(id: "automatic", cameraID: nil, name: "Automatic (System Preferred)", symbol: "sparkles",
                                selectable: true, selected: selectedID == nil)]
        rows += cameras.map {
            PanelCamera(id: $0.id, cameraID: $0.id, name: $0.name, symbol: symbols[$0.id] ?? "web.camera",
                        selectable: true, selected: selectedID == $0.id)
        }
        if let selectedID, !cameras.contains(where: { $0.id == selectedID }) {
            rows.append(PanelCamera(id: "unavailable", cameraID: selectedID, name: "Selected Camera Unavailable",
                                    symbol: "video.slash", selectable: false, selected: true))
        }
        if cameras.isEmpty {
            rows.append(PanelCamera(id: "none", cameraID: nil, name: "No Cameras Connected",
                                    symbol: "video.slash", selectable: false, selected: false))
        }
        return rows
    }

    static func symbol(for type: AVCaptureDevice.DeviceType) -> String {
        switch type {
        case .builtInWideAngleCamera: "laptopcomputer"
        case .continuityCamera: "iphone"
        default: "web.camera"
        }
    }
}

@MainActor
final class ModePanelModel: ObservableObject {
    /// The checked mode: where the camera is or is going.
    @Published var mode = GazeMode.off
    @Published var canSwitch = true
    /// Shown next to the title while the camera changes state.
    @Published var transition: String?
    @Published var cameras: [PanelCamera] = []
    var choose: (GazeMode) -> Void = { _ in }
    var select: (String?) -> Void = { _ in }
    /// The content's height, so the panel can follow it smoothly.
    var heightChanged: (CGFloat) -> Void = { _ in }
}

private struct PanelPalette {
    let dark: Bool
    /// The peach of the orange AirPods Max; symbols on it are dark, as white would not read.
    let accent = Color(red: 0xF7 / 255, green: 0xA9 / 255, blue: 0x82 / 255)
    let onAccent = Color(red: 0x1F / 255, green: 0x1D / 255, blue: 0x1C / 255)
    /// Light glass deepens its tint, so a paler peach shows as the same accent on screen.
    var knobTint: Color { dark ? accent : Color(red: 0xFB / 255, green: 0xC6 / 255, blue: 0xAA / 255) }
    var track: Color { dark ? .white.opacity(0.07) : .black.opacity(0.05) }
    var trackLine: Color { dark ? .white.opacity(0.1) : .black.opacity(0.06) }
    var icon: Color { .primary.opacity(0.72) }
    var circle: Color { dark ? .white.opacity(0.12) : .black.opacity(0.08) }
}

struct ModePanelView: View {
    @ObservedObject var model: ModePanelModel
    @AppStorage("modePanelShowsCameras") private var showsCameras = true
    @Environment(\.colorScheme) private var scheme
    private var palette: PanelPalette { PanelPalette(dark: scheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ModeSwitch(model: model, palette: palette)
            if showsCameras { cameraList }
        }
        .padding(12)
        .frame(width: ModePanelLayout.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.heightChanged($0) }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Locked Gaze").font(.system(size: 13, weight: .semibold))
            if let transition = model.transition {
                Text(transition).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                withAnimation(.snappy(duration: 0.3)) { showsCameras.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(showsCameras ? 90 : 0))
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Source Camera")
            .accessibilityLabel(showsCameras ? "Hide Source Cameras" : "Show Source Cameras")
        }
        .padding(.leading, 4)
        .padding(.bottom, 10)
    }

    private var cameraList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.horizontal, 4).padding(.top, 12).padding(.bottom, 8)
            Text("Source Camera")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 4).padding(.bottom, 4)
            ForEach(model.cameras) { row in
                CameraRow(row: row, palette: palette, enabled: model.canSwitch && row.selectable) { model.select(row.cameraID) }
            }
        }
        .transition(.opacity)
    }

    static func symbol(_ mode: GazeMode) -> String {
        switch mode {
        case .off: "eye.slash"
        case .passThrough: "video"
        case .lockedGaze: "eye"
        }
    }
}

/// Three labelled segments; the selected one carries the knob.
private struct ModeSwitch: View {
    @ObservedObject var model: ModePanelModel
    let palette: PanelPalette
    @Namespace private var knob
    private let radius: CGFloat = 14

    var body: some View {
        segments
            .padding(4)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(palette.track))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(palette.trackLine))
            .opacity(model.canSwitch ? 1 : 0.6)
            .animation(.bouncy(duration: 0.4), value: model.mode)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Mode")
    }

    @ViewBuilder private var segments: some View {
        let row = HStack(spacing: 2) { ForEach(GazeMode.allCases, id: \.self) { segment($0) } }
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { row }
        } else {
            row
        }
    }

    private func segment(_ option: GazeMode) -> some View {
        let selected = option == model.mode
        return Button { model.choose(option) } label: {
            VStack(spacing: 3) {
                Image(systemName: ModePanelView.symbol(option)).font(.system(size: 15, weight: .semibold))
                Text(option.title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(selected ? palette.onAccent : palette.icon)
            .frame(maxWidth: .infinity, minHeight: 48)
            .modifier(Knob(selected: selected, radius: radius - 4, color: palette.knobTint, space: knob))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canSwitch)
        .help(option.title)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Liquid glass tinted with the accent on macOS 26, which flows to the next selected segment;
/// a plain accent shape before.
private struct Knob: ViewModifier {
    let selected: Bool
    let radius: CGFloat
    let color: Color
    let space: Namespace.ID

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if !selected {
            content
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(color).interactive(), in: shape).glassEffectID("knob", in: space)
        } else {
            content.background { shape.fill(color).matchedGeometryEffect(id: "knob", in: space) }
        }
    }
}

private struct CameraRow: View {
    let row: PanelCamera
    let palette: PanelPalette
    let enabled: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle()
                    .fill(row.selected ? palette.accent : palette.circle)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: row.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(row.selected ? palette.onAccent : Color.primary)
                    }
                Text(row.name).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovered && enabled ? Color.primary.opacity(0.06) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(row.selectable ? 1 : 0.6)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(row.selected ? .isSelected : [])
    }
}

/// A borderless panel that takes key focus for Esc and closes when it loses it.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onCancel: () -> Void = {}
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

/// The panel the Control Center button opens. It closes on Esc or a click elsewhere, like Control Center.
@MainActor
final class ModePanel: NSObject, NSWindowDelegate {
    let model = ModePanelModel()
    private var panel: KeyPanel?
    private var screen: NSScreen?
    private var height: CGFloat = 120
    private var outsideClicks: Any?
    private let log = Logger(subsystem: CameraContract.appID, category: "Panel")
    var onOpen: () -> Void = {}
    var isOpen: Bool { panel?.isVisible == true && panel?.alphaValue == 1 }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init() {
        super.init()
        model.heightChanged = { [weak self] in self?.resize(to: $0) }
    }

    func show() {
        let panel = panel ?? makePanel()
        onOpen()
        let mouse = NSEvent.mouseLocation
        screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        panel.contentView?.layoutSubtreeIfNeeded()
        let appearing = !panel.isVisible || panel.alphaValue < 1
        panel.alphaValue = 1
        panel.setFrame(frame(height: height), display: false)
        panel.makeKeyAndOrderFront(nil)
        if appearing { grow(panel.contentView) }
        if outsideClicks == nil {
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
        log.notice("Mode panel opened")
    }

    func close() {
        if let outsideClicks {
            NSEvent.removeMonitor(outsideClicks)
            self.outsideClicks = nil
        }
        guard let panel, panel.isVisible, panel.alphaValue == 1 else { return }
        log.notice("Mode panel closed")
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0 : 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                // A reopen during the fade keeps the panel.
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        })
    }

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: ModePanelLayout.width, height: height),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.title = "Locked Gaze"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        // The panel follows the content's height itself, so a change can animate.
        let host = NSHostingView(rootView: ModePanelView(model: model))
        host.sizingOptions = []
        panel.contentView = Self.glass(around: host)
        self.panel = panel
        return panel
    }

    /// System liquid glass. The public styles look flat next to Control Center; variant 11 with
    /// adaptive appearance 0 is the clear glass, and its scrim keeps the text readable over busy
    /// windows. These keys are private, so they are set only while AppKit still has them;
    /// otherwise the public regular style remains.
    private static func glass(around content: NSView) -> NSView {
        let radius: CGFloat = 16
        let container: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            for (key, value) in [("_variant", 11), ("_adaptiveAppearance", 0), ("_scrimState", 1)]
            where glass.responds(to: NSSelectorFromString("set\(key):")) {
                glass.setValue(value, forKey: key)
            }
            glass.contentView = content
            container = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .popover
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = radius
            blur.layer?.cornerCurve = .continuous
            blur.layer?.masksToBounds = true
            blur.addSubview(content)
            container = blur
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func frame(height: CGFloat) -> NSRect {
        let size = NSSize(width: ModePanelLayout.width, height: height)
        guard let visible = (screen ?? panel?.screen ?? NSScreen.main)?.visibleFrame else { return NSRect(origin: .zero, size: size) }
        return NSRect(origin: ModePanelLayout.origin(for: size, in: visible), size: size)
    }

    /// Follows the content, keeping the top edge under the menu bar.
    private func resize(to newHeight: CGFloat) {
        let newHeight = newHeight.rounded(.up)
        guard abs(newHeight - height) >= 1 else { return }
        height = newHeight
        guard let panel else { return }
        guard panel.isVisible, !reduceMotion else {
            panel.setFrame(frame(height: newHeight), display: panel.isVisible)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame(height: newHeight), display: true)
        }
    }

    /// Grows out of the top right corner, below the menu bar, with a slight spring.
    private func grow(_ view: NSView?) {
        guard !reduceMotion, let view else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let scale: CGFloat = 0.9
        let anchor = layer.anchorPoint, size = view.bounds.size
        let start = CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1),
                                        CATransform3DMakeTranslation((1 - scale) * (1 - anchor.x) * size.width,
                                                                     (1 - scale) * (1 - anchor.y) * size.height, 0))
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: start)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.damping = 20
        spring.stiffness = 300
        spring.duration = spring.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.16
        layer.add(spring, forKey: "grow")
        layer.add(fade, forKey: "fade")
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}
