import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Minutia

private let longName = String(repeating: "Quarterly platform reliability and security review ", count: 3).prefix(120).description
private let sampleSeries = [Series(id: UUID(), name: "Weekly Eng Sync"), Series(id: UUID(), name: longName)]

@MainActor
final class MenuLayoutTests: XCTestCase {
    private func assertFits<V: View>(_ name: String, _ view: V, file: StaticString = #filePath, line: UInt = #line) {
        for dark in [false, true] {
            let size = Host.size(view, dark: dark)
            XCTAssertEqual(size.width, 320, "\(name) width (dark: \(dark))", file: file, line: line)
            XCTAssertLessThanOrEqual(size.height, 520, "\(name) height (dark: \(dark))", file: file, line: line)
            XCTAssertGreaterThan(size.height, 40, "\(name) renders", file: file, line: line)
        }
    }

    private var idleModel: IdleModel {
        IdleModel(series: sampleSeries, selected: sampleSeries[0].id, detectedVia: nil, softHint: false,
                  micBanner: false, recovering: false, instance: URL(string: "https://example.com")!)
    }

    func test_everyScreen_isPanelWidthAndFitsInTheBudget() {
        assertFits("idle", IdleScreen(model: idleModel))
        assertFits("detected", IdleScreen(model: { var m = idleModel; m.detectedVia = "Zoom"; return m }()))
        assertFits("everything at once", IdleScreen(model: { var m = idleModel; m.detectedVia = "Zoom"; m.micBanner = true; m.recovering = true; return m }()))
        assertFits("zero series", IdleScreen(model: { var m = idleModel; m.series = []; m.selected = nil; return m }()))
        assertFits("recording", RecordingContent(model: RecordingModel(seriesName: "Weekly Eng Sync", elapsed: 754, level: 0.5, progress: "2 of 3 segments uploaded")))
        assertFits("finishing", FinishingContent(label: "Uploading and requesting transcript", progress: nil, preparingSince: nil))
        assertFits("transcribing", FinishingContent(label: "Transcribing on this Mac, 3 of 12", progress: 0.25, preparingSince: nil))
        assertFits("consent", ConsentNotice(hasClaim: false))
        assertFits("consent with claim", ConsentNotice(hasClaim: true))
        assertFits("feedback", FeedbackNotice(message: "That recording could not be started. Try again in a moment."))

        assertFits("error", ErrorScreen(message: "Upload failed after several attempts. Your recording is saved on this Mac.", isMicError: false))
        assertFits("mic error", ErrorScreen(message: "Microphone access was denied.", isMicError: true))
        for stage in [SignInStage.connecting, .ready, .browserPending, .failed(message: "Can't reach app.getminutia.com. Check your connection.", retryable: true)] {
            assertFits("sign-in \(stage)", SignInScreen(stage: stage, showsMenuBarHint: true, signInError: nil, email: .constant(""), password: .constant(""), showEmailForm: .constant(true), busy: false))
        }
    }

    func test_veryLongSeriesName_clampsToTwoLinesWithoutGrowingThePanel() {
        let short = Host.size(RecordingContent(model: RecordingModel(seriesName: "Weekly Eng Sync", elapsed: 7457, level: 1, progress: "x")))
        let long = Host.size(RecordingContent(model: RecordingModel(seriesName: longName, elapsed: 7457, level: 1, progress: "x")))
        XCTAssertLessThan(long.height - short.height, 30)
        let huge = Host.size(RecordingContent(model: RecordingModel(seriesName: String(repeating: "W", count: 400), elapsed: 7457, level: 1, progress: "x")))
        XCTAssertEqual(huge.height, long.height, accuracy: 1)
    }

    func test_longSeriesName_inIdleSelectorDoesNotWidenThePanel() {
        var model = idleModel
        model.selected = sampleSeries[1].id
        XCTAssertEqual(Host.size(IdleScreen(model: model)).width, 320)
    }

