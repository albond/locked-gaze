import Foundation
import CoreMediaIO
import CoreVideo

/// Producer side of the local CMIO sink. Call on the service main queue only.
final class CameraPublisher {
    private var device: CMIODeviceID = 0
    private var stream: CMIOStreamID = 0
    private var bufferQueue: CMSimpleQueue?
    private var format: CMVideoFormatDescription?

    private func ids(_ object: CMIOObjectID, selector: CMIOObjectPropertySelector,
                     scope: CMIOObjectPropertyScope = CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal)) throws -> [UInt32] {
        var address = CMIOObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        try check(CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size))
        guard size % 4 == 0 else { throw GazeError.message("Invalid CMIO property size") }
        var result = [UInt32](repeating: 0, count: Int(size) / 4)
        try result.withUnsafeMutableBytes { bytes in try check(CMIOObjectGetPropertyData(object, &address, 0, nil, size, &size, bytes.baseAddress)) }
        return result
    }
    private func uid(_ object: CMIOObjectID) throws -> String {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        try check(CMIOObjectGetPropertyData(object, &address, 0, nil, size, &size, &value))
        return value?.takeRetainedValue() as String? ?? ""
    }
    func start() throws {
        stop()
        var started = false
        defer { if !started { stop() } }
        var property = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        _ = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &property, 0, nil, 4, &allow)
        let devices = try ids(CMIOObjectID(kCMIOObjectSystemObject), selector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        for candidate in devices where try uid(candidate) == CameraContract.deviceUID {
            let streams = try ids(candidate, selector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams), scope: CMIOObjectPropertyScope(kCMIODevicePropertyScopeOutput))
            if let sink = streams.first { device = candidate; stream = sink; break }
        }
        guard stream != 0 else { throw CameraConnectionError.notReady }
        var queue: Unmanaged<CMSimpleQueue>?
        // CMIO may return no queue when no queue-altered callback is registered.
        // Our processing queue checks capacity before enqueueing, so no wakeup is needed.
        try check(CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &queue))
        bufferQueue = queue?.takeRetainedValue()
        guard bufferQueue != nil else { throw CameraConnectionError.notReady }
        try check(CMIODeviceStartStream(device, stream))
        try check(CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCVPixelFormatType_32BGRA,
            width: Int32(CameraContract.width), height: Int32(CameraContract.height), extensions: nil, formatDescriptionOut: &format))
        started = true
    }
    func send(_ pixelBuffer: CVPixelBuffer) throws {
        guard let bufferQueue, let format else { throw GazeError.message("Camera publisher is stopped") }
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        guard CMIOObjectHasProperty(device, &address) else { throw CameraConnectionError.notReady }
        guard CMSimpleQueueGetCount(bufferQueue) < CMSimpleQueueGetCapacity(bufferQueue) else { return }
        var timing = CMSampleTimingInfo(duration: CameraContract.frameDuration,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try check(CMSampleBufferCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample))
        guard let sample else { return }
        let pointer = Unmanaged.passRetained(sample).toOpaque()
        let status = CMSimpleQueueEnqueue(bufferQueue, element: pointer)
        if status != noErr { Unmanaged<CMSampleBuffer>.fromOpaque(pointer).release(); try check(status) }
    }
    func stop() {
        if stream != 0 { _ = CMIODeviceStopStream(device, stream) }
        // CMIO owns queued sample retains after enqueue; never drain concurrently.
        bufferQueue = nil; stream = 0; device = 0; format = nil
    }
    private func check(_ status: OSStatus) throws {
        if status != noErr { throw GazeError.message("Core Media I/O: \(status)") }
    }
    deinit { stop() }
}
