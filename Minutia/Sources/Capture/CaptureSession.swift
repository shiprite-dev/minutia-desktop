import Foundation
import Combine
import os

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
    /// True when the system-audio tap could not start (or a mid-recording rebuild permanently
    /// failed), so only the microphone is being captured. Drives a persistent caption in
    /// RecordingView. Reset false on every start.
    @Published private(set) var systemAudioDegraded = false
    /// True when no microphone exists, so only system audio is being captured. Reset like
    /// `systemAudioDegraded`.
    @Published private(set) var micUnavailable = false
    @Published private(set) var finishingStep: FinishingStep?

    static let micUnavailableNotice = "No microphone found. Recording meeting audio only."

    /// Fired when capture dies mid-flight (denied mic, disk-full write). Carries a user-facing
    /// message and whether the capture directory was preserved for startup recovery (a disk-full or
    /// stall keeps the partial audio; a zero-frame mic denial does not). Invoked on the main actor.
    var onFailure: (@MainActor (String, Bool) -> Void)?

    /// Fired once per recording when a fast-lane segment register returns the account-lacks-AI
    /// terminal 403. Recording and uploads continue; the controller surfaces a single banner.
    var onTranscriptionUnavailable: (@MainActor () -> Void)?

    struct StopResult {
        let expectedSegments: Int?
        let transcriptRequested: Bool
        /// Set when a device meeting's local transcription failed and the stop finished in the cloud instead.
        var localFailure: LocalTranscriber.Failure? = nil
    }

    enum CaptureError: Error { case notRunning, stalled, recordingUnfinished, alreadyRunning, invalidMeetingId, transcriptionBlocked(TranscriptionReason),
        transcriptNotSent, transcriptRejected, localTranscriptionTimedOut, nothingRecorded, transcriptTooLarge }

    /// Ceiling for the stop-time network finalize (drain + upload + finalize + transcribe request).
    static let finalizeTimeout: TimeInterval = 60

    /// If no audio frames drain for this long while recording, the tap and mic have both stalled and
    /// the recording is silently frozen; the session flips to a fatal error rather than pinning a
    /// dead clock. A quiet meeting still drains silent samples, so this only fires on a true stall.
    static let watchdogTimeout: TimeInterval = 15

    private var pipeline: CapturePipeline?
    private var queue: UploadQueue?
    private(set) var audioMayLeaveMac = true
    private var client: MinutiaClient?
    private var transcriber: LocalTranscriber?
    private var meetingId: String?
    private var directory: URL?
    private var startedAt: Date?
    /// Last wall-clock time audio frames were actually drained from the ring buffers. Seeded at
    /// start so the watchdog has a grace period before audio flows.
    private var lastFramesAt: Date?
    /// Bumped on every `start`. The upload queue's progress/reconnecting callbacks capture the
    /// generation live at their creation; a callback from a superseded capture (a stale retry loop
    /// from a prior meeting) is gated out so it can never write onto the current meeting's UI.
    private var captureGeneration = 0
    private var finishingGeneration = 0

    /// Wires the capture graph and starts recording. Synchronous by contract; the mic engine spins
    /// up asynchronously inside the pipeline so a permission prompt never blocks the caller. The
    /// capture directory lives under Application Support (durable across quit/crash) with a manifest
    /// so an interrupted meeting can be recovered on the next launch.
    func start(meetingId: String, seriesId: UUID?, userId: String?, client: MinutiaClient,
               decision: TranscriptionDecision, deviceOnly: Bool, language: String?,
               transcriber: LocalTranscriber? = nil) throws {
        if case .blocked(let reason) = decision { throw CaptureError.transcriptionBlocked(reason) }
        if transcriber == nil, decision.mode != .cloud || deviceOnly { throw CaptureError.transcriptionBlocked(.modelNotReady) }
        guard pipeline == nil else { throw CaptureError.alreadyRunning }
        guard let canonical = UUID(uuidString: meetingId) else { throw CaptureError.invalidMeetingId }

        // Canonicalize to the lowercase meeting id the DB row and the storage RLS policy use;
        // Swift's UUID.uuidString is uppercase, which the case-sensitive path check would deny.
        let meetingId = canonical.uuidString.lowercased()

        let dir = try CaptureStore.capturesRoot()
            .appendingPathComponent(meetingId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let manifest = CaptureManifest(
            meetingId: meetingId,
            seriesId: seriesId?.uuidString,
            instanceURL: client.instance,
            userId: userId,
            createdAt: Date(),
            transcriptionMode: decision.mode,
            deviceOnly: deviceOnly,
            language: language)
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
            },
            onFeatureUnavailable: { [weak self] in
                await MainActor.run {
                    guard let self, self.captureGeneration == generation else { return }
                    self.onTranscriptionUnavailable?()
                }
            }
        )
        // Segments are handed to the queue synchronously on the tick queue, so `finishCapture`'s
        // tick-queue barrier guarantees every enqueue lands before `stop` drains. The main-actor
        // tick only drives UI (elapsed, level, live segment count).
        if manifest.audioMayLeaveMac {
            pipeline.onSegment = { segment in queue.enqueue(segment) }
        } else if let transcriber {
            pipeline.onSegment = { segment in transcriber.enqueue(segment) }
        }
        pipeline.onTick = { [weak self] peak, closedCount, framesDrained in
            Task { @MainActor in self?.handleTick(peak: peak, closedCount: closedCount, framesDrained: framesDrained) }
        }
        // A mic-denial (preserve == false: no useful audio yet) or a write failure such as disk-full
        // (preserve == true: keep the partial recording for startup recovery) both land here.
        pipeline.onFatal = { [weak self] error, preserve in
            Task { @MainActor in self?.handleFatal(error, preserveForRecovery: preserve) }
        }
        // System audio is best-effort: a tap that never starts (no output device) or one whose
        // mid-recording rebuild permanently fails degrades to mic-only. Surface it so the user is
        // never silently recording only their own side.
        pipeline.onSystemAudioUnavailable = { [weak self] in
            Task { @MainActor in self?.systemAudioDegraded = true }
        }
        pipeline.onSystemAudioRecovered = { [weak self] in
            Task { @MainActor in self?.systemAudioDegraded = false }
        }
        pipeline.onMicUnavailable = { [weak self] in
            Task { @MainActor in self?.micUnavailable = true }
        }
        try pipeline.start()
        if !manifest.audioMayLeaveMac, let transcriber { Task { await transcriber.startLoading() } }

        self.transcriber = transcriber
        self.pipeline = pipeline
        self.queue = queue
        self.client = client
        self.audioMayLeaveMac = manifest.audioMayLeaveMac
        self.meetingId = meetingId
        self.directory = dir
        self.startedAt = Date()
        self.lastFramesAt = self.startedAt
        elapsed = 0
        level = 0
        segmentsUploaded = 0
        segmentsTotal = 0
        reconnecting = false
        systemAudioDegraded = false
        micUnavailable = false
    }

    /// Stops capture, drains fast-lane uploads, uploads the full recording, and requests the final
    /// transcription. Local files are deleted only once transcription has been accepted.
    func stop(flushNotes: @escaping @Sendable () async throws -> Void = {}, recapOpened: Bool = false) async throws -> StopResult {
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
            self.transcriber = nil
            self.endFinishing()
            self.meetingId = nil
            self.directory = nil
            self.startedAt = nil
            self.lastFramesAt = nil
            self.reconnecting = false
            self.micUnavailable = false
        }

        if !audioMayLeaveMac, let transcriber {
            guard let finished = pipeline.finishCapture() else { throw CaptureError.recordingUnfinished }
            let tail = finished.tailPieces.isEmpty ? [finished.finalSegment].compactMap { $0 } : finished.tailPieces
            return try await Self.finishOnDevice(
                meetingId: meetingId, directory: directory, tail: tail,
                durationSeconds: Double(finished.recording.frames) / MixPlan.sampleRate,
                transcriber: transcriber, transport: client, recapOpened: recapOpened,
                flushNotes: flushNotes, onStep: finishingStepReporter())
        }

        // Without a finished recording the server has nothing to transcribe; throwing keeps the
        // directory so recovery uploads the readable fragmented file instead of deleting it.
        guard let finished = pipeline.finishCapture() else { throw CaptureError.recordingUnfinished }
        if !finished.tailPieces.isEmpty {
            for piece in finished.tailPieces { queue.enqueue(piece) }
        } else if let finalSegment = finished.finalSegment {
            queue.enqueue(finalSegment)
        }

        // Bound the network finalize so a stuck upload/finalize/transcribe (observed: a Kong 504 that
        // hung 60s+, and indefinite hangs on repeated failures) throws instead of pinning the UI in
        // .finalizing forever. TimeoutError propagates to the controller, which shows .error (Retry).
        let outcome = try await withTimeout(seconds: Self.finalizeTimeout) {
            let recording = finished.recording
            async let uploadedPath = client.uploadRecording(meetingId: meetingId, fileURL: recording.fileURL)
            let counts = await queue.drainAndWait()
            let expected = Self.expectedSegments(
                enqueued: counts.enqueued, registered: counts.registered,
                segmentsDropped: finished.segmentsDropped)
            let path = try await uploadedPath
            let duration = Double(recording.frames) / MixPlan.sampleRate
            let attrs = try? FileManager.default.attributesOfItem(atPath: recording.fileURL.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            try await client.finalizeMeeting(meetingId: meetingId, audioPath: path, duration: duration, sizeBytes: size)

            // A failed requestTranscription must never read as an accepted transcript: it rethrows so
            // the controller shows .failed (Retry re-runs refinalize) and the audio directory is kept
            // below, deleted only when the request truly succeeds (a 2xx, or the terminal-503 the
            // client treats as not-lost since the transcript assembles from fast-lane segments).
            _ = try await NotepadFinalize.flushThenTranscribe(
                flush: flushNotes,
                requestTranscription: { try await client.requestTranscription(meetingId: meetingId, expectedSegments: expected, deferExtraction: true) })
            return (counts: counts, expected: expected, transcriptRequested: true)
        }

        segmentsUploaded = outcome.counts.uploaded
        segmentsTotal = outcome.counts.enqueued

        if !recapOpened { Task { await client.warmSummary(meetingId: meetingId) } }
        Task { await Self.endMeetingIfAllowed { try await client.endMeeting(meetingId: meetingId) } }

        if outcome.transcriptRequested {
            try? FileManager.default.removeItem(at: directory)
        }

        return StopResult(expectedSegments: outcome.expected, transcriptRequested: outcome.transcriptRequested)
    }

    private func handleTick(peak: Float, closedCount: Int, framesDrained: Int) {
        let now = Date()
        if let startedAt { elapsed = now.timeIntervalSince(startedAt) }
        // Peak-hold with decay: snappy attack, gentle release for a readable meter.
        level = max(peak, level * 0.85)
        segmentsTotal += closedCount

        if framesDrained > 0 {
            lastFramesAt = now
        } else if let lastFramesAt,
                  Self.shouldWatchdogFire(
                    secondsSinceFrames: now.timeIntervalSince(lastFramesAt),
                    threshold: Self.watchdogTimeout) {
            handleFatal(CaptureError.stalled, preserveForRecovery: true)
        }
    }

    /// Only a fully registered set of fast-lane segments is announced; otherwise (none registered on
    /// a server that rejects segment registers, or some lost) the server transcribes the whole
    /// recording instead of waiting on segments that never arrive, or when the writer stopped producing
    /// segments mid-recording.
    nonisolated static func expectedSegments(enqueued: Int, registered: Int, segmentsDropped: Bool = false) -> Int? {
        !segmentsDropped && enqueued > 0 && registered == enqueued ? enqueued : nil
    }

    /// The `onStep` for the device stop in flight; a step it reports after `endFinishing` is dropped.
    func finishingStepReporter() -> @Sendable (FinishingStep) async -> Void {
        let generation = finishingGeneration
        return { [weak self] step in await MainActor.run {
            guard let self, self.finishingGeneration == generation else { return }
            self.finishingStep = step } }
    }

    /// Ends the device stop in flight and clears its step.
    func endFinishing() { finishingGeneration += 1; finishingStep = nil }

    /// What a device-mode stop is doing, shown by the finishing view. nil in cloud mode.
    enum FinishingStep: Equatable, Sendable {
        case preparingModel
        case transcribing(completed: Int, total: Int)
        case submitting

        var label: String {
            switch self {
            case .preparingModel: "Preparing the speech model"
            case .transcribing(let completed, let total): "Transcribing on this Mac, \(completed) of \(total)"
            case .submitting: "Sending the transcript"
            }
        }
    }

    /// Waits between transcript submits after a 409, a 401, a 5xx or a network error.
    nonisolated static let submitBackoff: [TimeInterval] = [1, 2, 4, 8, 16]

    /// POSTs the device transcript. A 2xx (a replay included) returns; a 409, 401, retriable 5xx or
    /// network error retries after each `submitBackoff` wait; anything else, or running out of
    /// waits, throws.
    nonisolated static func submitDeviceTranscript(
        meetingId: String, body: Data, transport: any DeviceTranscriptTransport,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) async throws {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            var status: Int?
            var failure: Error?
            do { status = try await transport.submitDeviceTranscript(meetingId: meetingId, body: body) } catch { failure = error }
            if let status, (200...299).contains(status) { return }
            if let status, (400...499).contains(status), ![401, 403, 408, 409, 429].contains(status) { throw CaptureError.transcriptRejected }
            let retryable: Bool
            if let status {
                retryable = status == 409 || [.authExpired, .transientRetryable].contains(MinutiaClient.classify(status: status, body: nil))
            } else {
                retryable = true
            }
            guard retryable, attempt < submitBackoff.count else {
                throw failure ?? MinutiaClientError.serverError(status: status ?? 0)
            }
            await sleep(submitBackoff[attempt])
            try Task.checkCancellation()
            attempt += 1
        }
    }

    /// The device-mode stop after capture has finished: finishes local transcription, writes
    /// `transcript.json`, marks the meeting as waiting for this Mac, submits it, deletes the directory on
    /// a 2xx, then warms the summary (unless the recap already opened) and ends the meeting.
    nonisolated static func finishOnDevice(
        meetingId: String, directory: URL, tail: [SegmentWriter.ClosedSegment], durationSeconds: Double,
        transcriber: LocalTranscriber, transport: any DeviceTranscriptTransport, recapOpened: Bool,
        deviceOnly: Bool = true, cloud: (any CloudFinalizeTransport)? = nil,
        transcribeTimeout: TimeInterval? = nil,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        flushNotes: @escaping @Sendable () async throws -> Void = {},
        onStep: @escaping @Sendable (FinishingStep) async -> Void = { _ in },
        notifyLocalFailure: @escaping @Sendable (LocalTranscriber.Failure) async -> Void = { _ in }
    ) async throws -> StopResult {
        guard durationSeconds > 0 else { throw CaptureError.nothingRecorded }
        async let notesFlushed: Void = { try? await flushNotes() }()
        let transcript: DeviceTranscript
        do {
            transcript = try await transcribeBounded(seconds: transcribeTimeout ?? localTranscriptionTimeout(durationSeconds: durationSeconds)) {
                try await transcriber.finish(tail: tail, durationSeconds: durationSeconds, onStep: onStep)
            }
        } catch CaptureError.localTranscriptionTimedOut {
            await transcriber.cancel()
            throw CaptureError.localTranscriptionTimedOut
        }
        guard let fitted = transcript.fitted() else { throw CaptureError.transcriptTooLarge }
        let body = try fitted.encoded()
        await notesFlushed
        try body.write(to: directory.appendingPathComponent(CaptureRecovery.transcriptName), options: .atomic)
        try? await transport.markAwaitingDeviceTranscript(meetingId: meetingId, durationSeconds: fitted.durationSeconds)
        await onStep(.submitting)
        do {
            try await withTimeout(seconds: finalizeTimeout) {
                try await submitDeviceTranscript(meetingId: meetingId, body: body, transport: transport, sleep: sleep)
            }
        } catch CaptureError.transcriptRejected {
            throw CaptureError.transcriptRejected
        } catch {
            throw CaptureError.transcriptNotSent
        }
        try? FileManager.default.removeItem(at: directory)
        if !recapOpened { Task { await transport.warmSummary(meetingId: meetingId) } }
        Task { await endMeetingIfAllowed { try await transport.endMeeting(meetingId: meetingId) } }
        return StopResult(expectedSegments: nil, transcriptRequested: true)
    }

    /// How long Quit waits for a stop already in flight.
    nonisolated static func quitDeadline(audioMayLeaveMac: Bool, elapsedSeconds: TimeInterval,
                                         finalizeTimeout: TimeInterval = CaptureSession.finalizeTimeout) -> TimeInterval {
        (audioMayLeaveMac ? 0 : localTranscriptionTimeout(durationSeconds: elapsedSeconds)) + finalizeTimeout + 5
    }

    /// Ceiling on local transcription at stop; past it the stop fails with a retryable error.
    nonisolated static func localTranscriptionTimeout(durationSeconds: Double) -> TimeInterval {
        max(180, durationSeconds / 10)
    }

    /// Races the work against a timer with a continuation that resumes once. A task group would
    /// wait for a wedged child: awaiting an unstructured task's value ignores cancellation.
    nonisolated static func transcribeBounded(
        seconds: TimeInterval,
        timer: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        _ work: @escaping @Sendable () async throws -> DeviceTranscript
    ) async throws -> DeviceTranscript {
        final class TimerBox: @unchecked Sendable {
            let lock = NSLock()
            var task: Task<Void, Never>?
            var job: Task<Void, Never>?
        }
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
        }
        let once = Once()
        let box = TimerBox()
        return try await withCheckedThrowingContinuation { continuation in
            box.lock.lock()
            defer { box.lock.unlock() }
            box.task = Task {
                do { try await timer(seconds) } catch { return }
                if once.first() {
                    box.lock.withLock { box.job }?.cancel()
                    continuation.resume(throwing: CaptureError.localTranscriptionTimedOut)
                }
            }
            box.job = Task {
                do {
                    let transcript = try await work()
                    if once.first() { continuation.resume(returning: transcript) }
                } catch {
                    if once.first() { continuation.resume(throwing: error) }
                }
                box.lock.withLock { box.task }?.cancel()
            }
        }
    }

    nonisolated static func shouldWatchdogFire(secondsSinceFrames: TimeInterval, threshold: TimeInterval) -> Bool {
        secondsSinceFrames >= threshold
    }

    /// Only series owners and facilitators may change a meeting's status, so a refusal must not fail the stop.
    nonisolated static func endMeetingIfAllowed(_ end: () async throws -> Void) async {
        try? await end()
    }

    /// Tears the pipeline down on a mid-capture fatal WITHOUT running the network finalize, resets
    /// published state, and surfaces a user message. `preserveForRecovery` keeps the capture dir on
    /// disk (real audio was written; startup recovery salvages it); otherwise the dir is deleted
    /// (mic denied at start left nothing worth keeping). Guarded so a double-fire is a no-op.
    private func handleFatal(_ error: Error, preserveForRecovery: Bool) {
        guard tearDownWithoutFinalize(removeDirectory: !preserveForRecovery) else { return }
        onFailure?(Self.failureMessage(for: error), preserveForRecovery)
    }

    /// Drops a capture that must leave nothing behind (the server refused a second recorder):
    /// tears the pipeline down and deletes the capture directory without touching the network.
    func discard() {
        _ = tearDownWithoutFinalize(removeDirectory: true)
    }

    private func tearDownWithoutFinalize(removeDirectory: Bool) -> Bool {
        guard let pipeline else { return false }
        pipeline.teardown()
        queue?.cancelAll()
        if removeDirectory, let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        self.pipeline = nil
        self.queue = nil
        self.client = nil
        self.transcriber = nil
        self.meetingId = nil
        self.directory = nil
        self.startedAt = nil
        self.lastFramesAt = nil
        elapsed = 0
        level = 0
        segmentsUploaded = 0
        segmentsTotal = 0
        reconnecting = false
        micUnavailable = false
        return true
    }

    /// Whether a mic-start failure should preserve the capture dir for recovery. The system-audio
    /// tap runs synchronously and the 250ms tick writes the other participants' audio the whole time
    /// the mic permission dialog is up, so any frames on disk are real meeting audio worth salvaging;
    /// only a zero-frame denial (immediate/persisted) leaves nothing to keep.
    nonisolated static func shouldPreserve(framesWritten: Int64) -> Bool {
        framesWritten > 0
    }

    enum MicFailureDisposition: Equatable { case continueWithoutMic, fatal }

    /// A missing input device is survivable while system audio records; anything else (a denied
    /// permission, a converter or engine fault) stays fatal.
    nonisolated static func micFailureDisposition(for error: Error, systemAudioAvailable: Bool) -> MicFailureDisposition {
        isNoInputDevice(error) && systemAudioAvailable ? .continueWithoutMic : .fatal
    }

    /// kAudioUnitErr_NoConnection (-10876) is what AVAudioEngine throws when the input device
    /// vanishes between MicCapture's device check and the engine start.
    nonisolated private static func isNoInputDevice(_ error: Error) -> Bool {
        if case .noInputDevice? = error as? MicCapture.CaptureError { return true }
        let ns = error as NSError
        return ns.domain == "com.apple.coreaudio.avfaudio" && ns.code == -10876
    }

    nonisolated static func failureMessage(for error: Error) -> String {
        if isNoInputDevice(error) {
            return "No microphone or meeting audio found to record."
        }
        if let micError = error as? MicCapture.CaptureError, case .permissionDenied = micError {
            return "Grant microphone access in System Settings to record."
        }
        if let captureError = error as? CaptureError, case .transcriptionBlocked(let reason) = captureError {
            return "Can't record: " + reason.settingsText
        }
        if let captureError = error as? CaptureError, case .stalled = captureError {
            return "Recording stopped: audio capture stalled."
        }
        return "Recording stopped: \(error.localizedDescription)"
    }
}

