import Foundation
import CoreMediaIO

let provider = try CameraProvider(queue: DispatchQueue(label: "local.lockedgaze.camera", qos: .userInteractive))
CMIOExtensionProvider.startService(provider: provider.provider)
CFRunLoopRun()