    func test_footer_isPanelWidthWithOrWithoutTheUpdateChip() {
        for update in [false, true] { XCTAssertEqual(Host.size(FooterBar(updateAvailable: update)).width, 320) }
    }

    func test_consentAboveIdle_staysPanelWidthAndInBudget() {
        let stack = VStack(spacing: 0) { ConsentNotice(hasClaim: true); IdleScreen(model: idleModel) }.environment(\.consentPending, true)
        let size = Host.size(stack)
        XCTAssertEqual(size.width, 320)
        XCTAssertLessThanOrEqual(size.height, 520)
    }

    func test_largestTextSize_stillFits() {
        let view = RecordingContent(model: RecordingModel(seriesName: longName, elapsed: 7457, level: 1, progress: "2 of 3 segments uploaded", reconnecting: true, systemAudioDegraded: true, micUnavailable: true))
            .dynamicTypeSize(.accessibility5)
        let size = Host.size(view)
        XCTAssertEqual(size.width, 320)
        XCTAssertLessThanOrEqual(size.height, 520)
    }

    func test_recordingWithEveryNotice_fitsTheBudget() {
        let model = RecordingModel(seriesName: longName, elapsed: 7457, level: 0.2, progress: "2 of 3 segments uploaded", reconnecting: true, systemAudioDegraded: true, micUnavailable: true)
        XCTAssertLessThanOrEqual(Host.size(RecordingContent(model: model)).height, 520)
    }
}

final class SeenMatcherTests: XCTestCase {
    private func seen(_ text: String) -> Seen { Seen(text: text, frames: []) }

    func test_rejectsTextThatSaysTheOpposite() {
        XCTAssertFalse(seen("Your recording is NOT saved on this Mac").has("Your recording is saved on this Mac"))
        XCTAssertFalse(seen("Your recording is no longer saved on this Mac").has("Your recording is saved on this Mac"))
    }

    func test_rejectsAnyWrongDigit() {
        XCTAssertFalse(seen("Transcribing on this Mac, 2 of 5").has("Transcribing on this Mac, 2 of 3"))
        XCTAssertFalse(seen("Downloading model 12%").has("Downloading model 42%"))
        XCTAssertFalse(seen("Downloading model 4%").has("Downloading model 42%"))
    }

    func test_rejectsANegatedOrExtendedVersionOfTheSentence() {
        XCTAssertFalse(seen("Not sent. Your recap is on its way").has("Sent. Your recap is on its way"))
        XCTAssertFalse(seen("Unsent. Your recap is on its way").has("Sent. Your recap is on its way"))
        XCTAssertFalse(seen("Couldn't send. Never sent. Your recap is on its way").has("Sent. Your recap is on its way"))
        XCTAssertFalse(seen("Downloading model 42%").has("Downloading model 4"))
        XCTAssertFalse(seen("Transcribing on this Mac, 3 of 120").has("Transcribing on this Mac, 3 of 12"))
        XCTAssertFalse(seen("Recording").has("Record"))
        XCTAssertFalse(seen("Retrying").has("Retry"))
        XCTAssertTrue(seen("Sent. Your recap is on its way").has("Sent. Your recap is on its way"))
        XCTAssertTrue(seen("Retry Dismiss").has("Retry"))
    }

    func test_rejectsAConfusionThatIsNotADocumentedGlyphPair() {
        XCTAssertFalse(seen("Recora a meeting").has("Record a meeting"))
        XCTAssertFalse(seen("Sign in with browser").has("Sign in with brower"))
        XCTAssertFalse(seen("Retry").has("Retrv"))
    }

