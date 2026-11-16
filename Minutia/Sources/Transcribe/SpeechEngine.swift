import Foundation

struct SpeechSegment: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String
    let confidence: Double
}

struct SpeechResult: Codable, Sendable {
    let modelId: String
    let segments: [SpeechSegment]

    var noSpeech: Bool { segments.isEmpty }
    var text: String { segments.map(\.text).joined(separator: " ") }
}

enum SpeechAudio: Sendable {
    /// 16 kHz mono Float32.
    case samples([Float])
    case file(URL)
}

protocol SpeechEngine: Sendable {
    var modelId: String { get }
    func transcribe(_ audio: SpeechAudio) async throws -> SpeechResult
}

struct TimedToken: Equatable, Sendable {
    let text: String
    let start: Double
    let end: Double
    let confidence: Double
}

enum TokenSegmenter {
    static let maxGap = 0.8

    /// Groups SentencePiece tokens ("\u{2581}" or a leading space starts a word) into segments,
    /// breaking at a word start after sentence punctuation or a pause longer than `maxGap`.
    /// A punctuation token keeps the previous token's end: the decoder can stamp it many seconds later.
    static func segments(_ tokens: [TimedToken]) -> [SpeechSegment] {
        var out: [SpeechSegment] = []
        var current: [TimedToken] = []

        func flush() {
            let text = current.map(\.text).joined()
                .replacingOccurrences(of: "\u{2581}", with: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if let first = current.first, let last = current.last, !text.isEmpty {
                let confidence = current.map(\.confidence).reduce(0, +) / Double(current.count)
                out.append(SpeechSegment(start: first.start, end: last.end, text: text, confidence: confidence))
            }
            current = []
        }

        for var token in tokens {
            if let previous = current.last, isPunctuation(token.text) {
                token = TimedToken(text: token.text, start: previous.end, end: previous.end, confidence: token.confidence)
            }
            if let previous = current.last,
               token.start - previous.end > maxGap || endsSentence(previous.text, before: token.text) {
                flush()
            }
            current.append(token)
        }
        flush()
        return out
    }

    private static func isPunctuation(_ token: String) -> Bool {
        let core = token.trimmingCharacters(in: CharacterSet(charactersIn: "\u{2581} "))
        return !core.isEmpty && core.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
    }

    private static func startsWord(_ token: String) -> Bool {
        token.hasPrefix("\u{2581}") || token.hasPrefix(" ")
    }

    /// Full-width punctuation ends a sentence on its own: Japanese vocabularies have no word markers.
    private static func endsSentence(_ token: String, before next: String) -> Bool {
        guard let last = token.last else { return false }
        if "\u{3002}\u{FF1F}\u{FF01}".contains(last) { return true }
        return ".?!".contains(last) && startsWord(next)
    }
}
