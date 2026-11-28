import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Security

// Chrome Native Messaging host for the Locked Gaze browser camera (LG-009).
// Chrome starts it over stdio. With source "app" it subscribes to the running Locked Gaze
// over a local Mach port and forwards its JPEG frames; with source "synthetic" it draws
// test frames for transport measurements. It never opens a camera, reads files or uses
// the network, and sends nothing from the browser to Locked Gaze except its own port name.

let width = 1280, height = 720
let output = FileHandle.standardOutput
let outputLock = NSLock()

func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

func send(_ json: Data) {
    var length = UInt32(json.count).littleEndian
    var packet = Data(bytes: &length, count: 4)
    packet.append(json)
    outputLock.lock(); defer { outputLock.unlock() }
    // write(2), not FileHandle: Chrome may close the pipe mid-frame, and FileHandle then
    // raises an exception that aborts the helper. A closed pipe simply ends the helper.
    let written = packet.withUnsafeBytes { raw -> Bool in
        var offset = 0
        while offset < raw.count {
            let result = write(STDOUT_FILENO, raw.baseAddress! + offset, raw.count - offset)
            if result < 0 { if errno == EINTR { continue }; return false }
            offset += result
        }
        return true
    }
    if !written { exit(0) }
}

func send(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object) { send(data) }
}