    func test_acceptsTheSameTextAndKnownOcrConfusions() {
        XCTAssertTrue(seen("Your recording is saved on this Mac. Retry Dismiss").has("Your recording is saved on this Mac"))
        XCTAssertTrue(seen("Your recording is saved on this \u{041C}\u{0430}\u{0441}").has("Your recording is saved on this Mac"))
        XCTAssertTrue(seen("Weekly Eng Sync Ill").has("Weekly Eng Sync Ill"))
        XCTAssertTrue(seen("QuarterIy platforrn review").has("Quarterly platform review"))
        XCTAssertTrue(seen("Downloading model 42%").has("Downloading model 42%"))
    }
}

@MainActor
final class MenuStatesSeenTests: XCTestCase {
    private func model(series: [Series] = sampleSeries, selected: UUID? = sampleSeries[0].id, detectedVia: String? = nil) -> IdleModel {
        IdleModel(series: series, selected: selected, detectedVia: detectedVia, softHint: false, micBanner: false,
                  recovering: false, instance: URL(string: "https://example.com")!)
    }

    private var idleModel: IdleModel { model() }

    func test_recording_namesTheSeriesTheClockAndStop() {
        let seen = Host.text(RecordingContent(model: RecordingModel(seriesName: "Weekly Eng Sync", elapsed: 7457, level: 0.4, progress: "2 of 3 segments uploaded")))
        XCTAssertTrue(seen.has("Weekly Eng Sync"), seen.text)
        XCTAssertTrue(seen.has("2:04:17"), seen.text)
        XCTAssertTrue(seen.has("Stop"), seen.text)
        XCTAssertTrue(seen.has("2 of 3 segments uploaded"), seen.text)
        XCTAssertTrue(seen.has("RECORDING"), seen.text)
    }

    func test_recording_longNameIsTruncatedNotWrappedPastTwoLines() {
        let seen = Host.text(RecordingContent(model: RecordingModel(seriesName: longName, elapsed: 5, level: 0, progress: "x")))
        XCTAssertTrue(seen.has("Quarterly platform"), seen.text)
        XCTAssertFalse(seen.has("security review Quarterly platform reliability and security review Quarterly platform reliability and security review"), seen.text)
    }

    func test_recording_surfacesDegradedAudioAndReconnecting() {
        let seen = Host.text(RecordingContent(model: RecordingModel(seriesName: "S", elapsed: 5, level: 0, progress: "x", reconnecting: true, systemAudioDegraded: true)))
        XCTAssertTrue(seen.has("Reconnecting"), seen.text)
        XCTAssertTrue(seen.has("System audio isn't being captured. Recording your microphone only."), seen.text)
    }

    func test_twoHourRecording_withALongName_stillShowsMostOfTheName() {
        let seen = Host.text(RecordingContent(model: RecordingModel(seriesName: longName, elapsed: 7457, level: 0, progress: "x")))
        XCTAssertTrue(seen.has("Quarterly platform reliability and security review"), seen.text)
        XCTAssertTrue(seen.has("2:04:17"), seen.text)
    }

    func test_notes_alignsWithTheRestOfTheColumn() throws {
        let seen = Host.text(RecordingContent(model: RecordingModel(seriesName: "Weekly Eng Sync", elapsed: 5, level: 0, progress: "x")))
        let notes = try XCTUnwrap(seen.frame(of: "Notes"))
        XCTAssertLessThan(notes.minX, 0.2)
    }

    func test_updateChip_sitsInTheMiddleOfThePanel() throws {
        let chip = try XCTUnwrap(Host.text(FooterBar(updateAvailable: true)).frame(of: "Update available"))
        XCTAssertEqual(chip.midX, 0.5, accuracy: 0.02)
    }

    func test_emailSignIn_opensFromAQuietButtonAndShowsTheFields() {
        let closed = Host.text(SignInScreen(stage: .ready, showsMenuBarHint: false, signInError: nil, email: .constant(""), password: .constant(""), showEmailForm: .constant(false), busy: false))
        let open = Host.text(SignInScreen(stage: .ready, showsMenuBarHint: false, signInError: nil, email: .constant(""), password: .constant(""), showEmailForm: .constant(true), busy: false))
        XCTAssertFalse(closed.has("Sign in with Google"), closed.text)
        XCTAssertTrue(open.has("Sign in with Google"), open.text)
        XCTAssertTrue(open.has("Use email instead"), open.text)
    }

