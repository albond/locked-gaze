import Foundation
import CoreMediaIO
import CoreVideo
import IOKit.audio
import OSLog
import Security

final class CameraProvider: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private let camera: CameraDevice
    init(queue: DispatchQueue) throws {
        camera = try CameraDevice(queue: queue)
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: queue)
        try provider.addDevice(camera.device)
    }
    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }
    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:]); result.manufacturer = "Locked Gaze"; return result
    }
    func setProviderProperties(_ properties: CMIOExtensionProviderProperties) throws {}
    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) { camera.disconnected(client) }
}

final class CameraDevice: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var source: CameraStream!
    private var sink: CameraStream!
    private let queue: DispatchQueue
    private let format: CMVideoFormatDescription
    private let black: CVPixelBuffer
    private var sourceTimer: DispatchSourceTimer?
    private var sinkTimer: DispatchSourceTimer?
    private var readers = 0
    private var sinkClient: CMIOExtensionClient?
    private var selectedSink: CMIOExtensionClient?
    private var pending = false
    private var generation = 0
    private var mailbox = FrameMailbox<CVPixelBuffer>(lifetime: CameraContract.staleAfter)

    init(queue: DispatchQueue) throws {
        self.queue = queue
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCVPixelFormatType_32BGRA,
            width: Int32(CameraContract.width), height: Int32(CameraContract.height), extensions: nil, formatDescriptionOut: &description)
        guard let description else { throw NSError(domain: "LockedGazeCamera", code: 1) }
        format = description
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, CameraContract.width, CameraContract.height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw NSError(domain: "LockedGazeCamera", code: 2) }
        black = buffer
        CVPixelBufferLockBaseAddress(black, [])
        let bytes = CVPixelBufferGetBaseAddress(black)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(black)
        memset(bytes, 0, rowBytes * CameraContract.height)
        for y in 0..<CameraContract.height { for x in 0..<CameraContract.width { bytes[y * rowBytes + x * 4 + 3] = 255 } }
        CVPixelBufferUnlockBaseAddress(black, [])
        super.init()
        device = CMIOExtensionDevice(localizedName: "Locked Gaze", deviceID: CameraContract.deviceID,
                                     legacyDeviceID: CameraContract.deviceUID, source: self)
        let streamFormat = CMIOExtensionStreamFormat(formatDescription: format,
            maxFrameDuration: CameraContract.frameDuration, minFrameDuration: CameraContract.frameDuration, validFrameDurations: nil)
        source = CameraStream(owner: self, format: streamFormat, isSink: false)
        sink = CameraStream(owner: self, format: streamFormat, isSink: true)
        try device.addStream(source.stream)
        try device.addStream(sink.stream)
    }
    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }
    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        result.transportType = kIOAudioDeviceTransportTypeVirtual; result.model = "Locked Gaze"; return result
    }
    func setDeviceProperties(_ properties: CMIOExtensionDeviceProperties) throws {}
    func authorize(_ client: CMIOExtensionClient, sink: Bool) -> Bool {
        guard sink else { return true }
        guard isTrustedProducer(client),
              sinkClient == nil || sinkClient?.clientID == client.clientID else { return false }
        selectedSink = client
        return true
    }
    private func isTrustedProducer(_ client: CMIOExtensionClient) -> Bool {
        // CMIO can report "unknown" for signingID even for a signed host app.
        // Validate the actual process against our own signing team instead.
        var ownCode: SecCode?
        var ownStaticCode: SecStaticCode?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCopyStaticCode(ownCode, [], &ownStaticCode) == errSecSuccess, let ownStaticCode,
              let team = ProducerAuthorization.teamIdentifier(of: ownStaticCode),
              let authorization = ProducerAuthorization(teamIdentifier: team) else {
            Logger(subsystem: CameraContract.extensionID, category: "authorization").error("Cannot establish the camera extension signing identity")
            return false
        }
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: client.pid),
                          kSecGuestAttributeDynamicCode as String: true] as CFDictionary
        let lookup = SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest)
        guard lookup == errSecSuccess, let guest else {
            Logger(subsystem: CameraContract.extensionID, category: "authorization").error("Producer code lookup failed: \(lookup)")
            return false
        }
        let status = authorization.validate(guest)
        Logger(subsystem: CameraContract.extensionID, category: "authorization").notice("Producer signature validation: \(status)")
        return status == errSecSuccess
    }
    func start(isSink: Bool) throws {
        if isSink {
            guard sinkTimer == nil, let selectedSink else { return }
            sinkClient = selectedSink; generation += 1
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(8))
            timer.setEventHandler { [weak self] in self?.consume() }
            sinkTimer = timer; timer.resume()
        } else {
            readers += 1
            guard sourceTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.sendFrame() }
            sourceTimer = timer; timer.resume()
        }
    }
    func stop(isSink: Bool) {
        if isSink {
            generation += 1; sinkTimer?.cancel(); sinkTimer = nil; sinkClient = nil; selectedSink = nil
            mailbox.reset(); pending = false
        } else {
            readers = max(0, readers - 1)
            if readers == 0 { sourceTimer?.cancel(); sourceTimer = nil }
        }
    }
    func disconnected(_ client: CMIOExtensionClient) {
        if client.clientID == sinkClient?.clientID { stop(isSink: true) }
    }
    private func consume() {
        guard !pending, let client = sinkClient else { return }
        pending = true
        let token = generation
        sink.stream.consumeSampleBuffer(from: client) { [weak self] sample, sequence, _, more, error in
            guard let self else { return }
            self.queue.async {
                guard self.generation == token else { return }
                self.pending = false
                if error == nil, let sample, let buffer = CMSampleBufferGetImageBuffer(sample),
                   CVPixelBufferGetWidth(buffer) == CameraContract.width, CVPixelBufferGetHeight(buffer) == CameraContract.height,
                   CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA {
                    self.mailbox.append(buffer, at: ProcessInfo.processInfo.systemUptime)
                    let host = CMClockGetTime(CMClockGetHostTimeClock())
                    self.sink.stream.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: UInt64(host.seconds * 1e9)))
                }
                if more { self.consume() }
            }
        }
    }
    private func sendFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        let buffer = mailbox.frame(at: now) ?? black
        var timing = CMSampleTimingInfo(duration: CameraContract.frameDuration,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(allocator: nil, imageBuffer: buffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        if status == noErr, let sample {
            source.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * 1e9))
        }
    }
}

