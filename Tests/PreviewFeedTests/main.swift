import CoreVideo
import Foundation

// Synthetic buffers only; the main run loop stands in for the preview window.
let width = 96, height = 54

func makeBuffer(seed: UInt8, alignment: Int = 64, format: OSType = kCVPixelFormatType_32BGRA,
                size: (Int, Int) = (width, height)) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferBytesPerRowAlignmentKey: alignment] as CFDictionary
    precondition(CVPixelBufferCreate(nil, size.0, size.1, format, attributes, &buffer) == kCVReturnSuccess)
    CVPixelBufferLockBaseAddress(buffer!, [])
    let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer!)
    for row in 0..<size.1 { for column in 0..<stride { base[row * stride + column] = UInt8(truncatingIfNeeded: row &* 7 &+ column &+ Int(seed)) } }
    CVPixelBufferUnlockBaseAddress(buffer!, [])
    return buffer!
}

func samePixels(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Bool {
    CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    let strideA = CVPixelBufferGetBytesPerRow(a), strideB = CVPixelBufferGetBytesPerRow(b)
    let baseA = CVPixelBufferGetBaseAddress(a)!, baseB = CVPixelBufferGetBaseAddress(b)!
    return (0..<height).allSatisfy { memcmp(baseA + $0 * strideA, baseB + $0 * strideB, width * 4) == 0 }
}

func pumpMain() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

let feed = PreviewFeed(width: width, height: height)
var delivered: [PreviewFeed.Frame] = []
MainActor.assumeIsolated { feed.display = { delivered.append($0) } }

feed.submit(original: makeBuffer(seed: 1), corrected: makeBuffer(seed: 2))
pumpMain()
precondition(delivered.isEmpty, "A disabled feed must not copy or deliver")
print("PASS: disabled feed delivers nothing")

feed.setEnabled(true)
let originals = (0..<40).map { makeBuffer(seed: UInt8($0)) }
let corrected = (0..<40).map { makeBuffer(seed: UInt8(100 + $0), alignment: 256) }
for index in 0..<40 { feed.submit(original: originals[index], corrected: corrected[index]) }
pumpMain()
precondition(delivered.count == 1, "Only the newest pair may wait for the main thread")
precondition(samePixels(delivered[0].original, originals[39]) && samePixels(delivered[0].corrected, corrected[39]))
precondition(delivered[0].original !== originals[39] && delivered[0].corrected !== corrected[39],
             "The preview must hold its own copies")
print("PASS: latest-only delivery, pixel-exact copies across padded strides")

let tagged = makeBuffer(seed: 3)
CVBufferSetAttachment(tagged, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
delivered.removeAll()
feed.submit(original: tagged, corrected: makeBuffer(seed: 4))
pumpMain()
precondition(delivered.count == 1)
let primaries = CVBufferCopyAttachment(delivered[0].original, kCVImageBufferColorPrimariesKey, nil) as? String
precondition(primaries == kCVImageBufferColorPrimaries_ITU_R_709_2 as String, "Colour attachments must follow the copy")
print("PASS: colour attachments propagate")

delivered.removeAll()
feed.submit(original: makeBuffer(seed: 5, size: (width + 2, height)), corrected: makeBuffer(seed: 6))
feed.submit(original: makeBuffer(seed: 7, format: kCVPixelFormatType_32ARGB), corrected: makeBuffer(seed: 8))
pumpMain()
precondition(delivered.isEmpty, "Unexpected sizes or formats are skipped")
print("PASS: mismatched size and format rejected")

feed.submit(original: makeBuffer(seed: 9), corrected: makeBuffer(seed: 10))
feed.setEnabled(false)
pumpMain()
precondition(delivered.isEmpty, "Disabling drops the waiting pair")
feed.setEnabled(true)
pumpMain()
precondition(delivered.isEmpty, "Re-enabling must not show a frame from before")
print("PASS: disable drops a waiting pair; re-enable starts clean")

// The window keeps every delivered pair: the pool must refuse to grow past its limit.
for index in 0..<10 {
    feed.submit(original: makeBuffer(seed: UInt8(20 + index)), corrected: makeBuffer(seed: UInt8(40 + index)))
    pumpMain()
}
precondition(delivered.count == PreviewFeed.poolLimit / 2, "Held pairs: \(delivered.count)")
delivered.removeAll()
feed.submit(original: makeBuffer(seed: 60), corrected: makeBuffer(seed: 61))
pumpMain()
precondition(delivered.count == 1, "Releasing held frames makes the pool usable again")
print("PASS: preview pool stays bounded and recovers")
print("All preview feed checks passed")
