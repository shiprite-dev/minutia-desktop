import Foundation

/// Thrown by `withTimeout` when the wrapped operation misses its deadline. Surfaced by the
/// stop/finalize path so a stuck upload becomes a recoverable `.error` instead of an endless spinner.
struct TimeoutError: Error {}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
    func claim() -> Bool { lock.withLock { defer { flag = true }; return !flag } }
}

/// Returns after `work` finishes or `seconds` pass, whichever is first. Both run as unstructured tasks,
/// so a wedged `work` or an already-cancelled caller cannot hold the wait open.
func waitAtMost(seconds: TimeInterval, _ work: @escaping @Sendable () async -> Void) async {
    let once = LockedFlag()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() { continuation.resume() }
        }
        Task {
            await work()
            timer.cancel()
            if once.claim() { continuation.resume() }
        }
    }
}

/// Runs `operation`, throwing `TimeoutError` if it does not finish within `seconds`. Whichever child
/// loses the race (the operation or the timer) is cancelled once the first result lands.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
