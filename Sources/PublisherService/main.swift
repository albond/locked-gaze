import Foundation
import CoreVideo
import IOSurface

final class PublisherService: NSObject, CameraPublisherProtocol, NSXPCListenerDelegate {
    private let publisher = CameraPublisher()
    private var accepted = false

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // A connection owns the process and its CMIO registry. Never reuse the
        // registry after that connection ends (for example after permission changes).
        guard !accepted else { return false }
        accepted = true
        connection.exportedInterface = NSXPCInterface(with: CameraPublisherProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { DispatchQueue.main.async { exit(0) } }
        connection.resume()
        return true
    }
    func start(reply: @escaping (Int, String?, Int32) -> Void) {
        DispatchQueue.main.async {
            do { try self.publisher.start(); reply(0, nil, getpid()) }
            catch is CameraConnectionError { reply(1, nil, getpid()) }
            catch { reply(2, error.localizedDescription, getpid()) }
        }
    }
    func send(_ surface: IOSurface, timestamp: Double, reply: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            guard surface.width == CameraContract.width, surface.height == CameraContract.height,
                  surface.pixelFormat == kCVPixelFormatType_32BGRA else {
                reply("Invalid camera frame."); return
            }
            guard timestamp.isFinite, timestamp <= ProcessInfo.processInfo.systemUptime,
                  ProcessInfo.processInfo.systemUptime - timestamp < CameraContract.staleAfter else {
                reply(nil); return
            }
            var storage: Unmanaged<CVPixelBuffer>?
            let status = CVPixelBufferCreateWithIOSurface(nil, surface, nil, &storage)
            guard status == kCVReturnSuccess, let buffer = storage?.takeRetainedValue() else { reply("Cannot open the camera frame."); return }
            do { try self.publisher.send(buffer); reply(nil) }
            catch { reply(error.localizedDescription) }
        }
    }
}
let service = PublisherService()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
RunLoop.main.run()
