import XCTest
@testable import Minutia

final class RecordingClockTests: XCTestCase {
    func test_clock_underAnHourMatchesTimestamp() {
        XCTAssertEqual(RecordingView.clock(0), "00:00")
        XCTAssertEqual(RecordingView.clock(3599), "59:59")
    }

    func test_clock_atAnHourOrMoreShowsHours() {
        XCTAssertEqual(RecordingView.clock(3600), "1:00:00")
        XCTAssertEqual(RecordingView.clock(7457), "2:04:17")
    }

    func test_clock_clampsNegative() {
        XCTAssertEqual(RecordingView.clock(-9), "00:00")
    }

    func test_timestamp_staysMinutesOnly() {
        XCTAssertEqual(RecordingView.timestamp(5400), "90:00")
    }

    func test_spokenDuration_readsNaturally() {
        XCTAssertEqual(RecordingView.spokenDuration(7457), "2 hours 4 minutes")
        XCTAssertEqual(RecordingView.spokenDuration(3600), "1 hour")
        XCTAssertEqual(RecordingView.spokenDuration(3660), "1 hour 1 minute")
        XCTAssertEqual(RecordingView.spokenDuration(754), "12 minutes")
        XCTAssertEqual(RecordingView.spokenDuration(60), "1 minute")
        XCTAssertEqual(RecordingView.spokenDuration(30), "30 seconds")
        XCTAssertEqual(RecordingView.spokenDuration(1), "1 second")
        XCTAssertEqual(RecordingView.spokenDuration(-4), "0 seconds")
    }
}
