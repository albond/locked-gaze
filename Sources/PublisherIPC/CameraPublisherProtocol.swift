import Foundation
import IOSurface

@objc protocol CameraPublisherProtocol {
    // status: 0 = ready, 1 = device not published yet, 2 = terminal error.
    func start(reply: @escaping (Int, String?, Int32) -> Void)
    func send(_ surface: IOSurface, timestamp: Double, reply: @escaping (String?) -> Void)
}
