import Foundation

@MainActor final class Latch {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@main struct LifecycleTests {
    @MainActor static func main() async throws {
        var events: [String] = []
        var deny = false, broken = false
        let controller = CameraLifecycle(prepare: { events.append("permission"); if deny { throw GazeError.message("Denied") } },
            start: { events.append("start"); if broken { throw GazeError.message("Model failure") } },
            stop: { events.append("stop") })
        try await controller.setEnabled(false); precondition(events.isEmpty)
        for _ in 0..<25 {
            try await controller.setEnabled(true); try await controller.setEnabled(true)
            precondition(controller.state == .active)
            try await controller.setEnabled(false); try await controller.setEnabled(false)
        }
        precondition(events.count == 75 && controller.state == .idle)
        deny = true
        do { try await controller.setEnabled(true); preconditionFailure() } catch {}
        precondition(events.suffix(2) == ["permission", "stop"] && controller.state == .idle)
        deny = false; broken = true
        do { try await controller.setEnabled(true); preconditionFailure() } catch {}
        precondition(controller.state == .idle && events.last == "stop")
        broken = false; try await controller.setEnabled(true)
        let handled = await controller.failed(GazeError.message("Disconnected"))
        precondition(handled && controller.state == .idle)
        let duplicate = await controller.failed(GazeError.message("Duplicate")); precondition(!duplicate)
        try await controller.setEnabled(true); await controller.shutdown()
        precondition(controller.state == .idle && controller.closing)
        do { try await controller.setEnabled(true); preconditionFailure() } catch {}
        // Quit during an awaited permission check must not start the camera later.
        let gate = Latch(); var starts = 0, stops = 0
        let pending = CameraLifecycle(prepare: { await gate.wait() }, start: { starts += 1 }, stop: { stops += 1 })
        let activation = Task { try await pending.setEnabled(true) }
        while gate.continuation == nil { await Task.yield() }
        do { try await pending.setEnabled(true); preconditionFailure("Double start accepted") } catch {}
        do { try await pending.setEnabled(false); preconditionFailure("Concurrent stop accepted") } catch {}
        let quitting = Task { await pending.shutdown() }
        while !pending.closing { await Task.yield() }
        gate.release(); await quitting.value
        do { try await activation.value; preconditionFailure() } catch is CancellationError {}
        precondition(starts == 0 && stops == 1 && pending.state == .idle)
        // Failure arriving before start returns must never publish active state.
        let startingGate = Latch(); var states: [CameraLifecycle.State] = []
        let starting = CameraLifecycle(prepare: {}, start: { await startingGate.wait() }, stop: {})
        starting.onChange = { states.append(starting.state) }
        let attempt = Task { try await starting.setEnabled(true) }
        while startingGate.continuation == nil { await Task.yield() }
        _ = await starting.failed(GazeError.message("Early stream failure"))
        startingGate.release()
        do { try await attempt.value; preconditionFailure() } catch { precondition(error.localizedDescription == "Early stream failure") }
        precondition(!states.contains(.active) && starting.state == .idle)
        // Switching cameras restarts in place: observers never see an idle session.
        var switchEvents: [String] = [], switchStates: [CameraLifecycle.State] = [], switchBroken = false
        let switching = CameraLifecycle(prepare: {}, start: { switchEvents.append("start"); if switchBroken { throw GazeError.message("Camera unavailable") } },
            stop: { switchEvents.append("stop") })
        try await switching.restart(); precondition(switchEvents.isEmpty && switching.state == .idle)
        try await switching.setEnabled(true)
        switching.onChange = { switchStates.append(switching.state) }
        try await switching.restart()
        precondition(switchStates == [.starting, .active] && switchEvents == ["start", "stop", "start"])
        switchBroken = true
        do { try await switching.restart(); preconditionFailure() } catch {}
        precondition(switchStates.suffix(2) == [.starting, .idle] && switchEvents.suffix(2) == ["start", "stop"])
        print("PASS: lifecycle idempotence, 25 restart cycles, permission/model failures, disconnect, duplicate failure, busy requests, quit during approval, early stream failure, in-place camera restart")
    }
}
