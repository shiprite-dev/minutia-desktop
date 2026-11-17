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
            guard let image = Host.render(view, dark: dark, spin: 0.2) else { return XCTFail("\(name) did not render", file: file, line: line) }
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

    func test_theSentScreen_staysUpForAReadableBeatAfterTheCheckFinishesDrawing() {
        let controller = rig.signedIn()
        let drawing = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18 + 0.42 + 0.24
        XCTAssertGreaterThanOrEqual(controller.recapHold(), drawing + 1.5)
    }

    func test_theSentCheck_finishesDrawingWithinTheHold_andReduceMotionShowsItAtOnce() {
        let drawn = Host.render(DoneContent().environment(\.reduceMotionOverride, true), spin: 0.05).map { Host.vermilionRuns($0).pixels } ?? 0
        XCTAssertGreaterThan(drawn, 50)
        let animated = Host.vermilionPixels(DoneContent().environment(\.reduceMotionOverride, false), spin: 1.4)
        XCTAssertGreaterThanOrEqual(animated, drawn * 9 / 10)
    }

    func test_waitingOnTheBrowser_tellsTheUserWhere_andStartOverBringsSignInBack() async {
        let controller = await adopted()
        _ = controller.authManager.beginBrowserSignIn(device: "Test Mac")
        let waiting = rig.panel(controller)
        XCTAssertTrue(waiting.has("Check your browser to finish signing in."), waiting.text)
        XCTAssertTrue(waiting.has("Start over"), waiting.text)
        XCTAssertFalse(waiting.has("Sign in with browser"), waiting.text)
        controller.authManager.cancelBrowserSignIn()
        let again = rig.panel(controller)
        XCTAssertTrue(again.has("Sign in with browser"), again.text)
        XCTAssertFalse(again.has("Check your browser"), again.text)
    }

    func test_louderAudio_drawsTallerMeterBars() {
        func barRows(_ level: Float) -> Int {
            guard let image = Host.render(LevelBars(levels: [level, level, level]), spin: 0.2) else { return 0 }
            let (width, height, data) = Host.pixels(image)
            return (0..<height).filter { row in
                (0..<width).contains { column in
                    let i = (row * width + column) * 4
                    return abs(Int(data[i]) - 0xE2) < 14 && abs(Int(data[i + 1]) - 0x3A) < 14 && Int(data[i + 2]) < 20
                }
            }.count
        }
        let silent = barRows(0), quiet = barRows(0.3), loud = barRows(1)
        XCTAssertGreaterThan(silent, 0)
        XCTAssertLessThan(silent, quiet)
        XCTAssertLessThan(quiet, loud)
    }

    func test_theMenuBarIcon_looksDifferentInEveryStateThatNeedsAttention() {
        func icon(_ phase: AppPhase, soft: Bool = false, consent: Bool = false) -> CGImage {
            Host.render(MenuBarIcon(phase: phase, softHint: soft, pendingConsent: consent).font(.system(size: 40)), spin: 0.15)!
        }
        let idle = icon(.idle)
        let states: [(String, CGImage)] = [
            ("recording", icon(.recording)), ("finishing", icon(.finalizing)), ("error", icon(.error("x"))),
            ("detected", icon(.detected(app: "Zoom"))), ("signed out", icon(.signedOut)), ("record request pending", icon(.idle, consent: true)),
        ]
        for (name, image) in states { XCTAssertGreaterThan(Host.differingBytes(idle, image), 0, "\(name) looks like idle") }
        for (i, a) in states.enumerated() {
            for b in states[(i + 1)...] where !(a.0 == "detected" && b.0 == "x") {
                XCTAssertGreaterThan(Host.differingBytes(a.1, b.1), 0, "\(a.0) looks like \(b.0)")
            }
        }
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

    private func requireAnimatingHost() throws {
        let panel = LivePanel(rig.menu(finishingController()))
        try XCTSkipUnless(panel.changedBytesBetweenFrames().contains { $0 > 0 }, "this host draws no animation frames (headless runner)")
    }

    func test_animationsRunWhileThePanelIsOpen_andStopOnceItIsClosed() throws {
        try requireAnimatingHost()
        for (name, controller) in [("finishing", finishingController()), ("recording", recordingController())] {
            let panel = LivePanel(rig.menu(controller))
            let whileOpen = panel.changedBytesBetweenFrames()
            XCTAssertTrue(whileOpen.contains { $0 > 0 }, "\(name) should be animating while open: \(whileOpen)")
            controller.panelClosed()
            panel.spin(0.5)
            let afterClose = panel.changedBytesBetweenFrames()
            XCTAssertEqual(afterClose, [Int](repeating: 0, count: afterClose.count), "\(name) kept animating after the panel closed")
            controller.panelOpened()
            panel.spin(0.5)
            XCTAssertTrue(panel.changedBytesBetweenFrames().contains { $0 > 0 }, "\(name) did not resume when the panel reopened")
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

    func test_withReduceMotionOn_theOpenPanelStaysStill() throws {
        try requireAnimatingHost()
        for (name, controller) in [("finishing", finishingController()), ("recording", recordingController())] {
            let panel = LivePanel(rig.menu(controller).environment(\.reduceMotionOverride, true))
            let frames = panel.changedBytesBetweenFrames()
            XCTAssertEqual(frames, [Int](repeating: 0, count: frames.count), "\(name) moved under Reduce Motion")
        }
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
                    guard let ratio = Host.contrast(in: image, frame: frame) else { continue }
                    XCTAssertGreaterThanOrEqual(ratio, 4.4, "\(name) (dark: \(dark)): \"\(text)\" reads at \(ratio):1")
                }
            }
        }
    }
}
