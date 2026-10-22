import CoreVideo
import Foundation

enum PixelCopy {
    /// Copies 32BGRA rows between buffers of the same size; strides may differ. Colour attachments follow.
    static func bgra(from source: CVPixelBuffer, to target: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        guard width == CVPixelBufferGetWidth(target), height == CVPixelBufferGetHeight(target),
              CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(target) == kCVPixelFormatType_32BGRA else { return false }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(target, [])
        defer {
            CVPixelBufferUnlockBaseAddress(target, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(target) else { return false }
        let sourceStride = CVPixelBufferGetBytesPerRow(source), targetStride = CVPixelBufferGetBytesPerRow(target)
        for row in 0..<height { memcpy(to + row * targetStride, from + row * sourceStride, width * 4) }
        CVBufferPropagateAttachments(source, target)
        return true
    }
}
