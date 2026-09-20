import Foundation
import CoreML
import CryptoKit

/// Confined to the processing queue. Loads compiled models once per activation.
final class ModelStore: NSObject, LGModelProvider {
    static let sourceHashes = [
        "face": "5c50a841191a32f947080dedc3a846791832521f2d885b2cff2da1060d1ff238",
        "landmarks": "35530d2d266932cf6d4140ad536a313bb5a2d542be25bf01062abfa833544ead",
        "encoder": "fb874567c0eff68aea1bd0f03f99de9f0b2595af381e127b18ea6f65f77dcacf",
        "decoder": "6fb208ffdae4a399b39aa63559fd6fa50ea361141b8ed0af4c06f262ba1ff67d"
    ]
    static let shapes: [String: [String: [Int]]] = [
        "face": ["input": [1, 3, 208, 368]],
        "landmarks": ["input": [1, 1, 160, 160]],
        "encoder": ["input_image": [1, 3, 64, 256]],
        "decoder": ["embeddings_flat": [1, 1344], "pseudo_labels_flat": [1, 12], "gaze_por": [1, 2]]
    ]
    static let outputShapes: [String: [String: [Int]]] = [
        "face": ["output_bbox": [1, 4, 13, 23], "output_cov/Sigmoid": [1, 1, 13, 23]],
        "landmarks": ["kpts": [1, 136], "confidence": [1, 68]],
        "encoder": ["embeddings_flat": [1, 1344], "pseudo_labels_flat": [1, 12]],
        "decoder": ["gaze_redirected_image": [1, 3, 64, 256], "gaze_landmarks": [1, 2, 12, 1]]
    ]
    private var models: [String: MLModel] = [:]
    private var mappings: [String: [String: String]] = [:]
    private var landmarkHead: LandmarkHead?
    private(set) var timings: [String: [Double]] = [:]
    func resetTimings() { timings.removeAll(keepingCapacity: true) }

