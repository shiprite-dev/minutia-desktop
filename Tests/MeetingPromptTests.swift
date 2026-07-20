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
}
