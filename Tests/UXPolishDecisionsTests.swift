import XCTest
@testable import Minutia

/// Pure decision seams introduced by the UX-polish pass: the detection notify gate, the retry
/// routing, the login-item state mapping, and the status-item accessibility label.
final class UXPolishDecisionsTests: XCTestCase {
    // MARK: - Detection notify gate

    func test_shouldNotify_firesOnlyOnRisingEdgeIntoHigh() {
        XCTAssertTrue(MeetingDetector.shouldNotify(isHigh: true, alreadyNotified: false))
    }

    func test_shouldNotify_suppressedWhenAlreadyNotified() {
        // The core debounce: a transient dip (high -> soft -> high) within one mic session keeps
        // notifiedHigh set, so re-entering high must not re-post for the same ongoing meeting.
        XCTAssertFalse(MeetingDetector.shouldNotify(isHigh: true, alreadyNotified: true))
    }

    func test_shouldNotify_neverFiresWhenNotHigh() {
        XCTAssertFalse(MeetingDetector.shouldNotify(isHigh: false, alreadyNotified: false))
        XCTAssertFalse(MeetingDetector.shouldNotify(isHigh: false, alreadyNotified: true))
    }

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

    // MARK: - Status-item accessibility label

    func test_accessibilityLabel_perPhase() {
        XCTAssertEqual(MenuBarIcon.accessibilityLabel(phase: .recording), "Minutia, recording")
        XCTAssertEqual(MenuBarIcon.accessibilityLabel(phase: .finalizing), "Minutia, finishing recording")
        XCTAssertEqual(MenuBarIcon.accessibilityLabel(phase: .detected(app: "Zoom")), "Minutia, meeting detected")
        XCTAssertEqual(MenuBarIcon.accessibilityLabel(phase: .error("boom")), "Minutia, error")
        XCTAssertEqual(MenuBarIcon.accessibilityLabel(phase: .idle), "Minutia, idle")
        XCTAssertEqual(MenuBarIcon.accessibilityLabel(phase: .signedOut), "Minutia, idle")
    }
}