// Low-amplitude noise makes JPEG size closer to a real webcam frame than a flat test card.
let noise: CGImage = {
    // Half-resolution noise, smoothly upscaled: closer to webcam sensor noise than per-pixel noise.
    let w = width / 2, h = height / 2
    var bytes = [UInt8](repeating: 0, count: w * h)
    var state: UInt32 = 0x9E3779B9
    for i in bytes.indices {
        state ^= state << 13; state ^= state >> 17; state ^= state << 5
        bytes[i] = UInt8(truncatingIfNeeded: state)
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}()

let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!

func renderFrame(_ seq: Int) -> CGImage {
    let phase = CGFloat(seq) / 30
    let colors = [CGColor(red: 0.20, green: 0.24, blue: 0.30, alpha: 1), CGColor(red: 0.55, green: 0.48, blue: 0.42, alpha: 1)]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    context.setAlpha(0.10)
    let shift = CGFloat(seq % 7) * 3
    context.draw(noise, in: CGRect(x: -shift, y: -shift, width: CGFloat(width) + 21, height: CGFloat(height) + 21))
    context.setAlpha(1)
    let x = 640 + 220 * sin(phase), y = 360 + 60 * cos(phase * 1.3)
    context.setFillColor(CGColor(red: 0.85, green: 0.68, blue: 0.56, alpha: 1))
    context.fillEllipse(in: CGRect(x: x - 150, y: y - 190, width: 300, height: 380))
    context.setFillColor(CGColor(red: 0.12, green: 0.10, blue: 0.10, alpha: 1))
    context.fillEllipse(in: CGRect(x: x - 85, y: y + 30, width: 50, height: 26))
    context.fillEllipse(in: CGRect(x: x + 35, y: y + 30, width: 50, height: 26))
    return context.makeImage()!
}

func encode(_ image: CGImage, quality: Double) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

final class Streamer {
    private let queue = DispatchQueue(label: "probe.frames", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var seq = 0
    private var busy = false
    private var skipped = 0

    func start(fps: Double, quality: Double) {
        queue.async { [self] in
            timer?.cancel(); seq = 0; skipped = 0
            let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            source.schedule(deadline: .now(), repeating: 1 / fps, leeway: .milliseconds(1))
            source.setEventHandler { [self] in tick(quality: quality) }
            timer = source
            source.resume()
        }
    }

    func stop() {
        queue.async { [self] in timer?.cancel(); timer = nil; send(["stopped": true, "frames": seq, "skipped": skipped]) }
    }

    private func tick(quality: Double) {
        guard !busy else { skipped += 1; return }
        busy = true; defer { busy = false }
        seq += 1
        let t0 = nowMs()
        let image = renderFrame(seq)
        let tRender = nowMs()
        guard let jpeg = encode(image, quality: quality) else { return }
        sendFrame(seq: UInt64(seq), t0: t0, render: tRender - t0, encode: nowMs() - tRender, skipped: skipped, jpeg: jpeg)
    }
}

func sendFrame(seq: UInt64, t0: Double, render: Double, encode: Double, skipped: Int, jpeg: Data) {
    // Built by hand: JSONSerialization would scan the large base64 string again.
    let header = String(format: "{\"seq\":%llu,\"t0\":%.3f,\"render\":%.3f,\"enc\":%.3f,\"bytes\":%d,\"skipped\":%d,\"t1\":%.3f,\"jpeg\":\"",
                        seq, t0, render, encode, jpeg.count, skipped, nowMs())
    var json = Data(header.utf8)
    json.append(Data(jpeg.base64EncodedString().utf8))
    json.append(Data("\"}".utf8))
    guard json.count < 1_000_000 else { send(["error": "frame too large", "bytes": json.count]); return }
    send(json)
}

/// Team ID of the installed app, for an unsigned development helper outside the bundle.
func installedAppGroup() -> String? {
    var code: SecStaticCode?
    var info: CFDictionary?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/Applications/Locked Gaze.app") as CFURL, [], &code) == errSecSuccess, let code,
          SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
    return team + "." + BrowserContract.groupSuffix
}

/// Subscription to the running Locked Gaze, forwarded to Chrome. Main queue only.
final class AppLink {
    private lazy var subscriber = FrameSubscriber(group: Self.group, queue: .main, onFrame: { frame in
        sendFrame(seq: frame.seq, t0: frame.captureMs, render: 0, encode: frame.encodeMs, skipped: 0, jpeg: frame.jpeg)
    }, onConnection: { connected in
        if connected { send(["status": "connected"]) }
        else { send(["error": "Choose Browser in the Locked Gaze menu"]) }
    })
    private var running = false

    private static var group: String? {
        if let group = BrowserContract.signedGroup() { return group }
        if let forced = ProcessInfo.processInfo.environment["LOCKED_GAZE_BROWSER_GROUP"] {
            // Tests pin one namespace ("" is the unsandboxed one); Chrome never sets this.
            return forced.isEmpty ? nil : forced
        }
        // An unsigned development helper outside the bundle follows the installed app.
        return installedAppGroup()
    }

    func start() { guard !running else { return }; running = true; subscriber.start() }
    func stop() {
        guard running else { return }
        running = false
        subscriber.stop()
        send(["stopped": true, "frames": subscriber.frames])
    }
}

signal(SIGPIPE, SIG_IGN)
let streamer = Streamer()
let appLink = AppLink()
let input = FileHandle.standardInput

func readExactly(_ count: Int) -> Data? {
    var data = Data()
    while data.count < count {
        let chunk = input.readData(ofLength: count - data.count)
        if chunk.isEmpty { return nil }
        data.append(chunk)
    }
    return data
}

send(["hello": "locked-gaze-browser-host", "pid": ProcessInfo.processInfo.processIdentifier, "t": nowMs()])

func handle(_ message: [String: Any]) {
    switch message["cmd"] as? String {
    case "start":
        if message["source"] as? String == "synthetic" {
            streamer.start(fps: message["fps"] as? Double ?? 30, quality: message["quality"] as? Double ?? 0.8)
        } else {
            appLink.start()
        }
    case "stop":
        streamer.stop(); appLink.stop()
    case "ping":
        send(["pong": message["t"] ?? 0, "th": nowMs()])
    default:
        send(["error": "unknown command"])
    }
}

// stdin is read on its own thread; Mach ports and timers live on the main run loop.
Thread.detachNewThread {
    while let lengthData = readExactly(4) {
        let length = Int(lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard let body = readExactly(length),
              let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { break }
        DispatchQueue.main.async { handle(message) }
    }
    // Chrome closed the port.
    DispatchQueue.main.async { appLink.stop(); exit(0) }
}
RunLoop.main.run()
