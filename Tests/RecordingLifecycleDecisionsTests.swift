import XCTest
import AVFoundation
@testable import Minutia

/// Pure decision seams introduced by the recording-lifecycle correctness pass: the retry routing for
/// a preserved-audio fatal, the quit-time finish action, the finalize-failure copy, and the mic
/// pre-check gate. Each is folded out of AppController so the branch matrix is tested without a live
/// client or capture pipeline.
final class RecordingLifecycleDecisionsTests: XCTestCase {
    private let meeting = "0f9c2c9a-1a2b-4c3d-8e4f-5a6b7c8d9e0f"

    // MARK: - B5: retry routing

    func test_retryTarget_finalizeRoutesToThatFinalize() {
        XCTAssertEqual(
            AppController.retryTarget(lastFailedStart: .finalize(meetingId: meeting)),
            .finalize(meetingId: meeting))
    }

    /// Preserved audio (disk-full, stall) must finish the durable directory, never re-record, no
    /// matter whether a series was selected.
    func test_fatalRetryTarget_preservedRoutesToFinalize() {
        XCTAssertEqual(
            AppController.fatalRetryTarget(preservedForRecovery: true, recordingMeetingId: meeting, hasSeries: true),
            .finalize(meetingId: meeting))
        XCTAssertEqual(
            AppController.fatalRetryTarget(preservedForRecovery: true, recordingMeetingId: meeting, hasSeries: false),
            .finalize(meetingId: meeting))
    }

    /// A non-preserved fatal (mic denied, nothing written) retries the original start: the web
    /// meeting id when there is no series, else the selected series.
    func test_fatalRetryTarget_notPreservedWithoutSeriesRoutesToMeeting() {
        XCTAssertEqual(
            AppController.fatalRetryTarget(preservedForRecovery: false, recordingMeetingId: meeting, hasSeries: false),
            .meeting(meeting))
    }

    func test_fatalRetryTarget_notPreservedWithSeriesRoutesToSeries() {
        XCTAssertEqual(
            AppController.fatalRetryTarget(preservedForRecovery: false, recordingMeetingId: meeting, hasSeries: true),
            .series)
    }

    func test_fatalRetryTarget_nilMeetingFallsBackToSeries() {
        XCTAssertEqual(
            AppController.fatalRetryTarget(preservedForRecovery: true, recordingMeetingId: nil, hasSeries: false),
            .series)
        XCTAssertEqual(
            AppController.fatalRetryTarget(preservedForRecovery: false, recordingMeetingId: nil, hasSeries: false),
            .series)
    }

    // MARK: - B6: quit-time finish action

    func test_quitFinishAction_recordingStops() {
        XCTAssertEqual(AppController.quitFinishAction(phase: .recording), .stop)
    }

    func test_quitFinishAction_finalizingAwaits() {
        XCTAssertEqual(AppController.quitFinishAction(phase: .finalizing), .awaitFinalizing)
    }

    func test_quitFinishAction_everythingElseIsNone() {
        let resting: [AppPhase] = [.signedOut, .idle, .detected(app: "Zoom"), .detected(app: nil), .error("boom")]
        for phase in resting {
            XCTAssertEqual(AppController.quitFinishAction(phase: phase), .none, "no finish work from \(phase)")
        }
    }

    // MARK: - B7: finalize-failure copy

    func test_finalizeFailureMessage_timeoutIsHonestAudioIsSafe() {
        XCTAssertEqual(
            AppController.finalizeFailureMessage(for: TimeoutError(), host: "minutia.example.com"),
            "Finishing the recording timed out. Your audio is saved locally; Retry to finish uploading.")
    }

    func test_finalizeFailureMessage_otherErrorUsesLocalizedDescription() {
        struct Boom: LocalizedError { var errorDescription: String? { "network down" } }
        XCTAssertEqual(
            AppController.finalizeFailureMessage(for: Boom(), host: "minutia.example.com"),
            "Could not finish recording: network down")
    }

    /// featureUnavailable names the host and reassures the audio is saved; a nil host (an instance
    /// URL with no host component) falls back to "the server".
    func test_finalizeFailureMessage_featureUnavailableNamesHost() {
        XCTAssertEqual(
            AppController.finalizeFailureMessage(for: MinutiaClientError.featureUnavailable, host: "acme.getminutia.com"),
            "Transcription is not enabled for this account on acme.getminutia.com. Your audio is saved. Ask your workspace admin to enable AI features.")
    }

