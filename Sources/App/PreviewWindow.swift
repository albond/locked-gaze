import AppKit
import OSLog
import SwiftUI

/// Shows a pixel buffer through its IOSurface and keeps the buffer alive while it is on screen.
final class VideoLayerView: NSView {
    private let video = CALayer()
    private var shown: CVPixelBuffer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        video.contentsGravity = .resizeAspect
        video.cornerRadius = PreviewView.cornerRadius
        video.cornerCurve = .continuous
        video.actions = ["contents": NSNull()]
        layer = video
        wantsLayer = true
        // AppKit syncs the layer's masksToBounds with clipsToBounds, which is off by default since macOS 14.
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ buffer: CVPixelBuffer?) {
        video.contents = buffer.flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() }
        shown = buffer
    }
}

@MainActor
final class PreviewModel: ObservableObject {
    enum Status: Equatable { case starting, live, failed(String) }
    @Published var cameras: [CameraChoice] = []
    @Published var selectedID: String?
    @Published var canSelect = true
    @Published var mode = GazeMode.off
    @Published var status = Status.starting
    var select: (String?) -> Void = { _ in }
}

struct PreviewView: View {
    static let cornerRadius: CGFloat = 18
    @ObservedObject var model: PreviewModel
    let original: VideoLayerView
    let corrected: VideoLayerView

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: AppArtwork.icon)
                    .resizable().frame(width: 48, height: 48).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview").font(.system(size: 24, weight: .bold, design: .rounded))
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.callout).foregroundStyle(CandyTheme.secondary)
                }
                Spacer(minLength: 20)
                cameraPicker
            }
            HStack(spacing: 18) {
                pane(original, title: "Original", symbol: "camera", highlighted: false)
                pane(corrected, title: "Locked Gaze", symbol: "eye.fill", highlighted: true)
            }
            .overlay { status }
            Label("Preview frames stay on your Mac and are never saved.", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(CandyTheme.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(28)
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
        .foregroundStyle(CandyTheme.text).tint(CandyTheme.accentInk)
        .background(CandyBackground().ignoresSafeArea())
    }

    private var subtitle: String {
        switch model.mode {
        case .off: "Locked Gaze is off. Choose Locked Gaze to send the view on the right to calls."
        case .passThrough: "Pass-through: calls receive the original view on the left."
        case .lockedGaze: "Calls using the Locked Gaze camera see the view on the right."
        }
    }

    private var cameraPicker: some View {
        HStack(spacing: 6) {
            Image(systemName: "video").foregroundStyle(CandyTheme.secondary).accessibilityHidden(true)
            Picker("Source Camera", selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                Text("Automatic (System Preferred)").tag(String?.none)
                ForEach(model.cameras, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                if let id = model.selectedID, !model.cameras.contains(where: { $0.id == id }) {
                    Text("Selected Camera Unavailable").tag(Optional(id))
                }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 4)
        .background(CandyTheme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(CandyTheme.line))
        .disabled(!model.canSelect)
        .help("Source camera for the preview and the Locked Gaze camera")
    }

    private func pane(_ video: VideoLayerView, title: String, symbol: String, highlighted: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return ZStack(alignment: .bottomLeading) {
            shape.fill(CandyTheme.surface)
            Image(systemName: symbol).font(.system(size: 34, weight: .light))
                .foregroundStyle(CandyTheme.line)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VideoSurface(view: video)
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(highlighted ? CandyTheme.buttonText : CandyTheme.text)
                .background(highlighted ? CandyTheme.accent : CandyTheme.surface, in: Capsule())
                .padding(12)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .overlay(shape.strokeBorder(highlighted ? CandyTheme.accent : CandyTheme.line, lineWidth: highlighted ? 2 : 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(highlighted ? "Locked Gaze view" : "Original camera view")
    }

    @ViewBuilder private var status: some View {
        switch model.status {
        case .live:
            EmptyView()
        case .starting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Starting camera…")
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(CandyTheme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(CandyTheme.line))
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26)).foregroundStyle(CandyTheme.accentInk).accessibilityHidden(true)
                Text("Preview unavailable").font(.system(size: 17, weight: .bold, design: .rounded))
                Text(message).font(.callout).foregroundStyle(CandyTheme.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .padding(24).frame(maxWidth: 420)
            .background(CandyTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(CandyTheme.line))
        }
    }
}

private struct VideoSurface: NSViewRepresentable {
    let view: VideoLayerView
    func makeNSView(context: Context) -> VideoLayerView { view }
    func updateNSView(_ nsView: VideoLayerView, context: Context) {}
}

/// Side-by-side live preview. Frames arrive only while the window is open and are never stored.
@MainActor
final class PreviewWindow: NSObject, NSWindowDelegate {
    let model = PreviewModel()
    private let feed: PreviewFeed
    private let original = VideoLayerView()
    private let corrected = VideoLayerView()
    private var window: NSWindow?
    private let log = Logger(subsystem: CameraContract.appID, category: "Preview")
    private(set) var isOpen = false
    var onOpen: () -> Void = {}
    var onClose: () -> Void = {}

    init(feed: PreviewFeed) {
        self.feed = feed
        super.init()
        feed.display = { [weak self] in self?.display($0) }
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 450),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Locked Gaze Preview"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = CandyTheme.window
            window.isReleasedWhenClosed = false
            window.delegate = self
            let host = NSHostingView(rootView: PreviewView(model: model, original: original, corrected: corrected))
            host.sizingOptions = [.minSize]
            window.contentView = host
            window.setContentSize(NSSize(width: 1000, height: 450))
            window.center()
            self.window = window
        }
        if !isOpen {
            isOpen = true
            log.notice("Preview opened")
            reset()
            feed.setEnabled(true)
            onOpen()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Clears the panes until the next session delivers a frame.
    func reset() {
        clear()
        model.status = .starting
    }

    func fail(_ error: Error) {
        clear()
        model.status = .failed(error.localizedDescription)
        log.notice("Preview unavailable: \(error.localizedDescription, privacy: .public)")
    }

    private func clear() {
        original.show(nil)
        corrected.show(nil)
    }

    private func display(_ frame: PreviewFeed.Frame) {
        guard isOpen else { return }
        if case .failed = model.status { return }
        original.show(frame.original)
        corrected.show(frame.corrected)
        if model.status != .live {
            model.status = .live
            log.notice("Preview showing frames")
        }
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        log.notice("Preview closed")
        feed.setEnabled(false)
        clear()
        onClose()
    }
}
