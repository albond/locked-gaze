import AVFoundation
import CoreImage
import CoreVideo
import Foundation

// Capture configuration lives on sessionQueue; models/pixels on processingQueue.
// CMIO publishing runs in an isolated XPC service. Lifecycle is main-actor isolated.
final class CameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let sessionQueue = DispatchQueue(label: "local.lockedgaze.capture")
    private let deliveryQueue = DispatchQueue(label: "local.lockedgaze.delivery", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "local.lockedgaze.processing", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let capture = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pipeline: LGFramePipeline?
    private var modelStore: ModelStore?
    private let publisher = CameraPublisherClient()
    private var inputPool: CVPixelBufferPool?
    private var outputPool: CVPixelBufferPool?
    private var failureReported = false
    private var processingGeneration = 0
    private struct Frame { let buffer: CVPixelBuffer; let receivedAt: TimeInterval }
    private var worker: LatestFrameWorker<Frame>!
    @MainActor private var observers: [NSObjectProtocol] = []
    @MainActor private var generation = 0
    @MainActor var onFailure: ((Error) -> Void)?

    override init() {
        super.init()
        worker = LatestFrameWorker(queue: processingQueue) { [weak self] frame in self?.process(frame) }
    }

    @MainActor func start(models: URL, sourceID: String? = nil) async throws {
        generation += 1
        let token = generation
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        guard generation == token else { throw CancellationError() }
        guard allowed else { throw GazeError.message("Allow Locked Gaze to access the camera in System Settings > Privacy & Security > Camera.") }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                processingQueue.async {
                    do {
                        self.modelStore = try ModelStore(directory: models)
                        self.pipeline = LGFramePipeline(models: self.modelStore!)
                        self.inputPool = try Self.makePool(); self.outputPool = try Self.makePool()
                        self.failureReported = false
                        self.processingGeneration = token
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            guard generation == token else { throw CancellationError() }
            try await StartupRetry.run {
                guard self.generation == token else { throw CancellationError() }
                try await self.publisher.start()
            }
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            await withCheckedContinuation { continuation in
                processingQueue.async { self.worker.begin(); continuation.resume() }
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sessionQueue.async {
                    do {
                        let device = try Self.physicalCamera(sourceID: sourceID)
                        let input = try AVCaptureDeviceInput(device: device)
                        self.capture.beginConfiguration()
                        defer { self.capture.commitConfiguration() }
                        self.capture.sessionPreset = .hd1280x720
                        guard self.capture.canAddInput(input), self.capture.canAddOutput(self.videoOutput) else { throw GazeError.message("Could not connect to the camera.") }
                        self.capture.addInput(input)
                        self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                        self.videoOutput.alwaysDiscardsLateVideoFrames = true
                        self.videoOutput.setSampleBufferDelegate(self, queue: self.deliveryQueue)
                        self.capture.addOutput(self.videoOutput)
                        if let connection = self.videoOutput.connection(with: .video), connection.isVideoMirroringSupported {
                            connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
                        }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            guard generation == token else { throw CancellationError() }
            let running = await withCheckedContinuation { continuation in
                sessionQueue.async { self.capture.startRunning(); continuation.resume(returning: self.capture.isRunning) }
            }
            guard generation == token else { throw CancellationError() }
            guard running else { throw GazeError.message("The camera could not start.") }
            for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: capture, queue: nil) { [weak self] _ in
                    self?.reportFailure(GazeError.message("The camera stream was interrupted. Reconnect your camera and activate Locked Gaze again."), token: token)
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] notification in
                guard let self, let removed = notification.object as? AVCaptureDevice else { return }
                let removedID = removed.uniqueID
                self.sessionQueue.async {
                    if self.capture.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).contains(where: { $0.device.uniqueID == removedID }) {
                        self.reportFailure(GazeError.message("The source camera was disconnected."), token: token)
                    }
                }
            })
        } catch { await stop(); throw error }
    }
    @MainActor func stop() async {
        generation += 1
        worker.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll()
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                self.capture.stopRunning()
                self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
                self.worker.stop()
                self.capture.beginConfiguration()
                for input in self.capture.inputs { self.capture.removeInput(input) }
                for output in self.capture.outputs { self.capture.removeOutput(output) }
                self.capture.commitConfiguration()
                self.processingQueue.async {
                    self.publisher.stop(); self.pipeline?.reset(); self.pipeline = nil; self.modelStore = nil
                    self.inputPool = nil; self.outputPool = nil
                    continuation.resume()
                }
            }
        }
    }
    static func availableCameras() -> [AVCaptureDevice] {
        let discovered = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
        let choices = CameraSelection.available(discovered.map {
            CameraChoice(id: $0.uniqueID, name: $0.localizedName, connected: $0.isConnected)
        }, virtualID: CameraContract.deviceUID)
        return choices.compactMap { choice in discovered.first { $0.uniqueID == choice.id } }
    }
    private static func physicalCamera(sourceID: String?) throws -> AVCaptureDevice {
        let available = availableCameras()
        let id = try CameraSelection.select(available.map {
            CameraChoice(id: $0.uniqueID, name: $0.localizedName, connected: $0.isConnected)
        }, requested: sourceID, preferred: [AVCaptureDevice.userPreferredCamera?.uniqueID,
                                           AVCaptureDevice.systemPreferredCamera?.uniqueID].compactMap { $0 })
        return available.first { $0.uniqueID == id }!
    }
    private static func makePool() throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: CameraContract.width,
            kCVPixelBufferHeightKey as String: CameraContract.height, kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else { throw GazeError.message("Cannot allocate frame pool") }
        return pool
    }
    private func allocate(_ pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, attributes, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        worker.submit(Frame(buffer: buffer, receivedAt: ProcessInfo.processInfo.systemUptime))
    }
    private func process(_ frame: Frame) {
        guard !failureReported, let pipeline, let inputPool, let outputPool,
              ProcessInfo.processInfo.systemUptime - frame.receivedAt < CameraContract.staleAfter,
              let corrected = allocate(outputPool) else { return }
        let cameraBuffer = frame.buffer
        autoreleasepool {
            do {
                let input: CVPixelBuffer
                if CVPixelBufferGetWidth(cameraBuffer) == CameraContract.width && CVPixelBufferGetHeight(cameraBuffer) == CameraContract.height { input = cameraBuffer }
                else {
                    guard let normalized = allocate(inputPool) else { return }
                    let image = CIImage(cvPixelBuffer: cameraBuffer)
                    let scale = min(CGFloat(CameraContract.width) / image.extent.width, CGFloat(CameraContract.height) / image.extent.height)
                    let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    let centered = scaled.transformed(by: CGAffineTransform(translationX: (CGFloat(CameraContract.width) - scaled.extent.width) / 2, y: (CGFloat(CameraContract.height) - scaled.extent.height) / 2))
                    let background = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: CameraContract.width, height: CameraContract.height))
                    context.render(centered.composited(over: background), to: normalized)
                    input = normalized
                }
                try pipeline.processPixelBuffer(input, into: corrected)
                if ProcessInfo.processInfo.systemUptime - frame.receivedAt < CameraContract.staleAfter {
                    try publisher.send(corrected)
                }
            } catch {
                failureReported = true
                worker.stop()
                self.deliverFailure(error, token: self.processingGeneration)
            }
        }
    }
    private func deliverFailure(_ error: Error, token: Int) {
        DispatchQueue.main.async {
            guard self.generation == token else { return }
            self.onFailure?(error)
        }
    }
    private func reportFailure(_ error: Error, token: Int) {
        processingQueue.async {
            guard token == self.processingGeneration, !self.failureReported else { return }
            self.worker.stop()
            self.failureReported = true
            self.deliverFailure(error, token: token)
        }
    }
}
