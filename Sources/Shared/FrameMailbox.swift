import Foundation

/// Confined to the extension's serial queue. A bounded jitter buffer with an
/// explicit clock keeps stale frames from surviving a producer disconnect.
struct FrameMailbox<Value> {
    private var waiting: [(Value, TimeInterval)] = []
    private var latest: (Value, TimeInterval)?
    let lifetime: TimeInterval
    let capacity: Int

    init(lifetime: TimeInterval, capacity: Int = 2) {
        precondition(lifetime.isFinite && lifetime > 0 && capacity > 0)
        self.lifetime = lifetime; self.capacity = capacity
    }
    mutating func append(_ value: Value, at time: TimeInterval) {
        guard time.isFinite else { return }
        if waiting.count == capacity { waiting.removeFirst() }
        waiting.append((value, time))
    }
    mutating func frame(at now: TimeInterval) -> Value? {
        guard now.isFinite else { reset(); return nil }
        let lifetime = self.lifetime
        func fresh(_ time: TimeInterval) -> Bool { now >= time && now - time < lifetime }
        waiting.removeAll { !fresh($0.1) }
        if !waiting.isEmpty { latest = waiting.removeFirst() }
        if let item = latest, fresh(item.1) { return item.0 }
        latest = nil
        return nil
    }
    mutating func reset() { waiting.removeAll(); latest = nil }
}