/// The Automatic-mode fallback's network surface: the cloud finalize over the full recording on disk.
protocol CloudFinalizeTransport {
    func uploadRecording(meetingId: String, fileURL: URL) async throws -> String
    func finalizeMeeting(meetingId: String, audioPath: String, duration: Double, sizeBytes: Int64) async throws
    func requestTranscription(meetingId: String, expectedSegments: Int?, deferExtraction: Bool) async throws
}

extension MinutiaClient: CloudFinalizeTransport {}

/// Owns the audio hot path off the main actor: ring buffers, the tap and mic, the segment writer,
/// and the 250ms mix/write tick. Reports the tick's peak level and any freshly closed segments
/// through `onTick`.
private final class CapturePipeline {
    /// Reports the tick's peak level, the number of segments closed this tick (for UI), and the
    /// total audio frames drained this tick (mic + sys, including catch-up chunks) so the session's
    /// watchdog can detect a true capture stall.
    var onTick: ((Float, Int, Int) -> Void)?
    /// Hands each freshly closed segment off synchronously on `tickQueue` for immediate upload.
    var onSegment: ((SegmentWriter.ClosedSegment) -> Void)?
    /// Fired when capture cannot continue: a mic-start failure (Bool == false, nothing worth
    /// keeping) or a segment-write failure such as disk-full (Bool == true, preserve for recovery).
    var onFatal: ((Error, Bool) -> Void)?
    /// Fired when the system-audio tap cannot start, or a mid-recording rebuild permanently fails,
    /// so capture continues mic-only. Non-fatal: the recording keeps going.
    var onSystemAudioUnavailable: (() -> Void)?
    /// Fired when a mid-recording rebuild succeeds after it was reported as failing.
    var onSystemAudioRecovered: (() -> Void)?
    /// Fired when no microphone exists but system audio is recording, so capture continues
    /// system-only. Non-fatal.
    var onMicUnavailable: (() -> Void)?

