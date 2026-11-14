import XCTest
@testable import Minutia

/// A Bluetooth headset switching modes fires a burst of output-device notifications (seven rate
/// changes inside 200 ms were measured). Each rebuild drops audio and can make the device notify
/// again, so a burst must become one rebuild, and a rate notification that leaves the device at the
/// rate the tap already runs at must not rebuild at all.
final class SystemAudioRebuildPolicyTests: XCTestCase {
    // MARK: - Debounce

    func test_noEvents_nothingDue() {
        var debounce = DeviceChangeDebounce()
        XCTAssertNil(debounce.takeDue(at: 100))
    }

    func test_singleEvent_dueOnlyAfterQuietInterval() {
        var debounce = DeviceChangeDebounce()
        let deadline = debounce.record(.rate, at: 10)
        XCTAssertEqual(deadline, 10 + DeviceChangeDebounce.quietInterval, accuracy: 1e-9)
        XCTAssertNil(debounce.takeDue(at: 10 + DeviceChangeDebounce.quietInterval - 0.01))
        XCTAssertEqual(debounce.takeDue(at: 10 + DeviceChangeDebounce.quietInterval), .rate)
    }

    func test_sevenEventsIn200ms_coalesceIntoOneRebuild() {
        var debounce = DeviceChangeDebounce()
        var deadline: TimeInterval = 0
        for i in 0..<7 { deadline = debounce.record(.rate, at: 10 + Double(i) * 0.033) }
        XCTAssertNil(debounce.takeDue(at: 10.2))
        XCTAssertEqual(debounce.takeDue(at: deadline), .rate)
        XCTAssertNil(debounce.takeDue(at: deadline + 10), "one burst yields exactly one rebuild")
    }

    func test_eachEvent_pushesTheDeadlineOut() {
        var debounce = DeviceChangeDebounce()
        let first = debounce.record(.rate, at: 10)
        let second = debounce.record(.rate, at: 10.3)
        XCTAssertGreaterThan(second, first)
        XCTAssertNil(debounce.takeDue(at: first))
    }

    func test_continuousEvents_cannotStarveTheRebuildPastMaxWait() {
        var debounce = DeviceChangeDebounce()
        let start: TimeInterval = 10
        let step = DeviceChangeDebounce.quietInterval / 2
        var t = start
        while t < start + DeviceChangeDebounce.maxWait {
            let deadline = debounce.record(.rate, at: t)
            XCTAssertLessThanOrEqual(deadline, start + DeviceChangeDebounce.maxWait + 1e-9)
            t += step
        }
        XCTAssertEqual(debounce.takeDue(at: start + DeviceChangeDebounce.maxWait), .rate)
    }

    func test_deviceEventInBurst_winsOverRateEvents() {
        var debounce = DeviceChangeDebounce()
        _ = debounce.record(.rate, at: 10)
        _ = debounce.record(.device, at: 10.05)
        let deadline = debounce.record(.rate, at: 10.1)
        XCTAssertEqual(debounce.takeDue(at: deadline), .device)
    }

    func test_reset_dropsAPendingBurst() {
        var debounce = DeviceChangeDebounce()
        let deadline = debounce.record(.device, at: 10)
        debounce.reset()
        XCTAssertNil(debounce.takeDue(at: deadline + 1))
    }

    func test_newBurstAfterFiring_startsFresh() {
        var debounce = DeviceChangeDebounce()
        let first = debounce.record(.device, at: 10)
        XCTAssertEqual(debounce.takeDue(at: first), .device)
        let second = debounce.record(.rate, at: 20)
        XCTAssertEqual(second, 20 + DeviceChangeDebounce.quietInterval, accuracy: 1e-9)
        XCTAssertEqual(debounce.takeDue(at: second), .rate)
    }

    // MARK: - Rate check

    func test_shouldRebuild_falseWhenDeviceRateEqualsConfiguredRate() {
        XCTAssertFalse(SystemAudioTap.shouldRebuild(configuredRate: 48_000, deviceRate: 48_000))
        XCTAssertFalse(SystemAudioTap.shouldRebuild(configuredRate: 16_000, deviceRate: 16_000))
    }

    func test_shouldRebuild_trueWhenDeviceRateDiffers() {
        XCTAssertTrue(SystemAudioTap.shouldRebuild(configuredRate: 48_000, deviceRate: 16_000))
        XCTAssertTrue(SystemAudioTap.shouldRebuild(configuredRate: 24_000, deviceRate: 48_000))
    }

    func test_shouldRebuild_trueWhenEitherRateIsUnknown() {
        XCTAssertTrue(SystemAudioTap.shouldRebuild(configuredRate: nil, deviceRate: 48_000))
        XCTAssertTrue(SystemAudioTap.shouldRebuild(configuredRate: 48_000, deviceRate: nil))
        XCTAssertTrue(SystemAudioTap.shouldRebuild(configuredRate: 48_000, deviceRate: 0))
    }

    // MARK: - Retry and recovery

    func test_retry_fastBackoffsThenSlowRetryForever() {
        var policy = RebuildRetryPolicy()
        let delays = (0..<6).map { _ in policy.attemptFailed().delay }
        XCTAssertEqual(delays, [0.3, 0.6, 1.2, RebuildRetryPolicy.slowRetry, RebuildRetryPolicy.slowRetry, RebuildRetryPolicy.slowRetry])
    }

    func test_retry_reportsFailureExactlyOnceWhenFastBudgetIsSpent() {
        var policy = RebuildRetryPolicy()
        let reports = (0..<7).map { _ in policy.attemptFailed().reportFailure }
        XCTAssertEqual(reports, [false, false, false, true, false, false, false])
    }

    func test_success_afterReportedFailure_signalsRecovery() {
        var policy = RebuildRetryPolicy()
        for _ in 0..<5 { _ = policy.attemptFailed() }
        XCTAssertTrue(policy.attemptSucceeded())
    }

    func test_success_withoutReportedFailure_signalsNothing() {
        var policy = RebuildRetryPolicy()
        _ = policy.attemptFailed()
        _ = policy.attemptFailed()
        XCTAssertFalse(policy.attemptSucceeded())
    }

    func test_success_resetsTheBudget() {
        var policy = RebuildRetryPolicy()
        for _ in 0..<4 { _ = policy.attemptFailed() }
        _ = policy.attemptSucceeded()
        XCTAssertEqual(policy.attemptFailed(), RebuildRetryPolicy.Step(delay: 0.3, reportFailure: false))
        XCTAssertFalse(policy.attemptSucceeded(), "recovery is signalled once per reported failure")
    }

    func test_reset_forgetsAReportedFailure() {
        var policy = RebuildRetryPolicy()
        for _ in 0..<4 { _ = policy.attemptFailed() }
        policy.reset()
        XCTAssertFalse(policy.attemptSucceeded())
    }
}
