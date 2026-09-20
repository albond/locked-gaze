import Foundation

@main struct PermissionTests {
    @MainActor static func main() async throws {
        var status = PermissionGate.Status.authorized
        var requests = 0, prompts = 0
        func run(_ answer: Bool = true) async throws {
            try await PermissionGate.ensure(probe: { status }, request: { requests += 1 }, prompt: { _ in prompts += 1; return answer })
        }
        try await run()
        precondition(requests == 0 && prompts == 0, "Existing approval must not prompt")
        status = .notDetermined
        try await PermissionGate.ensure(probe: { status }, request: { requests += 1; status = .authorized }, prompt: { _ in preconditionFailure("Unexpected Settings prompt") })
        precondition(requests == 1)
        status = .notDetermined; requests = 0; prompts = 0
        try await PermissionGate.ensure(probe: { status }, request: { requests += 1; status = .denied }, prompt: { observed in
            precondition(observed == .denied)
            prompts += 1
            if prompts == 3 { status = .authorized }
            return true
        })
        precondition(requests == 1 && prompts == 3, "Recheck each time; never treat Check Again as permission")
        for blocked in [PermissionGate.Status.denied, .restricted, .notDetermined] {
            status = blocked; requests = 0; prompts = 0
            do { try await run(false); preconditionFailure("Cancel must abort activation") }
            catch is CancellationError {} catch { throw error }
            precondition(prompts == 1 && requests == (blocked == .notDetermined ? 1 : 0))
        }
        // A request callback completing without a status change is not approval.
        status = .notDetermined; requests = 0; prompts = 0
        try await PermissionGate.ensure(probe: { status }, request: { requests += 1 }, prompt: { _ in
            prompts += 1; status = .authorized; return true
        })
        precondition(requests == 1 && prompts == 1)
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await PermissionGate.ensure(probe: { .authorized }, request: { preconditionFailure() }, prompt: { _ in preconditionFailure() })
        }
        do { try await cancelled.value; preconditionFailure("Cancelled activation must stop") } catch is CancellationError {}
        print("PASS: permission granted, denied, restricted, no status change, repeated recheck, cancel, task cancellation")
    }
}
