import AppKit
import CoreVideo
import Foundation

// Drives the app's BrowserFeed and the real browser helper end to end over the local
// Mach port channel, with synthetic frames only. Usage: BrowserFeedTests HELPER_PATH
@MainActor func expect(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}

func makeFrame(_ value: UInt8) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, CameraContract.width, CameraContract.height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    CVPixelBufferLockBaseAddress(buffer!, [])
    memset(CVPixelBufferGetBaseAddress(buffer!), Int32(value), CVPixelBufferGetDataSize(buffer!))
    CVPixelBufferUnlockBaseAddress(buffer!, [])
    return buffer!
}

final class Helper {
    let process = Process()
    let toHelper = Pipe(), fromHelper = Pipe()
    private let lock = NSLock()
    private var messages: [[String: Any]] = []

    init(path: String) throws {
        process.executableURL = URL(fileURLWithPath: path)
        process.standardInput = toHelper; process.standardOutput = fromHelper
        // Ignore an installed Locked Gaze that may be running: talk only to this test's feed.
        process.environment = ProcessInfo.processInfo.environment.merging(["LOCKED_GAZE_BROWSER_GROUP": ""]) { $1 }
        try process.run()
        Thread.detachNewThread { [self] in
            let handle = fromHelper.fileHandleForReading
            while true {
                let header = handle.readData(ofLength: 4)
                guard header.count == 4 else { return }
                let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
                let body = handle.readData(ofLength: length)
                if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    lock.withLock { messages.append(object) }
                }
            }
        }
    }
    func send(_ object: [String: Any]) {
        let body = try! JSONSerialization.data(withJSONObject: object)
        var length = UInt32(body.count).littleEndian
        toHelper.fileHandleForWriting.write(Data(bytes: &length, count: 4) + body)
    }
    var received: [[String: Any]] { lock.withLock { messages } }
}

@MainActor func wait(_ seconds: Double, until condition: () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline && !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

MainActor.assumeIsolated {
    guard CommandLine.arguments.count == 2 else { print("Usage: BrowserFeedTests HELPER_PATH"); exit(2) }
    let feed = BrowserFeed()
    var demand: [Bool] = []
    feed.onDemandChange = { demand.append($0) }

    // Helper started before Locked Gaze: it reports that the app is missing, then connects.
    let helper = try! Helper(path: CommandLine.arguments[1])
    helper.send(["cmd": "start", "source": "app"])
    wait(3) { helper.received.contains { $0["error"] != nil } }
    expect(helper.received.contains { ($0["error"] as? String)?.contains("Choose Browser") == true }, "helper reports a missing app")
    expect(!feed.isWanted, "no demand before the feed starts")

    feed.start()
    wait(3) { feed.isWanted }
    expect(feed.isWanted && demand == [true], "subscription raises demand")

    // 3 s of frames at 30 fps from a processing queue.
    let queue = DispatchQueue(label: "test.processing")
    let frames = [makeFrame(40), makeFrame(200)]
    var sent = 0
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: 1.0 / 30)
    timer.setEventHandler { feed.submit(frames[sent % 2], capturedAt: Date().timeIntervalSince1970 * 1000); sent += 1 }
    timer.resume()
    wait(3)
    timer.cancel()
    let delivered = helper.received.filter { $0["jpeg"] != nil }
    let latencies = delivered.compactMap { m -> Double? in
        guard let t0 = m["t0"] as? Double, let t1 = m["t1"] as? Double else { return nil }
        return t1 - t0
    }.sorted()
    let sizes = delivered.compactMap { $0["bytes"] as? Int }
    print("sent \(sent), delivered \(delivered.count), capture→helper p50 \(latencies.isEmpty ? -1 : latencies[latencies.count / 2]) ms, max \(latencies.last ?? -1) ms, JPEG \(sizes.first ?? 0) bytes")
    expect(delivered.count >= sent * 9 / 10, "at least 90% of frames delivered")
    expect(Set(delivered.compactMap { $0["seq"] as? Int }).count == delivered.count, "no duplicated frames")
    expect((latencies.last ?? 1000) < 100, "every frame under 100 ms")

    // Stop: the helper unsubscribes and demand falls at once.
    helper.send(["cmd": "stop"])
    wait(2) { !feed.isWanted }
    expect(!feed.isWanted && demand == [true, false], "unsubscribe releases demand")

    // A helper that disappears without unsubscribing expires.
    helper.send(["cmd": "start", "source": "app"])
    wait(3) { feed.isWanted }
    expect(feed.isWanted, "resubscribe")
    helper.process.terminate()
    wait(BrowserContract.subscriptionLifetime + 2) { !feed.isWanted }
    expect(!feed.isWanted, "a vanished helper expires")

    // No frames are encoded without a subscriber.
    let before = helper.received.count
    feed.submit(frames[0], capturedAt: 0)
    wait(0.3)
    expect(helper.received.count == before, "no frames without a subscriber")
    feed.stop()

    // Only one feed can hold the name, and stopping releases it (the strict feed below reuses it).
    wait(0.5)
    let name = BrowserContract.appPortName(group: BrowserContract.signedGroup())
    let first = MachChannel.checkIn(name)
    expect(first != nil && MachChannel.checkIn(name) == nil, "the port name is exclusive and free after stop")
    MachChannel.destroyReceivePort(first!)

    // A helper whose signature does not meet the requirement never subscribes.
    let strict = BrowserFeed(policy: BrowserContract.policy(identifier: BrowserContract.helperIdentifier, team: "NOTEAM0000"))
    var strictDemand: [Bool] = []
    strict.onDemandChange = { strictDemand.append($0) }
    strict.start()
    let intruder = try! Helper(path: CommandLine.arguments[1])
    intruder.send(["cmd": "start", "source": "app"])
    wait(3)
    expect(!strict.isWanted && strictDemand.isEmpty, "an unsigned helper is refused")
    strict.submit(frames[0], capturedAt: 0)
    wait(0.3)
    expect(!intruder.received.contains { $0["jpeg"] != nil }, "a refused helper gets no frames")
    intruder.process.terminate()
    strict.stop()
    // The policy accepts App Store, TestFlight and developer certificates, and always the team.
    let policy = BrowserContract.policy(identifiers: ["a", "b"], team: "ABCDE12345")!
    expect(policy.requirement.contains("1.2.840.113635.100.6.1.9") && policy.requirement.contains("1.2.840.113635.100.6.1.25.1")
           && policy.requirement.contains(#"identifier "a" or identifier "b""#) && policy.team == "ABCDE12345", "store and TestFlight signatures")
    expect(BrowserContract.policy(identifier: "a", team: nil) == nil && BrowserContract.policy(identifier: "a", team: "bad\" or true") == nil, "malformed teams")
    print("BrowserFeedTests: OK")
    exit(0)
}
