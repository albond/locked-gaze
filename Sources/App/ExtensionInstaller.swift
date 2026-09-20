import Foundation
import SystemExtensions

@MainActor
final class ExtensionInstaller: NSObject, @preconcurrency OSSystemExtensionRequestDelegate {
    enum ApprovalError: LocalizedError {
        case required, pending
        var errorDescription: String? {
            "Allow the Locked Gaze camera extension in System Settings, then click Check Again. On macOS 15 or later, open General > Login Items & Extensions > Camera Extensions. On macOS 14, open Privacy & Security."
        }
    }
    private var continuation: CheckedContinuation<Void, Error>?
    private var request: OSSystemExtensionRequest?

    private let submit: (OSSystemExtensionRequest) -> Void
    private let unsignedBuild: () -> Bool
    private let probeEnabled: (() async throws -> Bool)?
    private var propertiesRequest: OSSystemExtensionRequest?
    private var propertiesContinuation: CheckedContinuation<Bool, Error>?

    init(submit: @escaping (OSSystemExtensionRequest) -> Void = { OSSystemExtensionManager.shared.submitRequest($0) },
         probeEnabled: (() async throws -> Bool)? = nil,
         unsignedBuild: @escaping () -> Bool = { Bundle.main.object(forInfoDictionaryKey: "LGUnsignedDevelopmentBuild") as? Bool == true }) {
        self.submit = submit; self.unsignedBuild = unsignedBuild; self.probeEnabled = probeEnabled
        super.init()
    }

    func activate() async throws {
        guard !unsignedBuild() else {
            throw GazeError.message("The virtual camera requires an Apple Developer signed build. This development build supports interface and offline processing checks only.")
        }
        guard continuation == nil else { throw ApprovalError.pending }
        // Do not re-activate/replace an already enabled matching extension:
        // doing so can invalidate the host's current CMIO device discovery.
        let enabled: Bool
        if let probeEnabled { enabled = try await probeEnabled() }
        else { enabled = try await currentExtensionEnabled() }
        if enabled { request = nil; return }
        guard request == nil else { throw ApprovalError.pending }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: CameraContract.extensionID, queue: .main)
            request.delegate = self; self.request = request
            submit(request)
        }
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        guard request === self.request else { return }
        let pending = continuation; continuation = nil
        pending?.resume(throwing: ApprovalError.required)
    }
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        guard request === self.request else { return }
        if result == .completed { complete(.success(())) }
        else { complete(.failure(GazeError.message("Restart your Mac to finish installing the camera extension."))) }
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        if request === propertiesRequest {
            let pending = propertiesContinuation
            propertiesContinuation = nil; propertiesRequest = nil
            pending?.resume(throwing: error)
            return
        }
        guard request === self.request else { return }
        complete(.failure(error))
    }
    func currentExtensionEnabled() async throws -> Bool {
        guard propertiesRequest == nil else { throw ApprovalError.pending }
        return try await withCheckedThrowingContinuation { continuation in
            propertiesContinuation = continuation
            let query = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: CameraContract.extensionID, queue: .main)
            propertiesRequest = query; query.delegate = self; submit(query)
        }
    }
    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        guard request === propertiesRequest else { return }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(CameraContract.extensionID).systemextension")
        let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let enabled = properties.contains {
            $0.bundleIdentifier == CameraContract.extensionID && $0.isEnabled && !$0.isAwaitingUserApproval && $0.bundleVersion == version
        }
        let pending = propertiesContinuation
        propertiesContinuation = nil; propertiesRequest = nil
        pending?.resume(returning: enabled)
    }
    private func complete(_ result: Result<Void, Error>) {
        let pending = continuation; continuation = nil; request = nil; pending?.resume(with: result)
    }
}
