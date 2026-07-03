import XCTest
@testable import Minutia

final class AppPhaseTests: XCTestCase {
    func test_signedOut_signedIn_goesToIdle() {
        XCTAssertEqual(AppPhase.signedOut.next(.signedIn), .idle)
    }

    func test_idle_meetingDetected_goesToDetected() {
        XCTAssertEqual(AppPhase.idle.next(.meetingDetected("Zoom")), .detected(app: "Zoom"))
        XCTAssertEqual(AppPhase.idle.next(.meetingDetected(nil)), .detected(app: nil))
    }

    func test_detected_recordStarted_goesToRecording() {
        XCTAssertEqual(AppPhase.detected(app: "Zoom").next(.recordStarted), .recording)
    }

    func test_detected_dismissedDetection_goesToIdle() {
        XCTAssertEqual(AppPhase.detected(app: "Zoom").next(.dismissedDetection), .idle)
    }

    func test_recording_recordStopped_goesToFinalizing() {
        XCTAssertEqual(AppPhase.recording.next(.recordStopped), .finalizing)
    }

    func test_finalizing_finalized_goesToIdle() {
        XCTAssertEqual(AppPhase.finalizing.next(.finalized), .idle)
    }

    func test_anyState_failed_goesToError() {
        let states: [AppPhase] = [.idle, .detected(app: "Teams"), .recording, .finalizing, .error("previous")]
        for state in states {
            XCTAssertEqual(state.next(.failed("boom")), .error("boom"))
        }
    }

    func test_error_recordStarted_goesToRecording() {
        XCTAssertEqual(AppPhase.error("boom").next(.recordStarted), .recording)
    }

    func test_anyState_signedOut_goesToSignedOut() {
        let states: [AppPhase] = [.signedOut, .idle, .detected(app: "Meet"), .recording, .finalizing, .error("boom")]
        for state in states {
            XCTAssertEqual(state.next(.signedOut), .signedOut)
        }
    }
}
