import Foundation
import CoreMedia

enum CameraContract {
    static let appID = "local.lockedgaze.app"
    static let publisherID = "local.lockedgaze.app.publisher"
    static let extensionID = "local.lockedgaze.app.camera"
    static let deviceUID = "local.lockedgaze.virtual-camera"
    static let deviceID = UUID(uuidString: "712E4347-6405-4641-AD1B-4801B08AF818")!
    static let sourceID = UUID(uuidString: "74944B8C-DA3D-474F-91B5-9A3A2CE02D1B")!
    static let sinkID = UUID(uuidString: "BBA79B0A-C324-4963-960E-429F191C0303")!
    static let width = 1280
    static let height = 720
    static let frameDuration = CMTime(value: 1, timescale: 30)
    static let staleAfter: TimeInterval = 0.25
}
