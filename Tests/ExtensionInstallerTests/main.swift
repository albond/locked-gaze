import Foundation
import SystemExtensions

@main struct ExtensionInstallerTests {
    @MainActor static func main() async throws {
        var submitted: [OSSystemExtensionRequest] = []
        let installer = ExtensionInstaller(submit: { submitted.append($0) }, probeEnabled: { false }, unsignedBuild: { false })
        let first = Task { try await installer.activate() }
        while submitted.count < 1 { await Task.yield() }
        let old = submitted[0]
        installer.requestNeedsUserApproval(old)
        do { try await first.value; preconditionFailure() } catch is ExtensionInstaller.ApprovalError {}
        do { try await installer.activate(); preconditionFailure("Duplicate system request") } catch is ExtensionInstaller.ApprovalError {}
        precondition(submitted.count == 1)
        installer.request(old, didFinishWithResult: .completed)
        let retry = Task { try await installer.activate() }
        while submitted.count < 2 { await Task.yield() }
        installer.request(old, didFailWithError: GazeError.message("Late stale failure"))
        installer.request(submitted[1], didFinishWithResult: .completed)
        try await retry.value
        // Double completion must not resume an already resumed continuation.
        installer.request(submitted[1], didFinishWithResult: .completed)
        let failed = Task { try await installer.activate() }
        while submitted.count < 3 { await Task.yield() }
        installer.request(submitted[2], didFailWithError: GazeError.message("Denied by OS"))
        do { try await failed.value; preconditionFailure() } catch { precondition(error.localizedDescription == "Denied by OS") }
        let reboot = Task { try await installer.activate() }
        while submitted.count < 4 { await Task.yield() }
        installer.request(submitted[3], didFinishWithResult: .willCompleteAfterReboot)
        do { try await reboot.value; preconditionFailure() } catch { precondition(error.localizedDescription.contains("Restart")) }
        let unsigned = ExtensionInstaller(submit: { _ in preconditionFailure("Unsigned build submitted installation") }, unsignedBuild: { true })
        do { try await unsigned.activate(); preconditionFailure() } catch {}
        // Regression: Settings enabled the extension, but activation completion
        // never arrived. Check Again must use a fresh OS status, not loop forever.
        var enabled = false, probes = 0
        var delayedRequest: OSSystemExtensionRequest?
        let delayed = ExtensionInstaller(submit: { delayedRequest = $0 }, probeEnabled: { probes += 1; return enabled }, unsignedBuild: { false })
        let waiting = Task { try await delayed.activate() }
        while delayedRequest == nil { await Task.yield() }
        let stale = delayedRequest!
        delayed.requestNeedsUserApproval(stale)
        do { try await waiting.value; preconditionFailure() } catch is ExtensionInstaller.ApprovalError {}
        do { try await delayed.activate(); preconditionFailure() } catch is ExtensionInstaller.ApprovalError {}
        enabled = true
        try await delayed.activate()
        precondition(probes == 3, "Each Check Again must query current permission")
        delayed.request(stale, didFailWithError: GazeError.message("Stale failure after approval"))
        let alreadyEnabled = ExtensionInstaller(submit: { _ in preconditionFailure("Reinstalled an enabled extension") }, probeEnabled: { true }, unsignedBuild: { false })
        try await alreadyEnabled.activate()
        try await alreadyEnabled.activate()
        print("PASS: approval succeeds even when the original completion callback never arrives")
        print("PASS: extension approval, pending recheck, approved retry, stale/double callbacks, OS failure, reboot required, unsigned build")
    }
}
