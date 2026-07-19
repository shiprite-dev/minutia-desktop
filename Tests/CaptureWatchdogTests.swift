import XCTest
@testable import Minutia

final class CaptureWatchdogTests: XCTestCase {
    func test_belowThreshold_doesNotFire() {
        XCTAssertFalse(CaptureSession.shouldWatchdogFire(secondsSinceFrames: 0, threshold: 15))
        XCTAssertFalse(CaptureSession.shouldWatchdogFire(secondsSinceFrames: 14.9, threshold: 15))
    }

    func test_atOrAboveThreshold_fires() {
        XCTAssertTrue(CaptureSession.shouldWatchdogFire(secondsSinceFrames: 15, threshold: 15))
        XCTAssertTrue(CaptureSession.shouldWatchdogFire(secondsSinceFrames: 60, threshold: 15))
    }

    func test_usesConfiguredTimeout() {
        XCTAssertGreaterThan(CaptureSession.watchdogTimeout, 0)
        XCTAssertFalse(
            CaptureSession.shouldWatchdogFire(
                secondsSinceFrames: CaptureSession.watchdogTimeout - 0.01,
                threshold: CaptureSession.watchdogTimeout))
        XCTAssertTrue(
            CaptureSession.shouldWatchdogFire(
                secondsSinceFrames: CaptureSession.watchdogTimeout,
                threshold: CaptureSession.watchdogTimeout))
    }
}
