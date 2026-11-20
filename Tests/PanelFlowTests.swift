import SwiftUI
import XCTest
@testable import Minutia

@MainActor
final class PanelFlowTests: XCTestCase {
    private var rig: PanelRig!
    private var weekly: Series { rig.weekly }
    private var boardPrep: Series { rig.boardPrep }
    private var instance: URL { rig.instance }
    private var announcements: [String] { rig.announcements }
    private var opened: [URL] { rig.opened }

    override func setUp() async throws { rig = PanelRig() }

    override func tearDown() async throws { rig.tearDown() }

    private func controller() -> AppController { rig.controller() }
    private func signedIn(series: [Series]? = nil) -> AppController { rig.signedIn(series: series) }
    private func panel(_ controller: AppController, dark: Bool = false) -> Seen { rig.panel(controller, dark: dark) }
    private func sentCue() -> RecapCue { rig.sentCue() }
    private func finishCleanly(_ controller: AppController, cue: RecapCue?) { rig.finishCleanly(controller, cue: cue) }

    // MARK: - Which screen shows for each phase

    func test_signedOut_showsSignIn() async {
        let controller = controller()
        await controller.authManager.adopt(testSupabase(instance), instance: instance)
        let seen = rig.panel(controller, scale: 4)
        XCTAssertTrue(seen.has("Record a meeting. Get the issues log."), seen.text)
        XCTAssertTrue(seen.has("Sign in with browser"), seen.text)
        XCTAssertTrue(seen.has("Use email instead"), seen.text)
        XCTAssertFalse(seen.has("Weekly Eng Sync"), seen.text)
    }

    func test_idle_showsRecordUnderSeries() {
        let seen = panel(signedIn())
        XCTAssertTrue(seen.has("SERIES"), seen.text)
        XCTAssertTrue(seen.has("Record"), seen.text)
        XCTAssertFalse(seen.has("RECORDING"), seen.text)
    }

    func test_detected_showsTheBanner_inLightAndDark() {
        let controller = signedIn()
        controller.apply(.meetingDetected("Zoom"))
        for dark in [false, true] {
            let seen = panel(controller, dark: dark)
            XCTAssertTrue(seen.has(AppController.detectionBannerText(via: "Zoom")), "dark: \(dark) \(seen.text)")
            XCTAssertTrue(seen.has("Record"), "dark: \(dark) \(seen.text)")
        }
    }

    func test_recording_showsTheLivePanel() {
        let controller = signedIn()
        controller.useRecordingSeries(weekly.id)
        controller.apply(.recordStarted)
        let seen = panel(controller)
        XCTAssertTrue(seen.has("RECORDING"), seen.text)
        XCTAssertTrue(seen.has("Stop"), seen.text)
        XCTAssertFalse(seen.has("SERIES"), seen.text)
    }

    func test_finalizing_showsTheFinishingPanel() {
        let controller = signedIn()
        controller.apply(.recordStarted)
        controller.apply(.recordStopped)
        controller.captureSession.beginFinishing(audioMayLeaveMac: true)
        let seen = panel(controller)
        XCTAssertTrue(seen.has("Uploading and requesting transcript"), seen.text)
        XCTAssertTrue(seen.has("You can close this. Minutia finishes in the background."), seen.text)
        XCTAssertFalse(seen.has("Stop"), seen.text)
    }

    func test_failedFinish_with503_saysTheRecordingIsSavedAndOffersRetry() {
        let controller = signedIn()
        controller.apply(.recordStarted)
        controller.apply(.recordStopped)
        controller.apply(.failed(AppController.finalizeFailureMessage(for: MinutiaClientError.transcriptionNotConfigured, host: "minutia.example.com")))
        let seen = panel(controller)
        XCTAssertTrue(seen.has("Your recording is saved on this Mac"), seen.text)
        XCTAssertTrue(seen.has("Retry"), seen.text)
        XCTAssertTrue(seen.has("Dismiss"), seen.text)
    }

    // MARK: - Title of a recording

    func test_webStartedRecording_namesTheSeriesItRecordsInto_notThePickerSelection() {
        let controller = signedIn()
        XCTAssertEqual(controller.selectedSeriesId, weekly.id)
        controller.useRecordingSeries(boardPrep.id)
        controller.apply(.recordStarted)
        let seen = panel(controller)
        XCTAssertTrue(seen.has("Board prep"), seen.text)
        XCTAssertFalse(seen.has("Weekly Eng Sync"), seen.text)
    }

    func test_recordingIntoAnUnknownSeries_neverBorrowsThePickersName() {
        for unknown in [nil, UUID()] as [UUID?] {
            let controller = signedIn()
            controller.useRecordingSeries(unknown)
            controller.apply(.recordStarted)
            let seen = panel(controller)
            XCTAssertFalse(seen.has("Weekly Eng Sync"), seen.text)
            XCTAssertNil(controller.recordingSeriesName)
            XCTAssertTrue(seen.has("RECORDING"), seen.text)
        }
    }

    // MARK: - Announcements and the sent screen

    func test_recordingStarted_isAnnouncedOncePerRecording_notOnEveryMenuOpen() {
        let controller = signedIn()
        controller.apply(.recordStarted)
        for _ in 0..<3 { _ = panel(controller) }
        XCTAssertEqual(announcements, ["Recording started"])
        controller.apply(.recordStopped)
        controller.apply(.finalized)
        controller.apply(.recordStarted)
        XCTAssertEqual(announcements.filter { $0 == "Recording started" }.count, 2)
    }

    func test_failureAfterRecording_isNotAnnouncedAsStarted() {
        let controller = signedIn()
        controller.apply(.recordStarted)
        controller.apply(.failed("Microphone access was denied."))
        XCTAssertEqual(announcements, ["Recording started"])
    }

    func test_webEndedStop_goesStraightToIdle() {
        let controller = signedIn()
        finishCleanly(controller, cue: AppController.recapCue(reason: .webEnded, transcriptRequested: true, meetingId: UUID(), seriesId: nil, instance: instance))
        XCTAssertNil(controller.review.model)
        XCTAssertTrue(panel(controller).has("SERIES"))
    }

    func test_aReviewInProgress_givesWayToABackToBackRecording() {
        let controller = signedIn()
        finishCleanly(controller, cue: sentCue())
        controller.apply(.recordStarted)
        XCTAssertTrue(panel(controller).has("RECORDING"))
    }

    func test_cueIsOnlyShownOverIdle() {
        let controller = signedIn()
        controller.apply(.recordStarted)
        controller.presentRecapCue(sentCue())
        XCTAssertNil(controller.review.model)
    }

    // MARK: - Consent

    func test_pendingWebRecord_showsOneVermilionFill_andKeepsRecordAsASecondChoice() {
        let controller = signedIn()
        controller.promptRecordConsent(meetingId: UUID().uuidString)
        XCTAssertEqual(Host.fills(rig.menu(controller)).count, 1)
        let seen = panel(controller)
        XCTAssertTrue(seen.has("Record this meeting from your browser?"), seen.text)
        XCTAssertTrue(seen.has("Start recording"), seen.text)
        XCTAssertTrue(seen.has("Record"), seen.text)
    }
}
