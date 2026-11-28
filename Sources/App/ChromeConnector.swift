import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Sets up Google Chrome for the browser camera (LG-009). Until the extension is on the
/// Chrome Web Store, Locked Gaze ships it and saves a copy to a folder the user picks, to be
/// added with Developer mode → Load unpacked; Locked Gaze refreshes that copy after updates.
/// Chrome finds the bundled helper through a small Native Messaging manifest in the user's
/// Chrome folder. The sandbox lets Locked Gaze write only where the user picks, so each save
/// panel opens at the right place with the name filled in; the user only clicks Save.
@MainActor
enum ChromeConnector {
    static var helperURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LockedGazeBrowserHost") }

    /// Connected when the saved Native Messaging file is still there and names this copy's
    /// helper. Checked on the file itself: it can be deleted, or the app moved, at any time.
    static var isConnected: Bool {
        guard let file = resolveBookmark("chromeHostBookmark") else { return false }
        defer { file.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["path"] as? String == helperURL.path
    }

    static func manifest(helperPath: String) throws -> Data {
        let object: [String: Any] = [
            "name": BrowserContract.chromeHostName,
            "description": "Locked Gaze browser camera",
            "path": helperPath,
            "type": "stdio",
            "allowed_origins": BrowserContract.chromeExtensionIDs.map { "chrome-extension://\($0)/" },
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// The real home folder; inside the sandbox `NSHomeDirectory()` is the app's container.
    private static var userHome: URL {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return URL(fileURLWithPath: NSHomeDirectory()) }
        return URL(fileURLWithPath: String(cString: directory))
    }

    private static var bundledExtension: URL? { Bundle.main.resourceURL?.appendingPathComponent("ChromeExtension", isDirectory: true) }
    private static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    /// Opens the setup window; every action happens there, one step at a time.
    static func setUp() { ChromeSetupWindow.shared.show() }

    /// Where the extension folder was saved (with ~ for the home folder), if it is still there.
    static var savedFolderPath: String? {
        guard let folder = savedExtensionFolder() else { return nil }
        defer { folder.stopAccessingSecurityScopedResource() }
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) else { return nil }
        let home = userHome.path
        return folder.path.hasPrefix(home + "/") ? "~" + folder.path.dropFirst(home.count) : folder.path
    }

    /// Chrome refuses chrome:// pages opened by other apps, so the address goes to the clipboard.
    static func openExtensionsPage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("chrome://extensions", forType: .string)
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            NSWorkspace.shared.openApplication(at: chrome, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    static func revealFolder() {
        guard let folder = savedExtensionFolder() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        folder.stopAccessingSecurityScopedResource()
    }

    /// Saves the bundled extension to a folder the user picks and remembers it for updates.
    @discardableResult static func saveExtension() -> Bool {
        guard let source = bundledExtension else { return false }
        let panel = NSSavePanel()
        panel.title = "Save the Locked Gaze Extension for Chrome"
        panel.message = "Choose where to keep the extension folder. Chrome loads it from here, so keep the folder; Locked Gaze updates it after app updates."
        panel.prompt = "Save"
        panel.nameFieldStringValue = "Locked Gaze Chrome Extension"
        panel.directoryURL = userHome.appendingPathComponent("Documents", isDirectory: true)
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try replaceContents(of: url, with: source)
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: "chromeExtensionBookmark")
            UserDefaults.standard.set(build, forKey: "chromeExtensionBuild")
            return true
        } catch {
            NSAlert(error: error).runModal(); return false
        }
    }

    /// After an app update, brings the saved extension folder up to date; Chrome picks the
    /// change up when it restarts or when the extension is reloaded.
    static func refreshSavedExtension() {
        guard UserDefaults.standard.string(forKey: "chromeExtensionBuild") != build,
              let source = bundledExtension, let folder = savedExtensionFolder() else { return }
        defer { folder.stopAccessingSecurityScopedResource() }
        if (try? replaceContents(of: folder, with: source)) != nil {
            UserDefaults.standard.set(build, forKey: "chromeExtensionBuild")
        }
    }

    /// Resolves the remembered folder and starts security-scoped access; the caller stops it.
    private static func savedExtensionFolder() -> URL? { resolveBookmark("chromeExtensionBookmark") }

    /// Resolves a remembered location and starts security-scoped access; the caller stops it.
    private static func resolveBookmark(_ key: String) -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: key)
        }
        return url
    }

    /// Replaces the folder's files with the bundled ones; anything else in it stays.
    private static func replaceContents(of folder: URL, with source: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in try files.contentsOfDirectory(atPath: source.path) {
            let target = folder.appendingPathComponent(name)
            if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
            try files.copyItem(at: source.appendingPathComponent(name), to: target)
        }
    }

    /// Registers the helper with Chrome. Returns true once the manifest is saved.
    @discardableResult static func connect() -> Bool {
        let panel = NSSavePanel()
        panel.title = "Connect Google Chrome"
        panel.message = "Click Save to let the Locked Gaze extension in Google Chrome receive the Locked Gaze camera. The file tells Chrome where the Locked Gaze helper is; nothing leaves your Mac."
        panel.prompt = "Save"
        panel.nameFieldStringValue = "\(BrowserContract.chromeHostName).json"
        panel.directoryURL = userHome.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try manifest(helperPath: helperURL.path).write(to: url, options: .atomic)
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: "chromeHostBookmark")
            return true
        } catch {
            let alert = NSAlert(error: error); alert.runModal()
            return false
        }
    }
}

