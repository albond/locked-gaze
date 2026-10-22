import Foundation

@MainActor final class Latch {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@main struct GazeModeTests {
    @MainActor static func main() async throws {
        var events: [String] = []
        var correction: [Bool] = []
        let lifecycle = CameraLifecycle(prepare: {}, start: { events.append("start") }, stop: { events.append("stop") })
        let modes = GazeModeController(lifecycle: lifecycle) { correction.append($0) }
        precondition(modes.target == .off && correction == [true])

        // Off -> Pass-through starts the camera without correction.
        try await modes.set(.passThrough)
        precondition(events == ["start"] && lifecycle.state == .active && modes.target == .passThrough && correction.last == false)
        // Pass-through <-> Locked Gaze flips correction only: no restart, no stop.
        for _ in 0..<20 {
            try await modes.set(.lockedGaze); precondition(modes.target == .lockedGaze && correction.last == true)
            try await modes.set(.passThrough); precondition(modes.target == .passThrough && correction.last == false)
        }
        precondition(events == ["start"], "Switching between running modes must not restart the camera")
        let flips = correction.count
        try await modes.set(.passThrough); precondition(correction.count == flips, "Re-selecting the mode is a no-op")
        // Locked Gaze -> Off and Off -> Locked Gaze skip the middle mode.
        try await modes.set(.lockedGaze); try await modes.set(.off)
        precondition(events == ["start", "stop"] && modes.target == .off)
        try await modes.set(.lockedGaze)
        precondition(events == ["start", "stop", "start"] && modes.target == .lockedGaze && correction.last == true)
        try await modes.set(.off); try await modes.set(.off)
        precondition(events.last == "stop" && events.count == 4 && lifecycle.state == .idle)
        // The last running mode is kept while off, but Off still reads as Off.
        try await modes.set(.passThrough); try await modes.set(.off)
        precondition(modes.target == .off && !modes.correcting)
        print("PASS: Off, Pass-through and Locked Gaze in every order; running modes switch without a restart")

        // While the camera is starting, a running mode only changes correction for that start.
        let gate = Latch(); var starts = 0
        let slow = CameraLifecycle(prepare: { await gate.wait() }, start: { starts += 1 }, stop: {})
        var slowCorrection: [Bool] = []
        let slowModes = GazeModeController(lifecycle: slow) { slowCorrection.append($0) }
        var changes = 0
        slowModes.onChange = { changes += 1 }
        let starting = Task { try await slowModes.set(.lockedGaze) }
        while gate.continuation == nil { await Task.yield() }
        try await slowModes.set(.passThrough)
        precondition(slowModes.target == .passThrough && slowCorrection.last == false && changes == 1)
        gate.release(); try await starting.value
        precondition(starts == 1 && slow.state == .active && slowModes.target == .passThrough)
        // While stopping, a running mode is refused and correction stays unchanged.
        let stopGate = Latch()
        let stopping = CameraLifecycle(prepare: {}, start: {}, stop: { await stopGate.wait() })
        let stoppingModes = GazeModeController(lifecycle: stopping) { _ in }
        try await stoppingModes.set(.lockedGaze)
        let stop = Task { try await stoppingModes.set(.off) }
        while stopGate.continuation == nil { await Task.yield() }
        do { try await stoppingModes.set(.passThrough); preconditionFailure("Accepted a mode while stopping") } catch {}
        precondition(stoppingModes.correcting)
        stopGate.release(); try await stop.value
        precondition(stopping.state == .idle)
        print("PASS: mode change during start applies to that start; during stop it is refused")
    }
}
