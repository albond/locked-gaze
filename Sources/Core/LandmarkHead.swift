import Foundation
import CoreML
import Metal

/// CNN heatmaps remain FP16; normalization, thresholding and central moments
/// execute in FP32. Buffers and command queue are reused on the processing queue.
final class LandmarkHead {
    private struct Spec: Decodable {
        let version: Int, channels: [Int], width: Int, height: Int
        let alpha: Float, threshold: Float
        let keypoint_weights: [[Float]], keypoint_bias: [Float]
        let confidence_weights: [[Float]], confidence_bias: [Float]
        let confidence_a: [Float], confidence_b: [Float]
    }
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let kernel: MTLComputePipelineState
    private let weights: MTLBuffer, moments: MTLBuffer
    private let backingBuffer: MTLBuffer
    private var input: MTLBuffer?
    let outputBacking: MLMultiArray
    private let spec: Spec
    private let pointRows: [[(Int, Float)]], confidenceRows: [[(Int, Float)]]

    init(data: Data) throws {
        spec = try JSONDecoder().decode(Spec.self, from: data)
        guard spec.version == 1, spec.channels.count == 72, Set(spec.channels).count == 72,
              spec.width == 160, spec.height == 160, spec.alpha == 0.01, spec.threshold == 1e-5,
              spec.keypoint_weights.count == 136, spec.keypoint_weights.allSatisfy({ $0.count == 144 }),
              spec.confidence_weights.count == 68, spec.confidence_weights.allSatisfy({ $0.count == 72 }),
              spec.keypoint_bias.count == 136, spec.confidence_bias.count == 68,
              spec.confidence_a.count == 72, spec.confidence_b.count == 72,
              spec.confidence_a.allSatisfy({ $0.isFinite && $0 != 0 }),
              spec.keypoint_weights.joined().allSatisfy(\.isFinite),
              spec.confidence_weights.joined().allSatisfy(\.isFinite),
              (spec.keypoint_bias + spec.confidence_bias + spec.confidence_b).allSatisfy(\.isFinite),
              let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let input = device.makeBuffer(length: 72 * 25600 * 2, options: .storageModeShared),
              let weights = device.makeBuffer(length: 72 * 25600 * 4, options: .storageModeShared),
              let moments = device.makeBuffer(length: 72 * 4 * 4, options: .storageModeShared) else {
            throw GazeError.message("Invalid native landmark head or unavailable Metal device")
        }
        self.device = device; self.queue = queue; self.weights = weights; self.moments = moments
        self.input = input
        backingBuffer = input
        outputBacking = try MLMultiArray(dataPointer: input.contents(), shape: [1, 72, 160, 160], dataType: .float16,
                                        strides: [72 * 25600, 25600, 160, 1].map { NSNumber(value: $0) }, deallocator: nil)
        let options = MTLCompileOptions(); options.fastMathEnabled = false
        let library = try device.makeLibrary(source: Self.source, options: options)
        guard let function = library.makeFunction(name: "heatmap_moments") else { throw GazeError.message("Missing Metal landmark kernel") }
        kernel = try device.makeComputePipelineState(function: function)
        guard kernel.maxTotalThreadsPerThreadgroup >= 256 else { throw GazeError.message("Unsupported Metal threadgroup size") }
        pointRows = spec.keypoint_weights.map { row in row.enumerated().compactMap { $0.element == 0 ? nil : ($0.offset, $0.element) } }
        confidenceRows = spec.confidence_weights.map { row in row.enumerated().compactMap { $0.element == 0 ? nil : ($0.offset, $0.element) } }
    }

