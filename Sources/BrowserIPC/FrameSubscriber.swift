import Darwin
import Foundation

/// The receiving side of the browser frame channel, shared by the Chrome helper and the
/// Safari extension. It subscribes to the running Locked Gaze, renews every second, and
/// accepts frames only from Locked Gaze signed by its own team. All work runs on `queue`.
final class FrameSubscriber: @unchecked Sendable {
    struct Frame { let seq: UInt64; let captureMs: Double; let encodeMs: Double; let jpeg: Data }

    private let queue: DispatchQueue
    private let group: String?
    private let onFrame: (Frame) -> Void
    private let onConnection: (Bool) -> Void
    /// A signed receiver accepts frames only from Locked Gaze signed by the same team.
    private let policy = BrowserContract.policy(identifier: BrowserContract.appIdentifier, team: BrowserContract.signedTeam())
    private var port: mach_port_t?
    private var source: DispatchSourceMachReceive?
    private var remote: mach_port_t?
    private var timer: DispatchSourceTimer?
    private var connected: Bool?
    private var trustedPID: pid_t?
    private(set) var frames = 0

    init(group: String?, queue: DispatchQueue, onFrame: @escaping (Frame) -> Void, onConnection: @escaping (Bool) -> Void) {
        self.group = group; self.queue = queue; self.onFrame = onFrame; self.onConnection = onConnection
    }

    /// Call on `queue`.
    func start() {
        guard timer == nil else { return }
        if port == nil, let receive = MachChannel.makeReceivePort() {
            port = receive
            let source = DispatchSource.makeMachReceiveSource(port: receive, queue: queue)
            source.setEventHandler { [weak self] in self?.drain(receive) }
            source.setCancelHandler { MachChannel.destroyReceivePort(receive) }
            source.resume()
            self.source = source
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: BrowserContract.renewInterval)
        timer.setEventHandler { [weak self] in self?.renew() }
        timer.resume()
        self.timer = timer
    }

    /// Call on `queue`.
    func stop() {
        timer?.cancel(); timer = nil
        if let remote, let port { MachChannel.send(to: remote, id: BrowserContract.unsubscribe, reply: port, timeout: 200) }
        if let remote { MachChannel.release(remote) }
        remote = nil; connected = nil; trustedPID = nil
        // Keep the port alive briefly, so Locked Gaze still recognises it in the unsubscribe.
        let closing = source
        source = nil; port = nil
        queue.asyncAfter(deadline: .now() + 0.5) { closing?.cancel() }
    }

    private func renew() {
        guard let port else { return }
        if remote == nil { remote = MachChannel.lookUp(BrowserContract.appPortName(group: group)) }
        guard let remote, MachChannel.send(to: remote, id: BrowserContract.subscribe, reply: port, timeout: 200) == MACH_MSG_SUCCESS else {
            if let remote { MachChannel.release(remote) }
            self.remote = nil; trustedPID = nil
            report(false); return
        }
        report(true)
    }

    private func drain(_ port: mach_port_t) {
        while let message = MachChannel.receive(on: port, maxPayload: BrowserContract.maxPayload) {
            if message.replyPort != MACH_PORT_NULL { MachChannel.release(message.replyPort) }
            guard message.id == BrowserContract.frame else { continue }
            if trustedPID != message.pid {
                guard MachChannel.verify(message.audit, policy: policy) else { continue }
                trustedPID = message.pid
            }
            guard let frame = BrowserContract.decodeFrame(message.payload) else { continue }
            frames += 1
            onFrame(Frame(seq: frame.seq, captureMs: frame.captureMs, encodeMs: Double(frame.encodeMicros) / 1000, jpeg: frame.jpeg))
        }
    }

    private func report(_ now: Bool) {
        guard connected != now else { return }
        connected = now
        onConnection(now)
    }
}
