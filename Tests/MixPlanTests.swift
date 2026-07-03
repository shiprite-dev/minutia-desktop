import XCTest
@testable import Minutia

final class MixPlanTests: XCTestCase {
    func test_plan_bothFull_returnsTickFrames() {
        let tick = MixPlan.plan(micAvailable: 20_000, sysAvailable: 20_000)
        XCTAssertEqual(tick.micFrames, MixPlan.tickFrames)
        XCTAssertEqual(tick.sysFrames, MixPlan.tickFrames)
    }

    func test_plan_oneStarved_returnsShortMicFrames() {
        let tick = MixPlan.plan(micAvailable: 3_000, sysAvailable: 20_000)
        XCTAssertEqual(tick.micFrames, 3_000)
        XCTAssertEqual(tick.sysFrames, MixPlan.tickFrames)
    }

    func test_plan_bothEmpty_returnsZero() {
        let tick = MixPlan.plan(micAvailable: 0, sysAvailable: 0)
        XCTAssertEqual(tick.micFrames, 0)
        XCTAssertEqual(tick.sysFrames, 0)
    }

    func test_mix_sums() {
        let out = MixPlan.mix(mic: [0.5, 0.5], sys: [0.5, 0.5], count: 2)
        XCTAssertEqual(out, [1.0, 1.0])
    }

    func test_mix_clampsPositive() {
        let out = MixPlan.mix(mic: [0.8], sys: [0.8], count: 1)
        XCTAssertEqual(out, [1.0])
    }

    func test_mix_clampsNegative() {
        let out = MixPlan.mix(mic: [-0.9], sys: [-0.9], count: 1)
        XCTAssertEqual(out, [-1.0])
    }

    func test_mix_mismatchedLength_usesCountWithImplicitZeros() {
        // sys is shorter than count: missing samples read as zero.
        let out = MixPlan.mix(mic: [0.3, 0.3, 0.3], sys: [0.4], count: 3)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0], 0.7, accuracy: 1e-6)
        XCTAssertEqual(out[1], 0.3, accuracy: 1e-6)
        XCTAssertEqual(out[2], 0.3, accuracy: 1e-6)
    }

    func test_mix_countBeyondBoth_padsBothWithZeros() {
        let out = MixPlan.mix(mic: [0.2], sys: [0.1], count: 3)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0], 0.3, accuracy: 1e-6)
        XCTAssertEqual(out[1], 0.0, accuracy: 1e-6)
        XCTAssertEqual(out[2], 0.0, accuracy: 1e-6)
    }
}
