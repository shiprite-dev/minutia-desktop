import Foundation

/// Upload + register surface the queue drives. MinutiaClient satisfies it directly (its method
/// names and signatures already match), so tests can stand in a stub without touching the network.
protocol SegmentTransport {
    func uploadSegment(meetingId: String, seq: Int, fileURL: URL) async throws
    func registerSegment(meetingId: String, seq: Int) async throws -> Bool
}

extension MinutiaClient: SegmentTransport {}

/// Serializes per-segment upload-then-register with capped exponential backoff. Each segment is
/// uploaded to storage once, then registered for fast-lane transcription; transient failures retry
/// with the capped schedule and effectively never give up while the session is live (`maxAttempts`
/// is a very high runaway ceiling, not a normal give-up point). A terminal register outcome
/// (`false`, e.g. a 4xx/503 the server will not accept) counts as uploaded-but-not-registered,
/// never as a hard failure. After a short streak of consecutive failures the queue signals
/// `reconnecting` so the UI can show it, clearing the signal the moment an upload lands.
actor UploadQueue {
    /// Runaway ceiling only: high enough that a normal outage never exhausts it, bounded so a
    /// pathological loop cannot spin truly forever. The stop-time drain is bounded separately by
    /// the session's finalize timeout.
    static let maxAttempts = 1000
    /// Consecutive failed attempts for a segment before the reconnecting signal is raised.
    static let reconnectThreshold = 3

    private let transport: any SegmentTransport
    private let meetingId: String
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let onProgress: @Sendable (Int) async -> Void
    private let onReconnecting: @Sendable (Bool) async -> Void
    private let onFeatureUnavailable: @Sendable () async -> Void

    private var uploaded = 0
    private var registered = 0
    private var failed = 0
    private var reconnecting = false
    /// Fired at most once per queue (one recording session): the account lacks the AI entitlement,
    /// so every remaining segment would hit the same terminal 403. One signal, no banner spam.
    private var featureUnavailableSignaled = false

    // Nonisolated intake so a synchronous caller (the audio tick) hands a segment over without a
    // detached Task or an actor hop. drainAndWait snapshots under the same lock, so every segment
    // enqueued before the drain begins is always tracked, awaited, and counted.
    private let intakeLock = NSLock()
    nonisolated(unsafe) private var pendingTasks: [Task<Void, Never>] = []
    // Append-only mirror of every spawned task, kept alive independently of drainAndWait's draining
    // so cancelAll can still reach in-flight retry loops after they leave pendingTasks.
    nonisolated(unsafe) private var spawnedTasks: [Task<Void, Never>] = []
    nonisolated(unsafe) private var enqueuedCount = 0

    init(
        transport: any SegmentTransport,
        meetingId: String,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        onProgress: @escaping @Sendable (Int) async -> Void = { _ in },
        onReconnecting: @escaping @Sendable (Bool) async -> Void = { _ in },
        onFeatureUnavailable: @escaping @Sendable () async -> Void = {}
    ) {
        self.transport = transport
        self.meetingId = meetingId
        self.sleep = sleep
        self.onProgress = onProgress
        self.onReconnecting = onReconnecting
        self.onFeatureUnavailable = onFeatureUnavailable
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
        spawnedTasks.append(task)
        enqueuedCount += 1
        intakeLock.unlock()
    }

    /// Cancels every spawned segment task so an abandoned retry loop (a segment stuck failing for up
    /// to the runaway ceiling) stops promptly once its capture ends. `process` checks `Task
    /// .isCancelled` cooperatively, so cancelled loops return instead of spinning ~16h. Nonisolated
    /// so `CaptureSession.stop`'s synchronous defer and the fatal teardown can call it without an
    /// actor hop. Idempotent: cancelling a finished task is a no-op.
    nonisolated func cancelAll() {
        intakeLock.lock()
        let tasks = spawnedTasks
        intakeLock.unlock()
        for task in tasks { task.cancel() }
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
        var attempt = 1
        while attempt <= Self.maxAttempts {
            if Task.isCancelled { return }
            do {
                if !didUpload {
                    try await transport.uploadSegment(meetingId: meetingId, seq: segment.seq, fileURL: segment.fileURL)
                    didUpload = true
                    uploaded += 1
                    await onProgress(uploaded)
                    await setReconnecting(false)
                }
                if try await transport.registerSegment(meetingId: meetingId, seq: segment.seq) {
                    registered += 1
                }
                return
            } catch MinutiaClientError.featureUnavailable {
                // Terminal entitlement failure: retrying is futile. The upload already landed, so the
                // segment stays uploaded-but-not-registered (never counted failed); signal once.
                await signalFeatureUnavailable()
                return
            } catch {
                if attempt >= Self.maxAttempts {
                    failed += 1
                    return
                }
                if attempt >= Self.reconnectThreshold {
                    await setReconnecting(true)
                }
                await sleep(Self.backoffSchedule(attempt: attempt))
                if Task.isCancelled { return }
                attempt += 1
            }
        }
    }

    /// Emits only on transitions so the UI is not spammed while an outage persists.
    private func setReconnecting(_ value: Bool) async {
        guard reconnecting != value else { return }
        reconnecting = value
        await onReconnecting(value)
    }

    /// Fires the entitlement-missing signal at most once for the queue's lifetime.
    private func signalFeatureUnavailable() async {
        guard !featureUnavailableSignaled else { return }
        featureUnavailableSignaled = true
        await onFeatureUnavailable()
    }
}
