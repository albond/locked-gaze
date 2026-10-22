import CoreVideo
import Foundation

/// Hands the newest original/corrected pair to the preview window. Frames are
/// copied into the feed's own small pool, so the preview never holds capture or
/// virtual-camera buffers; at most one pair waits for the main thread.
final class PreviewFeed: @unchecked Sendable {
    struct Frame { let original: CVPixelBuffer; let corrected: CVPixelBuffer }
    /// Displayed, waiting and in-copy pairs.
    static let poolLimit = 6
    private let lock = NSLock()
    private let width: Int
    private let height: Int
    private let pool: CVPixelBufferPool?
    private var enabled = false
    private var pending: Frame?
    private var scheduled = false
    @MainActor var display: ((Frame) -> Void)?

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        self.pool = pool
    }

    var isEnabled: Bool { lock.withLock { enabled } }

    /// Enabling or disabling drops a waiting pair, so a new session never shows an old frame.
    func setEnabled(_ value: Bool) { lock.withLock { enabled = value; pending = nil } }

    /// Called on a processing queue. Frames must be 32BGRA at the feed size.
    func submit(original: CVPixelBuffer, corrected: CVPixelBuffer) {
        guard lock.withLock({ enabled }), let original = copy(original), let corrected = copy(corrected) else { return }
        let schedule: Bool = lock.withLock {
            guard enabled else { return false }
            pending = Frame(original: original, corrected: corrected)
            defer { scheduled = true }
            return !scheduled
        }
        if schedule { DispatchQueue.main.async { MainActor.assumeIsolated { self.deliver() } } }
    }

    @MainActor private func deliver() {
        let frame: Frame? = lock.withLock {
            defer { pending = nil; scheduled = false }
            return pending
        }
        if let frame { display?(frame) }
    }

    private func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool, CVPixelBufferGetWidth(source) == width, CVPixelBufferGetHeight(source) == height,
              CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else { return nil }
        var target: CVPixelBuffer?
        let limit = [kCVPixelBufferPoolAllocationThresholdKey: Self.poolLimit] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limit, &target) == kCVReturnSuccess,
              let target else { return nil }
        return PixelCopy.bgra(from: source, to: target) ? target : nil
    }
}
