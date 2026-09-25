import Foundation

if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--write" {
    let store = ControlStateStore(url: URL(fileURLWithPath: CommandLine.arguments[2]))
    try store.publish(active: CommandLine.arguments[3] == "on", processID: 42)
    exit(0)
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let url = directory.appendingPathComponent("state.json")
let reader = ControlStateStore(url: url)
precondition(!reader.isActive { _ in true }, "A missing snapshot means inactive")

// Keep the reader alive while distinct writer processes publish alternating
// values. Each completed write must be visible on the very first read.
for index in 0..<20 {
    let active = index % 2 == 0
    let writer = Process()
    writer.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    writer.arguments = ["--write", url.path, active ? "on" : "off"]
    try writer.run(); writer.waitUntilExit()
    precondition(writer.terminationStatus == 0)
    precondition(reader.isActive { $0 == 42 } == active, "Stale cross-process control state")
}
try reader.publish(active: true, processID: 42)
precondition(!reader.isActive { _ in false }, "An exited host must not leave an active control")
try reader.publish(active: false, processID: 42)
precondition(!reader.isActive { _ in preconditionFailure("Inactive snapshot must not query a host") })
try Data("invalid snapshot".utf8).write(to: url)
precondition(!reader.isActive { _ in true }, "Corrupt state must fail closed")
print("PASS: fresh cross-process control state in both directions; missing/corrupt state and stopped host are inactive")
