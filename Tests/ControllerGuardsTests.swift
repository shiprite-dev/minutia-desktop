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
}
