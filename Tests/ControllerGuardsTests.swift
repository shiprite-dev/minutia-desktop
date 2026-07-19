import XCTest
@testable import Minutia

/// Guard decisions folded out of AppController so the record-start and sign-out
/// branches are testable without a live client or capture pipeline.
final class ControllerGuardsTests: XCTestCase {
    // MARK: - M1: record start guard

    func test_canStartRecording_trueFromRestingAndRecoverablePhases() {
        XCTAssertTrue(AppController.canStartRecording(from: .idle))
        XCTAssertTrue(AppController.canStartRecording(from: .detected(app: "Zoom")))
        XCTAssertTrue(AppController.canStartRecording(from: .detected(app: nil)))
        XCTAssertTrue(AppController.canStartRecording(from: .error("boom")))
    }

    func test_canStartRecording_falseWhileCapturing() {
        // A stale "Record this meeting?" notification clicked mid-recording must not
        // spin up a second server meeting or overwrite the recording meeting id.
        XCTAssertFalse(AppController.canStartRecording(from: .recording))
        XCTAssertFalse(AppController.canStartRecording(from: .finalizing))
    }

    func test_canStartRecording_falseWhenSignedOut() {
        XCTAssertFalse(AppController.canStartRecording(from: .signedOut))
    }

    // MARK: - Web-triggered record command

    private let meetingA = "0f9c2c9a-1a2b-4c3d-8e4f-5a6b7c8d9e0f"
    private let meetingB = "11111111-2222-3333-4444-555555555555"

    func test_recordCommand_signInRequiredWhenSignedOut() {
        XCTAssertEqual(
            AppController.recordCommandDecision(
                requestedMeetingId: meetingA, phase: .signedOut,
                signedIn: false, recordingMeetingId: nil),
            .signInRequired)
    }

    func test_recordCommand_startsFromRestingPhases() {
        for phase in [AppPhase.idle, .detected(app: "Zoom"), .error("boom")] {
            XCTAssertEqual(
                AppController.recordCommandDecision(
                    requestedMeetingId: meetingA, phase: phase,
                    signedIn: true, recordingMeetingId: nil),
                .start,
                "expected .start from \(phase)")
        }
    }

    func test_recordCommand_ignoresSameMeetingWhileRecording() {
        for phase in [AppPhase.recording, .finalizing] {
            XCTAssertEqual(
                AppController.recordCommandDecision(
                    requestedMeetingId: meetingA, phase: phase,
                    signedIn: true, recordingMeetingId: meetingA),
                .ignoreSameMeeting,
                "expected no-op for the same meeting in \(phase)")
        }
    }

    func test_recordCommand_rejectsDifferentMeetingWhileRecording() {
        for phase in [AppPhase.recording, .finalizing] {
            XCTAssertEqual(
                AppController.recordCommandDecision(
                    requestedMeetingId: meetingB, phase: phase,
                    signedIn: true, recordingMeetingId: meetingA),
                .rejectOtherMeeting,
                "expected reject for a different meeting in \(phase)")
        }
    }

    // MARK: - C1: sign-out capture teardown

    func test_shouldStopCaptureOnSignOut_trueWhileCapturing() {
        XCTAssertTrue(AppController.shouldStopCaptureOnSignOut(phase: .recording))
        XCTAssertTrue(AppController.shouldStopCaptureOnSignOut(phase: .finalizing))
    }

    func test_shouldStopCaptureOnSignOut_falseOtherwise() {
        let restingPhases: [AppPhase] = [.signedOut, .idle, .detected(app: "Teams"), .error("boom")]
        for phase in restingPhases {
            XCTAssertFalse(AppController.shouldStopCaptureOnSignOut(phase: phase))
        }
    }

    // MARK: - Quit-while-recording/recovering guard (C7)

    func test_shouldConfirmQuit_trueWhileCapturing() {
        XCTAssertTrue(AppController.shouldConfirmQuit(phase: .recording, recoveryActive: false))
        XCTAssertTrue(AppController.shouldConfirmQuit(phase: .finalizing, recoveryActive: false))
    }

    func test_shouldConfirmQuit_falseWhenRestingAndNoRecovery() {
        let restingPhases: [AppPhase] = [.signedOut, .idle, .detected(app: "Zoom"), .detected(app: nil), .error("boom")]
        for phase in restingPhases {
            XCTAssertFalse(
                AppController.shouldConfirmQuit(phase: phase, recoveryActive: false),
                "must not confirm quit from \(phase)")
        }
    }

    /// An in-flight startup recovery sweep must block a quit even from a resting phase, so the
    /// rescue of a prior recording is not abandoned on the way out.
    func test_shouldConfirmQuit_trueWheneverRecoveryActive() {
        let phases: [AppPhase] = [.signedOut, .idle, .detected(app: "Zoom"), .detected(app: nil), .recording, .finalizing, .error("boom")]
        for phase in phases {
            XCTAssertTrue(
                AppController.shouldConfirmQuit(phase: phase, recoveryActive: true),
                "recovery in flight must confirm quit from \(phase)")
        }
    }

    // MARK: - Mic-permission error classification (C6)

    func test_isMicPermissionError_matchesTheCaptureConstant() {
        let message = CaptureSession.failureMessage(for: MicCapture.CaptureError.permissionDenied)
        XCTAssertTrue(AppController.isMicPermissionError(message: message))
    }

    func test_isMicPermissionError_falseForOtherMessages() {
        XCTAssertFalse(AppController.isMicPermissionError(message: "Recording stopped: audio capture stalled."))
        XCTAssertFalse(AppController.isMicPermissionError(message: "Could not start recording: network error"))
        XCTAssertFalse(AppController.isMicPermissionError(message: ""))
    }

    // MARK: - Soft-detection hint

    /// Soft confidence (mic active, no corroborating app/calendar signal) surfaces the quiet
    /// hint only while resting at idle. It must stay invisible mid-capture and never compete
    /// with the .high detection banner.
    func test_shouldShowSoftHint_trueOnlyForSoftAtIdle() {
        XCTAssertTrue(AppController.shouldShowSoftHint(confidence: .soft, phase: .idle))
    }

    func test_shouldShowSoftHint_falseForSoftInEveryNonIdlePhase() {
        let nonIdle: [AppPhase] = [
            .signedOut, .detected(app: "Zoom"), .detected(app: nil),
            .recording, .finalizing, .error("boom"),
        ]
        for phase in nonIdle {
            XCTAssertFalse(
                AppController.shouldShowSoftHint(confidence: .soft, phase: phase),
                "soft hint must not show in \(phase)")
        }
    }

    func test_shouldShowSoftHint_falseForHighAndNoneInEveryPhase() {
        let phases: [AppPhase] = [
            .signedOut, .idle, .detected(app: "Zoom"), .detected(app: nil),
            .recording, .finalizing, .error("boom"),
        ]
        let nonSoft: [DetectionConfidence] = [.high(.zoom), .high(.teams), .high(nil), .none]
        for confidence in nonSoft {
            for phase in phases {
                XCTAssertFalse(
                    AppController.shouldShowSoftHint(confidence: confidence, phase: phase),
                    "\(confidence) must never show the soft hint (phase \(phase))")
            }
        }
    }
}
