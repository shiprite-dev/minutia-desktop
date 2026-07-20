import XCTest
@testable import Minutia

/// Pure decision seams introduced by the UX-polish pass: the retry routing, the login-item state
/// mapping, and the status-item accessibility label. (The rising-edge detection debounce moved to
/// the floating-prompt layer; its gate is covered by MeetingPromptTests.)
final class UXPolishDecisionsTests: XCTestCase {
    // MARK: - Retry routing

    func test_retryTarget_nilFallsBackToSeries() {
        XCTAssertEqual(AppController.retryTarget(lastFailedStart: nil), .series)
    }

    func test_retryTarget_seriesRoutesToSeries() {
        XCTAssertEqual(AppController.retryTarget(lastFailedStart: .series), .series)
    }

    func test_retryTarget_meetingRoutesToThatMeeting() {
        let id = "0f9c2c9a-1a2b-4c3d-8e4f-5a6b7c8d9e0f"
        XCTAssertEqual(AppController.retryTarget(lastFailedStart: .meeting(id)), .meeting(id))
    }

    // MARK: - Login-item state mapping

    func test_loginItemState_enabled() {
        XCTAssertEqual(SettingsView.loginItemState(.enabled), .enabled)
    }

    func test_loginItemState_requiresApprovalIsDistinctFromDisabled() {
        XCTAssertEqual(SettingsView.loginItemState(.requiresApproval), .requiresApproval)
    }

    func test_loginItemState_notRegisteredAndNotFoundAreDisabled() {
        XCTAssertEqual(SettingsView.loginItemState(.notRegistered), .disabled)
        XCTAssertEqual(SettingsView.loginItemState(.notFound), .disabled)
    }

    // MARK: - Login-item error message (C4)

    private struct StubError: LocalizedError {
        var errorDescription: String? { "operation not permitted" }
    }

    func test_loginItemErrorMessage_prefixesAndCarriesDescription() {
        let message = SettingsView.loginItemErrorMessage(for: StubError())
        XCTAssertEqual(message, "Couldn't update Login Item: operation not permitted")
    }

    // MARK: - Status-item accessibility label

    func test_accessibilityLabel_perPhase() {
        XCTAssertEqual(MenuBarIcon.accessibilityLabel(phase: .recording, pendingConsent: false), "Minutia, recording")
        XCTAssertEqual(MenuBarIcon.accessibilityLabel(phase: .finalizing, pendingConsent: false), "Minutia, finishing recording")
        XCTAssertEqual(MenuBarIcon.accessibilityLabel(phase: .detected(app: "Zoom"), pendingConsent: false), "Minutia, meeting detected")
        XCTAssertEqual(MenuBarIcon.accessibilityLabel(phase: .error("boom"), pendingConsent: false), "Minutia, error")
        XCTAssertEqual(MenuBarIcon.accessibilityLabel(phase: .idle, pendingConsent: false), "Minutia, idle")
    }

    /// A cold-launch sign-in failure parks in .signedOut; the status item must say so at a glance.
    func test_accessibilityLabel_signedOutIsDistinct() {
        XCTAssertEqual(MenuBarIcon.accessibilityLabel(phase: .signedOut, pendingConsent: false), "Minutia, signed out")
    }

    /// A pending web-record consent (browser asked to record) is its own announced state in the
    /// phases where it can linger, but never overrides a live recording, finalize, or error.
    func test_accessibilityLabel_pendingConsent() {
        XCTAssertEqual(MenuBarIcon.accessibilityLabel(phase: .idle, pendingConsent: true), "Minutia, record request pending")
        XCTAssertEqual(MenuBarIcon.accessibilityLabel(phase: .detected(app: "Zoom"), pendingConsent: true), "Minutia, record request pending")
        XCTAssertEqual(MenuBarIcon.accessibilityLabel(phase: .error("boom"), pendingConsent: true), "Minutia, error")
    }

    // MARK: - Status-item glyph decision (C1)

    func test_symbolName_recordingAndFinalizing() {
        XCTAssertEqual(MenuBarIcon.symbolName(phase: .recording, softHint: false, pendingConsent: false), "record.circle.fill")
        XCTAssertEqual(MenuBarIcon.symbolName(phase: .finalizing, softHint: false, pendingConsent: false), "record.circle")
    }

    func test_symbolName_error() {
        XCTAssertEqual(MenuBarIcon.symbolName(phase: .error("boom"), softHint: false, pendingConsent: false), "waveform.badge.exclamationmark")
    }

    /// Detected must differ from plain idle so notifications-denied users still get a cue.
    func test_symbolName_detectedIsAttentionGlyph() {
        XCTAssertEqual(MenuBarIcon.symbolName(phase: .detected(app: "Zoom"), softHint: false, pendingConsent: false), "waveform.badge.mic")
        XCTAssertEqual(MenuBarIcon.symbolName(phase: .detected(app: nil), softHint: false, pendingConsent: false), "waveform.badge.mic")
    }

    /// Signed out must read differently from idle so a cold-launch sign-in failure is visible.
    func test_symbolName_signedOut() {
        XCTAssertEqual(MenuBarIcon.symbolName(phase: .signedOut, softHint: false, pendingConsent: false), "waveform.slash")
    }

    func test_symbolName_idleSoftHintAndPlain() {
        XCTAssertEqual(MenuBarIcon.symbolName(phase: .idle, softHint: true, pendingConsent: false), "waveform.badge.mic")
        XCTAssertEqual(MenuBarIcon.symbolName(phase: .idle, softHint: false, pendingConsent: false), "waveform")
    }

    /// A pending consent surfaces its own attention glyph in idle/detected (over the soft hint), but
    /// error and live recording glyphs win over it.
    func test_symbolName_pendingConsentPrecedence() {
        XCTAssertEqual(MenuBarIcon.symbolName(phase: .idle, softHint: false, pendingConsent: true), "questionmark.circle.fill")
        XCTAssertEqual(MenuBarIcon.symbolName(phase: .idle, softHint: true, pendingConsent: true), "questionmark.circle.fill")
        XCTAssertEqual(MenuBarIcon.symbolName(phase: .detected(app: "Zoom"), softHint: false, pendingConsent: true), "questionmark.circle.fill")
        XCTAssertEqual(MenuBarIcon.symbolName(phase: .error("boom"), softHint: false, pendingConsent: true), "waveform.badge.exclamationmark")
        XCTAssertEqual(MenuBarIcon.symbolName(phase: .recording, softHint: false, pendingConsent: true), "record.circle.fill")
    }
}
