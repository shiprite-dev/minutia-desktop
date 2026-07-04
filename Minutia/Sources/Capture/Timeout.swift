import Foundation

/// Thrown by `withTimeout` when the wrapped operation misses its deadline. Surfaced by the
/// stop/finalize path so a stuck upload becomes a recoverable `.error` instead of an endless spinner.
struct TimeoutError: Error {}

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
