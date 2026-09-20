import Foundation

final class Sentinel { let released: () -> Void; init(_ released: @escaping () -> Void) { self.released = released }; deinit { released() } }
let lock = NSLock()
for _ in 0..<1000 {
    var calls = 0
    let reply = ReplyOnce<Int> { _ in lock.withLock { calls += 1 } }
    DispatchQueue.concurrentPerform(iterations: 32) { reply.finish($0) }
    precondition(calls == 1, "reply delivered more than once")
}
var released = false
var sentinel: Sentinel? = Sentinel { released = true }
let reply = ReplyOnce<Int> { [value = sentinel!] _ in withExtendedLifetime(value) {} }
sentinel = nil
precondition(!released)
reply.finish(0)
precondition(released, "timeout closure must not keep frame alive after reply")
reply.finish(1)
var reentrant: ReplyOnce<Int>!
var calls = 0
reentrant = ReplyOnce { _ in calls += 1; reentrant.finish(1) }
reentrant.finish(0)
precondition(calls == 1)
print("PASS: 32,000 raced replies, immediate capture release, reentrant completion")
