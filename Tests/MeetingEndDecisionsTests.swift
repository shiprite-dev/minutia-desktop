import XCTest
@testable import Minutia

/// Pure decisions behind following the meeting's end: the web-app status poll that stops recording
/// when the meeting is completed on the server, and the locally-detected end that offers to wrap up.
/// All folded out of AppController/MeetingPrompt so the full matrix is tested without a live client,
/// capture pipeline, or NSPanel.
final class MeetingEndDecisionsTests: XCTestCase {
    // MARK: - Web-end poll decision

    func test_meetingEndPollDecision_completedStops() {
        XCTAssertEqual(AppController.meetingEndPollDecision(status: "completed"), .stop)
    }

    func test_meetingEndPollDecision_liveUpcomingNilContinue() {
        for status in ["live", "upcoming", "in_progress", "", "COMPLETED"] {
            XCTAssertEqual(
                AppController.meetingEndPollDecision(status: status), .keepPolling,
                "status \(status) must keep polling")
        }
        XCTAssertEqual(AppController.meetingEndPollDecision(status: nil), .keepPolling)
    }

    // MARK: - Web-end poll lifecycle gating

    func test_shouldPollMeetingEnd_trueOnlyWhileRecording() {
        XCTAssertTrue(AppController.shouldPollMeetingEnd(phase: .recording))
    }

    func test_shouldPollMeetingEnd_falseInEveryOtherPhase() {
        let others: [AppPhase] = [
            .signedOut, .idle, .detected(app: "Zoom"), .detected(app: nil), .finalizing, .error("boom"),
        ]
        for phase in others {
            XCTAssertFalse(
                AppController.shouldPollMeetingEnd(phase: phase),
                "must not poll for web-end in \(phase)")
        }
    }

    // MARK: - Suppressed-recap stop path

    func test_opensRecap_manualAndLocalEndedOpen_webEndedSuppressed() {
        XCTAssertTrue(AppController.opensRecap(for: .manual))
        XCTAssertTrue(AppController.opensRecap(for: .localEnded))
        // The user is already on the web app when they end the meeting there; auto-opening a tab is
        // noise, so the web-end stop suppresses the recap.
        XCTAssertFalse(AppController.opensRecap(for: .webEnded))
    }

    // MARK: - Origin capture at start

    func test_detectionOrigin_mapsEveryConfidenceCase() {
        XCTAssertEqual(AppController.detectionOrigin(for: .high(.zoom)), .zoom)
        XCTAssertEqual(AppController.detectionOrigin(for: .high(.teams)), .teams)
        XCTAssertEqual(AppController.detectionOrigin(for: .high(.browser)), .browser)
        // A calendar-only high carries a nil app.
        XCTAssertEqual(AppController.detectionOrigin(for: .high(nil)), .calendar)
        // Mic-only (soft) and no signal start with no attributable origin: menu/deep-link starts.
        XCTAssertEqual(AppController.detectionOrigin(for: .soft), .none)
        XCTAssertEqual(AppController.detectionOrigin(for: .none), .none)
    }

    // MARK: - Which raw signal an origin watches

    private func signals(native: Bool, browser: Bool) -> MeetingDetector.RawSignals {
        MeetingDetector.RawSignals(nativeAppPresent: native, browserInputPresent: browser)
    }

    func test_endSignalAbsent_nativeOriginsWatchNativeSignal() {
        for origin in [AppController.DetectionOrigin.zoom, .teams] {
            XCTAssertTrue(
                AppController.endSignalAbsent(origin: origin, signals: signals(native: false, browser: true)),
                "\(origin) is absent when no native app is present")
            XCTAssertFalse(
                AppController.endSignalAbsent(origin: origin, signals: signals(native: true, browser: false)),
                "\(origin) is present when its native app is present")
        }
    }

    func test_endSignalAbsent_browserOriginWatchesBrowserSignal() {
        XCTAssertTrue(
            AppController.endSignalAbsent(origin: .browser, signals: signals(native: true, browser: false)))
        XCTAssertFalse(
            AppController.endSignalAbsent(origin: .browser, signals: signals(native: false, browser: true)))
    }

    func test_endSignalAbsent_calendarAndNoneNeverAbsent() {
        for origin in [AppController.DetectionOrigin.calendar, .none] {
            XCTAssertFalse(
                AppController.endSignalAbsent(origin: origin, signals: signals(native: false, browser: false)),
                "\(origin) never counts an absence: it never auto-ends")
        }
    }

    // MARK: - End rule matrix

