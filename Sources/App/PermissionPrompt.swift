import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class PermissionPrompt: NSObject, NSWindowDelegate {
    private var pending: CheckedContinuation<Bool, Never>?
    private var window: NSWindow?
    private var settingsURL: URL?

    func ensureCamera() async throws {
        try await PermissionGate.ensure(probe: {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .authorized
            case .notDetermined: return .notDetermined
            case .restricted: return .restricted
            default: return .denied
            }
        }, request: { _ = await AVCaptureDevice.requestAccess(for: .video) }, prompt: { status in
            await self.checkAgain(title: "Camera Access Required",
                message: status == .restricted
                    ? "Camera access is restricted on this Mac. Check Screen Time or your device administrator's settings. After access is allowed, click Check Again."
                    : "Allow Locked Gaze in System Settings > Privacy & Security > Camera. Then click Check Again to verify access and continue.",
                settings: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        })
    }

    func ensureExtension(_ installer: ExtensionInstaller) async throws {
        while true {
            try Task.checkCancellation()
            do { try await installer.activate(); return }
            catch is ExtensionInstaller.ApprovalError {
                let settings: String
                let message: String
                let buttonTitle: String
                if #available(macOS 15.0, *) {
                    settings = "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.system_extension.cmio.extension-point"
                    message = "Open Camera Extensions and turn on Locked Gaze. Then return here and click Check Again."
                    buttonTitle = "Open Camera Extensions…"
                } else {
                    settings = "x-apple.systempreferences:com.apple.preference.security"
                    message = "Open Privacy & Security and allow the Locked Gaze camera extension. Then return here and click Check Again."
                    buttonTitle = "Open Privacy & Security…"
                }
                guard await checkAgain(title: "Camera Extension Approval Required", message: message,
                    settings: settings, buttonTitle: buttonTitle) else { throw CancellationError() }
            }
        }
    }

    private func checkAgain(title: String, message: String, settings: String, buttonTitle: String = "Open System Settings…") async -> Bool {
        settingsURL = URL(string: settings)
        // Opening Settings does not dismiss the prompt. The user explicitly
        // returns and rechecks; no timer repeatedly steals keyboard focus.
        // Do not nest runModal inside an async activation: it can prevent
        // main-queue extension/device callbacks from being delivered promptly.
        return await withCheckedContinuation { continuation in
            precondition(pending == nil)
            pending = continuation
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = title
            window.titlebarAppearsTransparent = true
            window.backgroundColor = CandyTheme.window
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: PermissionView(
                title: title, message: message, settingsTitle: buttonTitle,
                openSettings: { [weak self] in self?.openSettings() },
                retry: { [weak self] in self?.finish(true) },
                cancel: { [weak self] in self?.finish(false) }))
            self.window = window
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
    func cancel() { finish(false) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(false); return false }
    private func finish(_ retry: Bool) {
        guard let continuation = pending else { return }
        pending = nil
        window?.orderOut(nil); window?.close(); window = nil
        settingsURL = nil
        continuation.resume(returning: retry)
    }
    @objc private func openSettings() {
        if let settingsURL { NSWorkspace.shared.open(settingsURL) }
    }
}
