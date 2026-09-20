import Foundation
import CoreVideo

final class FakeModels: NSObject, LGModelProvider {
    enum Mode { case empty, nonfinite, failure, lowConfidence, degenerate, landmarkFailure, infinite, extremeBox }
    var mode: Mode = .empty
    var calls = 0
    func predictModel(_ name: String, inputs: [String: LGTensorBuffer], outputs: [String: LGTensorBuffer]) throws {
        calls += 1
        if mode == .failure { throw NSError(domain: "Test", code: 4, userInfo: [NSLocalizedDescriptionKey: "Injected model error"]) }
        for output in outputs.values {
            let values = output.pointer.assumingMemoryBound(to: Float.self)
            values.update(repeating: 0, count: Int(output.count))
            if mode == .nonfinite { values[0] = .nan }
            if mode == .infinite { values[0] = .infinity }
        }
        if mode == .extremeBox {
            outputs["output_cov/Sigmoid"]!.pointer.assumingMemoryBound(to: Float.self)[6 * 23 + 11] = 1
            let bbox = outputs["output_bbox"]!.pointer.assumingMemoryBound(to: Float.self)
            for channel in 0..<4 { bbox[channel * 299 + 6 * 23 + 11] = 1e20 }
        }
        if [.lowConfidence, .degenerate, .landmarkFailure].contains(mode) {
            if name == "face" {
                outputs["output_cov/Sigmoid"]!.pointer.assumingMemoryBound(to: Float.self)[6 * 23 + 11] = 1
                let bbox = outputs["output_bbox"]!.pointer.assumingMemoryBound(to: Float.self)
                for channel in 0..<4 { bbox[channel * 299 + 6 * 23 + 11] = 1 }
            } else if name == "landmarks" {
                if mode == .landmarkFailure { throw NSError(domain: "Test", code: 5) }
                outputs["kpts"]!.pointer.assumingMemoryBound(to: Float.self).update(repeating: 80, count: 136)
                if mode == .degenerate { outputs["confidence"]!.pointer.assumingMemoryBound(to: Float.self).update(repeating: 1, count: 68) }
            } else { preconditionFailure("Unsafe geometry must skip encoder and decoder") }
        }
    }
}
func makeBuffer(_ width: Int, _ height: Int, format: OSType = kCVPixelFormatType_32BGRA) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, width, height, format, nil, &buffer) == kCVReturnSuccess)
    return buffer!
}
func fill(_ buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    let ptr = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<CVPixelBufferGetHeight(buffer) { for x in 0..<CVPixelBufferGetWidth(buffer) {
        ptr[y * stride + x * 4] = UInt8((x + y) % 256)
        ptr[y * stride + x * 4 + 1] = UInt8(x % 256)
        ptr[y * stride + x * 4 + 2] = UInt8(y % 256)
        ptr[y * stride + x * 4 + 3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(buffer, [])
}
func pixels(_ buffer: CVPixelBuffer) -> Data {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    var result = Data()
    let pointer = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<CVPixelBufferGetHeight(buffer) { result.append(pointer + y * CVPixelBufferGetBytesPerRow(buffer), count: CVPixelBufferGetWidth(buffer) * 4) }
    return result
}
func expectFailure(_ body: () throws -> Void) {
    var failed = false
    do { try body() } catch { failed = true }
    precondition(failed, "Expected an error")
}

let models = FakeModels()
let pipeline = LGFramePipeline(models: models)
let input = makeBuffer(320, 180), output = makeBuffer(320, 180)
fill(input)
try pipeline.processPixelBuffer(input, into: output)
precondition(pipeline.lastStatus == "bypass" && pipeline.lastReason == "no_face")
precondition(pixels(input) == pixels(output), "Bypass must preserve all pixels")
precondition(models.calls == 1, "No-face path must skip the other three models")
models.mode = .nonfinite
expectFailure { try pipeline.processPixelBuffer(input, into: output) }
precondition(pipeline.lastStatus == "error")
models.mode = .failure
expectFailure { try pipeline.processPixelBuffer(input, into: output) }
precondition(pipeline.lastReason == "Injected model error")
let mismatched = makeBuffer(160, 90)
expectFailure { try pipeline.processPixelBuffer(input, into: mismatched) }
let invalid = makeBuffer(320, 180, format: kCVPixelFormatType_32ARGB)
expectFailure { try pipeline.processPixelBuffer(invalid, into: output) }
let tiny = makeBuffer(8, 8)
expectFailure { try pipeline.processPixelBuffer(tiny, into: tiny) }
pipeline.reset(); models.mode = .empty
try pipeline.processPixelBuffer(input, into: output)
precondition(pixels(input) == pixels(output), "Recovery after reset must be clean")
print("PASS: bypass preserves pixels; skips inference; rejects NaN, model failure, invalid formats/sizes; reset recovers")

for (mode, reason) in [(FakeModels.Mode.lowConfidence, "landmark_confidence"), (.degenerate, "invalid_face_geometry")] {
    pipeline.reset(); models.mode = mode; models.calls = 0
    try pipeline.processPixelBuffer(input, into: output)
    precondition(pipeline.lastStatus == "bypass" && pipeline.lastReason == reason)
    precondition(models.calls == 2 && pixels(output) == pixels(input), "Unsafe face must bypass unchanged")
}
for mode in [FakeModels.Mode.infinite, .landmarkFailure] {
    pipeline.reset(); models.mode = mode
    expectFailure { try pipeline.processPixelBuffer(input, into: output) }
    models.mode = .empty; pipeline.reset()
    try pipeline.processPixelBuffer(input, into: output)
    precondition(pixels(input) == pixels(output))
}
for (width, height) in [(16, 16), (321, 181), (180, 320), (1280, 720), (4096, 16)] {
    let source = makeBuffer(width, height), destination = makeBuffer(width, height)
    fill(source); models.mode = .empty
    try pipeline.processPixelBuffer(source, into: destination)
    precondition(pixels(source) == pixels(destination), "Bypass handles orientation, bounds and padded row strides")
}
let tooLarge = makeBuffer(4097, 16)
expectFailure { try pipeline.processPixelBuffer(tooLarge, into: tooLarge) }
models.mode = .empty; pipeline.reset(); pipeline.profilingEnabled = true
try pipeline.processPixelBuffer(input, into: output)
precondition(!pipeline.lastStageTimings.isEmpty)
pipeline.reset()
precondition(pipeline.lastStageTimings.isEmpty, "Reset must clear previous diagnostics")
expectFailure { try pipeline.processPixelBuffer(input, into: invalid) }
precondition(pipeline.lastStatus == "error", "Rejected buffers must not report the previous successful status")
print("PASS: low confidence, degenerate geometry, landmark failure, infinity, portrait/padded/boundary buffers, diagnostics reset")

pipeline.reset(); models.mode = .extremeBox
try pipeline.processPixelBuffer(input, into: output)
precondition(pipeline.lastStatus == "bypass" && pipeline.lastReason == "invalid_face_box")
precondition(pixels(input) == pixels(output), "Huge finite detections must bypass without allocation or integer overflow")
print("PASS: unbounded finite detection rejected safely")
