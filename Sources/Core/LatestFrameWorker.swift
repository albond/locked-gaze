import Foundation

/// At most one frame in inference and one waiting frame. New arrivals replace
/// the waiting frame, so a slower processor never builds a capture backlog.
/// Stop accepting before draining `queue`; begin only after that drain.
final class LatestFrameWorker<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let process: (Value) -> Void
    private var accepting = false
    private var scheduled = false
    private var pending: Value?

    init(queue: DispatchQueue, process: @escaping (Value) -> Void) {
        self.queue = queue
        self.process = process
    }

    func begin() {
        lock.lock(); defer { lock.unlock() }
        precondition(!scheduled && pending == nil, "Drain the old worker before restarting")
        accepting = true
    }

    func submit(_ value: Value) {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        pending = value
        if !scheduled {
            scheduled = true
            // Schedule under the lock: a stop followed by a queue drain cannot
            // overtake a previously accepted frame's worker.
            queue.async { self.drain() }
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        accepting = false
        pending = nil
    }

    private func take() -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard accepting, let value = pending else {
            pending = nil
            scheduled = false
            return nil
        }
        pending = nil
        return value
    }

    private func drain() {
        while let value = take() { autoreleasepool { process(value) } }
    }
}
