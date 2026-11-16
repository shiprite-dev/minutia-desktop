import Foundation

/// Transcribes a device-mode meeting segment by segment while it records. The engine loads in the
/// background from `startLoading()` (record start); segment jobs queue until it is loaded, each
/// writes `seg-N.transcript.json` beside its audio, and the engine unloads `idleUnloadSeconds`
/// after the last job.
actor LocalTranscriber {
    static let idleUnloadSeconds: TimeInterval = 60
    /// FluidAudio's `ASRConstants.minimumAudioDurationSeconds`: shorter audio throws `invalidAudioData`.
    static let minimumSegmentSeconds: Double = 0.3

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

    init(source: DeviceTranscript.Source, language: String,
         idleUnloadSeconds: TimeInterval = LocalTranscriber.idleUnloadSeconds,
         loadEngine: @escaping @Sendable () async throws -> any SpeechEngine) {
        self.source = source
        self.language = language
        unloadAfter = idleUnloadSeconds
        self.loadEngine = loadEngine
    }

    private var engine: (any SpeechEngine)?
    private var loadTask: Task<any SpeechEngine, Error>?
    private var loadFailure: Error?
    private var unloadTask: Task<Void, Never>?

    private let intakeLock = NSLock()
    nonisolated(unsafe) private var jobs: [Task<[DeviceTranscript.Segment], Error>] = []
    nonisolated(unsafe) private var activeJobs = 0

    var isEngineLoaded: Bool { engine != nil }

    func startLoading() {
        guard engine == nil, loadTask == nil else { return }
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
        loadFailure = nil
        return task
    }

    private func didLoad(_ loaded: any SpeechEngine) {
        engine = loaded
        loadTask = nil
    }

    private func didFailLoad(_ error: Error) {
        loadTask = nil
        loadFailure = error
    }

    private var activeCount: Int { intakeLock.withLock { activeJobs } }

    private func engineForJob() async throws -> any SpeechEngine {
        unloadTask?.cancel()
        unloadTask = nil
        if let engine { return engine }
        return try await (loadTask ?? beginLoad()).value
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
        let engine = try await engineForJob()
        let mine = try await engine.transcribe(.file(segment.micURL))
        let theirs = try await engine.transcribe(.file(segment.sysURL))
        let labeled = DeviceTranscript.labeled(mine, speaker: .me, offset: segment.offsetSeconds)
            + DeviceTranscript.labeled(theirs, speaker: .them, offset: segment.offsetSeconds)
        let saved = SegmentTranscript(seq: segment.seq, modelId: engine.modelId, segments: labeled)
        try JSONEncoder().encode(saved).write(
            to: segment.micURL.deletingLastPathComponent().appendingPathComponent(Self.transcriptName(seq: segment.seq)),
            options: .atomic)
        return labeled
    }

    private func jobFinished() {
        intakeLock.withLock { activeJobs -= 1 }
    }

    /// Synchronous hand-off from the capture tick queue.
    nonisolated func enqueue(_ segment: SegmentWriter.ClosedSegment) {
        intakeLock.lock()
        defer { intakeLock.unlock() }
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

    /// Cancels every pending job and the load, and drops the engine.
    func cancel() {
        let pending = intakeLock.withLock { defer { jobs = [] }; return jobs }
        pending.forEach { $0.cancel() }
        loadTask?.cancel(); loadTask = nil
        unloadTask?.cancel(); unloadTask = nil
        engine = nil
    }

    /// Queues the tail, waits for the engine and every job, and returns the meeting transcript.
    /// Reports `.preparingModel` while the engine is still loading and `.transcribing` as jobs finish.
    func finish(tail: [SegmentWriter.ClosedSegment], durationSeconds: Double,
                onStep: @escaping @Sendable (CaptureSession.FinishingStep) async -> Void = { _ in }) async throws -> DeviceTranscript {
        if engine == nil { await onStep(.preparingModel) }
        tail.forEach(enqueue)
        let all = intakeLock.withLock { jobs }
        var segments: [DeviceTranscript.Segment] = []
        for (index, job) in all.enumerated() {
            segments += try await job.value
            await onStep(.transcribing(completed: index + 1, total: all.count))
        }
        if let loadFailure { throw loadFailure }
        scheduleUnload()
        return DeviceTranscript.build(source: source, language: language, durationSeconds: durationSeconds, segments: segments)
    }
}
