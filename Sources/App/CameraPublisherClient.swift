import Foundation
import CoreVideo
import IOSurface
import OSLog

/// Owns a disposable CMIO process. Frames share IOSurface storage across XPC;
/// only one send may be in flight, so a slow service cannot accumulate frames.
final class CameraPublisherClient: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var generation = 0
    private var sending = false
    private var failure: String?
    private var pending: ReplyOnce<Result<Void, Error>>?

    @MainActor func start() async throws {
        try Task.checkCancellation()
        let (connection, token): (NSXPCConnection, Int) = lock.withLock {
            if let connection { return (connection, generation) }
            let created = NSXPCConnection(serviceName: CameraContract.publisherID)
            created.remoteObjectInterface = NSXPCInterface(with: CameraPublisherProtocol.self)
            created.resume()
            connection = created
            return (created, generation)
        }
        do {
            try await withTaskCancellationHandler(operation: {
              try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let reply = ReplyOnce<Result<Void, Error>> { continuation.resume(with: $0) }
                lock.withLock { pending = reply }
                if Task.isCancelled { reply.finish(.failure(CancellationError())); return }
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                    reply.finish(.failure(CameraConnectionError.notReady))
                } as! CameraPublisherProtocol
                proxy.start { status, message, pid in
                    if status == 0 {
                        Logger(subsystem: CameraContract.appID, category: "Publisher").notice("Connected camera publisher pid=\(pid)")
                        reply.finish(.success(()))
                    } else if status == 1 { reply.finish(.failure(CameraConnectionError.notReady)) }
                    else { reply.finish(.failure(GazeError.message(message ?? "Camera publisher failed."))) }
                }
                // launchd may throttle a service recycled shortly after launch.
                DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                    reply.finish(.failure(GazeError.message("The virtual camera service did not respond. Activate Locked Gaze again.")))
                }
              }
            }, onCancel: { self.stop() })
            try Task.checkCancellation()
            guard lock.withLock({ generation == token }) else { throw CancellationError() }
            lock.withLock { pending = nil }
        } catch {
            stop()
            throw error
        }
    }

    func send(_ pixelBuffer: CVPixelBuffer, completion: ((String?) -> Void)? = nil) throws {
        let state: (NSXPCConnection, Int)? = try lock.withLock {
            if let failure { throw GazeError.message(failure) }
            guard let connection else { throw GazeError.message("Camera publisher is stopped.") }
            guard !sending else { return nil }
            sending = true
            return (connection, generation)
        }
        guard let (connection, token) = state else { completion?("Camera publisher is busy."); return }
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            lock.withLock { if generation == token { sending = false } }
            throw GazeError.message("Camera frame has no shared storage.")
        }
        // Keep the pool buffer retained until the service has taken ownership.
        let done: (String?) -> Void = { [weak self, pixelBuffer] error in
            withExtendedLifetime(pixelBuffer) {
                self?.lock.withLock {
                    guard let self, self.generation == token else { return }
                    self.sending = false
                    self.failure = error
                }
            }
            completion?(error)
        }
        let reply = ReplyOnce<String?>(done)
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            reply.finish("The virtual camera connection was interrupted. Activate Locked Gaze again.")
        } as! CameraPublisherProtocol
        proxy.send(surface, timestamp: ProcessInfo.processInfo.systemUptime) { reply.finish($0) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            reply.finish("The virtual camera stopped responding. Activate Locked Gaze again.")
        }
    }

    func stop() {
        let old: (NSXPCConnection?, ReplyOnce<Result<Void, Error>>?) = lock.withLock {
            generation += 1
            let old = (connection, pending)
            connection = nil; pending = nil; sending = false; failure = nil
            return old
        }
        old.1?.finish(.failure(CancellationError()))
        old.0?.invalidate()
    }
    deinit { stop() }
}
