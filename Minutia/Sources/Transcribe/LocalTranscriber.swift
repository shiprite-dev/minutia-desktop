import Foundation

/// Transcribes a device-mode meeting segment by segment while it records. The engine loads in the
/// background from `startLoading()` (record start); segment jobs queue until it is loaded, each
/// writes `seg-N.transcript.json` beside its audio, and the engine unloads `idleUnloadSeconds`
/// after the last job.
actor LocalTranscriber {
    static let idleUnloadSeconds: TimeInterval = 60

    /// Contents of `seg-N.transcript.json`: both channels, labeled and on the meeting clock.
    struct SegmentTranscript: Codable, Equatable {
        let seq: Int
        let modelId: String
        let segments: [DeviceTranscript.Segment]
    }

    nonisolated static func transcriptName(seq: Int) -> String { "" }

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

    var isEngineLoaded: Bool { false }

    func startLoading() {}

    /// Synchronous hand-off from the capture tick queue.
    nonisolated func enqueue(_ segment: SegmentWriter.ClosedSegment) {}

    /// Queues the tail, waits for the engine and every job, and returns the meeting transcript.
    /// Reports `.preparingModel` while the engine is still loading and `.transcribing` as jobs finish.
    func finish(tail: [SegmentWriter.ClosedSegment], durationSeconds: Double,
                onStep: @escaping @Sendable (CaptureSession.FinishingStep) async -> Void = { _ in }) async throws -> DeviceTranscript {
        throw CocoaError(.featureUnsupported)
    }
}
