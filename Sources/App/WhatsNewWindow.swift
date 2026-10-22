import AppKit
import SwiftUI

struct WhatsNewView: View {
    let version: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 12) {
                Image(nsImage: AppArtwork.icon)
                    .resizable().frame(width: 76, height: 76)
                    .shadow(color: CandyTheme.accent.opacity(0.16), radius: 16, y: 6)
                    .accessibilityHidden(true)
                Text("What's New").font(.system(size: 28, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Text("Locked Gaze \(version)")
                    .font(.caption.weight(.medium)).foregroundStyle(CandyTheme.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(CandyTheme.surface, in: Capsule())
            }
            VStack(alignment: .leading, spacing: 16) {
                ForEach(ReleaseNotes.items, id: \.title) { item in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 19, weight: .medium)).foregroundStyle(CandyTheme.accentInk)
                            .frame(width: 28).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.system(size: 15, weight: .semibold, design: .rounded))
                            Text(item.detail).font(.callout).foregroundStyle(CandyTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(CandyTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(CandyTheme.line))
            Button("Continue", action: close).keyboardShortcut(.defaultAction)
                .buttonStyle(CandyButtonStyle(primary: true))
        }
        .padding(32).frame(width: 440)
        .foregroundStyle(CandyTheme.text).tint(CandyTheme.accentInk)
        .background(CandyBackground())
    }
}

/// Appears once after an update without taking focus from the app in use.
@MainActor
final class WhatsNewWindow {
    private var window: NSWindow?

    func show(version: String) {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "What's New in Locked Gaze"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = CandyTheme.window
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WhatsNewView(version: version) { [weak window] in window?.close() })
        window.center()
        window.orderFrontRegardless()
        self.window = window
    }
}