    private let micBuffer: RingBuffer
    private let sysBuffer: RingBuffer
    private let tap: SystemAudioTap
    private let mic: MicCapture
    private let writer: SegmentWriter
    private let tickQueue = DispatchQueue(label: "app.minutia.capture.tick", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var failed = false
    private var micScratch: [Float]
    private var sysScratch: [Float]
    private static let logger = Logger(subsystem: "app.minutia.desktop", category: "CapturePipeline")

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
        // A permanent rebuild failure (device handoff that never recovers) also degrades to mic-only;
        // surface it the same way as a failed initial start. Fires on controlQueue; the consumer hops
        // to the main actor.
        tap.onFailure = { [weak self] error in
            Self.logger.error("System audio lost mid-recording: \(String(describing: error), privacy: .public)")
            self?.onSystemAudioUnavailable?()
        }
        tap.onRecovered = { [weak self] in self?.onSystemAudioRecovered?() }
        // System audio is best-effort: if the tap can't start (no default output device, transient
        // HAL error), degrade to mic-only rather than failing the whole recording. The tick mixes
        // against an empty sys buffer, which the existing silence-pad already handles. Only a mic
        // failure (below) is fatal.
        var systemAudioAvailable = true
        do { try tap.start() }
        catch {
            systemAudioAvailable = false
            Self.logger.warning("System audio unavailable, recording mic-only: \(String(describing: error), privacy: .public)")
            onSystemAudioUnavailable?()
        }
        // A denied mic must surface, not be swallowed: without this a permission-denied recording
        // looks healthy but captures only system audio. Preserve the dir when the tick has already
        // written system audio during the permission prompt; deleting it would lose that audio.
        // A Mac with no microphone at all keeps recording system audio; the tick pads the empty mic.
        Task { [systemAudioAvailable] in
            do { try await mic.start() }
            catch {
                switch CaptureSession.micFailureDisposition(for: error, systemAudioAvailable: systemAudioAvailable) {
                case .continueWithoutMic:
                    Self.logger.warning("No microphone, recording system audio only: \(String(describing: error), privacy: .public)")
                    self.onMicUnavailable?()
                case .fatal:
                    self.onFatal?(error, CaptureSession.shouldPreserve(framesWritten: self.writer.totalFrames))
                }
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: tickQueue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    /// Stops the timer, tap, and mic, then closes the files. Returns the trailing partial segment
    /// (if any) and the full recording.
    func finishCapture() -> (finalSegment: SegmentWriter.ClosedSegment?, recording: SegmentWriter.Recording, tailPieces: [SegmentWriter.ClosedSegment], segmentsDropped: Bool)? {
        timer?.cancel()
        timer = nil
        // cancel() does not wait for an in-flight handler; barrier on tickQueue so no tick() is
        // running (or can start) before we stop the sources and close the writer. SegmentWriter is
        // not thread-safe, so append() must never overlap finish().
        tickQueue.sync {}
        tap.stop()
        mic.stop()
        guard let result = try? writer.finish() else { return nil }
        return (result.finalSegment, result.recording, result.tailPieces, writer.segmentsDropped)
    }

    /// Lightweight stop for the fatal path: halts the timer, tap, and mic WITHOUT the network finalize
    /// and WITHOUT finishing the writer. The fragmented files on disk are already readable for startup
    /// recovery, and finishing rewrites them, which can fail on a full disk. The writer is released with
    /// the pipeline, never cancelled (cancelWriting deletes its output). Shares finishCapture's
    /// tick-queue barrier discipline.
    func teardown() {
        timer?.cancel()
        timer = nil
        tickQueue.sync {}
        tap.stop()
        mic.stop()
    }

    private func tick() {
        guard !failed else { return }
        let plan = MixPlan.plan(micAvailable: micBuffer.availableFrames, sysAvailable: sysBuffer.availableFrames)
        let micGot = micBuffer.pop(into: &micScratch, count: plan.micFrames)
        let sysGot = sysBuffer.pop(into: &sysScratch, count: plan.sysFrames)
        let count = max(micGot, sysGot)
        guard count > 0 else {
            onTick?(0, 0, 0)
            return
        }

        var peak: Float = 0
        var closedCount = 0
        var framesDrained = micGot + sysGot
        do {
            peak = try mixAndWrite(micGot: micGot, sysGot: sysGot, count: count, closedCount: &closedCount)

            // Bounded catch-up: after a scheduling slip the backlog can exceed one tick; drain a
            // capped number of extra chunks so latency is recovered over a tick or two instead of
            // growing until the ring overflows.
            let extra = MixPlan.catchUpChunks(
                micAvailable: micBuffer.availableFrames, sysAvailable: sysBuffer.availableFrames)
            for _ in 0..<extra {
                let mg = micBuffer.pop(into: &micScratch, count: MixPlan.tickFrames)
                let sg = sysBuffer.pop(into: &sysScratch, count: MixPlan.tickFrames)
                let c = max(mg, sg)
                guard c > 0 else { break }
                framesDrained += mg + sg
                peak = try mixAndWrite(micGot: mg, sysGot: sg, count: c, closedCount: &closedCount)
            }
        } catch {
            // Disk-full or any write failure: the audio already on disk is real, so preserve the
            // directory for startup recovery rather than silently dropping this and every later tick.
            failed = true
            onFatal?(error, true)
            return
        }
        onTick?(peak, closedCount, framesDrained)
    }

    /// Pads one drained chunk, appends it to the writer, hands off any closed segments, and returns
    /// the chunk's peak. Accumulates the closed-segment count across the tick's chunks.
    private func mixAndWrite(micGot: Int, sysGot: Int, count: Int, closedCount: inout Int) throws -> Float {
        let mic = MixPlan.pad(Array(micScratch[0..<micGot]), to: count)
        let sys = MixPlan.pad(Array(sysScratch[0..<sysGot]), to: count)
        let closed = try writer.append(mic: mic, sys: sys)
        for segment in closed { onSegment?(segment) }
        closedCount += closed.count
        var peak: Float = 0
        for sample in mic { peak = max(peak, abs(sample)) }
        for sample in sys { peak = max(peak, abs(sample)) }
        return peak
    }
}
