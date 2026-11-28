import Foundation
import SafariServices

/// Native side of the Locked Gaze Safari extension (LG-009). The extension's background
/// script asks for the next frame; this handler answers from the newest frame Locked Gaze
/// sent over the authenticated local channel, waiting briefly when none is newer.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        SafariFrameStore.shared.handle(message) { response in
            let reply = NSExtensionItem()
            reply.userInfo = [SFExtensionMessageKey: response]
            context.completeRequest(returningItems: [reply])
        }
    }
}

/// One subscription per extension process, kept while Safari keeps asking for frames.
final class SafariFrameStore: @unchecked Sendable {
    static let shared = SafariFrameStore()
    private typealias Reply = ([String: Any]) -> Void
    private let queue = DispatchQueue(label: "local.lockedgaze.safari.frames", qos: .userInitiated)
    private lazy var subscriber = FrameSubscriber(group: BrowserContract.signedGroup(), queue: queue,
                                                  onFrame: { [weak self] in self?.received($0) },
                                                  onConnection: { [weak self] in self?.connected = $0 })
    private var running = false
    private var latest: FrameSubscriber.Frame?
    private var connected: Bool?
    private var waiters: [(id: Int, after: UInt64, reply: Reply)] = []
    private var nextWaiter = 0
    private var lastRequest = DispatchTime.now()
    private var idleTimer: DispatchSourceTimer?
    /// Without a request for this long (the tab closed or switched cameras), the camera is released.
    private let idleAfter = 3.0
    private let waitLimit = 0.25

    func handle(_ message: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        queue.async { [self] in
            switch message["cmd"] as? String {
            case "frame":
                lastRequest = .now()
                startIfNeeded()
                let after = (message["after"] as? NSNumber)?.uint64Value ?? 0
                if let latest, latest.seq > after { reply(payload(latest)); return }
                if connected == false { reply(["error": "Choose Browser in the Locked Gaze menu"]); return }
                nextWaiter += 1
                let id = nextWaiter
                waiters.append((id, after, reply))
                queue.asyncAfter(deadline: .now() + waitLimit) { [self] in
                    // Still unanswered: let the background script ask again.
                    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
                    let expired = waiters.remove(at: index)
                    expired.reply(connected == false ? ["error": "Choose Browser in the Locked Gaze menu"] : ["status": "waiting"])
                }
            case "stop":
                stopIfRunning(); reply(["stopped": true])
            default:
                reply(["error": "unknown command"])
            }
        }
    }

    private func received(_ frame: FrameSubscriber.Frame) {
        latest = frame
        let ready = waiters.filter { frame.seq > $0.after }
        waiters.removeAll { frame.seq > $0.after }
        let response = payload(frame)
        ready.forEach { $0.reply(response) }
    }

    private func payload(_ frame: FrameSubscriber.Frame) -> [String: Any] {
        ["seq": frame.seq, "t0": frame.captureMs, "enc": frame.encodeMs, "bytes": frame.jpeg.count,
         "t1": Date().timeIntervalSince1970 * 1000, "jpeg": frame.jpeg.base64EncodedString()]
    }

    private func startIfNeeded() {
        guard !running else { return }
        running = true; latest = nil; connected = nil
        subscriber.start()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [self] in
            if Double(DispatchTime.now().uptimeNanoseconds - lastRequest.uptimeNanoseconds) / 1e9 > idleAfter { stopIfRunning() }
        }
        timer.resume()
        idleTimer = timer
    }

    private func stopIfRunning() {
        guard running else { return }
        running = false
        idleTimer?.cancel(); idleTimer = nil
        subscriber.stop()
        latest = nil
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.reply(["stopped": true]) }
    }
}
