import Foundation

let queue = DispatchQueue(label: "test.latest-frame")
let entered = DispatchSemaphore(value: 0)
let release = DispatchSemaphore(value: 0)
var processed: [Int] = [] // Worker queue; inspected only after draining it.
let worker = LatestFrameWorker<Int>(queue: queue) { frame in
    processed.append(frame)
    if frame == 1 || frame == 200 {
        entered.signal()
        precondition(release.wait(timeout: .now() + 5) == .success)
    }
}
worker.submit(-1)
worker.begin()
worker.submit(1)
precondition(entered.wait(timeout: .now() + 5) == .success)
for frame in 2...100 { worker.submit(frame) }
release.signal()
queue.sync {}
precondition(processed == [1, 100], "Only the latest pending frame may run")

worker.submit(200)
precondition(entered.wait(timeout: .now() + 5) == .success)
worker.submit(201)
worker.stop()
worker.submit(202)
release.signal()
queue.sync {}
precondition(processed == [1, 100, 200], "Stop must discard pending frames and reject arrivals")
worker.begin()
worker.submit(300)
queue.sync {}
worker.stop()
precondition(processed == [1, 100, 200, 300], "Restart must not resurrect old frames")

final class Frame {}
let held = DispatchSemaphore(value: 0)
let finish = DispatchSemaphore(value: 0)
let lifetimeWorker = LatestFrameWorker<Frame>(queue: queue) { _ in
    held.signal(); precondition(finish.wait(timeout: .now() + 5) == .success)
}
lifetimeWorker.begin()
lifetimeWorker.submit(Frame())
precondition(held.wait(timeout: .now() + 5) == .success)
var pending: Frame? = Frame()
weak var expired = pending
lifetimeWorker.submit(pending!)
pending = nil
lifetimeWorker.submit(Frame())
precondition(expired == nil, "Replaced frames must be released immediately")
lifetimeWorker.stop()
finish.signal()
queue.sync {}
print("PASS: latest-only delivery, bounded pending storage, stop/restart, immediate release")

// Overlapping producers and stop: no old frame may enter a later activation.
for cycle in 0..<100 {
    let stressQueue = DispatchQueue(label: "test.stress.\(cycle)")
    let lock = NSLock()
    var values: [Int] = []
    let stress = LatestFrameWorker<Int>(queue: stressQueue) { value in
        lock.lock(); values.append(value); lock.unlock()
    }
    stress.begin()
    DispatchQueue.concurrentPerform(iterations: 8) { producer in
        for i in 0..<100 {
            stress.submit(producer * 100 + i)
            if producer == 3 && i == 50 { stress.stop() }
        }
    }
    stress.stop(); stressQueue.sync {}
    let count = values.count
    stress.submit(-1); stressQueue.sync {}
    precondition(values.count == count, "No work after stop")
    stress.begin(); stress.submit(10000); stressQueue.sync {}; stress.stop()
    precondition(values.count == count + 1 && values.last == 10000, "Restart receives only new generation")
}
print("PASS: 100 concurrent submit/stop/restart cycles (80,000 submissions)")
