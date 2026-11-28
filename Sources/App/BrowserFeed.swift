import CoreVideo
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers
import VideoToolbox

/// Serves processed frames to the browser helper while it is subscribed (LG-009).
/// Frames leave only as JPEG in Mach messages to a helper whose code signature matches
/// Locked Gaze's own team; nothing is stored, and nothing is encoded without a subscriber.
final class BrowserFeed: @unchecked Sendable {
    private struct Subscriber { let pid: pid_t; var until: TimeInterval }
    private let lock = NSLock()
    /// Keyed by the send right to the helper's frame port.
    private var subscribers: [mach_port_t: Subscriber] = [:]
    private var port: mach_port_t?
    private var source: DispatchSourceMachReceive?
    private var timer: Timer?
    private let controlQueue = DispatchQueue(label: "local.lockedgaze.browser.control", qos: .userInitiated)
    private let encodeQueue = DispatchQueue(label: "local.lockedgaze.browser", qos: .userInitiated)
    private var encoding = false
    private var seq: UInt64 = 0
    private var pool: CVPixelBufferPool?
    private let group = BrowserContract.signedGroup()
    private let policy: BrowserContract.PeerPolicy?
    private let log = Logger(subsystem: CameraContract.appID, category: "Browser")
    private var wanted = false
    @MainActor var onDemandChange: ((Bool) -> Void)?

    /// `policy` defaults to the Chrome helper or Safari extension signed by this app's team; unsigned
    /// development builds have no team and accept any helper.
    init(policy: BrowserContract.PeerPolicy?? = nil) {
        self.policy = policy ?? BrowserContract.policy(
            identifiers: [BrowserContract.helperIdentifier, BrowserContract.safariIdentifier], team: BrowserContract.signedTeam())
    }

    /// True while at least one helper is subscribed.
    var isWanted: Bool { lock.withLock { wanted } }

    @MainActor func start() {
        guard port == nil else { return }
        let name = BrowserContract.appPortName(group: group)
        guard let receive = MachChannel.checkIn(name) else {
            log.error("Browser port \(name, privacy: .public) is unavailable"); return
        }
        port = receive
        let source = DispatchSource.makeMachReceiveSource(port: receive, queue: controlQueue)
        source.setEventHandler { [weak self] in self?.drain(receive) }
        source.setCancelHandler { MachChannel.destroyReceivePort(receive) }
        source.resume()
        self.source = source
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
        var attributes: [String: Any] = [kCVPixelBufferWidthKey as String: CameraContract.width,
            kCVPixelBufferHeightKey as String: CameraContract.height, kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
        var created: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
        lock.withLock { pool = created }
        log.notice("Browser port ready")
    }

    @MainActor func stop() {
        timer?.invalidate(); timer = nil
        source?.cancel(); source = nil; port = nil
        let removed = lock.withLock { () -> [mach_port_t] in defer { subscribers.removeAll() }; return Array(subscribers.keys) }
        removed.forEach(MachChannel.release)
        updateDemand()
    }

    private func drain(_ port: mach_port_t) {
        var changed = false
        while let message = MachChannel.receive(on: port, maxPayload: 1024) {
            let reply = message.replyPort
            guard reply != MACH_PORT_NULL else { continue }
            let known = lock.withLock { subscribers[reply] }
            // A known port already passed the check; the right it brought again is surplus.
            if known == nil && !MachChannel.verify(message.audit, policy: policy) {
                log.error("Refused browser subscriber pid \(message.pid)")
                MachChannel.release(reply); continue
            }
            switch message.id {
            case BrowserContract.subscribe:
                let until = ProcessInfo.processInfo.systemUptime + BrowserContract.subscriptionLifetime
                lock.withLock { subscribers[reply] = Subscriber(pid: message.pid, until: until) }
                if known != nil { MachChannel.release(reply) } else { changed = true }
            case BrowserContract.unsubscribe:
                MachChannel.release(reply)
                if known != nil { lock.withLock { subscribers[reply] = nil }; MachChannel.release(reply); changed = true }
            default:
                MachChannel.release(reply)
            }
        }
        if changed { DispatchQueue.main.async { MainActor.assumeIsolated { self.updateDemand() } } }
    }

    @MainActor private func prune() {
        let now = ProcessInfo.processInfo.systemUptime
        let expired = lock.withLock { () -> [mach_port_t] in
            // Expired, or the helper's port died (it quit or crashed without unsubscribing).
            let gone = subscribers.filter { entry in
                var type = mach_port_type_t()
                // MACH_PORT_TYPE_DEAD_NAME is a C macro: MACH_PORT_TYPE(MACH_PORT_RIGHT_DEAD_NAME).
                let deadName = mach_port_type_t(1) << (UInt32(MACH_PORT_RIGHT_DEAD_NAME) + 16)
                let dead = mach_port_type(mach_task_self_, entry.key, &type) != KERN_SUCCESS || type & deadName != 0
                return entry.value.until <= now || dead
            }.map(\.key)
            gone.forEach { subscribers[$0] = nil }
            return gone
        }
        expired.forEach(MachChannel.release)
        updateDemand()
    }

    @MainActor private func updateDemand() {
        let (now, changed) = lock.withLock { () -> (Bool, Bool) in
            let now = !subscribers.isEmpty
            defer { wanted = now }
            return (now, now != wanted)
        }
        if changed {
            log.notice("Browser camera \(now ? "requested" : "released", privacy: .public)")
            onDemandChange?(now)
        }
    }

    /// Called on a processing queue with the frame the virtual camera would show.
    /// Drops the frame while the previous one is still being encoded.
    func submit(_ buffer: CVPixelBuffer, capturedAt wallMs: Double) {
        let pool: CVPixelBufferPool? = lock.withLock {
            guard wanted, !encoding, let pool = self.pool else { return nil }
            encoding = true
            return pool
        }
        guard let pool else { return }
        // Copy into the feed's own pool so capture and camera buffers are never held.
        var copy: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &copy) == kCVReturnSuccess, let copy,
              PixelCopy.bgra(from: buffer, to: copy) else { lock.withLock { encoding = false }; return }
        encodeQueue.async { [self] in
            defer { lock.withLock { encoding = false } }
            let started = DispatchTime.now().uptimeNanoseconds
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(copy, options: nil, imageOut: &image)
            let jpeg = NSMutableData()
            guard let image, let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: BrowserContract.jpegQuality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return }
            let micros = UInt32((DispatchTime.now().uptimeNanoseconds - started) / 1000)
            seq += 1
            let message = BrowserContract.encodeFrame(seq: seq, captureMs: wallMs, encodeMicros: micros, jpeg: jpeg as Data)
            // Fire and forget: a helper whose queue is full misses this frame; a dead one is dropped.
            let targets = lock.withLock { Array(subscribers.keys) }
            for target in targets {
                let result = MachChannel.send(to: target, id: BrowserContract.frame, payload: message)
                if result == MACH_SEND_INVALID_DEST {
                    let removed = lock.withLock { subscribers.removeValue(forKey: target) != nil }
                    if removed {
                        MachChannel.release(target)
                        DispatchQueue.main.async { MainActor.assumeIsolated { self.updateDemand() } }
                    }
                }
            }
        }
    }
}