    func test_secondaryButton_keepsItsLabelAwayFromItsBorder() {
        let label = Text("Open System Settings").font(Typo.body)
        let bare = Host.size(label).width
        let button = Host.size(Button(action: {}) { label }.buttonStyle(SecondaryButtonStyle()).fixedSize()).width
        XCTAssertGreaterThanOrEqual(button - bare, 24)
    }

    func test_meetingPromptCapsule_isReadableInLightAndDark() {
        let content = MeetingPromptContent(title: "Meeting detected", symbol: "waveform", primaryTitle: "Start taking notes", secondaryTitle: nil)
        for dark in [false, true] {
            let seen = Host.text(MeetingPromptView(content: content, onStart: {}, onDismiss: {}).padding(24), dark: dark)
            XCTAssertTrue(seen.has("Meeting detected"), "dark: \(dark) \(seen.text)")
            XCTAssertTrue(seen.has("Start taking notes"), "dark: \(dark) \(seen.text)")
        }
    }




    private func signIn(_ stage: SignInStage, hint: Bool = false, error: String? = nil) -> Seen {
        Host.text(SignInScreen(stage: stage, showsMenuBarHint: hint, signInError: error, email: .constant(""), password: .constant(""), showEmailForm: .constant(false), busy: false), scale: 4)
    }

    func test_signedOut_invitesBrowserSignInAndKeepsEmailQuiet() {
        let seen = signIn(.ready)
        XCTAssertTrue(seen.has("Sign in with browser"), seen.text)
        XCTAssertTrue(seen.has("Use email instead"), seen.text)
        XCTAssertTrue(seen.has("Record a meeting. Get the issues log."), seen.text)
    }

    func test_signedOut_firstRunShowsTheMenuBarHint() {
        XCTAssertTrue(signIn(.ready, hint: true).has(FirstRun.menuBarHint))
        XCTAssertFalse(signIn(.ready, hint: false).has(FirstRun.menuBarHint))
    }

    func test_connecting_canBeCancelled() {
        let seen = signIn(.connecting)
        XCTAssertTrue(seen.has("Connecting to Minutia"), seen.text)
        XCTAssertTrue(seen.has("Cancel"), seen.text)
    }

    func test_offline_showsMessageRetryAndSelfHostLink() {
        let seen = signIn(.failed(message: "Can't reach the server.", retryable: true))
        XCTAssertTrue(seen.has("Can't reach the server."), seen.text)
        XCTAssertTrue(seen.has("Try again"), seen.text)
        XCTAssertTrue(seen.has("Using a self-hosted server?"), seen.text)
    }

    func test_notAMinutiaServer_hasNoRetry() {
        let seen = signIn(.failed(message: "Not a Minutia server.", retryable: false))
        XCTAssertFalse(seen.has("Try again"), seen.text)
        XCTAssertTrue(seen.has("Using a self-hosted server?"), seen.text)
    }

    func test_signInFailure_isShownAboveTheButton() {
        XCTAssertTrue(signIn(.ready, error: "Invalid login").has("Invalid login"))
    }

    func test_footer_showsUpdateChipOnlyWhenAvailable() {
        XCTAssertTrue(Host.text(FooterBar(updateAvailable: true)).has("Update available"))
        XCTAssertFalse(Host.text(FooterBar(updateAvailable: false)).has("Update available"))
        XCTAssertTrue(Host.text(FooterBar(updateAvailable: false)).has("Quit"))
    }

    func test_modelDownload_showsTheExistingLabel() {
        XCTAssertTrue(Host.text(ModelDownloadRow(label: "Downloading model 42%", fraction: 0.42)).has("Downloading model 42%"))
    }
}