/// Set Up Google Chrome: each action is its own step with its own button and a visible result.
@MainActor
final class ChromeSetupModel: ObservableObject {
    @Published var folderPath = ChromeConnector.savedFolderPath
    @Published var connected = ChromeConnector.isConnected
    @Published var copied = false

    func saveFolder() { if ChromeConnector.saveExtension() { folderPath = ChromeConnector.savedFolderPath } }
    func connect() { if ChromeConnector.connect() { connected = ChromeConnector.isConnected } }
    func showFolder() { ChromeConnector.revealFolder() }
    func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("chrome://extensions", forType: .string)
        copied = true
    }
    func openChrome() { ChromeConnector.openExtensionsPage(); copied = true }
    func refresh() { folderPath = ChromeConnector.savedFolderPath; connected = ChromeConnector.isConnected }
}

@MainActor
final class ChromeSetupWindow: NSObject, NSWindowDelegate {
    static let shared = ChromeSetupWindow()
    private var window: NSWindow?
    private let model = ChromeSetupModel()

    func show() {
        model.refresh()
        if window == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Add Locked Gaze to Chrome"
            window.titlebarAppearsTransparent = true
            window.backgroundColor = CandyTheme.window
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: ChromeSetupView(model: model, done: { [weak self] in self?.window?.close() }))
            window.centerOnActiveScreen()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { window = nil }
}

struct ChromeSetupView: View {
    @ObservedObject var model: ChromeSetupModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: AppArtwork.icon).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add Locked Gaze to Chrome").font(.system(size: 22, weight: .bold, design: .rounded))
                        .accessibilityAddTraits(.isHeader)
                    Text("Do these steps once, in order.").font(.system(size: 13)).foregroundStyle(CandyTheme.secondary)
                }
            }
            step(1, "Save the extension folder", complete: model.folderPath != nil,
                 model.folderPath.map { "Saved to \($0). Keep this folder: Chrome loads the extension from it." }
                    ?? "Locked Gaze includes the Chrome extension. Choose where to save its folder, for example Documents.") {
                if model.folderPath == nil {
                    Button("Save Extension Folder…", action: model.saveFolder).buttonStyle(CandyButtonStyle(primary: true))
                } else {
                    HStack(spacing: 10) {
                        Button("Show in Finder", action: model.showFolder).buttonStyle(CandyButtonStyle())
                        Button("Save Elsewhere…", action: model.saveFolder).buttonStyle(CandyButtonStyle())
                    }
                }
            }
            step(2, "Let Chrome start Locked Gaze", complete: model.connected,
                 model.connected ? "Done. Chrome can reach Locked Gaze on this Mac; nothing goes online."
                    : "Save a small file in Chrome's folder; the save window opens there with the name filled in. Just click Save.") {
                if !model.connected {
                    Button("Allow Chrome…", action: model.connect).buttonStyle(CandyButtonStyle(primary: model.folderPath != nil))
                }
            }
            step(3, "Open Chrome's Extensions page", complete: false,
                 "Chrome does not let apps open this page, so go there by its address: click Chrome's address bar, paste with ⌘V and press Return.") {
                addressField
                Button(model.copied ? "Copied — Open Chrome Again" : "Copy Address and Open Chrome", action: model.openChrome)
                    .buttonStyle(CandyButtonStyle(primary: model.folderPath != nil && model.connected && !model.copied))
            }
            step(4, "Turn on Developer mode", complete: false, "The switch is in the top-right corner of that page.") { EmptyView() }
            step(5, "Click Load unpacked", complete: false,
                 model.folderPath.map { "Choose the folder you saved in step 1: \($0)." } ?? "Choose the folder you saved in step 1.") {
                if model.folderPath != nil { Button("Show in Finder", action: model.showFolder).buttonStyle(CandyButtonStyle()) }
            }
            step(6, "Pick the camera in your meeting", complete: false,
                 "In Google Meet, Microsoft Teams, Zoom, Webex, Jitsi, Whereby, Slack or Discord in Chrome, choose Locked Gaze Camera, with Browser selected in Locked Gaze. Chrome asks once per site to allow the camera.") { EmptyView() }
            HStack {
                Text("Your camera frames stay on your Mac.").font(.caption).foregroundStyle(CandyTheme.secondary)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction).buttonStyle(CandyButtonStyle(primary: model.copied))
            }
        }
        .padding(28).frame(width: 480)
        .foregroundStyle(CandyTheme.text).tint(CandyTheme.accentInk)
        .background(CandyBackground())
    }

    /// The address as it appears in Chrome's address bar; it can also be selected and copied by hand.
    private var addressField: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(CandyTheme.secondary).accessibilityHidden(true)
            Text("chrome://extensions").font(.system(size: 14, design: .monospaced)).textSelection(.enabled)
            Spacer(minLength: 8)
            Button(action: model.copyAddress) { Label("Copy", systemImage: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy the address")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Capsule().fill(CandyTheme.surface))
        .overlay(Capsule().strokeBorder(CandyTheme.line))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Address: chrome://extensions")
    }

    private func step<Action: View>(_ number: Int, _ title: String, complete: Bool, _ detail: String,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if complete { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)) }
                else { Text("\(number)").font(.system(size: 14, weight: .bold, design: .rounded)) }
            }
            .frame(width: 28, height: 28)
            .background(Circle().fill(CandyTheme.accent))
            .foregroundStyle(CandyTheme.buttonText)
            .accessibilityLabel(complete ? "Step \(number), done" : "Step \(number)")
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(CandyTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action()
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }
}
