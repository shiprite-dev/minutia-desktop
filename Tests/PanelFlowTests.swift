import AVFoundation
import SwiftUI
import XCTest
@testable import Minutia

@MainActor
final class PanelFlowTests: XCTestCase {
    private let weekly = Series(id: UUID(), name: "Weekly Eng Sync")
    private let boardPrep = Series(id: UUID(), name: "Board prep")
    private let instance = URL(string: "https://minutia.example.com")!
    private var suite: String!
    private var defaults: UserDefaults!
    private var opened: [URL] = []
    private var announcements: [String] = []
    private var controllers: [AppController] = []
    private let updater = UpdaterController()

    override func setUp() async throws {
        suite = "PanelFlowTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        opened = []
        announcements = []
    }

    override func tearDown() async throws {
        for controller in controllers {
            controller.handleDetection(.none)
            controller.authManager.cancelBrowserSignIn()
        }
        controllers = []
        defaults.removePersistentDomain(forName: suite)
    }

    private func controller() -> AppController {
        let controller = AppController(
            defaults: defaults, openURL: { [weak self] in self?.opened.append($0) }, micCheck: { (.authorized, true) })
        controller.announce = { [weak self] in self?.announcements.append($0) }
        controllers.append(controller)
        return controller
    }

    private func signedIn(series: [Series]? = nil) -> AppController {
        let controller = controller()
        controller.apply(.signedIn)
        controller.seriesLoaded(series ?? [weekly, boardPrep])
        return controller
    }

    private func panel(_ controller: AppController, dark: Bool = false) -> Seen {
        Host.text(MenuContent(controller: controller, updater: updater), dark: dark)
    }

    private func sentCue() -> RecapCue { RecapCue(meetingId: UUID(), seriesId: boardPrep.id, instance: instance) }

    private func finishCleanly(_ controller: AppController, cue: RecapCue?) {
        controller.apply(.recordStarted)
        controller.apply(.recordStopped)
        controller.apply(.finalized)
        controller.presentRecapCue(cue)
    }

    // MARK: - Which screen shows for each phase

    func test_signedOut_showsSignIn() async {
        let controller = controller()
        await controller.authManager.adopt(testSupabase(instance), instance: instance)
        let seen = panel(controller)
        XCTAssertTrue(seen.has("Sign in with browser"), seen.text)
        XCTAssertFalse(seen.has("SERIES"), seen.text)
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
            XCTAssertTrue(panel(controller, dark: dark).has(AppController.detectionBannerText(via: "Zoom")), "dark: \(dark)")
        }
    }

    func test_recording_showsTheLivePanel() {
        let controller = signedIn()
        controller.recordingSeriesId = weekly.id
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
        XCTAssertTrue(seen.has("You can close this"), seen.text)
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
        controller.recordingSeriesId = boardPrep.id
        controller.apply(.recordStarted)
        let seen = panel(controller)
        XCTAssertTrue(seen.has("Board prep"), seen.text)
        XCTAssertFalse(seen.has("Weekly Eng Sync"), seen.text)
    }

    func test_recordingIntoAnUnknownSeries_neverBorrowsThePickersName() {
        for unknown in [nil, UUID()] as [UUID?] {
            let controller = signedIn()
            controller.recordingSeriesId = unknown
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

    func test_sentScreen_saysSentInPlainWords_andIsAnnouncedOnce() {
        let controller = signedIn()
        finishCleanly(controller, cue: sentCue())
        for _ in 0..<2 {
            let seen = panel(controller)
            XCTAssertTrue(seen.has("Sent. Your recap is on its way"), seen.text)
            XCTAssertTrue(seen.has("Open recap"), seen.text)
            XCTAssertFalse(seen.has("SERIES"), seen.text)
        }
        XCTAssertEqual(announcements.filter { $0 == "Sent. Your recap is on its way" }.count, 1)
    }

    func test_webEndedStop_goesStraightToIdle() {
        let controller = signedIn()
        finishCleanly(controller, cue: AppController.recapCue(reason: .webEnded, transcriptRequested: true, meetingId: UUID(), seriesId: nil, instance: instance))
        let seen = panel(controller)
        XCTAssertFalse(seen.has("Sent. Your recap"), seen.text)
        XCTAssertTrue(seen.has("SERIES"), seen.text)
    }

    func test_sentScreen_givesWayToADetectedMeetingWithinTheHold() {
        let controller = signedIn()
        finishCleanly(controller, cue: sentCue())
        XCTAssertNotNil(controller.recapCue)
        controller.apply(.meetingDetected("Zoom"))
        XCTAssertNil(controller.recapCue)
        let seen = panel(controller)
        XCTAssertTrue(seen.has(AppController.detectionBannerText(via: "Zoom")), seen.text)
        XCTAssertFalse(seen.has("Sent. Your recap"), seen.text)
    }

    func test_sentScreen_givesWayToABackToBackRecording() {
        let controller = signedIn()
        finishCleanly(controller, cue: sentCue())
        controller.apply(.recordStarted)
        XCTAssertNil(controller.recapCue)
        XCTAssertTrue(panel(controller).has("RECORDING"))
    }

    func test_sentScreen_clearsWhenItsHoldEnds() {
        let controller = signedIn()
        finishCleanly(controller, cue: sentCue())
        controller.clearRecapCue()
        XCTAssertTrue(panel(controller).has("SERIES"))
    }

    func test_openRecap_opensTheMeetingTheCueNames() async {
        let controller = signedIn()
        let cue = sentCue()
        finishCleanly(controller, cue: cue)
        controller.openRecapFromCue()
        let expected = MinutiaClient.recapURL(instance: instance, seriesId: boardPrep.id, meetingId: cue.meetingId)
        for _ in 0..<50 where opened.isEmpty { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(opened, [expected])
    }

    func test_openRecap_withoutACue_doesNothing() async {
        let controller = signedIn()
        controller.openRecapFromCue()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(opened.isEmpty)
    }

    func test_cueIsOnlyShownOverIdle() {
        let controller = signedIn()
        controller.apply(.recordStarted)
        controller.presentRecapCue(sentCue())
        XCTAssertNil(controller.recapCue)
    }

    // MARK: - Consent

    func test_pendingWebRecord_showsOneVermilionFill_andKeepsRecordAsASecondChoice() {
        let controller = signedIn()
        controller.promptRecordConsent(meetingId: UUID().uuidString)
        let view = MenuContent(controller: controller, updater: updater)
        XCTAssertEqual(Host.fillBands(view, atPoint: 30), 1)
        let seen = panel(controller)
        XCTAssertTrue(seen.has("Record this meeting from your browser?"), seen.text)
        XCTAssertTrue(seen.has("Start recording"), seen.text)
        XCTAssertTrue(seen.has("Record"), seen.text)
    }
}
