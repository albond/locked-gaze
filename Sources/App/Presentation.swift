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
    static let processors = "M2 Pro / Max / Ultra or a newer Pro / Max / Ultra chip"
    static var chip: String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0 else { return "Unknown processor" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "Unknown processor" }
        return String(cString: bytes)
    }
    static func supports(_ name: String) -> Bool {
        guard let range = name.range(of: #"\bM([0-9]+) (Pro|Max|Ultra)\b"#, options: .regularExpression) else { return false }
        let model = name[range].split(separator: " ")[0].dropFirst()
        return (Int(model) ?? 0) >= 2
    }
}

enum MenuIcon {
    static func image(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let eye = NSBezierPath()
            eye.move(to: NSPoint(x: 2, y: 9))
            eye.curve(to: NSPoint(x: 20, y: 9), controlPoint1: NSPoint(x: 7, y: 17), controlPoint2: NSPoint(x: 15, y: 17))
            eye.curve(to: NSPoint(x: 2, y: 9), controlPoint1: NSPoint(x: 15, y: 1), controlPoint2: NSPoint(x: 7, y: 1))
            eye.close(); eye.lineWidth = 1.5; eye.lineJoinStyle = .round; eye.stroke()
            let iris = NSBezierPath(ovalIn: NSRect(x: 7.5, y: 5.5, width: 7, height: 7))
            if active { iris.fill() } else { iris.lineWidth = 1.4; iris.stroke() }
            if active {
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: 9, y: 9, width: 2, height: 2)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = active ? "Locked Gaze active" : "Locked Gaze inactive"
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
    static let window = adaptive("CandyWindow", light: 0xFFF8F3, dark: 0x281F2C)
    static let background = Color(nsColor: window)
    static let text = Color(nsColor: adaptive("CandyText", light: 0x402A3F, dark: 0xFFF1E9))
    static let secondary = Color(nsColor: adaptive("CandySecondary", light: 0x755B70, dark: 0xCFB9CB))
    static let surface = Color(nsColor: adaptive("CandySurface", light: 0xFFFDFC, dark: 0x382B3D))
    static let blush = Color(nsColor: adaptive("CandyBlush", light: 0xFBE0E6, dark: 0x503347))
    static let lavender = Color(nsColor: adaptive("CandyLavender", light: 0xEEE2F5, dark: 0x3B2F4A))
    static let accent = Color(nsColor: adaptive("CandyAccent", light: 0x9B4265, dark: 0xF3B4CF))
    static let buttonText = Color(nsColor: adaptive("CandyButtonText", light: 0xFFFFFF, dark: 0x382338))
    static let line = Color(nsColor: adaptive("CandyLine", light: 0xE8CFDC, dark: 0x705466))
}

struct CandyBackground: View {
    var body: some View {
        LinearGradient(colors: [CandyTheme.blush, CandyTheme.background, CandyTheme.lavender],
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
        .foregroundStyle(CandyTheme.text).tint(CandyTheme.accent)
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
        .foregroundStyle(CandyTheme.text).tint(CandyTheme.accent)
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
