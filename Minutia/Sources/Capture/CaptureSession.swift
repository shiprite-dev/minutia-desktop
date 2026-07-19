import Foundation
import Combine

/// Drives one meeting recording end to end: two ring buffers fed by the system-audio tap and the
/// mic, a 250ms mix/write tick, fast-lane segment uploads, and the stop-time finalize sequence.
/// UI-facing state is published on the main actor; the audio hot path runs on a private queue
/// inside `CapturePipeline`.
@MainActor
final class CaptureSession: ObservableObject {
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var segmentsUploaded = 0
    @Published private(set) var segmentsTotal = 0
    /// True while the upload queue is retrying through a network outage. Drives the "Reconnecting…"
    /// line in RecordingView; cleared the moment an upload lands or capture ends.
    @Published private(set) var reconnecting = false

    /// Fired when capture dies mid-flight (denied mic, disk-full write). Carries a user-facing
    /// message; the controller flips the UI to `.error`. Invoked on the main actor.
    var onFailure: (@MainActor (String) -> Void)?

    struct StopResult {
        let expectedSegments: Int?
        let transcriptRequested: Bool
    }

    enum CaptureError: Error { case notRunning }

    /// Ceiling for the stop-time network finalize (drain + upload + finalize + transcribe request).
    static let finalizeTimeout: TimeInterval = 30

    private var pipeline: CapturePipeline?
    private var queue: UploadQueue?
    private var client: MinutiaClient?
    private var meetingId: String?
    private var directory: URL?
    private var startedAt: Date?
    /// Bumped on every `start`. The upload queue's progress/reconnecting callbacks capture the
    /// generation live at their creation; a callback from a superseded capture (a stale retry loop
    /// from a prior meeting) is gated out so it can never write onto the current meeting's UI.
    private var captureGeneration = 0

    /// Wires the capture graph and starts recording. Synchronous by contract; the mic engine spins
    /// up asynchronously inside the pipeline so a permission prompt never blocks the caller. The
    /// capture directory lives under Application Support (durable across quit/crash) with a manifest
    /// so an interrupted meeting can be recovered on the next launch.
    func start(meetingId: String, seriesId: UUID?, client: MinutiaClient) throws {
        guard pipeline == nil else { return }

        // Canonicalize to the lowercase meeting id the DB row and the storage RLS policy use;
        // Swift's UUID.uuidString is uppercase, which the case-sensitive path check would deny.
        let meetingId = meetingId.lowercased()

        let dir = try CaptureStore.capturesRoot()
            .appendingPathComponent(meetingId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let manifest = CaptureManifest(
            meetingId: meetingId,
            seriesId: seriesId?.uuidString,
            instanceURL: client.instance,
            createdAt: Date())
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent(CaptureRecovery.manifestName))

        captureGeneration += 1
        let generation = captureGeneration

        let pipeline = try CapturePipeline(directory: dir)
        let queue = UploadQueue(
            transport: client,
            meetingId: meetingId,
            onProgress: { [weak self] uploaded in
                await MainActor.run {
                    guard let self, self.captureGeneration == generation else { return }
                    self.segmentsUploaded = uploaded
                }
            },
            onReconnecting: { [weak self] value in
                await MainActor.run {
                    guard let self, self.captureGeneration == generation else { return }
                    self.reconnecting = value
                }
            }
        )
        // Segments are handed to the queue synchronously on the tick queue, so `finishCapture`'s
        // tick-queue barrier guarantees every enqueue lands before `stop` drains. The main-actor
        // tick only drives UI (elapsed, level, live segment count).
        pipeline.onSegment = { segment in queue.enqueue(segment) }
        pipeline.onTick = { [weak self] peak, closedCount in
            Task { @MainActor in self?.handleTick(peak: peak, closedCount: closedCount) }
        }
        // A mic-denial (preserve == false: no useful audio yet) or a write failure such as disk-full
        // (preserve == true: keep the partial recording for startup recovery) both land here.
        pipeline.onFatal = { [weak self] error, preserve in
            Task { @MainActor in self?.handleFatal(error, preserveForRecovery: preserve) }
        }
        try pipeline.start()

        self.pipeline = pipeline
        self.queue = queue
        self.client = client
        self.meetingId = meetingId
        self.directory = dir
        self.startedAt = Date()
        elapsed = 0
        level = 0
        segmentsUploaded = 0
        segmentsTotal = 0
        reconnecting = false
    }

