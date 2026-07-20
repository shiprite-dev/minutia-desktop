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

    func test_idle_meetingDetectedBrowserLabel_goesToDetected() {
        XCTAssertEqual(
            AppPhase.idle.next(.meetingDetected("browser meeting")), .detected(app: "browser meeting"))
    }

    func test_detected_recordStarted_goesToRecording() {
        XCTAssertEqual(AppPhase.detected(app: "Zoom").next(.recordStarted), .recording)
    }

    func test_idle_recordStarted_goesToRecording() {
        XCTAssertEqual(AppPhase.idle.next(.recordStarted), .recording)
    }

    func test_detected_dismissedDetection_goesToIdle() {
        XCTAssertEqual(AppPhase.detected(app: "Zoom").next(.dismissedDetection), .idle)
    }

    func test_error_dismissedDetection_goesToIdle() {
        XCTAssertEqual(AppPhase.error("boom").next(.dismissedDetection), .idle)
    }

    func test_recording_recordStopped_goesToFinalizing() {
        XCTAssertEqual(AppPhase.recording.next(.recordStopped), .finalizing)
    }

    func test_finalizing_finalized_goesToIdle() {
        XCTAssertEqual(AppPhase.finalizing.next(.finalized), .idle)
    }

    func test_anyState_failed_goesToError() {
        let states: [AppPhase] = [.signedOut, .idle, .detected(app: "Teams"), .recording, .finalizing, .error("previous")]
        for state in states {
            XCTAssertEqual(state.next(.failed("boom")), .error("boom"))
        }
    }

    func test_error_recordStarted_goesToRecording() {
        XCTAssertEqual(AppPhase.error("boom").next(.recordStarted), .recording)
    }

    func test_error_refinalizeStarted_goesToFinalizing() {
        XCTAssertEqual(AppPhase.error("boom").next(.refinalizeStarted), .finalizing)
    }

    /// refinalizeStarted moves only from .error; every other phase ignores it (self-transition),
    /// so a stray refinalize can never yank a live recording or a resting app into .finalizing.
    func test_refinalizeStarted_isNoOpFromEveryNonErrorPhase() {
        let nonError: [AppPhase] = [
            .signedOut, .idle, .detected(app: "Zoom"), .detected(app: nil), .recording, .finalizing,
        ]
        for state in nonError {
            XCTAssertEqual(state.next(.refinalizeStarted), state, "refinalizeStarted must be a no-op from \(state)")
        }
    }

    func test_anyState_signedOut_goesToSignedOut() {
        let states: [AppPhase] = [.signedOut, .idle, .detected(app: "Meet"), .recording, .finalizing, .error("boom")]
        for state in states {
            XCTAssertEqual(state.next(.signedOut), .signedOut)
        }
    }
}