    init(directory: URL, computeUnits: MLComputeUnits = .all) throws {
        super.init()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        for key in Self.shapes.keys.sorted() {
            let url = directory.appendingPathComponent("\(key).mlmodelc")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw GazeError.message("Model \(key) is missing. Rebuild the app.")
            }
            let model = try MLModel(contentsOf: url, configuration: configuration)
            let data = try Data(contentsOf: directory.appendingPathComponent("\(key).json"))
            guard let spec = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mapping = spec["outputs"] as? [String: String],
                  Set(mapping.values).count == mapping.count else {
                throw GazeError.message("Invalid model contract: \(key).")
            }
            let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
            let nativeHead = spec["native_head"] as? String
            var modelOutputs = Self.outputShapes[key]!
            if let nativeHead {
                guard key == "landmarks", nativeHead == "metal-moments-v1", metadata["native_head"] == nativeHead,
                      Set(mapping.keys) == ["heatmaps"] else { throw GazeError.message("Invalid native landmark contract") }
                let headData = try Data(contentsOf: directory.appendingPathComponent("landmarks.head.json"))
                let digest = SHA256.hash(data: headData).map { String(format: "%02x", $0) }.joined()
                guard digest == metadata["head_sha256"], digest == spec["head_sha256"] as? String else {
                    throw GazeError.message("Landmark head identity mismatch")
                }
                landmarkHead = try LandmarkHead(data: headData)
                modelOutputs = ["heatmaps": [1, 72, 160, 160]]
            } else {
                // Earlier reference candidates also expose the unused headpose
                // diagnostic. Retain loading compatibility for A/B benchmarks.
                if key == "landmarks", mapping["headpose"] != nil { modelOutputs["headpose"] = [1, 3] }
                guard Set(mapping.keys) == Set(modelOutputs.keys) else { throw GazeError.message("Invalid model output contract") }
            }
            guard spec["source_sha256"] as? String == Self.sourceHashes[key],
                  metadata["source_sha256"] == Self.sourceHashes[key],
                  let adaptedHash = spec["adapted_sha256"] as? String, adaptedHash.count == 64,
                  metadata["adapted_sha256"] == adaptedHash,
                  let precision = spec["compute_precision"] as? String,
                  ["fp32", "fp16", "mixed"].contains(precision),
                  metadata["compute_precision"] == precision,
                  key != "face" || precision == "fp32" else {
                throw GazeError.message("Model provenance mismatch: \(key). Rebuild the models and app.")
            }
            for (name, shape) in Self.shapes[key]! {
                guard let constraint = model.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint,
                      constraint.shape.map(\.intValue) == shape, constraint.dataType == .float32 else {
                    throw GazeError.message("Invalid input: \(key).\(name).")
                }
            }
            for (name, shape) in modelOutputs {
                guard let outputName = mapping[name],
                      let constraint = model.modelDescription.outputDescriptionsByName[outputName]?.multiArrayConstraint,
                      constraint.shape.map(\.intValue) == shape, constraint.dataType == (nativeHead == nil ? .float32 : .float16) else {
                    throw GazeError.message("Invalid output: \(key).\(name).")
                }
            }
            models[key] = model
            mappings[key] = mapping
        }
    }

    func predictModel(_ name: String, inputs: [String: LGTensorBuffer], outputs: [String: LGTensorBuffer]) throws {
        guard let model = models[name], let shapes = Self.shapes[name],
              let mapping = mappings[name], Set(inputs.keys) == Set(shapes.keys),
              Set(outputs.keys) == Set(Self.outputShapes[name]!.keys) else { throw GazeError.message("Unknown model contract") }
        for (key, shape) in Self.outputShapes[name]! {
            guard outputs[key]!.count == shape.reduce(1, *) else { throw GazeError.message("Invalid output tensor length") }
        }
        // Retain the Foundation buffers throughout the synchronous prediction.
        let buffers = inputs
        var features: [String: MLFeatureValue] = [:]
        for (key, shape) in shapes {
            let buffer = buffers[key]!
            guard buffer.count == shape.reduce(1, *) else { throw GazeError.message("Invalid tensor length") }
            var strides = [Int](repeating: 1, count: shape.count)
            if shape.count > 1 { for i in stride(from: shape.count - 2, through: 0, by: -1) { strides[i] = strides[i + 1] * shape[i + 1] } }
            let tensor = try MLMultiArray(dataPointer: buffer.pointer,
                                         shape: shape.map(NSNumber.init), dataType: .float32,
                                         strides: strides.map(NSNumber.init), deallocator: nil)
            features[key] = MLFeatureValue(multiArray: tensor)
        }
        let start = ProcessInfo.processInfo.systemUptime
        let options = MLPredictionOptions()
        if name == "landmarks", let landmarkHead {
            options.outputBackings = [mapping["heatmaps"]!: landmarkHead.outputBacking]
        }
        let prediction = try withExtendedLifetime(buffers) {
            try model.prediction(from: MLDictionaryFeatureProvider(dictionary: features), options: options)
        }
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        // Keep bounded aggregate samples; no tensor/frame data is logged.
        timings[name, default: []].append(elapsed)
        if timings[name]!.count > 180 { timings[name]!.removeFirst() }
        if name == "landmarks", let landmarkHead {
            guard let heatmaps = prediction.featureValue(for: mapping["heatmaps"]!)?.multiArrayValue else {
                throw GazeError.message("Missing landmark heatmaps")
            }
            let headStart = ProcessInfo.processInfo.systemUptime
            try landmarkHead.decode(heatmaps, outputs: outputs)
            timings["landmark_head", default: []].append((ProcessInfo.processInfo.systemUptime - headStart) * 1000)
            if timings["landmark_head"]!.count > 180 { timings["landmark_head"]!.removeFirst() }
            return
        }
        for (key, destination) in outputs {
            guard let value = prediction.featureValue(for: mapping[key]!)?.multiArrayValue,
                  value.dataType == .float32, destination.count == value.count,
                  value.shape.map(\.intValue) == Self.outputShapes[name]![key]! else {
                throw GazeError.message("Invalid model output")
            }
            let source = value.dataPointer.assumingMemoryBound(to: Float.self)
            let target = destination.pointer.assumingMemoryBound(to: Float.self)
            let shape = value.shape.map(\.intValue), strides = value.strides.map(\.intValue)
            var contiguous = true, expected = 1
            for axis in shape.indices.reversed() {
                if shape[axis] > 1 && strides[axis] != expected { contiguous = false }
                expected *= shape[axis]
            }
            if contiguous { target.update(from: source, count: value.count) }
            else {
                for index in 0..<value.count {
                    var remaining = index, offset = 0
                    for axis in shape.indices.reversed() { offset += (remaining % shape[axis]) * strides[axis]; remaining /= shape[axis] }
                    target[index] = source[offset]
                }
            }
        }
    }
}