    func test_meetingEndDetected_nativeAndBrowserEndAtTwoConsecutiveAbsent() {
        for origin in [AppController.DetectionOrigin.zoom, .teams, .browser] {
            XCTAssertFalse(AppController.meetingEndDetected(origin: origin, consecutiveAbsent: 0), "\(origin) @0")
            XCTAssertFalse(AppController.meetingEndDetected(origin: origin, consecutiveAbsent: 1), "\(origin) @1")
            XCTAssertTrue(AppController.meetingEndDetected(origin: origin, consecutiveAbsent: 2), "\(origin) @2")
        }
    }

    func test_meetingEndDetected_calendarAndNoneNeverEnd() {
        for origin in [AppController.DetectionOrigin.calendar, .none] {
            for count in 0...5 {
                XCTAssertFalse(
                    AppController.meetingEndDetected(origin: origin, consecutiveAbsent: count),
                    "\(origin) must never auto-end (count \(count))")
            }
        }
    }

    /// A signal that returns before the second absent poll resets the count, so a brief blip never
    /// trips the end prompt. Threads the raw signal through exactly as the controller does.
    func test_endRule_signalRecoveryResetsCount() {
        let origin = AppController.DetectionOrigin.zoom
        // native present, absent, present (recovery), absent, absent -> only the final pair ends.
        let polls = [true, false, true, false, false]
        var count = 0
        var fired: [Bool] = []
        for present in polls {
            let s = signals(native: present, browser: false)
            count = AppController.endSignalAbsent(origin: origin, signals: s) ? count + 1 : 0
            fired.append(AppController.meetingEndDetected(origin: origin, consecutiveAbsent: count))
        }
        XCTAssertEqual(fired, [false, false, false, false, true])
    }

    // MARK: - Recovery cancels a pending wrap-up

    func test_shouldDismissEndPromptOnRecovery_recoveredSignalWithPromptUp_dismisses() {
        XCTAssertTrue(
            AppController.shouldDismissEndPromptOnRecovery(signalAbsent: false, endPromptShowing: true))
    }

    func test_shouldDismissEndPromptOnRecovery_absentSignalKeepsPrompt() {
        XCTAssertFalse(
            AppController.shouldDismissEndPromptOnRecovery(signalAbsent: true, endPromptShowing: true))
    }

    func test_shouldDismissEndPromptOnRecovery_noPromptNothingToDismiss() {
        XCTAssertFalse(
            AppController.shouldDismissEndPromptOnRecovery(signalAbsent: false, endPromptShowing: false))
        XCTAssertFalse(
            AppController.shouldDismissEndPromptOnRecovery(signalAbsent: true, endPromptShowing: false))
    }

    /// The signal drops long enough to arm the wrap-up, then recovers: the pending countdown must be
    /// cancelled (the meeting is live again), and a later real end must still re-prompt. Threads the
    /// signals through the same fold the controller uses.
    func test_endRule_recoveryAfterPromptCancelsThenReArms() {
        let origin = AppController.DetectionOrigin.zoom
        // absent, absent (prompt arms), present (recovery cancels), absent, absent (re-arms).
        let polls = [false, false, true, false, false]
        var count = 0
        var showing = false
        var dismissals = 0
        var arms = 0
        for present in polls {
            let s = signals(native: present, browser: false)
            let absent = AppController.endSignalAbsent(origin: origin, signals: s)
            count = absent ? count + 1 : 0
            if AppController.shouldDismissEndPromptOnRecovery(signalAbsent: absent, endPromptShowing: showing) {
                showing = false
                dismissals += 1
            }
            if AppController.meetingEndDetected(origin: origin, consecutiveAbsent: count), !showing {
                showing = true
                arms += 1
            }
        }
        XCTAssertEqual(dismissals, 1)
        XCTAssertEqual(arms, 2)
        XCTAssertTrue(showing)
    }

    // MARK: - Auto-stop timeout guard

    func test_shouldAutoStopOnEndTimeout_trueWhileRecordingAndEnabled() {
        XCTAssertTrue(AppController.shouldAutoStopOnEndTimeout(phase: .recording, autoEndDisabled: false))
    }

    func test_shouldAutoStopOnEndTimeout_falseWhenKeepRecordingChosen() {
        // "Keep recording" disables auto-end for the rest of the recording, so a late-firing timer is
        // a no-op.
        XCTAssertFalse(AppController.shouldAutoStopOnEndTimeout(phase: .recording, autoEndDisabled: true))
    }

    func test_shouldAutoStopOnEndTimeout_falseOnceRecordingLeft() {
        // A manual stop (or web-end) leaves .recording before the countdown fires; the timer must not
        // trigger a second stop.
        let left: [AppPhase] = [.finalizing, .idle, .error("boom"), .signedOut, .detected(app: nil)]
        for phase in left {
            XCTAssertFalse(
                AppController.shouldAutoStopOnEndTimeout(phase: phase, autoEndDisabled: false),
                "auto-stop must not fire once phase is \(phase)")
        }
    }
}
