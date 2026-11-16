import Foundation

/// Flags audio the local model is likely decoding in a language it does not know, by mean token
/// confidence per 30 s window against a per-model floor (`ParakeetEngine.Model.guardFloor`).
/// Characters per speech second do not separate English from Japanese in the MIN-211 eval
/// (Japanese decodes to 9 to 15, English 6 to 23), so they are reported but not gated on.
enum QualityGuard {
    static let windowSeconds = 30.0
    static let minSpeechSeconds = 3.0
    static let maxFailingShare = 0.25

    struct Window: Codable, Equatable, Sendable {
        let start: Double
        let speechSeconds: Double
        let meanConfidence: Double
        let charsPerSpeechSecond: Double

        var evaluated: Bool { speechSeconds >= QualityGuard.minSpeechSeconds }
        func fails(floor: Double) -> Bool { evaluated && meanConfidence < floor }
    }

    static func windows(_ segments: [SpeechSegment]) -> [Window] {
        Dictionary(grouping: segments) { ($0.start / windowSeconds).rounded(.down) }
            .sorted { $0.key < $1.key }
            .compactMap { index, group in
                let speech = group.reduce(0) { $0 + max($1.end - $1.start, 0) }
                guard speech > 0 else { return nil }
                let chars = group.reduce(0) { $0 + $1.text.count }
                let confidence = group.reduce(0) { $0 + $1.confidence * max($1.end - $1.start, 0) } / speech
                return Window(start: index * windowSeconds, speechSeconds: speech,
                              meanConfidence: confidence, charsPerSpeechSecond: Double(chars) / speech)
            }
    }

    /// True unless at least `maxFailingShare` of the windows with enough speech fall below the floor.
    static func passes(_ segments: [SpeechSegment], floor: Double) -> Bool {
        let evaluated = windows(segments).filter(\.evaluated)
        guard !evaluated.isEmpty else { return true }
        return Double(evaluated.filter { $0.fails(floor: floor) }.count) / Double(evaluated.count) < maxFailingShare
    }
}
