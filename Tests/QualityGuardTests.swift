import XCTest
@testable import Minutia

final class QualityGuardTests: XCTestCase {
    private func speech(at start: Double, seconds: Double = 10, confidence: Double) -> SpeechSegment {
        SpeechSegment(start: start, end: start + seconds, text: String(repeating: "a", count: Int(seconds * 14)),
                      confidence: confidence)
    }

    private let floor = ParakeetEngine.Model.v3.guardFloor

    func test_thresholds_matchTheEvalCalibration() {
        XCTAssertEqual(QualityGuard.windowSeconds, 30)
        XCTAssertEqual(QualityGuard.minSpeechSeconds, 3)
        XCTAssertEqual(QualityGuard.maxFailingShare, 0.25)
        XCTAssertEqual(ParakeetEngine.Model.v3.guardFloor, 0.75)
        XCTAssertEqual(ParakeetEngine.Model.ultra.guardFloor, 0.78)
        XCTAssertEqual(ParakeetEngine.Model.ja.guardFloor, 0)
    }

    func test_noSpeech_passes() {
        XCTAssertTrue(QualityGuard.passes(QualityGuard.windows([]), floor: floor))
    }

    func test_englishLikeMeeting_passes() {
        XCTAssertTrue(QualityGuard.passes(QualityGuard.windows((0..<10).map { speech(at: Double($0) * 30, confidence: 0.91) }), floor: floor))
    }

    func test_japaneseDecodedByV3_fails() {
        XCTAssertFalse(QualityGuard.passes(QualityGuard.windows((0..<4).map { speech(at: Double($0) * 30, confidence: 0.6) }), floor: floor))
    }

    func test_englishThenJapanese_fails() {
        XCTAssertFalse(QualityGuard.passes(QualityGuard.windows([speech(at: 0, confidence: 0.93), speech(at: 30, confidence: 0.59),
                                                                 speech(at: 60, confidence: 0.59)]), floor: floor))
    }

    func test_oneLowWindowInALongMeeting_passes() {
        let windows = (0..<10).map { speech(at: Double($0) * 30, confidence: $0 == 4 ? 0.5 : 0.9) }
        XCTAssertTrue(QualityGuard.passes(QualityGuard.windows(windows), floor: floor))
    }

    func test_windowsWithTooLittleSpeech_areNotJudged() {
        XCTAssertTrue(QualityGuard.passes(QualityGuard.windows([speech(at: 0, seconds: 2, confidence: 0.3)]), floor: floor))
    }

