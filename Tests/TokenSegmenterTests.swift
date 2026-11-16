import XCTest
@testable import Minutia

final class TokenSegmenterTests: XCTestCase {
    private func token(_ text: String, _ start: Double, _ end: Double, _ confidence: Double = 0.9) -> TimedToken {
        TimedToken(text: text, start: start, end: end, confidence: confidence)
    }

    func test_noTokens_isNoSpeech() {
        let result = SpeechResult(modelId: "m", segments: TokenSegmenter.segments([]))
        XCTAssertTrue(result.noSpeech)
        XCTAssertEqual(result.text, "")
    }

    func test_subwordTokens_joinIntoWords_withSpanAndMeanConfidence() {
        let segments = TokenSegmenter.segments([
            token("\u{2581}hel", 0.0, 0.2, 0.8), token("lo", 0.2, 0.4, 1.0), token("\u{2581}there", 0.5, 0.9, 0.9),
        ])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "hello there")
        XCTAssertEqual(segments[0].start, 0.0)
        XCTAssertEqual(segments[0].end, 0.9)
        XCTAssertEqual(segments[0].confidence, 0.9, accuracy: 1e-9)
    }

    func test_longPause_startsNewSegment() {
        let segments = TokenSegmenter.segments([token("\u{2581}yes", 0, 0.4), token("\u{2581}okay", 1.5, 1.9)])
        XCTAssertEqual(segments.map(\.text), ["yes", "okay"])
        XCTAssertEqual(segments.map(\.start), [0, 1.5])
    }

    func test_sentencePunctuation_splitsOnlyBeforeAWordStart() {
        let segments = TokenSegmenter.segments([
            token("\u{2581}it", 0, 0.2), token("\u{2581}costs", 0.2, 0.5), token("\u{2581}3.", 0.5, 0.7),
            token("5", 0.7, 0.8), token("\u{2581}dollars.", 0.8, 1.2), token("\u{2581}Next", 1.3, 1.6),
        ])
        XCTAssertEqual(segments.map(\.text), ["it costs 3.5 dollars.", "Next"])
    }

    func test_fullWidthPunctuation_splitsWithoutWordMarkers() {
        let segments = TokenSegmenter.segments([token("こんにちは", 0, 0.6), token("。", 0.6, 0.7), token("元気", 0.8, 1.1)])
        XCTAssertEqual(segments.map(\.text), ["こんにちは。", "元気"])
    }

    func test_lateStampedPunctuation_doesNotStretchTheSegment() {
        let segments = TokenSegmenter.segments([token("\u{2581}go", 36.4, 36.5), token(".", 80.4, 80.4), token("\u{2581}Next", 81.0, 81.3)])
        XCTAssertEqual(segments.map(\.text), ["go.", "Next"])
        XCTAssertEqual(segments[0].end, 36.5)
    }
}
