import Foundation

if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--write" {
    let store = ControlStateStore(url: URL(fileURLWithPath: CommandLine.arguments[2]))
    try store.publish(mode: GazeMode(rawValue: CommandLine.arguments[3])!, processID: 42)
    exit(0)
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let url = directory.appendingPathComponent("state.json")
let reader = ControlStateStore(url: url)
precondition(reader.mode { _ in true } == .off, "A missing snapshot means Off")

// Keep the reader alive while distinct writer processes publish every mode in
// turn. Each completed write must be visible on the very first read.
for index in 0..<21 {
    let mode = GazeMode.allCases[index % 3]
    let writer = Process()
    writer.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    writer.arguments = ["--write", url.path, mode.rawValue]
    try writer.run(); writer.waitUntilExit()
    precondition(writer.terminationStatus == 0)
    precondition(reader.mode { $0 == 42 } == mode, "Stale cross-process control state")
}
try reader.publish(mode: .lockedGaze, processID: 42)
precondition(reader.mode { _ in false } == .off, "An exited host must not leave a running mode")
try reader.publish(mode: .off, processID: 42)
precondition(reader.mode { _ in preconditionFailure("An Off snapshot must not query a host") } == .off)
try Data(#"{"active":true,"processID":42}"#.utf8).write(to: url)
precondition(reader.mode { _ in true } == .off, "A snapshot from 1.0.1 reads as Off")
try Data("invalid snapshot".utf8).write(to: url)
precondition(reader.mode { _ in true } == .off, "Corrupt state must fail closed")
print("PASS: fresh cross-process mode state for all three modes; missing, older or corrupt state and a stopped host read as Off")
