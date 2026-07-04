import XCTest
@testable import Minutia

final class RecordingFormattingTests: XCTestCase {
    func test_timestamp_formatsMinutesAndSeconds() {
        XCTAssertEqual(RecordingView.timestamp(0), "00:00")
        XCTAssertEqual(RecordingView.timestamp(59.4), "00:59")
        XCTAssertEqual(RecordingView.timestamp(60), "01:00")
        XCTAssertEqual(RecordingView.timestamp(754), "12:34")
    }

    func test_timestamp_foldsHoursIntoMinutes() {
        XCTAssertEqual(RecordingView.timestamp(5400), "90:00")
    }

    func test_timestamp_clampsNegativeToZero() {
        XCTAssertEqual(RecordingView.timestamp(-3), "00:00")
    }

    func test_litBars_zeroForSilence() {
        XCTAssertEqual(RecordingView.litBars(level: 0, total: 8), 0)
    }

    func test_litBars_atLeastOneForAnySignal() {
        XCTAssertEqual(RecordingView.litBars(level: 0.01, total: 8), 1)
    }

    func test_litBars_scalesAndClamps() {
        XCTAssertEqual(RecordingView.litBars(level: 0.5, total: 8), 4)
        XCTAssertEqual(RecordingView.litBars(level: 1.0, total: 8), 8)
        XCTAssertEqual(RecordingView.litBars(level: 1.5, total: 8), 8)
    }
}

@MainActor
final class DetectionLabelTests: XCTestCase {
    func test_detectionLabel_mapsAppsAndCalendarFallback() {
        XCTAssertEqual(AppController.detectionLabel(.zoom), "Zoom")
        XCTAssertEqual(AppController.detectionLabel(.teams), "Teams")
        XCTAssertEqual(AppController.detectionLabel(nil), "Calendar")
    }
}
