import AppKit
import AVFoundation
import CoreVideo

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private let cameraMenu = NSMenu(title: "Source Camera")
    private let about = AboutWindow()
    private var selectedCameraID: String? { UserDefaults.standard.string(forKey: "sourceCameraID") }
    private let camera = CameraSession()
    private let installer = ExtensionInstaller()
    private let permissions = PermissionPrompt()
    private lazy var lifecycle = CameraLifecycle(prepare: { [unowned self] in
        guard PlatformRequirements.supports(PlatformRequirements.chip) else {
            throw GazeError.message("Locked Gaze requires \(PlatformRequirements.processors). Detected: \(PlatformRequirements.chip).")
        }
        try await permissions.ensureCamera()
        try Task.checkCancellation()
        try await permissions.ensureExtension(installer)
    }, start: { [unowned self] in
        guard let resources = Bundle.main.resourceURL else { throw GazeError.message("Application resources are missing.") }
        try await camera.start(models: resources.appendingPathComponent("Models"), sourceID: selectedCameraID)
    }, stop: { [unowned self] in await camera.stop() })
    private var state: CameraLifecycle.State { lifecycle.state }
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = AppArtwork.icon
        if CommandLine.arguments.contains("--check-extension-status") {
            Task {
                do {
                    let enabled = try await installer.currentExtensionEnabled()
                    print("Current camera extension enabled: \(enabled)")
                    exit(enabled ? 0 : 1)
                } catch { print("Extension status query failed: \(error)"); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--watch-camera-publisher") {
            // Exercise a host that already initialized the camera registry.
            _ = CameraSession.availableCameras()
            Task {
                let publisher = CameraPublisherClient()
                var previous = ""
                for _ in 0..<600 {
                    let result: String
                    do {
                        try await installer.activate()
                        try await publisher.start()
                        result = "ready"
                    } catch {
                        publisher.stop()
                        result = "unavailable: \(error.localizedDescription)"
                    }
                    if result != previous {
                        print("Publisher host pid=\(getpid()): \(result)"); fflush(stdout)
                        previous = result
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                publisher.stop(); exit(0)
            }
            return
        }
        if CommandLine.arguments.contains("--check-camera-publisher") {
            Task {
                do {
                    try await installer.activate()
                    let publisher = CameraPublisherClient()
                    try await StartupRetry.run { try await publisher.start() }
                    var frame: CVPixelBuffer?
                    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
                    guard CVPixelBufferCreate(nil, CameraContract.width, CameraContract.height,
                        kCVPixelFormatType_32BGRA, attrs, &frame) == kCVReturnSuccess, let frame else {
                        throw GazeError.message("Cannot allocate synthetic diagnostic frame.")
                    }
                    CVPixelBufferLockBaseAddress(frame, [])
                    memset(CVPixelBufferGetBaseAddress(frame), 0, CVPixelBufferGetDataSize(frame))
                    CVPixelBufferUnlockBaseAddress(frame, [])
                    try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                        do {
                            try publisher.send(frame) { error in
                                if let error { reply.resume(throwing: GazeError.message(error)) }
                                else { reply.resume() }
                            }
                        } catch { reply.resume(throwing: error) }
                    }
                    publisher.stop()
                    print("Camera publisher XPC start / synthetic IOSurface transfer / stop: OK")
                    exit(0)
                } catch {
                    print("Camera publisher check failed: \(error)")
                    exit(1)
                }
            }
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.delegate = self
        toggleItem = menu.addItem(withTitle: "Activate", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(.separator())
        let source = menu.addItem(withTitle: "Source Camera", action: nil, keyEquivalent: "")
        source.image = NSImage(systemSymbolName: "video", accessibilityDescription: nil)
        source.submenu = cameraMenu
        menu.addItem(.separator())
        let aboutItem = menu.addItem(withTitle: "About Locked Gaze…", action: #selector(showAbout), keyEquivalent: "")
        let quit = menu.addItem(withTitle: "Quit Locked Gaze", action: #selector(quit), keyEquivalent: "q")
        for item in [toggleItem!, aboutItem, quit] { item.target = self }
        statusItem.menu = menu
        GazeControlState.setActive = { [weak self] enabled in
            guard let self else { throw GazeError.message("Locked Gaze is closing.") }
            try await self.setEnabled(enabled)
        }
        lifecycle.onChange = { [weak self] in self?.refresh() }
        camera.onFailure = { [weak self] error in
            guard let self else { return }
            Task { if await self.lifecycle.failed(error) { self.show(error) } }
        }
        refresh()
        if CommandLine.arguments.contains("--show-about") { about.show() }
    }
    private func refresh() {
        guard statusItem != nil else { return }
        let presentation = CameraPresentation(state: state, closing: terminating)
        toggleItem.title = presentation.actionTitle
        toggleItem.isEnabled = presentation.canToggle
        toggleItem.state = presentation.active ? .on : .off
        toggleItem.image = MenuIcon.image(active: presentation.active)
        statusItem.button?.image = MenuIcon.image(active: presentation.active)
        statusItem.button?.toolTip = "Locked Gaze — \(presentation.status)"
        statusItem.button?.setAccessibilityLabel("Locked Gaze — \(presentation.status)")
        // Accessory apps do not normally appear in the Dock. If macOS shows a
        // Dock tile, keep its badge in sync without changing activation policy.
        NSApp.dockTile.badgeLabel = presentation.dockBadge
        for item in cameraMenu.items where item.action == #selector(selectCamera(_:)) {
            item.isEnabled = presentation.canToggle
        }
        GazeControlState.publish(presentation.active)
    }
    func menuWillOpen(_ menu: NSMenu) { rebuildCameras() }
    private func rebuildCameras() {
        cameraMenu.removeAllItems()
        cameraMenu.autoenablesItems = false
        func add(_ title: String, id: String?) {
            let item = cameraMenu.addItem(withTitle: title, action: #selector(selectCamera(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id
            item.state = selectedCameraID == id ? .on : .off
            item.isEnabled = state == .idle || state == .active
        }
        add("Automatic (System Preferred)", id: nil)
        cameraMenu.addItem(.separator())
        let devices = CameraSession.availableCameras()
        for device in devices { add(device.localizedName, id: device.uniqueID) }
        if let selectedCameraID, !devices.contains(where: { $0.uniqueID == selectedCameraID }) {
            let missing = cameraMenu.addItem(withTitle: "Selected Camera Unavailable", action: nil, keyEquivalent: "")
            missing.state = .on; missing.isEnabled = false
        }
        if devices.isEmpty {
            let empty = cameraMenu.addItem(withTitle: "No Cameras Connected", action: nil, keyEquivalent: "")
            empty.isEnabled = false
        }
    }
    @objc private func selectCamera(_ item: NSMenuItem) {
        guard state == .idle || state == .active else { return }
        let id = item.representedObject as? String
        guard id != selectedCameraID else { return }
        UserDefaults.standard.set(id, forKey: "sourceCameraID")
        let restart = state == .active
        Task {
            if restart {
                do { try await setEnabled(false); try await setEnabled(true) } catch { show(error) }
            }
        }
    }
    @objc private func showAbout() { about.show() }
    @objc private func toggle() {
        let presentation = CameraPresentation(state: state, closing: terminating)
        guard presentation.canToggle else { return }
        let enabled = !presentation.active
        Task { do { try await setEnabled(enabled) } catch { if !terminating { show(error) } } }
    }
    private func setEnabled(_ enabled: Bool) async throws {
        guard !terminating else { throw GazeError.message("Locked Gaze is closing.") }
        try await lifecycle.setEnabled(enabled)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        refresh()
        permissions.cancel()
        NSApp.abortModal()
        Task { await lifecycle.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    private func show(_ error: Error) {
        guard !(error is CancellationError), !terminating else { return }
        let alert = NSAlert(); alert.messageText = "Locked Gaze"; alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK"); NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
