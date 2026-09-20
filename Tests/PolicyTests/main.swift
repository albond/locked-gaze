import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
func rejects(_ body: () throws -> Void) {
    do { try body(); preconditionFailure("Expected rejection") } catch {}
}
let devices = [CameraChoice(id: "external", name: "USB", connected: true),
               CameraChoice(id: "phone", name: "iPhone", connected: true),
               CameraChoice(id: "lost", name: "USB", connected: false),
               CameraChoice(id: "virtual", name: "Renamed", connected: true),
               CameraChoice(id: "other", name: "Locked Gaze", connected: true),
               CameraChoice(id: "phone", name: "Duplicate", connected: true)]
let available = CameraSelection.available(devices, virtualID: "virtual")
check(available.map(\.id) == ["external", "phone"], "Exclude disconnected, self, and duplicate cameras")
let explicit = try CameraSelection.select(available, requested: "phone", preferred: ["external"])
check(explicit == "phone", "Explicit choice wins")
let preferred = try CameraSelection.select(available, requested: nil, preferred: ["lost", "phone", "external"])
check(preferred == "phone", "Fall through unavailable user preference to system preference")
let fallback = try CameraSelection.select(available, requested: nil, preferred: ["virtual"])
check(fallback == "external", "Automatic fallback uses first physical camera")
rejects { _ = try CameraSelection.select(available, requested: "lost", preferred: ["phone"]) }
rejects { _ = try CameraSelection.select([], requested: nil, preferred: []) }

var mailbox = FrameMailbox<Int>(lifetime: 0.25)
check(mailbox.frame(at: 0) == nil, "No producer means black")
mailbox.append(1, at: 1); mailbox.append(2, at: 1.01); mailbox.append(3, at: 1.02)
check(mailbox.frame(at: 1.03) == 2, "Overflow discards oldest, retaining two-frame jitter buffer")
check(mailbox.frame(at: 1.04) == 3, "Preserve order")
check(mailbox.frame(at: 1.269) == 3, "Repeat only fresh latest frame")
check(mailbox.frame(at: 1.27) == nil, "Exact expiry returns black")
mailbox.append(4, at: 2); mailbox.reset()
check(mailbox.frame(at: 2) == nil, "Disconnect clears queued and retained frames")
mailbox.append(5, at: 3)
check(mailbox.frame(at: 2) == nil, "Clock rollback must not retain future frames")
mailbox.append(6, at: .nan); mailbox.append(7, at: .infinity)
check(mailbox.frame(at: 4) == nil, "Reject invalid producer timestamps")
mailbox.append(8, at: 4)
check(mailbox.frame(at: .nan) == nil && mailbox.frame(at: 4) == nil, "Invalid clock clears state")
final class Frame {}
var frames = FrameMailbox<Frame>(lifetime: 0.25)
var object: Frame? = Frame(); weak var released = object
frames.append(object!, at: 1); object = nil
_ = frames.frame(at: 1)
frames.reset()
check(released == nil, "Disconnect releases buffers immediately")
print("PASS: camera selection, disconnection, overflow, exact expiry, clock faults, buffer lifetime")
