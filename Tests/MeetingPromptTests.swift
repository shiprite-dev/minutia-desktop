import XCTest
@testable import Minutia

/// Pure decisions behind the proactive "start taking notes?" floating panel: when it may show,
/// when it auto-expires, its per-app copy, and the once-per-mic-session suppression. The NSPanel
/// shell only renders what these decide.
final class MeetingPromptTests: XCTestCase {
    // MARK: - shouldShow

    func test_shouldShow_risingHighWhileIdle_shows() {
        XCTAssertTrue(
            MeetingPrompt.shouldShow(isHigh: true, phase: .idle, suppressedForSession: false))
    }

    func test_shouldShow_risingHighWhileDetected_shows() {
        // handleDetection applies .meetingDetected first, so the phase is already .detected by the
        // time the panel decision runs; it must still be allowed to show.
        XCTAssertTrue(
            MeetingPrompt.shouldShow(isHigh: true, phase: .detected(app: "Zoom"), suppressedForSession: false))
    }

    func test_shouldShow_notHigh_neverShows() {
        XCTAssertFalse(
            MeetingPrompt.shouldShow(isHigh: false, phase: .idle, suppressedForSession: false))
    }

    func test_shouldShow_suppressedForSession_neverShows() {
        // Covers both "second high edge in the same mic session" and "already dismissed": once a
        // prompt has been shown or dismissed for a session, no re-show until the session resets.
        XCTAssertFalse(
            MeetingPrompt.shouldShow(isHigh: true, phase: .idle, suppressedForSession: true))
    }

    func test_shouldShow_recordingFinalizingSignedOut_neverShow() {
        let blocked: [AppPhase] = [.recording, .finalizing, .signedOut, .error("boom")]
        for phase in blocked {
            XCTAssertFalse(
                MeetingPrompt.shouldShow(isHigh: true, phase: phase, suppressedForSession: false),
                "prompt must not show in \(phase)")
        }
    }

    // MARK: - canPrompt

    func test_canPrompt_trueForRestingSignedInPhases() {
        XCTAssertTrue(MeetingPrompt.canPrompt(phase: .idle))
        XCTAssertTrue(MeetingPrompt.canPrompt(phase: .detected(app: "Teams")))
        XCTAssertTrue(MeetingPrompt.canPrompt(phase: .detected(app: nil)))
    }

    func test_canPrompt_falseWhileCapturingOrSignedOut() {
        // The controller dismisses the panel whenever the phase leaves a promptable state, so an
        // external recording start (menu, deep link), finalize, sign-out, or error all hide it.
        let blocked: [AppPhase] = [.recording, .finalizing, .signedOut, .error("boom")]
        for phase in blocked {
            XCTAssertFalse(MeetingPrompt.canPrompt(phase: phase), "\(phase) must not be promptable")
        }
    }

    // MARK: - copy

    func test_title_namesNativeApps() {
        XCTAssertEqual(MeetingPrompt.title(for: .zoom), "Looks like you're in a Zoom meeting")
        XCTAssertEqual(MeetingPrompt.title(for: .teams), "Looks like you're in a Teams meeting")
    }

    func test_title_browserAndCalendarStayGeneric() {
        XCTAssertEqual(MeetingPrompt.title(for: .browser), "Looks like you're in a meeting")
        XCTAssertEqual(MeetingPrompt.title(for: nil), "Looks like you're in a meeting")
    }

    func test_content_carriesTitleAndGlyph() {
        let content = MeetingPrompt.content(for: .zoom)
        XCTAssertEqual(content.title, "Looks like you're in a Zoom meeting")
        XCTAssertFalse(content.symbol.isEmpty)
    }

    func test_startContent_carriesStartVariantButtons() {
        let content = MeetingPrompt.content(for: .zoom)
        XCTAssertEqual(content.primaryTitle, "Start taking notes")
        // The start variant renders the compact xmark dismiss, not a labeled secondary button.
        XCTAssertNil(content.secondaryTitle)
    }

    // MARK: - End variant

    func test_endContent_carriesEndVariantCopy() {
        let content = MeetingPrompt.endContent()
        XCTAssertEqual(content.title, "Meeting ended?")
        XCTAssertEqual(content.primaryTitle, "Wrap up my notes")
        XCTAssertEqual(content.secondaryTitle, "Keep recording")
        XCTAssertFalse(content.symbol.isEmpty)
    }

    // MARK: - canPromptEnd

    func test_canPromptEnd_trueOnlyWhileRecording() {
        XCTAssertTrue(MeetingPrompt.canPromptEnd(phase: .recording))
    }

    func test_canPromptEnd_falseInEveryOtherPhase() {
        // A web-end or manual stop leaves .recording (to .finalizing), so any pending end prompt is
        // dismissed by the same phase gate; the end prompt never shows outside a live recording.
        let others: [AppPhase] = [
            .signedOut, .idle, .detected(app: "Zoom"), .detected(app: nil), .finalizing, .error("boom"),
        ]
        for phase in others {
            XCTAssertFalse(MeetingPrompt.canPromptEnd(phase: phase), "\(phase) must not host the end prompt")
        }
    }

    // MARK: - shouldShowEnd

    func test_shouldShowEnd_whileRecordingNotDisabledNotShowing_shows() {
        XCTAssertTrue(
            MeetingPrompt.shouldShowEnd(phase: .recording, autoEndDisabled: false, alreadyShowing: false))
    }

    func test_shouldShowEnd_keepRecordingDisablesFurtherAutoEnd() {
        XCTAssertFalse(
            MeetingPrompt.shouldShowEnd(phase: .recording, autoEndDisabled: true, alreadyShowing: false))
    }

    func test_shouldShowEnd_notReShownWhileAlreadyShowing() {
        XCTAssertFalse(
            MeetingPrompt.shouldShowEnd(phase: .recording, autoEndDisabled: false, alreadyShowing: true))
    }

    func test_shouldShowEnd_neverOutsideRecording() {
        let others: [AppPhase] = [.idle, .detected(app: nil), .finalizing, .error("boom"), .signedOut]
        for phase in others {
            XCTAssertFalse(
                MeetingPrompt.shouldShowEnd(phase: phase, autoEndDisabled: false, alreadyShowing: false),
                "end prompt must not show in \(phase)")
        }
    }
}
