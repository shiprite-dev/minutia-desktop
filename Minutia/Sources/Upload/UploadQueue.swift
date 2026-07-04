import Foundation

/// Upload + register surface the queue drives. MinutiaClient satisfies it directly (its method
/// names and signatures already match), so tests can stand in a stub without touching the network.
protocol SegmentTransport {
    func uploadSegment(meetingId: String, seq: Int, fileURL: URL) async throws
    func registerSegment(meetingId: String, seq: Int) async throws -> Bool
}

extension MinutiaClient: SegmentTransport {}

/// Serializes per-segment upload-then-register with bounded exponential backoff. Each segment is
/// uploaded to storage once, then registered for fast-lane transcription; transient failures retry
/// up to `maxAttempts`, after which the local file is parked (left on disk) for the stop-time sweep.
/// A terminal register outcome (`false`, e.g. a 4xx/503 the server will not accept) counts as
/// uploaded-but-not-registered, never as a hard failure.
actor UploadQueue {
    static let maxAttempts = 6

    private let transport: any SegmentTransport
    private let meetingId: String
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let onProgress: @Sendable (Int) async -> Void

    private var uploaded = 0
    private var registered = 0
    private var failed = 0

    // Nonisolated intake so a synchronous caller (the audio tick) hands a segment over without a
    // detached Task or an actor hop. drainAndWait snapshots under the same lock, so every segment
    // enqueued before the drain begins is always tracked, awaited, and counted.
    private let intakeLock = NSLock()
    nonisolated(unsafe) private var pendingTasks: [Task<Void, Never>] = []
    nonisolated(unsafe) private var enqueuedCount = 0

    init(
        transport: any SegmentTransport,
        meetingId: String,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        onProgress: @escaping @Sendable (Int) async -> Void = { _ in }
    ) {
        self.transport = transport
        self.meetingId = meetingId
        self.sleep = sleep
        self.onProgress = onProgress
    }

    /// Backoff table between attempts: 1, 2, 4, 8, 16, 32, then 60 capped, in seconds.
    static func backoffSchedule(attempt: Int) -> TimeInterval {
        guard attempt >= 1 else { return 1 }
        if attempt >= 7 { return 60 }
        return min(60, TimeInterval(1 << (attempt - 1)))
    }

    /// Kicks off upload+register for one closed segment. Synchronous and nonisolated so the caller
    /// can hand off from the audio tick without awaiting; `drainAndWait` settles it.
    nonisolated func enqueue(_ segment: SegmentWriter.ClosedSegment) {
        let task = Task { await self.process(segment) }
        intakeLock.lock()
        pendingTasks.append(task)
        enqueuedCount += 1
        intakeLock.unlock()
    }

    /// Awaits every in-flight segment (including its retries) and returns the running totals. Any
    /// segment enqueued before this call is guaranteed to be included in `enqueued` and awaited.
    func drainAndWait() async -> (uploaded: Int, registered: Int, failed: Int, enqueued: Int) {
        while true {
            intakeLock.lock()
            let pending = pendingTasks
            pendingTasks.removeAll()
            intakeLock.unlock()
            if pending.isEmpty { break }
            for task in pending { await task.value }
        }
        intakeLock.lock()
        let total = enqueuedCount
        intakeLock.unlock()
        return (uploaded, registered, failed, total)
    }

    private func process(_ segment: SegmentWriter.ClosedSegment) async {
        var didUpload = false
        for attempt in 1...Self.maxAttempts {
            do {
                if !didUpload {
                    try await transport.uploadSegment(meetingId: meetingId, seq: segment.seq, fileURL: segment.fileURL)
                    didUpload = true
                    uploaded += 1
                    await onProgress(uploaded)
                }
                if try await transport.registerSegment(meetingId: meetingId, seq: segment.seq) {
                    registered += 1
                }
                return
            } catch {
                if attempt == Self.maxAttempts {
                    failed += 1
                    return
                }
                await sleep(Self.backoffSchedule(attempt: attempt))
            }
        }
    }
}
