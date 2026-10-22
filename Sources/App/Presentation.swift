import AppKit
import SwiftUI
import Darwin

// Load our bundled artwork directly: Launch Services can retain the previous app icon.
@MainActor
enum AppArtwork {
    static let icon: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) { return image }
        return NSApp.applicationIconImage
    }()
}

// Product support policy; inference benchmarking remains a separate acceptance stage.
enum PlatformRequirements {
    static let summary = "macOS 14 Sonoma or later"
    // Every tier of this generation and newer is allowed: base, Pro, Max and Ultra.
    static let minimumChipGeneration = 2
    static let processors = "Apple M\(minimumChipGeneration) or a newer chip"
    static var chip: String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0 else { return "Unknown processor" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "Unknown processor" }
        return String(cString: bytes)
    }
    static func supports(_ name: String) -> Bool {
        guard let range = name.range(of: #"\bM[0-9]+\b"#, options: .regularExpression),
              let generation = Int(name[range].dropFirst()) else { return false }
        return generation >= minimumChipGeneration
    }
    static func requireSupported() throws {
        guard supports(chip) else { throw GazeError.message("Locked Gaze requires \(processors). Detected: \(chip).") }
    }
}

enum AppStoreLinks {
    static let appID = "6814174298"
    /// Opens the Mac App Store app directly on the review sheet for Locked Gaze.
    static let writeReview = URL(string: "macappstore://apps.apple.com/app/id\(appID)?action=write-review")!
}

/// Highlights of the bundled build for What's New. Update them before every release.
enum ReleaseNotes {
    struct Item { let symbol: String; let title: String; let detail: String }
    static let items = [
        Item(symbol: "switch.2", title: "Three modes",
             detail: "Off, Pass-through and Locked Gaze: turn correction off without leaving the Locked Gaze camera."),
        Item(symbol: "widget.small", title: "Widget and Control Center",
             detail: "Switch modes from a desktop widget or Control Center, where Mode and Camera also picks the source camera."),
        Item(symbol: "rectangle.split.2x1", title: "Preview",
             detail: "See your camera and the corrected view side by side before a call."),
        Item(symbol: "laptopcomputer", title: "More Macs",
             detail: "Runs on Apple M2 and newer chips, including MacBook Air."),
    ]
    /// Once after an update; never on a first install or after a downgrade.
    static func shouldShow(lastLaunched: String?, current: String, launchedBefore: Bool) -> Bool {
        guard let lastLaunched else { return launchedBefore }
        return current.compare(lastLaunched, options: .numeric) == .orderedDescending
    }
}

enum MenuIcon {
    /// Off: outlined iris. Pass-through: outlined iris with a pupil. Locked Gaze: filled iris.
    static func image(mode: GazeMode) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let eye = NSBezierPath()
            eye.move(to: NSPoint(x: 2, y: 9))
            eye.curve(to: NSPoint(x: 20, y: 9), controlPoint1: NSPoint(x: 7, y: 17), controlPoint2: NSPoint(x: 15, y: 17))
            eye.curve(to: NSPoint(x: 2, y: 9), controlPoint1: NSPoint(x: 15, y: 1), controlPoint2: NSPoint(x: 7, y: 1))
            eye.close(); eye.lineWidth = 1.5; eye.lineJoinStyle = .round; eye.stroke()
            let iris = NSBezierPath(ovalIn: NSRect(x: 7.5, y: 5.5, width: 7, height: 7))
            switch mode {
            case .off:
                iris.lineWidth = 1.4; iris.stroke()
            case .passThrough:
                iris.lineWidth = 1.4; iris.stroke()
                NSBezierPath(ovalIn: NSRect(x: 9.6, y: 7.6, width: 2.8, height: 2.8)).fill()
            case .lockedGaze:
                iris.fill()
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: 9, y: 9, width: 2, height: 2)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Locked Gaze \(mode.title)"
        return image
    }
}

/// Opaque, adaptive surfaces keep the candy palette readable with reduced transparency.
enum CandyTheme {
    static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
    static let window = adaptive("CandyWindow", light: 0xFFF8F4, dark: 0x1E1D1D)
    static let background = Color(nsColor: window)
    static let text = Color(nsColor: adaptive("CandyText", light: 0x1F1D1C, dark: 0xFFF5EF))
    static let secondary = Color(nsColor: adaptive("CandySecondary", light: 0x6B625D, dark: 0xC9BFBA))
    static let surface = Color(nsColor: adaptive("CandySurface", light: 0xFFFDFB, dark: 0x2A2827))
    static let blush = Color(nsColor: adaptive("CandyBlush", light: 0xFFE3D3, dark: 0x2E2522))
    static let apricot = Color(nsColor: adaptive("CandyApricot", light: 0xFDEADF, dark: 0x242121))
    /// The peach of the orange AirPods Max. It is a fill: text and symbols on it are dark.
    static let accent = Color(nsColor: adaptive("CandyAccent", light: 0xF7A982, dark: 0xF7A982))
    /// The accent for symbols on light surfaces, where the peach fill is too pale to read.
    static let accentInk = Color(nsColor: adaptive("CandyAccentInk", light: 0xE57B4F, dark: 0xF7A982))
    static let buttonText = Color(nsColor: adaptive("CandyButtonText", light: 0x1F1D1C, dark: 0x1F1D1C))
    static let line = Color(nsColor: adaptive("CandyLine", light: 0xF2D9CB, dark: 0x45403D))
}

