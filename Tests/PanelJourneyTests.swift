import AVFoundation
import SwiftUI
import XCTest
@testable import Minutia

@MainActor
final class PanelJourneyTests: XCTestCase {
    private var rig: PanelRig!

    override func setUp() async throws { rig = PanelRig() }
    override func tearDown() async throws { rig.tearDown() }

    private let micDenied = CaptureSession.failureMessage(for: MicCapture.CaptureError.permissionDenied)
    private let uploadFailed = "Upload failed after several attempts. Your recording is saved on this Mac."

    private func adopted() async -> AppController {
        let controller = rig.controller()
        await controller.authManager.adopt(testSupabase(rig.instance), instance: rig.instance)
        return controller
    }

    private func assertFills(_ name: String, _ view: some View, labels: [String], file: StaticString = #filePath, line: UInt = #line) {
        for dark in [false, true] {
            guard let image = Host.render(view, dark: dark, spin: 0.5) else { return XCTFail("\(name) did not render", file: file, line: line) }
            let regions = Host.fillRegions(image)
            let seen = Host.read(image)
            XCTAssertEqual(regions.count, labels.count, "\(name) (dark: \(dark)) fills: \(regions.map(\.frame)) text: \(seen.text)", file: file, line: line)
            for label in labels {
                let held = seen.frames(of: label).contains { frame in regions.contains { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) } }
                XCTAssertTrue(held, "\(name) (dark: \(dark)): the fill is not behind \"\(label)\". text: \(seen.text)", file: file, line: line)
            }
        }
    }

    // MARK: - Screens the controller picks

    func test_anAccountWithNoSeries_isGuidedToConnectACalendarOrCreateOne_andIsNotOfferedRecord() {
        let seen = rig.panel(rig.signedIn(series: []))
        XCTAssertTrue(seen.has("No series yet"), seen.text)
        XCTAssertTrue(seen.has("Connect a calendar or create a series in Minutia on the web, then record here."), seen.text)
        XCTAssertTrue(seen.has("Connect Google Calendar"), seen.text)
        XCTAssertTrue(seen.has("Create a series"), seen.text)
        XCTAssertFalse(seen.has("Weekly Eng Sync"), seen.text)
        XCTAssertFalse(seen.has("Board prep"), seen.text)
    }

    func test_aFailedStart_offersRetryAndDismiss_withRetryTheOnlyFilledButton() {
        let controller = rig.signedIn()
        controller.apply(.failed(uploadFailed))
        let seen = rig.panel(controller)
        XCTAssertTrue(seen.has(uploadFailed), seen.text)
        XCTAssertTrue(seen.has("Retry"), seen.text)
        XCTAssertTrue(seen.has("Dismiss"), seen.text)
        XCTAssertFalse(seen.has("Open System Settings"), seen.text)
        assertFills("failed start", rig.menu(controller), labels: ["Retry"])
    }

    func test_whenTheMicIsDenied_openSystemSettingsLeads_andRetryAndDismissRemain() {
        let controller = rig.signedIn()
        controller.apply(.failed(micDenied))
        let seen = rig.panel(controller)
        XCTAssertTrue(seen.has(micDenied), seen.text)
        XCTAssertTrue(seen.has("Open System Settings"), seen.text)
        XCTAssertTrue(seen.has("Retry"), seen.text)
        XCTAssertTrue(seen.has("Dismiss"), seen.text)
        assertFills("mic denied", rig.menu(controller), labels: ["Open System Settings"])
    }

    func test_dismissingAnError_returnsToTheSeriesPickerWithRecordOffered() {
        let controller = rig.signedIn()
        controller.apply(.failed(uploadFailed))
        controller.dismissError()
        let seen = rig.panel(controller)
        XCTAssertTrue(seen.has("SERIES"), seen.text)
        XCTAssertTrue(seen.has("Record"), seen.text)
        XCTAssertFalse(seen.has(uploadFailed), seen.text)
    }

    func test_aStopThatSentNothing_neverTellsTheUserItWasSent() {
        for (reason, requested, meeting) in [(AppController.StopReason.manual, false, UUID() as UUID?), (.manual, true, nil)] {
            let controller = rig.signedIn()
            let cue = AppController.recapCue(reason: reason, transcriptRequested: requested, meetingId: meeting, seriesId: nil, instance: rig.instance)
            rig.finishCleanly(controller, cue: cue)
            let seen = rig.panel(controller)
            XCTAssertFalse(seen.has("Sent. Your recap"), seen.text)
            XCTAssertTrue(seen.has("SERIES"), seen.text)
        }
    }

    func test_aManualStopThatSentTheTranscript_showsSentAndKeepsTheRecapLinkToThatMeeting() async {
        let controller = rig.signedIn()
        let meeting = UUID()
        let cue = AppController.recapCue(reason: .manual, transcriptRequested: true, meetingId: meeting, seriesId: rig.boardPrep.id, instance: rig.instance)
        rig.finishCleanly(controller, cue: cue)
        XCTAssertTrue(rig.panel(controller).has("Sent. Your recap is on its way"))
        controller.openRecapFromCue()
        for _ in 0..<50 where rig.opened.isEmpty { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(rig.opened, [MinutiaClient.recapURL(instance: rig.instance, seriesId: rig.boardPrep.id, meetingId: meeting)])
    }

    func test_theSentScreen_staysUpForAReadableBeat_thenGivesWayToTheSeriesPicker() async {
        let controller = rig.signedIn()
        let clock = ManualClock()
        controller.sleep = { await clock.sleep($0) }
        let hold = controller.recapHold()
        rig.finishCleanly(controller, cue: rig.sentCue())
        await clock.waitForSleepers(1)

        await clock.advance(1.5)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let reading = rig.panel(controller)
        XCTAssertTrue(reading.has("Sent. Your recap is on its way"), "gone before a user could read it: \(reading.text)")

        await clock.advance(hold - 1.5 + 0.1)
        for _ in 0..<100 where controller.recapCue != nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        let after = rig.panel(controller)
        XCTAssertFalse(after.has("Sent. Your recap is on its way"), after.text)
        XCTAssertTrue(after.has("SERIES"), after.text)
    }

    private func done(at elapsed: TimeInterval, reduceMotion: Bool) -> CGImage {
        Host.render(DoneContent().environment(\.checkElapsed, elapsed).environment(\.reduceMotionOverride, reduceMotion), spin: 0.2)!
    }

    func test_theSentCheck_isNotDrawnAtFirst_isPartwayMidDraw_andIsTheFinishedCheckAfterwards() {
        let reference = done(at: 0, reduceMotion: true)
        let finished = Host.vermilionRuns(reference).pixels
        XCTAssertGreaterThan(finished, 50)

        XCTAssertEqual(Host.vermilionRuns(done(at: 0, reduceMotion: false)).pixels, 0, "the check is already drawn before the draw starts")

        let partway = Host.vermilionRuns(done(at: CheckReveal.delay + 0.1, reduceMotion: false)).pixels
        XCTAssertGreaterThan(partway, finished / 5)
        XCTAssertLessThan(partway, finished * 9 / 10)

        let after = done(at: CheckReveal.total + 0.5, reduceMotion: false)
        XCTAssertEqual(Host.differingBytes(after, reference), 0, "the settled check is not the finished check")
    }

    func test_withReduceMotionOn_theSentCheckIsFinishedAtOnce() {
        let finished = Host.vermilionRuns(done(at: CheckReveal.total + 0.5, reduceMotion: true)).pixels
        XCTAssertEqual(Host.vermilionRuns(done(at: 0, reduceMotion: true)).pixels, finished)
        XCTAssertGreaterThan(finished, 50)
    }

    // MARK: - Finishing progress

    private func finishing(step: CaptureSession.FinishingStep) async -> AppController {
        let controller = rig.signedIn()
        controller.apply(.recordStarted)
        controller.apply(.recordStopped)
        await controller.captureSession.finishingStepReporter()(step)
        return controller
    }

    private func filledShare(of view: some View) -> (share: Double, seen: Seen) {
        guard let image = Host.render(view, spin: 0.3) else { return (-1, Seen(text: "", frames: [])) }
        let run = Host.vermilionRuns(image)
        let track = Double(Int(Space.panelWidth - 2 * Space.x4) * 3)
        return (Double(run.longestRun) / track, Host.read(image))
    }

    func test_transcribingOnThisMac_showsWhichPieceItIsOnAndAQuarterFilledBar() async {
        let (share, seen) = filledShare(of: rig.menu(await finishing(step: .transcribing(completed: 3, total: 12))))
        XCTAssertTrue(seen.has("Transcribing on this Mac, 3 of 12"), seen.text)
        XCTAssertEqual(share, 0.25, accuracy: 0.03)
    }

    func test_aStepWithNoTotal_hasNoBarAtAll_whileARealTotalAlwaysHasOne() async {
        let none = Host.size(rig.menu(await finishing(step: .transcribing(completed: 0, total: 0)))).height
        let started = Host.size(rig.menu(await finishing(step: .transcribing(completed: 0, total: 5)))).height
        XCTAssertGreaterThan(started, none)
    }

    func test_aStepThatRunsPastItsTotal_fillsTheBarAndNoFurther() async {
        let (share, seen) = filledShare(of: rig.menu(await finishing(step: .transcribing(completed: 9, total: 4))))
        XCTAssertTrue(seen.has("Transcribing on this Mac, 9 of 4"), seen.text)
        XCTAssertEqual(share, 1, accuracy: 0.03)
    }

    func test_stepsWithNoMeasurableProgress_showTheirLabelAndNoBar() async {
        for (step, label) in [(CaptureSession.FinishingStep.preparingModel, "Preparing the speech model"),
                              (.uploadingRecording, "Uploading and requesting transcript")] {
            let (share, seen) = filledShare(of: rig.menu(await finishing(step: step)))
            XCTAssertTrue(seen.has(label), seen.text)
            XCTAssertEqual(share, 0, accuracy: 0.001, label)
        }
    }

    // MARK: - One vermilion fill

    func test_everyScreen_paintsExactlyTheExpectedPrimaryButtonAndNoSecondFill() async {
        let signedOut = await adopted()
        assertFills("sign in", rig.menu(signedOut), labels: ["Sign in with browser"])

        let pending = await adopted()
        _ = pending.authManager.beginBrowserSignIn(device: "Test Mac")
        assertFills("waiting on the browser", rig.menu(pending), labels: [])

        assertFills("idle", rig.menu(rig.signedIn()), labels: ["Record"])
        assertFills("no series", rig.menu(rig.signedIn(series: [])), labels: ["Connect Google Calendar"])

        let detected = rig.signedIn()
        detected.apply(.meetingDetected("Zoom"))
        assertFills("detected", rig.menu(detected), labels: ["Record"])

        let micRig = PanelRig(mic: (.denied, true))
        defer { micRig.tearDown() }
        assertFills("idle with the mic banner", micRig.menu(micRig.signedIn()), labels: ["Record"])

        let recording = rig.signedIn()
        recording.apply(.recordStarted)
        assertFills("recording", rig.menu(recording), labels: ["Stop"])

        assertFills("finishing", rig.menu(await finishing(step: .uploadingRecording)), labels: [])

        let sent = rig.signedIn()
        rig.finishCleanly(sent, cue: rig.sentCue())
        assertFills("sent", rig.menu(sent), labels: [])

        let failed = rig.signedIn()
        failed.apply(.failed(uploadFailed))
        assertFills("error", rig.menu(failed), labels: ["Retry"])

        let denied = rig.signedIn()
        denied.apply(.failed(micDenied))
        assertFills("mic error", rig.menu(denied), labels: ["Open System Settings"])
    }

    func test_aBrowserRecordRequest_paintsOneFill_overEveryScreenItCanLandOn() {
        let idle = rig.signedIn()
        idle.promptRecordConsent(meetingId: UUID().uuidString)
        assertFills("consent over idle", rig.menu(idle), labels: ["Start recording"])

        let empty = rig.signedIn(series: [])
        empty.promptRecordConsent(meetingId: UUID().uuidString)
        assertFills("consent over no series", rig.menu(empty), labels: ["Start recording"])

        let detected = rig.signedIn()
        detected.apply(.meetingDetected("Zoom"))
        detected.promptRecordConsent(meetingId: UUID().uuidString)
        assertFills("consent over detected", rig.menu(detected), labels: ["Start recording"])

        let failed = rig.signedIn()
        failed.apply(.failed(uploadFailed))
        failed.promptRecordConsent(meetingId: UUID().uuidString)
        assertFills("consent over error", rig.menu(failed), labels: ["Start recording"])

        let denied = rig.signedIn()
        denied.apply(.failed(micDenied))
        denied.promptRecordConsent(meetingId: UUID().uuidString)
        assertFills("consent over mic error", rig.menu(denied), labels: ["Start recording"])
    }

    func test_aBrowserRecordRequestWithAStandingChoice_paintsOneFill_overIdle() {
        let model = IdleModel(series: [rig.weekly], selected: rig.weekly.id, detectedVia: nil, softHint: false, micBanner: false, recovering: false, instance: rig.instance)
        let view = VStack(spacing: 0) { ConsentNotice(hasClaim: true); IdleScreen(model: model) }.environment(\.consentPending, true)
        assertFills("claim consent over idle", view, labels: ["Always start automatically"])
    }

    func test_signInFailures_paintOneFillOnlyWhereRetryIsPossible() {
        func screen(_ stage: SignInStage) -> some View {
            SignInScreen(stage: stage, showsMenuBarHint: false, signInError: nil, email: .constant(""), password: .constant(""), showEmailForm: .constant(false), busy: false)
        }
        assertFills("connecting", screen(.connecting), labels: [])
        assertFills("offline", screen(.failed(message: "Can't reach the server.", retryable: true)), labels: ["Try again"])
        assertFills("not a Minutia server", screen(.failed(message: "Not a Minutia server.", retryable: false)), labels: [])
    }

    // MARK: - Motion

    private func recordingController() -> AppController {
        let controller = rig.signedIn()
        controller.apply(.recordStarted)
        return controller
    }

    private func finishingController() -> AppController {
        let controller = rig.signedIn()
        controller.apply(.recordStarted)
        controller.apply(.recordStopped)
        controller.captureSession.beginFinishing(audioMayLeaveMac: true)
        return controller
    }

    func test_animationsRunWhileThePanelIsOpen_stopOnceItIsClosed_andResumeOnReopen() {
        for (name, controller) in [("finishing", finishingController()), ("recording", recordingController())] {
            let panel = LivePanel(rig.menu(controller).environment(\.reduceMotionOverride, false))
            XCTAssertTrue(panel.animates(), "\(name) should be animating while open")
            controller.panelClosed()
            panel.spin(0.3)
            XCTAssertFalse(panel.animates(), "\(name) kept animating after the panel closed")
            controller.panelOpened()
            panel.spin(0.3)
            XCTAssertTrue(panel.animates(), "\(name) did not resume when the panel reopened")
        }
    }

    func test_withReduceMotionOn_theOpenPanelStaysStill() {
        for (name, controller) in [("finishing", finishingController()), ("recording", recordingController())] {
            XCTAssertTrue(LivePanel(rig.menu(controller).environment(\.reduceMotionOverride, false)).animates(), "\(name) should move with motion allowed")
            XCTAssertFalse(LivePanel(rig.menu(controller).environment(\.reduceMotionOverride, true)).animates(), "\(name) moved under Reduce Motion")
        }
    }

    func test_closingTheMenuWindow_tellsTheControllerThePanelIsClosed_andReopeningTellsItAgain() {
        let controller = finishingController()
        let panel = LivePanel(rig.menu(controller))
        XCTAssertTrue(controller.panelOpen)
        panel.detach()
        panel.spin(0.5)
        XCTAssertFalse(controller.panelOpen, "the menu left its window but still counts as open")
        panel.attach()
        panel.spin(0.5)
        XCTAssertTrue(controller.panelOpen)
    }

    // MARK: - Increase Contrast

    func test_increaseContrast_drawsAFirmerRule_aNoticeBorder_andDarkerQuietText() {
        func ruleRows(_ view: some View) -> Int {
            guard let image = Host.render(view.frame(width: 100, height: 10), spin: 0.1, scale: 6) else { return 0 }
            let (width, height, data) = Host.pixels(image)
            return (0..<height).filter { abs(Int(data[($0 * width + width / 2) * 4]) - 0xF5) > 20 }.count
        }
        let standardRule = ruleRows(HairlineRule())
        let increasedRule = ruleRows(HairlineRule().environment(\.contrastOverride, .increased))
        XCTAssertGreaterThanOrEqual(increasedRule, 5, "an Increase Contrast rule should be a full point (6 rows at 6x)")
        XCTAssertGreaterThan(increasedRule, standardRule)

        func longestBorderLine(_ view: some View) -> Int {
            guard let image = Host.render(view, spin: 0.1) else { return 0 }
            let (width, height, data) = Host.pixels(image)
            var longest = 0
            for column in 0..<width {
                var run = 0
                for row in 0..<height {
                    let i = (row * width + column) * 4
                    let ink = abs(Int(data[i]) - 0x70) < 5 && abs(Int(data[i + 1]) - 0x6B) < 5 && abs(Int(data[i + 2]) - 0x66) < 5
                    run = ink ? run + 1 : 0
                    longest = max(longest, run)
                }
            }
            return longest
        }
        let notice = FeedbackNotice(message: "That recording could not be started. Try again in a moment.")
        XCTAssertLessThan(longestBorderLine(notice), 60)
        XCTAssertGreaterThan(longestBorderLine(notice.environment(\.contrastOverride, .increased)), 60)

        let quiet = Button("Dismiss") {}.buttonStyle(QuietButtonStyle()).padding(8)
        func quietInk(_ view: some View) -> Double {
            guard let image = Host.render(view, spin: 0.1) else { return 0 }
            return Host.worstContrast(in: image, seen: Host.read(image))?.ratio ?? 0
        }
        XCTAssertGreaterThan(quietInk(quiet.environment(\.contrastOverride, .increased)), quietInk(quiet))
    }

    // MARK: - Readability as rendered

    private func everyScreen() async -> [(String, AppController)] {
        let detected = rig.signedIn()
        detected.apply(.meetingDetected("Zoom"))
        let failed = rig.signedIn()
        failed.apply(.failed(uploadFailed))
        let consent = rig.signedIn()
        consent.promptRecordConsent(meetingId: UUID().uuidString)
        let sent = rig.signedIn()
        rig.finishCleanly(sent, cue: rig.sentCue())
        return [
            ("idle", rig.signedIn()), ("detected", detected), ("error", failed), ("consent", consent), ("recording", recordingController()),
            ("sent", sent), ("no series", rig.signedIn(series: [])), ("sign in", await adopted()),
            ("finishing", await finishing(step: .preparingModel)),
        ]
    }

    func test_everyScreenTheControllerShows_isPanelWidthAndFitsTheMenuBudget() async {
        for (name, controller) in await everyScreen() {
            let size = Host.size(rig.menu(controller))
            XCTAssertEqual(size.width, 320, name)
            XCTAssertLessThanOrEqual(size.height, 520, name)
        }
    }

    func test_everyLineOfText_inEveryState_isReadableOnTheSurfaceItIsDrawnOn() async {
        for (name, controller) in await everyScreen() {
            for dark in [false, true] {
                guard let image = Host.render(rig.menu(controller), dark: dark, spin: 0.2) else { return XCTFail("\(name) did not render") }
                let seen = Host.read(image)
                XCTAssertFalse(seen.frames.isEmpty, "\(name) (dark: \(dark)) read no text")
                for (text, frame) in seen.frames where text.contains(where: \.isLetter) {
                    guard let ratio = Host.contrast(in: image, frame: frame) else { XCTFail("\(name) (dark: \(dark)): could not measure \"\(text)\""); continue }
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name) (dark: \(dark)): \"\(text)\" reads at \(ratio):1")
                }
            }
        }
    }
}
