import AppKit
import AVFoundation
import CoreVideo
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var modeItems: [NSMenuItem] = []
    private var loggedStatus: String?
    private let cameraMenu = NSMenu(title: "Source Camera")
    private let about = AboutWindow()
    private let whatsNew = WhatsNewWindow()
    private var selectedCameraID: String? { UserDefaults.standard.string(forKey: "sourceCameraID") }
    private let previewFeed = PreviewFeed(width: CameraContract.width, height: CameraContract.height)
    private lazy var camera = CameraSession(preview: previewFeed)
    /// Runs only for an open preview while Locked Gaze is off; it never publishes.
    private lazy var previewCamera = CameraSession(preview: previewFeed)
    private lazy var preview = PreviewWindow(feed: previewFeed)
    private let modePanel = ModePanel()
    private struct PreviewRun { let sourceID: String? }
    private var previewRun: PreviewRun?
    private var previewSync: Task<Void, Never>?
    private let installer = ExtensionInstaller()
    private let permissions = PermissionPrompt()
    private lazy var lifecycle = CameraLifecycle(prepare: { [unowned self] in
        try PlatformRequirements.requireSupported()
        try await permissions.ensureCamera()
        try Task.checkCancellation()
        try await permissions.ensureExtension(installer)
    }, start: { [unowned self] in
        // Activation owns the camera: the preview session stops first (see syncPreview).
        await previewSync?.value
        guard let resources = Bundle.main.resourceURL else { throw GazeError.message("Application resources are missing.") }
        try await camera.start(models: resources.appendingPathComponent("Models"), sourceID: selectedCameraID)
    }, stop: { [unowned self] in await camera.stop() })
    private lazy var modes = GazeModeController(lifecycle: lifecycle) { [unowned self] on in camera.setCorrection(on) }
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
        for mode in GazeMode.allCases {
            let item = menu.addItem(withTitle: mode.title, action: #selector(chooseMode(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            modeItems.append(item)
        }
        menu.addItem(.separator())
        let source = menu.addItem(withTitle: "Source Camera", action: nil, keyEquivalent: "")
        source.image = NSImage(systemSymbolName: "video", accessibilityDescription: nil)
        cameraMenu.delegate = self
        source.submenu = cameraMenu
        let previewItem = menu.addItem(withTitle: "Preview…", action: #selector(showPreview), keyEquivalent: "")
        previewItem.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
        menu.addItem(.separator())
        let aboutItem = menu.addItem(withTitle: "About Locked Gaze…", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(.separator())
        let rateItem = menu.addItem(withTitle: "🙏 Please Rate our App", action: #selector(rateApp), keyEquivalent: "")
        let quit = menu.addItem(withTitle: "Quit Locked Gaze", action: #selector(quit), keyEquivalent: "q")
        for item in modeItems + [previewItem, aboutItem, rateItem, quit] { item.target = self }
        statusItem.menu = menu
        rebuildCameras()
        GazeControlState.setMode = { [weak self] mode in
            guard let self else { throw GazeError.message("Locked Gaze is closing.") }
            try await self.setMode(mode)
        }
        modes.onChange = { [weak self] in self?.refresh() }
        lifecycle.onChange = { [weak self] in
            guard let self else { return }
            refresh()
            if state == .starting || state == .stopping { preview.reset() }
            syncPreview()
        }
        camera.onFailure = { [weak self] error in
            guard let self else { return }
            Task { if await self.lifecycle.failed(error) { self.show(error) } }
        }
        previewCamera.onFailure = { [weak self] error in self?.previewFailed(error) }
        preview.model.select = { [weak self] id in self?.chooseCamera(id) }
        preview.onOpen = { [weak self] in self?.updatePreviewCameras(); self?.syncPreview() }
        preview.onClose = { [weak self] in self?.syncPreview() }
        modePanel.model.choose = { [weak self] in self?.requestMode($0) }
        modePanel.model.select = { [weak self] id in self?.chooseCamera(id) }
        modePanel.onOpen = { [weak self] in self?.updatePanelCameras() }
        GazeControlState.showPanel = { [weak self] in self?.modePanel.show() }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updatePreviewCameras()
                    if self?.modePanel.isOpen == true { self?.updatePanelCameras() }
                }
            }
        }
        let launchedBefore = GazeControlState.hasPublishedState
        refresh()
        showWhatsNewAfterUpdate(launchedBefore: launchedBefore)
        if CommandLine.arguments.contains("--show-about") { about.show() }
    }
    private func refresh() {
        guard statusItem != nil else { return }
        let presentation = CameraPresentation(state: state, correcting: modes.correcting, closing: terminating)
        for item in modeItems {
            item.state = item.representedObject as? String == presentation.mode.rawValue ? .on : .off
            item.isEnabled = presentation.canSwitch
        }
        statusItem.button?.image = MenuIcon.image(mode: presentation.iconMode)
        statusItem.button?.toolTip = "Locked Gaze — \(presentation.status)"
        statusItem.button?.setAccessibilityLabel("Locked Gaze — \(presentation.status)")
        // Accessory apps do not normally appear in the Dock. If macOS shows a
        // Dock tile, keep its badge in sync without changing activation policy.
        NSApp.dockTile.badgeLabel = presentation.dockBadge
        for item in cameraMenu.items where item.action == #selector(selectCamera(_:)) {
            item.isEnabled = presentation.canSwitch
        }
        preview.model.mode = presentation.iconMode
        preview.model.canSelect = presentation.canSwitch
        modePanel.model.mode = presentation.mode
        modePanel.model.canSwitch = presentation.canSwitch
        modePanel.model.transition = presentation.canSwitch ? nil : presentation.status
        if loggedStatus != presentation.status {
            loggedStatus = presentation.status
            Logger(subsystem: CameraContract.appID, category: "Mode").notice("Status: \(presentation.status, privacy: .public)")
        }
        // Publish completed states; a request from the menu is published as it
        // is made (see chooseMode), so transitions in between add nothing.
        if state == .idle || state == .active || terminating {
            GazeControlState.publish(presentation.iconMode)
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildCameras() }
    private func cameraChoices() -> [CameraChoice] {
        CameraSession.availableCameras().map {
            CameraChoice(id: $0.uniqueID, name: $0.localizedName, connected: $0.isConnected)
        }
    }
    private func rebuildCameras() {
        SourceCameraMenu.populate(cameraMenu, devices: cameraChoices(), selectedID: selectedCameraID,
                                  enabled: state == .idle || state == .active,
                                  target: self, action: #selector(selectCamera(_:)))
    }
    private func updatePreviewCameras() {
        guard preview.isOpen else { return }
        preview.model.cameras = cameraChoices()
        preview.model.selectedID = selectedCameraID
    }
    /// Also runs just before the panel opens, so it does not wait for the panel to be visible.
    private func updatePanelCameras() {
        let devices = CameraSession.availableCameras()
        let symbols = Dictionary(devices.map { ($0.uniqueID, PanelCameraList.symbol(for: $0.deviceType)) },
                                 uniquingKeysWith: { first, _ in first })
        modePanel.model.cameras = PanelCameraList.rows(
            cameras: devices.map { CameraChoice(id: $0.uniqueID, name: $0.localizedName, connected: $0.isConnected) },
            symbols: symbols, selectedID: selectedCameraID)
    }
    @objc private func selectCamera(_ item: NSMenuItem) { chooseCamera(item.representedObject as? String) }
    /// One source camera setting serves the menu, the panel, the preview and the virtual camera.
    private func chooseCamera(_ id: String?) {
        defer {
            updatePreviewCameras()
            if modePanel.isOpen { updatePanelCameras() }
        }
        guard state == .idle || state == .active, id != selectedCameraID else { return }
        UserDefaults.standard.set(id, forKey: "sourceCameraID")
        rebuildCameras()
        guard state == .active else { syncPreview(); return }
        Task { do { try await lifecycle.restart() } catch { show(error) } }
    }
    /// While Locked Gaze is off, an open preview runs its own camera session without the
    /// virtual camera. Steps run one at a time; activation waits for them to finish.
    private func syncPreview() {
        let previous = previewSync
        previewSync = Task { [weak self] in
            await previous?.value
            await self?.reconcilePreview()
        }
    }
    private func reconcilePreview() async {
        let wanted = preview.isOpen && state == .idle && !terminating
        if let run = previewRun, !wanted || run.sourceID != selectedCameraID {
            previewRun = nil
            await previewCamera.stop()
        }
        guard wanted, previewRun == nil else { return }
        previewRun = PreviewRun(sourceID: selectedCameraID)
        preview.reset()
        do {
            try PlatformRequirements.requireSupported()
            guard let resources = Bundle.main.resourceURL else { throw GazeError.message("Application resources are missing.") }
            try await previewCamera.start(models: resources.appendingPathComponent("Models"),
                                          sourceID: selectedCameraID, publishing: false)
        } catch {
            previewRun = nil
            if !(error is CancellationError) { preview.fail(error) }
        }
    }
    private func previewFailed(_ error: Error) {
        preview.fail(error)
        let previous = previewSync
        previewSync = Task { [weak self] in
            await previous?.value
            guard let self, previewRun != nil else { return }
            previewRun = nil
            await previewCamera.stop()
        }
    }
    @objc private func showPreview() { preview.show() }
    @objc private func showAbout() { about.show() }
    @objc private func rateApp() { NSWorkspace.shared.open(AppStoreLinks.writeReview) }
    private func showWhatsNewAfterUpdate(launchedBefore: Bool) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let defaults = UserDefaults.standard
        if ReleaseNotes.shouldShow(lastLaunched: defaults.string(forKey: "lastLaunchedVersion"), current: version,
                                   launchedBefore: launchedBefore) {
            whatsNew.show(version: version)
        }
        defaults.set(version, forKey: "lastLaunchedVersion")
    }
    @objc private func chooseMode(_ item: NSMenuItem) {
        guard let mode = (item.representedObject as? String).flatMap(GazeMode.init(rawValue:)) else { return }
        requestMode(mode)
    }
    /// A mode chosen in the menu or the panel.
    private func requestMode(_ mode: GazeMode) {
        guard CameraPresentation(state: state, correcting: modes.correcting, closing: terminating).canSwitch else { return }
        // Show the request in Control Center while the menu or panel is still in use: macOS
        // applies a menu bar app's control reloads at once only while it is in the
        // foreground. The outcome is published again when the transition completes.
        GazeControlState.publish(mode)
        Task { do { try await setMode(mode) } catch { if !terminating { show(error) } } }
    }
    private func setMode(_ mode: GazeMode) async throws {
        guard !terminating else { throw GazeError.message("Locked Gaze is closing.") }
        try await modes.set(mode)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationDidBecomeActive(_ notification: Notification) {
        // Alerts and permission windows bring the app forward; resynchronize the
        // control then, e.g. after an activation requested from the menu failed.
        GazeControlState.reload()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        refresh()
        permissions.cancel()
        NSApp.abortModal()
        Task {
            await lifecycle.shutdown()
            syncPreview()
            await previewSync?.value
            sender.reply(toApplicationShouldTerminate: true)
        }
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