    /// Stops capture, drains fast-lane uploads, uploads the full recording, and requests the final
    /// transcription. Local files are deleted only once transcription has been accepted.
    func stop() async throws -> StopResult {
        guard let pipeline, let queue, let client, let meetingId, let directory else {
            throw CaptureError.notRunning
        }
        // Teardown must happen even if uploadRecording/finalize throws below; otherwise `pipeline`
        // stays non-nil and every future `start` silently no-ops. The error still propagates.
        // cancelAll stops any segment retry loop still running after the finalize window (drained
        // ones are already finished, so this only bites the abandoned-on-timeout case).
        defer {
            queue.cancelAll()
            self.pipeline = nil
            self.queue = nil
            self.client = nil
            self.meetingId = nil
            self.directory = nil
            self.startedAt = nil
            self.reconnecting = false
        }

        let finished = pipeline.finishCapture()
        if let finalSegment = finished?.finalSegment {
            queue.enqueue(finalSegment)
        }

        // Bound the network finalize so a stuck upload/finalize/transcribe (observed: a Kong 504 that
        // hung 60s+, and indefinite hangs on repeated failures) throws instead of pinning the UI in
        // .finalizing forever. TimeoutError propagates to the controller, which shows .error (Retry).
        let outcome = try await withTimeout(seconds: Self.finalizeTimeout) {
            let counts = await queue.drainAndWait()
            let total = counts.enqueued
            let allRegistered = total > 0 && counts.registered == total

            if let recording = finished?.recording {
                let path = try await client.uploadRecording(meetingId: meetingId, fileURL: recording.fileURL)
                let duration = Double(recording.frames) / MixPlan.sampleRate
                let attrs = try? FileManager.default.attributesOfItem(atPath: recording.fileURL.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                try await client.finalizeMeeting(meetingId: meetingId, audioPath: path, duration: duration, sizeBytes: size)
            }

            let expected = allRegistered ? total : nil
            var transcriptRequested = false
            do {
                try await client.requestTranscription(meetingId: meetingId, expectedSegments: expected)
                transcriptRequested = true
            } catch {
                transcriptRequested = false
            }
            return (counts: counts, expected: expected, transcriptRequested: transcriptRequested)
        }

        segmentsUploaded = outcome.counts.uploaded
        segmentsTotal = outcome.counts.enqueued

        Task { await client.warmSummary(meetingId: meetingId) }

        if outcome.transcriptRequested {
            try? FileManager.default.removeItem(at: directory)
        }

        return StopResult(expectedSegments: outcome.expected, transcriptRequested: outcome.transcriptRequested)
    }

    private func handleTick(peak: Float, closedCount: Int) {
        if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
        // Peak-hold with decay: snappy attack, gentle release for a readable meter.
        level = max(peak, level * 0.85)
        segmentsTotal += closedCount
    }

    /// Tears the pipeline down on a mid-capture fatal WITHOUT running the network finalize, resets
    /// published state, and surfaces a user message. `preserveForRecovery` keeps the capture dir on
    /// disk (real audio was written; startup recovery salvages it); otherwise the dir is deleted
    /// (mic denied at start left nothing worth keeping). Guarded so a double-fire is a no-op.
    private func handleFatal(_ error: Error, preserveForRecovery: Bool) {
        guard let pipeline else { return }
        pipeline.teardown()
        queue?.cancelAll()
        if !preserveForRecovery, let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        self.pipeline = nil
        self.queue = nil
        self.client = nil
        self.meetingId = nil
        self.directory = nil
        self.startedAt = nil
        elapsed = 0
        level = 0
        segmentsUploaded = 0
        segmentsTotal = 0
        reconnecting = false
        onFailure?(Self.failureMessage(for: error))
    }

    /// Whether a mic-start failure should preserve the capture dir for recovery. The system-audio
    /// tap runs synchronously and the 250ms tick writes the other participants' audio the whole time
    /// the mic permission dialog is up, so any frames on disk are real meeting audio worth salvaging;
    /// only a zero-frame denial (immediate/persisted) leaves nothing to keep.
    nonisolated static func shouldPreserve(framesWritten: Int64) -> Bool {
        framesWritten > 0
    }

    nonisolated static func failureMessage(for error: Error) -> String {
        if let micError = error as? MicCapture.CaptureError, case .permissionDenied = micError {
            return "Grant microphone access in System Settings to record."
        }
        return "Recording stopped: \(error.localizedDescription)"
    }
}

/// Owns the audio hot path off the main actor: ring buffers, the tap and mic, the segment writer,
/// and the 250ms mix/write tick. Reports the tick's peak level and any freshly closed segments
/// through `onTick`.
private final class CapturePipeline {
    /// Reports the tick's peak level and the number of segments closed this tick (for UI).
    var onTick: ((Float, Int) -> Void)?
    /// Hands each freshly closed segment off synchronously on `tickQueue` for immediate upload.
    var onSegment: ((SegmentWriter.ClosedSegment) -> Void)?
    /// Fired when capture cannot continue: a mic-start failure (Bool == false, nothing worth
    /// keeping) or a segment-write failure such as disk-full (Bool == true, preserve for recovery).
    var onFatal: ((Error, Bool) -> Void)?