struct CandyBackground: View {
    var body: some View {
        LinearGradient(colors: [CandyTheme.blush, CandyTheme.background, CandyTheme.apricot],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct CandyButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .padding(.horizontal, 18).padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .foregroundStyle(primary ? CandyTheme.buttonText : CandyTheme.text)
            .background(primary ? CandyTheme.accent : CandyTheme.surface,
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(CandyTheme.line, lineWidth: primary ? 0 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
    }
}

struct PermissionView: View {
    let title: String
    let message: String
    let settingsTitle: String
    let openSettings: () -> Void
    let retry: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(nsImage: AppArtwork.icon)
                    .resizable().frame(width: 64, height: 64).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Locked Gaze").font(.system(size: 19, weight: .bold, design: .rounded))
                    Label("Private by design", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(CandyTheme.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.system(size: 25, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Text(message).font(.system(size: 14)).lineSpacing(4)
                    .foregroundStyle(CandyTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: openSettings) {
                HStack {
                    Text(settingsTitle)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
            }.buttonStyle(CandyButtonStyle())
            HStack(spacing: 12) {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                    .buttonStyle(CandyButtonStyle())
                Button("Check Again", action: retry).keyboardShortcut(.defaultAction)
                    .buttonStyle(CandyButtonStyle(primary: true))
            }
            Text("Your camera frames stay on your Mac.")
                .font(.caption).foregroundStyle(CandyTheme.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(28).frame(width: 440)
        .foregroundStyle(CandyTheme.text).tint(CandyTheme.accentInk)
        .background(CandyBackground())
    }
}

struct AboutView: View {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    private let githubURL = URL(string: "https://github.com/albond/locked-gaze")!

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 14) {
                Image(nsImage: AppArtwork.icon)
                    .resizable().frame(width: 112, height: 112)
                    .shadow(color: CandyTheme.accent.opacity(0.16), radius: 20, y: 8)
                    .accessibilityHidden(true)
                VStack(spacing: 7) {
                    Text("Locked Gaze")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("Keep your eyes on the conversation.")
                        .font(.system(size: 15)).foregroundStyle(CandyTheme.secondary)
                    Text("Version \(version)")
                        .font(.caption.weight(.medium)).foregroundStyle(CandyTheme.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(CandyTheme.surface, in: Capsule())
                }
            }

            HStack(spacing: 10) {
                feature("On-device", symbol: "cpu")
                feature("Private", symbol: "lock.shield")
                feature("Offline", symbol: "wifi.slash")
            }

            VStack(alignment: .leading, spacing: 14) {
                Label("Stay present. Stay yourself.", systemImage: "eye")
                    .font(.headline)
                Text("A little help with eye contact, so you can focus on the people on your screen.")
                    .font(.callout).foregroundStyle(CandyTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(CandyTheme.line).frame(height: 1).accessibilityHidden(true)
                Label("Your camera frames stay on your Mac.", systemImage: "checkmark.shield")
                    .font(.callout.weight(.medium))
                Text("No video uploads. No camera recordings.")
                    .font(.caption).foregroundStyle(CandyTheme.secondary)
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(CandyTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(CandyTheme.line))

            VStack(spacing: 10) {
                Link(destination: githubURL) {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                        Text("Follow on GitHub").fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                }
                .buttonStyle(CandyButtonStyle(primary: true))
                .help("Open github.com/albond/locked-gaze in your browser")
                .accessibilityLabel("Follow Locked Gaze on GitHub")
                Text("Made for Mac by albond")
                    .font(.caption).foregroundStyle(CandyTheme.secondary)
            }
        }
        .padding(32).frame(width: 460)
        .foregroundStyle(CandyTheme.text).tint(CandyTheme.accentInk)
        .background(CandyBackground())
    }

    private func feature(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(CandyTheme.text)
            .background(CandyTheme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(CandyTheme.line))
    }
}

@MainActor
final class AboutWindow {
    private var window: NSWindow?
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "About Locked Gaze"
            window.titlebarAppearsTransparent = true
            window.backgroundColor = CandyTheme.window
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AboutView())
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
