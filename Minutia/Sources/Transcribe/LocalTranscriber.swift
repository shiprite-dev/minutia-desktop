import Foundation

/// Transcribes a device-mode meeting segment by segment while it records. The engine loads in the
/// background from `startLoading()` (record start); segment jobs queue until it is loaded, each
/// writes `seg-N.transcript.json` beside its audio, and the engine unloads `idleUnloadSeconds`
/// after the last job.
actor LocalTranscriber {
    static let idleUnloadSeconds: TimeInterval = 60
    /// FluidAudio's `ASRConstants.minimumAudioDurationSeconds`: shorter audio throws `invalidAudioData`.
    static let minimumSegmentSeconds: Double = 0.3
    /// A model load running longer than this fails the meeting's local transcription.
    static let loadTimeoutSeconds: TimeInterval = 120

    /// Why a meeting's local transcription failed as a whole.
    enum Failure: Error, Equatable {
        case modelLoad
        case modelLoadTimedOut
        case qualityGuard
        case transcriptionTimedOut
    }

    /// Contents of `seg-N.transcript.json`: both channels, labeled and on the meeting clock.
    struct SegmentTranscript: Codable, Equatable {
        let seq: Int
        let modelId: String
        let segments: [DeviceTranscript.Segment]
    }

    nonisolated static func transcriptName(seq: Int) -> String { "seg-\(seq).transcript.json" }

    private let source: DeviceTranscript.Source
    private let language: String
    private let unloadAfter: TimeInterval
    private let loadEngine: @Sendable () async throws -> any SpeechEngine
    private let guardFloor: Double
    private let loadTimeout: TimeInterval

    init(source: DeviceTranscript.Source, language: String,
         idleUnloadSeconds: TimeInterval = LocalTranscriber.idleUnloadSeconds,
         guardFloor: Double = 0, loadTimeout: TimeInterval = LocalTranscriber.loadTimeoutSeconds,
         loadEngine: @escaping @Sendable () async throws -> any SpeechEngine) {
        self.source = source
        self.language = language
        unloadAfter = idleUnloadSeconds
        self.guardFloor = guardFloor
        self.loadTimeout = loadTimeout
        self.loadEngine = loadEngine
    }

    private var engine: (any SpeechEngine)?
    private var loadTask: Task<any SpeechEngine, Error>?
    private var loadFailure: Failure?
    private var loadStartedAt = Date()
    private var verdicts: [Int: QualityGuard.Verdict] = [:]
    private var unloadTask: Task<Void, Never>?

    private let intakeLock = NSLock()
    nonisolated(unsafe) private var jobs: [Task<[DeviceTranscript.Segment], Error>] = []
    nonisolated(unsafe) private var activeJobs = 0
    nonisolated(unsafe) private var cancelled = false

    var isEngineLoaded: Bool { engine != nil }

    func startLoading() {
        guard engine == nil, loadTask == nil, loadFailure == nil else { return }
        beginLoad()
    }

    @discardableResult
    private func beginLoad() -> Task<any SpeechEngine, Error> {
        let task = Task { [loadEngine] in
            do {
                let loaded = try await loadEngine()
                await self.didLoad(loaded)
                return loaded
            } catch {
                await self.didFailLoad(error)
                throw error
            }
        }
        loadTask = task
        loadStartedAt = Date()
        return task
    }

    private func didLoad(_ loaded: any SpeechEngine) {
        guard loadFailure == nil, !intakeLock.withLock({ cancelled }) else { return }
        engine = loaded
        loadTask = nil
    }

    private func didFailLoad(_ error: Error) {
        loadTask = nil
        if !(error is CancellationError), loadFailure == nil { loadFailure = .modelLoad }
    }

    private var activeCount: Int { intakeLock.withLock { activeJobs } }

    private func engineForJob() async throws -> any SpeechEngine {
        unloadTask?.cancel()
        unloadTask = nil
        if let loadFailure { throw loadFailure }
        if let engine { return engine }
        let task = loadTask ?? beginLoad()
        let remaining = max(0, loadTimeout - Date().timeIntervalSince(loadStartedAt))
        do {
            return try await Self.race(task, timeout: remaining)
        } catch Failure.modelLoadTimedOut {
            loadFailure = loadFailure ?? .modelLoadTimedOut
            throw loadFailure!
        } catch {
            throw loadFailure ?? error
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }

    private static func race(_ task: Task<any SpeechEngine, Error>, timeout: TimeInterval) async throws -> any SpeechEngine {
        let once = Once()
        let claim: @Sendable () -> Bool = { once.claim() }
        return try await withCheckedThrowingContinuation { continuation in
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !Task.isCancelled, claim() { continuation.resume(throwing: Failure.modelLoadTimedOut) }
            }
            Task {
                let result = await task.result
                timer.cancel()
                if claim() { continuation.resume(with: result) }
            }
        }
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        let seconds = unloadAfter
        unloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        guard activeCount == 0 else { return }
        engine = nil
        unloadTask = nil
    }

    private func run(_ segment: SegmentWriter.ClosedSegment) async throws -> [DeviceTranscript.Segment] {
        guard Double(segment.frames) / MixPlan.sampleRate >= Self.minimumSegmentSeconds else { return [] }
        guard !QualityGuard.abortsEarly(orderedVerdicts) else { return [] }
        do {
            let engine = try await engineForJob()
            let mine = try await engine.transcribe(.file(segment.micURL))
            try Task.checkCancellation()
            let theirs = try await engine.transcribe(.file(segment.sysURL))
            let verdict = QualityGuard.verdict(mine.segments + theirs.segments, floor: guardFloor)
            guard verdict != .fail else { verdicts[segment.seq] = .fail; return [] }
            let labeled = DeviceTranscript.labeled(mine, speaker: .me, offset: segment.offsetSeconds)
                + DeviceTranscript.labeled(theirs, speaker: .them, offset: segment.offsetSeconds)
            let saved = SegmentTranscript(seq: segment.seq, modelId: engine.modelId, segments: labeled)
            try JSONEncoder().encode(saved).write(
                to: segment.micURL.deletingLastPathComponent().appendingPathComponent(Self.transcriptName(seq: segment.seq)),
                options: .atomic)
            verdicts[segment.seq] = verdict
            return labeled
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            verdicts[segment.seq] = .fail
            return []
        }
    }

    /// Counts saved segment transcripts toward the meeting verdict, so recovery judges the whole meeting.
    func seed(_ saved: [SegmentTranscript]) {
        verdicts = Dictionary(saved.map { transcript in
            (transcript.seq, QualityGuard.verdict(
                transcript.segments.compactMap { segment in
                    segment.confidence.map { SpeechSegment(start: segment.start, end: segment.end, text: segment.text, confidence: $0) }
                },
                floor: guardFloor))
        }, uniquingKeysWith: { _, new in new })
    }

    private var orderedVerdicts: [QualityGuard.Verdict] { verdicts.sorted { $0.key < $1.key }.map(\.value) }

    private func jobFinished() {
        intakeLock.withLock { activeJobs -= 1 }
    }

    /// Synchronous hand-off from the capture tick queue.
    nonisolated func enqueue(_ segment: SegmentWriter.ClosedSegment) {
        intakeLock.lock()
        defer { intakeLock.unlock() }
        guard !cancelled else { return }
        let previous = jobs.last
        activeJobs += 1
        jobs.append(Task {
            _ = await previous?.result
            if Task.isCancelled { await self.jobFinished(); throw CancellationError() }
            do {
                let labeled = try await self.run(segment)
                await self.jobFinished()
                return labeled
            } catch {
                await self.jobFinished()
                throw error
            }
        })
    }

    /// Cancels every pending job and the load, waits for each to return (a Core ML call or model load
    /// cannot be interrupted), then drops the engine.
    func cancel() async {
        let pending = intakeLock.withLock { defer { jobs = []; cancelled = true }; return jobs }
        let load = loadTask
        loadTask = nil
        unloadTask?.cancel(); unloadTask = nil
        pending.forEach { $0.cancel() }
        load?.cancel()
        for job in pending { _ = await job.result }
        _ = await load?.result
        engine = nil
    }

    /// Queues the tail, waits for the engine and every job, and returns the meeting transcript.
    /// Reports `.preparingModel` while the engine is still loading and `.transcribing` as jobs finish.
    func finish(tail: [SegmentWriter.ClosedSegment], durationSeconds: Double,
                onStep: @escaping @Sendable (CaptureSession.FinishingStep) async -> Void = { _ in }) async throws -> DeviceTranscript {
        if intakeLock.withLock({ cancelled }) { throw CancellationError() }
        tail.forEach(enqueue)
        let all = intakeLock.withLock { jobs }
        await onStep(engine == nil ? .preparingModel : .transcribing(completed: 0, total: all.count))
        var segments: [DeviceTranscript.Segment] = []
        for (index, job) in all.enumerated() {
            segments += try await job.value
            await onStep(.transcribing(completed: index + 1, total: all.count))
        }
        if let loadFailure { throw loadFailure }
        guard QualityGuard.passes(orderedVerdicts) else { throw Failure.qualityGuard }
        scheduleUnload()
        return DeviceTranscript.build(source: source, language: language, durationSeconds: durationSeconds, segments: segments)
    }
}
