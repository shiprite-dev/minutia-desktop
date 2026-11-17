import Foundation

/// Flags audio the local model is likely decoding in a language it does not know, by mean token
/// confidence per 30 s window against a per-model floor (`ParakeetEngine.Model.guardFloor`).
/// A recording fails when two judged windows in a row fail, when none of the judged windows pass, or,
/// once at least `minWindowsForShareRule` windows are judged, when `maxFailingShare` of them fail; a
/// lone failed window is tolerated, a short meeting included. Characters per speech
/// second do not separate English from Japanese in the eval calibration (Japanese decodes to 9 to 15,
/// English 6 to 23), so they are reported but not gated on.
enum QualityGuard {
    static let windowSeconds = 30.0
    static let minSpeechSeconds = 3.0
    static let maxFailingShare = 0.25
    static let minWindowsForShareRule = 5

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

    static func passes(_ windows: [Window], floor: Double) -> Bool {
        passes(windows.filter(\.evaluated).map { $0.fails(floor: floor) ? .fail : .pass })
    }

    /// The stop-time judgment of a device meeting: one judged window per segment transcription.
    enum Verdict: Equatable, Sendable { case pass, fail, unjudged }

    /// When the first this-many judged windows all fail, the rest of the meeting is not transcribed locally.
    static let earlyAbortWindows = 4

    /// A segment's verdict from both channels' speech, or nil when the engine threw on it. A throw fails;
    /// at least `minSpeechSeconds` of speech whose duration-weighted mean confidence is under `floor`
    /// fails; less speech than that (silence included) is unjudged.
    static func verdict(_ speech: [SpeechSegment]?, floor: Double) -> Verdict {
        guard let speech else { return .fail }
        let seconds = speech.reduce(0) { $0 + max($1.end - $1.start, 0) }
        guard seconds >= minSpeechSeconds else { return .unjudged }
        let confidence = speech.reduce(0) { $0 + $1.confidence * max($1.end - $1.start, 0) } / seconds
        return confidence < floor ? .fail : .pass
    }

    /// The same rules as `passes(_:floor:)`, over judged segment verdicts (unjudged ones are ignored).
    static func passes(_ verdicts: [Verdict]) -> Bool {
        let fails = verdicts.filter { $0 != .unjudged }.map { $0 == .fail }
        guard !fails.isEmpty else { return true }
        let failCount = fails.filter { $0 }.count
        if zip(fails, fails.dropFirst()).contains(where: { $0 && $1 }) { return false }
        if failCount == fails.count { return false }
        return fails.count < minWindowsForShareRule || Double(failCount) / Double(fails.count) < maxFailingShare
    }

    /// True once the first `earlyAbortWindows` judged verdicts are all failures.
    static func abortsEarly(_ verdicts: [Verdict]) -> Bool {
        let judged = verdicts.filter { $0 != .unjudged }.prefix(earlyAbortWindows)
        return judged.count == earlyAbortWindows && judged.allSatisfy { $0 == .fail }
    }
}