    func test_finalizeFailureMessage_featureUnavailableNilHostFallsBackToServer() {
        XCTAssertEqual(
            AppController.finalizeFailureMessage(for: MinutiaClientError.featureUnavailable, host: nil),
            "Transcription is not enabled for this account on the server. Your audio is saved. Ask your workspace admin to enable AI features.")
    }

    // MARK: - Startup recovery outcome

    func test_recoveryOutcome_nilErrorIsRecovered() {
        XCTAssertEqual(AppController.recoveryOutcome(for: nil), .recovered)
    }

    func test_recoveryOutcome_featureUnavailableNotifiesAndKeeps() {
        XCTAssertEqual(
            AppController.recoveryOutcome(for: MinutiaClientError.featureUnavailable),
            .transcriptionUnavailable)
    }

    func test_recoveryOutcome_otherErrorsRetryNextLaunch() {
        struct Boom: Error {}
        XCTAssertEqual(AppController.recoveryOutcome(for: Boom()), .retryLater)
        XCTAssertEqual(AppController.recoveryOutcome(for: MinutiaClientError.serverError(status: 500)), .retryLater)
    }

    // MARK: - Startup recovery attempt bound

    /// A fresh or mid-way capture is still attempted, incrementing the persisted count; the count that
    /// reaches the ceiling notifies exactly once; at or past the ceiling the sweep skips the directory
    /// entirely (audio kept) so a dead recording never retries on every launch forever.
    func test_recoverySweep_belowCeilingAttemptsAndIncrements() {
        XCTAssertEqual(
            AppController.recoverySweep(priorAttempts: 0),
            .init(skip: false, nextAttempts: 1, notifyOnExhaustion: false))
    }

    func test_recoverySweep_lastAttemptReachesCeilingAndNotifiesOnce() {
        XCTAssertEqual(
            AppController.recoverySweep(priorAttempts: AppController.maxRecoveryAttempts - 1),
            .init(skip: false, nextAttempts: AppController.maxRecoveryAttempts, notifyOnExhaustion: true))
    }

    func test_recoverySweep_atCeilingSkipsWithoutReNotifying() {
        XCTAssertEqual(
            AppController.recoverySweep(priorAttempts: AppController.maxRecoveryAttempts),
            .init(skip: true, nextAttempts: AppController.maxRecoveryAttempts, notifyOnExhaustion: false))
    }

    func test_recoverySweep_pastCeilingStaysSkippedAndSilent() {
        XCTAssertEqual(
            AppController.recoverySweep(priorAttempts: AppController.maxRecoveryAttempts + 1),
            .init(skip: true, nextAttempts: AppController.maxRecoveryAttempts + 1, notifyOnExhaustion: false))
    }

    // MARK: - B8: mic pre-check gate

    func test_micPreCheckFails_trueForDeniedAndRestricted() {
        XCTAssertTrue(AppController.micPreCheckFails(status: .denied))
        XCTAssertTrue(AppController.micPreCheckFails(status: .restricted))
    }

    /// Authorized proceeds; notDetermined flows through unchanged so the deliberate
    /// prompt-during-capture design (which preserves system audio recorded while the dialog is up)
    /// is never pre-empted by a pre-check.
    func test_micPreCheckFails_falseForAuthorizedAndNotDetermined() {
        XCTAssertFalse(AppController.micPreCheckFails(status: .authorized))
        XCTAssertFalse(AppController.micPreCheckFails(status: .notDetermined))
    }

    // MARK: - B9: series Record pre-flight guard

    func test_recordPreflight_micDeniedWinsRegardlessOfSeries() {
        XCTAssertEqual(AppController.recordPreflight(micStatus: .denied, hasSeries: true), .micDenied)
        XCTAssertEqual(AppController.recordPreflight(micStatus: .denied, hasSeries: false), .micDenied)
        XCTAssertEqual(AppController.recordPreflight(micStatus: .restricted, hasSeries: true), .micDenied)
    }

    func test_recordPreflight_noSeriesWhenMicOkAndNoSeries() {
        XCTAssertEqual(AppController.recordPreflight(micStatus: .authorized, hasSeries: false), .noSeries)
        XCTAssertEqual(AppController.recordPreflight(micStatus: .notDetermined, hasSeries: false), .noSeries)
    }

    func test_recordPreflight_proceedWhenMicOkAndHasSeries() {
        XCTAssertEqual(AppController.recordPreflight(micStatus: .authorized, hasSeries: true), .proceed)
        XCTAssertEqual(AppController.recordPreflight(micStatus: .notDetermined, hasSeries: true), .proceed)
    }
}