    private let micBuffer: RingBuffer
    private let sysBuffer: RingBuffer
    private let tap: SystemAudioTap
    private let mic: MicCapture
    private let writer: SegmentWriter
    private let tickQueue = DispatchQueue(label: "app.minutia.capture.tick", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var micScratch: [Float]
    private var sysScratch: [Float]

    init(directory: URL) throws {
        let capacity = Int(MixPlan.sampleRate) * 5   // 5s of headroom per source
        micBuffer = RingBuffer(capacityFrames: capacity)
        sysBuffer = RingBuffer(capacityFrames: capacity)
        writer = try SegmentWriter(directory: directory)
        tap = SystemAudioTap(into: sysBuffer)
        mic = MicCapture(into: micBuffer)
        micScratch = [Float](repeating: 0, count: MixPlan.tickFrames)
        sysScratch = [Float](repeating: 0, count: MixPlan.tickFrames)
    }

    func start() throws {
        try tap.start()
        // A denied mic must surface, not be swallowed: without this a permission-denied recording
        // looks healthy but captures only system audio. Preserve the dir when the tick has already
        // written system audio during the permission prompt; deleting it would lose that audio.
        Task {
            do { try await mic.start() }
            catch { self.onFatal?(error, CaptureSession.shouldPreserve(framesWritten: self.writer.totalFrames)) }
        }

        let timer = DispatchSource.makeTimerSource(queue: tickQueue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    /// Stops the timer, tap, and mic, then closes the files. Returns the trailing partial segment
    /// (if any) and the full recording.
    func finishCapture() -> (finalSegment: SegmentWriter.ClosedSegment?, recording: SegmentWriter.ClosedSegment)? {
        timer?.cancel()
        timer = nil
        // cancel() does not wait for an in-flight handler; barrier on tickQueue so no tick() is
        // running (or can start) before we stop the sources and close the writer. AVAudioFile is not
        // thread-safe, so append() must never overlap finish().
        tickQueue.sync {}
        tap.stop()
        mic.stop()
        return try? writer.finish()
    }

    /// Lightweight stop for the fatal path: halts the timer, tap, and mic, then flushes the writer's
    /// files (best-effort, so a preserved recording is as playable as possible) WITHOUT the network
    /// finalize. Shares finishCapture's tick-queue barrier discipline.
    func teardown() {
        timer?.cancel()
        timer = nil
        tickQueue.sync {}
        tap.stop()
        mic.stop()
        _ = try? writer.finish()
    }

    private func tick() {
        let plan = MixPlan.plan(micAvailable: micBuffer.availableFrames, sysAvailable: sysBuffer.availableFrames)
        let micGot = micBuffer.pop(into: &micScratch, count: plan.micFrames)
        let sysGot = sysBuffer.pop(into: &sysScratch, count: plan.sysFrames)
        let count = max(micGot, sysGot)
        guard count > 0 else {
            onTick?(0, 0)
            return
        }

        let mixed = MixPlan.mix(
            mic: Array(micScratch[0..<micGot]),
            sys: Array(sysScratch[0..<sysGot]),
            count: count
        )
        let closed: [SegmentWriter.ClosedSegment]
        do {
            closed = try writer.append(mixed)
        } catch {
            // Disk-full or any write failure: the audio already on disk is real, so preserve the
            // directory for startup recovery rather than silently dropping this and every later tick.
            onFatal?(error, true)
            return
        }
        for segment in closed { onSegment?(segment) }
        var peak: Float = 0
        for sample in mixed { peak = max(peak, abs(sample)) }
        onTick?(peak, closed.count)
    }
}
