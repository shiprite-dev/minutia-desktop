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
