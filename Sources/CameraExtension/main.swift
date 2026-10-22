import Foundation
import CoreMediaIO

// Exit at once on SIGTERM. When macOS replaces this extension, Core Media I/O submits the new
// version's launchd job 3-11 ms after stopping this one; if this process is still exiting
// then, launchd refuses the job (error 37) and no camera runs until a restart.
CMIOExtensionProvider.ignoreSIGTERM()
signal(SIGTERM) { _ in _exit(0) }

let provider = try CameraProvider(queue: DispatchQueue(label: "local.lockedgaze.camera", qos: .userInteractive))
CMIOExtensionProvider.startService(provider: provider.provider)
CFRunLoopRun()
