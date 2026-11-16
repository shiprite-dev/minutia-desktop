import XCTest
@testable import Minutia

final class QualityGuardTests: XCTestCase {
    private func speech(at start: Double, seconds: Double = 10, confidence: Double) -> SpeechSegment {
        SpeechSegment(start: start, end: start + seconds, text: String(repeating: "a", count: Int(seconds * 14)),
                      confidence: confidence)
    }

    private let floor = ParakeetEngine.Model.v3.guardFloor

    func test_thresholds_matchTheMIN211Calibration() {
        XCTAssertEqual(QualityGuard.windowSeconds, 30)
        XCTAssertEqual(QualityGuard.minSpeechSeconds, 3)
        XCTAssertEqual(QualityGuard.maxFailingShare, 0.25)
        XCTAssertEqual(ParakeetEngine.Model.v3.guardFloor, 0.75)
        XCTAssertEqual(ParakeetEngine.Model.ultra.guardFloor, 0.78)
        XCTAssertEqual(ParakeetEngine.Model.ja.guardFloor, 0)
    }

    func test_noSpeech_passes() {
        XCTAssertTrue(QualityGuard.passes([], floor: floor))
    }

    func test_englishLikeMeeting_passes() {
        XCTAssertTrue(QualityGuard.passes((0..<10).map { speech(at: Double($0) * 30, confidence: 0.91) }, floor: floor))
    }

    func test_japaneseDecodedByV3_fails() {
        XCTAssertFalse(QualityGuard.passes((0..<4).map { speech(at: Double($0) * 30, confidence: 0.6) }, floor: floor))
    }

    func test_englishThenJapanese_fails() {
        XCTAssertFalse(QualityGuard.passes([speech(at: 0, confidence: 0.93), speech(at: 30, confidence: 0.59)], floor: floor))
    }

    func test_oneLowWindowInALongMeeting_passes() {
        let windows = (0..<10).map { speech(at: Double($0) * 30, confidence: $0 == 4 ? 0.5 : 0.9) }
        XCTAssertTrue(QualityGuard.passes(windows, floor: floor))
    }

    func test_windowsWithTooLittleSpeech_areNotJudged() {
        XCTAssertTrue(QualityGuard.passes([speech(at: 0, seconds: 2, confidence: 0.3)], floor: floor))
    }

    func test_windowConfidence_isDurationWeighted() {
        let windows = QualityGuard.windows([speech(at: 0, seconds: 9, confidence: 1.0), speech(at: 10, seconds: 3, confidence: 0.6)])
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].meanConfidence, 0.9, accuracy: 1e-9)
        XCTAssertEqual(windows[0].speechSeconds, 12, accuracy: 1e-9)
    }
}
