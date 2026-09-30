import Foundation

/// Owns a continuation and its event-tap cleanup through success, cancellation,
/// and timeout. The recursive lock permits an event received during start() to
/// complete immediately, and prevents a late start from re-enabling stale taps.
final class EventOperationCompletion: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    private var cleanup: (() -> Void)?

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result == nil
    }

    /// Serializes the last liveness check, stage bookkeeping and actual post
    /// with cancellation. finish() cannot observe an unposted down and then
    /// let that down escape after the operation has already been cleaned up.
    func performIfPending<Value>(_ action: () -> Value) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return nil }
        return action()
    }

    func install(
        _ continuation: CheckedContinuation<Void, Error>,
        start: () -> Void,
        cleanup: @escaping () -> Void
    ) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        self.cleanup = cleanup
        start()
        lock.unlock()
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        cleanup?()
        cleanup = nil
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