    func test_windowConfidence_isDurationWeighted() {
        let windows = QualityGuard.windows([speech(at: 0, seconds: 9, confidence: 1.0), speech(at: 10, seconds: 3, confidence: 0.6)])
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].meanConfidence, 0.9, accuracy: 1e-9)
        XCTAssertEqual(windows[0].speechSeconds, 12, accuracy: 1e-9)
    }

    func test_oneFailingWindowOfFour_passes_becauseTheShareRuleNeedsFiveJudgedWindows() {
        XCTAssertEqual(QualityGuard.minWindowsForShareRule, 5)
        let segments = (0..<4).map { speech(at: Double($0) * 30, confidence: $0 == 0 ? 0.5 : 0.9) }
        XCTAssertTrue(QualityGuard.passes(QualityGuard.windows(segments), floor: floor))
    }

    func test_aQuarterOfEightWindowsFailingApart_tripsTheShareRule() {
        let segments = (0..<8).map { speech(at: Double($0) * 30, confidence: $0 == 0 || $0 == 7 ? 0.5 : 0.9) }
        XCTAssertFalse(QualityGuard.passes(QualityGuard.windows(segments), floor: floor))
    }

    func test_twoConsecutiveFailingWindows_tripInALongMeeting() {
        let segments = (0..<10).map { speech(at: Double($0) * 30, confidence: $0 == 4 || $0 == 5 ? 0.5 : 0.9) }
        XCTAssertFalse(QualityGuard.passes(QualityGuard.windows(segments), floor: floor))
    }

    func test_twoSeparatedFailingWindows_passInALongMeeting() {
        let segments = (0..<10).map { speech(at: Double($0) * 30, confidence: $0 == 2 || $0 == 6 ? 0.5 : 0.9) }
        XCTAssertTrue(QualityGuard.passes(QualityGuard.windows(segments), floor: floor))
    }

    // MARK: Stop-time verdicts, one judged window per segment

    private var ultraFloor: Double { DeviceFixtures.ultra.guardFloor }

    func test_aSegmentVerdict_failsOnAThrowOrConfidenceUnderTheFloor_andSkipsSilence() {
        let rows: [(String, [SpeechSegment]?, QualityGuard.Verdict)] = [
            ("the engine threw", nil, .fail),
            ("speech under the floor", [speech(at: 0, seconds: 5, confidence: 0.5)], .fail),
            ("speech at the floor", [speech(at: 0, seconds: 5, confidence: ultraFloor)], .pass),
            ("confident speech", [speech(at: 0, seconds: 5, confidence: 0.92)], .pass),
            ("both channels, weighted by duration", [speech(at: 0, seconds: 9, confidence: 0.9),
                                                     speech(at: 0, seconds: 3, confidence: 0.5)], .pass),
            ("too little speech to judge", [speech(at: 0, seconds: 2, confidence: 0.1)], .unjudged),
            ("silence", [], .unjudged),
        ]
        for (label, input, expected) in rows {
            XCTAssertEqual(QualityGuard.verdict(input, floor: ultraFloor), expected, label)
        }
    }

    func test_stopGuard_tripsAtAQuarterFailingOfFiveOrMore_orTwoInARow_orNothingPassing_butToleratesOneLoneFailure() {
        let p = QualityGuard.Verdict.pass, f = QualityGuard.Verdict.fail, u = QualityGuard.Verdict.unjudged
        let rows: [(String, [QualityGuard.Verdict], Bool)] = [
            ("one failed segment in an otherwise passing meeting", [p, p, p, f, p, p, p, p], true),
            ("a short meeting tolerates one bad segment at the end", [p, p, p, f], true),
            ("a short meeting tolerates one bad segment in the middle", [p, f, p], true),
            ("two of four failing apart is under five judged windows", [f, p, f, p], true),
            ("silence does not count toward the five judged windows", [u, u, f, p, f, p], true),
            ("two of five failing apart trips the share rule", [f, p, f, p, p], false),
            ("one of five failing stays under a quarter", [p, p, p, p, f], true),
            ("two of eight failing apart is exactly a quarter", [f, p, p, p, p, p, p, f], false),
            ("two failing in a short meeting", [f, f], false),
            ("the only judged segment failing", [f], false),
            ("the only judged segment failing among silence", [u, f, u], false),
            ("two of ten apart stays under a quarter", [f, p, p, p, p, f, p, p, p, p], true),
            ("two in a row in a long meeting", [p, p, p, p, f, f, p, p, p, p], false),
            ("every segment failing", [f, f, f], false),
            ("silent segments are not judged", [u, u, f, p, p, p, p, u], true),
            ("a meeting with nothing judged", [u, u], true),
            ("no segments at all", [], true),
        ]
        for (label, verdicts, passes) in rows {
            XCTAssertEqual(QualityGuard.passes(verdicts), passes, label)
        }
    }

    func test_earlyAbort_onlyWhenTheFirstFourJudgedSegmentsAllFail() {
        XCTAssertEqual(QualityGuard.earlyAbortWindows, 4)
        let p = QualityGuard.Verdict.pass, f = QualityGuard.Verdict.fail, u = QualityGuard.Verdict.unjudged
        let rows: [(String, [QualityGuard.Verdict], Bool)] = [
            ("the first four fail", [f, f, f, f], true),
            ("silence before them is not judged", [u, f, u, f, f, f], true),
            ("only three judged so far", [f, f, f], false),
            ("the fourth passes", [f, f, f, p], false),
            ("a pass first", [p, f, f, f, f], false),
        ]
        for (label, verdicts, aborts) in rows {
            XCTAssertEqual(QualityGuard.abortsEarly(verdicts), aborts, label)
        }
    }
}