final class CameraStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private unowned let owner: CameraDevice
    private let format: CMIOExtensionStreamFormat
    private let isSink: Bool
    init(owner: CameraDevice, format: CMIOExtensionStreamFormat, isSink: Bool) {
        self.owner = owner; self.format = format; self.isSink = isSink
        super.init()
        stream = CMIOExtensionStream(localizedName: isSink ? "Locked Gaze Input" : "Locked Gaze Video",
            streamID: isSink ? CameraContract.sinkID : CameraContract.sourceID,
            direction: isSink ? .sink : .source, clockType: .hostTime, source: self)
    }
    var formats: [CMIOExtensionStreamFormat] { [format] }
    var availableProperties: Set<CMIOExtensionProperty> {
        var result: Set<CMIOExtensionProperty> = [.streamActiveFormatIndex, .streamFrameDuration]
        if isSink { result.formUnion([.streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup, .streamSinkEndOfData]) }
        return result
    }
    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        result.activeFormatIndex = 0; result.frameDuration = CameraContract.frameDuration
        if isSink { result.sinkBufferQueueSize = 2; result.sinkBuffersRequiredForStartup = 1; result.sinkEndOfData = 0 }
        return result
    }
    func setStreamProperties(_ properties: CMIOExtensionStreamProperties) throws {
        if let index = properties.activeFormatIndex, index != 0 { throw NSError(domain: "LockedGazeCamera", code: 3) }
        if let duration = properties.frameDuration, duration != CameraContract.frameDuration { throw NSError(domain: "LockedGazeCamera", code: 4) }
    }
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { owner.authorize(client, sink: isSink) }
    func startStream() throws { try owner.start(isSink: isSink) }
    func stopStream() throws { owner.stop(isSink: isSink) }
}
