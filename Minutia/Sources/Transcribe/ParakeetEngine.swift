import FluidAudio
import Foundation

final class ParakeetEngine: SpeechEngine {
    enum Model: String, CaseIterable, Sendable {
        case v3 = "parakeet-v3"
        case ultra = "parakeet-ultra"
        case ja = "parakeet-ja"

        var version: AsrModelVersion {
            switch self {
            case .v3: .v3
            case .ultra: .ultra
            case .ja: .tdtJa
            }
        }

        var repo: Repo {
            switch self {
            case .v3: .parakeetV3
            case .ultra: .parakeetUltra
            case .ja: .parakeetJa
            }
        }

        /// Hugging Face commits the model files are pinned to.
        var revision: String {
            switch self {
            case .v3: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe"
            case .ultra: "95eaa59a39d4394f047a4dc5cce480388a60d1b6"
            case .ja: "2952296ff1da4a6d6a7aec545e226367db80c612"
            }
        }

        var modelId: String { "\(rawValue)@\(revision.prefix(7))" }

        /// Quality-guard confidence floor from the MIN-211 calibration (30 s windows, 3 s or more of speech).
        /// English bottoms out at 0.80 (v3) and 0.76 (Ultra, one window; the failing-share rule absorbs it);
        /// Japanese decoded by them tops out at 0.73 and 0.75. The Japanese model is only selected for
        /// Japanese, so it is not guarded.
        var guardFloor: Double {
            switch self {
            case .v3: 0.75
            case .ultra: 0.78
            case .ja: 0
            }
        }
    }

    let modelId: String
    private let model: Model
    private let manager: AsrManager

    private init(model: Model, manager: AsrManager) {
        self.model = model
        self.manager = manager
        modelId = model.modelId
    }

    static func download(_ model: Model, to directory: URL) async throws {
        pin(model)
        _ = try await AsrModels.download(to: directory, version: model.version)
    }

    static func load(_ model: Model, from directory: URL) async throws -> ParakeetEngine {
        pin(model)
        let models = try await AsrModels.load(from: directory, version: model.version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return ParakeetEngine(model: model, manager: manager)
    }

    func transcribe(_ audio: SpeechAudio) async throws -> SpeechResult {
        var state = TdtDecoderState.make(decoderLayers: model.version.decoderLayers)
        let result: ASRResult
        switch audio {
        case .samples(let samples):
            guard samples.count >= ASRConstants.minimumRequiredSamples(forSampleRate: 16_000) else {
                return SpeechResult(modelId: modelId, segments: [])
            }
            result = try await manager.transcribe(samples, decoderState: &state)
        case .file(let url):
            result = try await manager.transcribe(url, decoderState: &state)
        }
        let tokens = (result.tokenTimings ?? []).map {
            TimedToken(text: $0.token, start: $0.startTime, end: $0.endTime, confidence: Double($0.confidence))
        }
        return SpeechResult(modelId: modelId, segments: TokenSegmenter.segments(tokens))
    }

    private static func pin(_ model: Model) {
        ModelRegistry.revisionOverrides[model.repo.remotePath] = model.revision
    }
}