    func decode(_ tensor: MLMultiArray, outputs: [String: LGTensorBuffer]) throws {
        guard tensor.dataType == .float16, tensor.shape.map(\.intValue) == [1, 72, 160, 160],
              let points = outputs["kpts"], points.count == 136,
              let confidence = outputs["confidence"], confidence.count == 68 else { throw GazeError.message("Invalid landmark heatmaps") }
        let strides = tensor.strides.map(\.intValue)
        guard strides.allSatisfy({ $0 > 0 }) else { throw GazeError.message("Invalid heatmap strides") }
        let elements = 71 * strides[1] + 159 * strides[2] + 159 * strides[3] + 1
        guard elements <= 72 * 25600 * 4 else { throw GazeError.message("Unbounded heatmap storage") }
        if input == nil || input!.length < elements * 2 { input = device.makeBuffer(length: elements * 2, options: .storageModeShared) }
        guard let input, let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw GazeError.message("Cannot allocate Metal command") }
        if input.contents() != tensor.dataPointer { memcpy(input.contents(), tensor.dataPointer, elements * 2) }
        encoder.setComputePipelineState(kernel)
        encoder.setBuffer(input, offset: 0, index: 0); encoder.setBuffer(weights, offset: 0, index: 1)
        encoder.setBuffer(moments, offset: 0, index: 2)
        var layout = SIMD4<UInt32>(UInt32(strides[1]), UInt32(strides[2]), UInt32(strides[3]), 0)
        encoder.setBytes(&layout, length: MemoryLayout.size(ofValue: layout), index: 3)
        encoder.dispatchThreadgroups(MTLSize(width: 72, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? GazeError.message("Metal landmark inference failed") }
        let values = moments.contents().assumingMemoryBound(to: Float.self)
        var coordinates = [Float](repeating: 0, count: 144), scores = [Float](repeating: 0, count: 72)
        for channel in 0..<72 {
            let x = values[channel * 4], y = values[channel * 4 + 1], variance = values[channel * 4 + 2]
            guard x.isFinite && y.isFinite && variance.isFinite else { throw GazeError.message("Non-finite landmark moments") }
            coordinates[channel] = x; coordinates[72 + channel] = y
            scores[channel] = 1 - min(1, max(0, (0.5 * variance + spec.confidence_b[channel]) / spec.confidence_a[channel]))
        }
        let pointTarget = points.pointer.assumingMemoryBound(to: Float.self), confidenceTarget = confidence.pointer.assumingMemoryBound(to: Float.self)
        for i in 0..<136 { pointTarget[i] = pointRows[i].reduce(spec.keypoint_bias[i]) { $0 + coordinates[$1.0] * $1.1 } }
        for i in 0..<68 { confidenceTarget[i] = confidenceRows[i].reduce(spec.confidence_bias[i]) { $0 + scores[$1.0] * $1.1 } }
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    inline float4 sum_group(float4 value, threadgroup float4 *scratch, uint tid) {
        scratch[tid] = value; threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint stride = 128; stride > 0; stride >>= 1) {
            if (tid < stride) scratch[tid] += scratch[tid + stride];
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        float4 result = scratch[0]; threadgroup_barrier(mem_flags::mem_threadgroup); return result;
    }
    kernel void heatmap_moments(device const half *input [[buffer(0)]],
        device float *weights [[buffer(1)]], device float4 *output [[buffer(2)]],
        constant uint4 &layout [[buffer(3)]], uint channel [[threadgroup_position_in_grid]],
        uint tid [[thread_index_in_threadgroup]]) {
        threadgroup float4 scratch[256];
        float maximum = -INFINITY;
        for (uint i = tid; i < 25600; i += 256) {
            float x = float(input[channel * layout.x + (i / 160) * layout.y + (i % 160) * layout.z]);
            x = x < 0 ? x * 0.01f : x; maximum = isfinite(x) ? max(maximum, x) : INFINITY;
        }
        scratch[tid].x = maximum; threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint stride = 128; stride > 0; stride >>= 1) {
            if (tid < stride) scratch[tid].x = max(scratch[tid].x, scratch[tid + stride].x);
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        maximum = scratch[0].x; threadgroup_barrier(mem_flags::mem_threadgroup);
        float sum = 0;
        for (uint i = tid; i < 25600; i += 256) {
            float x = float(input[channel * layout.x + (i / 160) * layout.y + (i % 160) * layout.z]);
            x = x < 0 ? x * 0.01f : x;
            float value = exp(x - maximum); weights[channel * 25600 + i] = value; sum += value;
        }
        float denominator = sum_group(float4(sum, 0, 0, 0), scratch, tid).x;
        threadgroup_barrier(mem_flags::mem_device);
        float2 mean = float2(0);
        for (uint i = tid; i < 25600; i += 256) {
            float p = weights[channel * 25600 + i] / denominator;
            p = p < 1e-5f ? 0 : p; weights[channel * 25600 + i] = p;
            mean += p * float2(i % 160, i / 160);
        }
        mean = sum_group(float4(mean, 0, 0), scratch, tid).xy;
        threadgroup_barrier(mem_flags::mem_device);
        float2 variance = float2(0);
        for (uint i = tid; i < 25600; i += 256) {
            float2 d = float2(i % 160, i / 160) - mean;
            variance += weights[channel * 25600 + i] * d * d;
        }
        variance = sum_group(float4(variance, 0, 0), scratch, tid).xy;
        if (tid == 0) output[channel] = float4(mean, variance.x + variance.y, 0);
    }
    """
}
