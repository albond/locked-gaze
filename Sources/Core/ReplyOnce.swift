import Foundation

/// A response, interruption, timeout and shutdown can race. Deliver exactly one
/// completion and release its captured frame/continuation immediately afterward.
final class ReplyOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Value) -> Void)?
    init(_ completion: @escaping (Value) -> Void) { self.completion = completion }
    func finish(_ value: Value) {
        let callback = lock.withLock { let current = completion; completion = nil; return current }
        callback?(value)
    }
}
