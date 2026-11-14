import XCTest
import AVFoundation
@testable import Minutia

/// With no input device the mic permission is never requested (the device check runs first), so the
/// status stays not-determined forever and a past denial is moot: system-only recording still works.
/// The idle banner and the Record preflight must both account for whether a microphone exists.
final class MicPresenceDecisionsTests: XCTestCase {
    private let statuses: [AVAuthorizationStatus] = [.notDetermined, .restricted, .denied, .authorized]

    func test_banner_neverShownWithoutAnInputDevice() {
        for status in statuses {
            XCTAssertFalse(AppController.showsMicPermissionBanner(status: status, hasInputDevice: false), "\(status.rawValue)")
        }
    }

    func test_banner_withAnInputDevice_shownUnlessAuthorized() {
        XCTAssertTrue(AppController.showsMicPermissionBanner(status: .notDetermined, hasInputDevice: true))
        XCTAssertTrue(AppController.showsMicPermissionBanner(status: .restricted, hasInputDevice: true))
        XCTAssertTrue(AppController.showsMicPermissionBanner(status: .denied, hasInputDevice: true))
        XCTAssertFalse(AppController.showsMicPermissionBanner(status: .authorized, hasInputDevice: true))
    }

    func test_preCheck_neverFailsWithoutAnInputDevice() {
        for status in statuses {
            XCTAssertFalse(AppController.micPreCheckFails(status: status, hasInputDevice: false), "\(status.rawValue)")
        }
    }

    func test_preCheck_withAnInputDevice_failsOnlyWhenDeniedOrRestricted() {
        XCTAssertTrue(AppController.micPreCheckFails(status: .denied, hasInputDevice: true))
        XCTAssertTrue(AppController.micPreCheckFails(status: .restricted, hasInputDevice: true))
        XCTAssertFalse(AppController.micPreCheckFails(status: .notDetermined, hasInputDevice: true))
        XCTAssertFalse(AppController.micPreCheckFails(status: .authorized, hasInputDevice: true))
    }

    func test_preflight_deniedWithoutMic_proceedsToSystemOnlyRecording() {
        XCTAssertEqual(AppController.recordPreflight(micStatus: .denied, hasInputDevice: false, hasSeries: true), .proceed)
        XCTAssertEqual(AppController.recordPreflight(micStatus: .restricted, hasInputDevice: false, hasSeries: true), .proceed)
    }

    func test_preflight_deniedWithoutMic_stillGuidesWhenNoSeries() {
        XCTAssertEqual(AppController.recordPreflight(micStatus: .denied, hasInputDevice: false, hasSeries: false), .noSeries)
    }

    func test_preflight_deniedWithMic_isRefused() {
        XCTAssertEqual(AppController.recordPreflight(micStatus: .denied, hasInputDevice: true, hasSeries: true), .micDenied)
        XCTAssertEqual(AppController.recordPreflight(micStatus: .denied, hasInputDevice: true, hasSeries: false), .micDenied)
    }

    func test_preflight_authorizedOrUndecided_proceedsEitherWay() {
        for hasInputDevice in [true, false] {
            XCTAssertEqual(AppController.recordPreflight(micStatus: .authorized, hasInputDevice: hasInputDevice, hasSeries: true), .proceed)
            XCTAssertEqual(AppController.recordPreflight(micStatus: .notDetermined, hasInputDevice: hasInputDevice, hasSeries: true), .proceed)
        }
    }
}
