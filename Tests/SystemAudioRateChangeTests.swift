import XCTest
import CoreAudio
@testable import Minutia

/// A Bluetooth headset drops its output to a lower rate (A2DP to the headset profile) when the
/// voice-processing mic opens it, after the tap has already read a 48k source format. The tap must
/// rebuild on that rate change so the IOProc's frames are resampled from the rate it really runs at.
final class SystemAudioRateChangeTests: XCTestCase {
    func test_outputDeviceSampleRateChange_triggersRebuild() {
        XCTAssertTrue(SystemAudioTap.outputDeviceRebuildSelectors.contains(kAudioDevicePropertyNominalSampleRate))
        XCTAssertTrue(SystemAudioTap.outputDeviceRebuildSelectors.contains(kAudioDevicePropertyDeviceIsAlive))
    }

    /// Models one 250ms tick: the mic delivers a full tick at 48k while the tap's IOProc delivers a
    /// quarter second of 16k frames. Pushed under the stale 48k label, only a third of the tick is
    /// audio and the rest is padding (the chopped capture); resampled from 16k the tick is full.
    func test_lowRateFramesUnderStale48kLabel_fillOnlyAThirdOfTheTick() {
        let quarterSecondAt16k = (0..<4_000).map { Float(sin(Double($0) * 0.3)) * 0.5 }

        func sysFramesAfterTick(resampleFrom sourceRate: Double) -> (got: Int, padded: [Float]) {
            let ring = RingBuffer(capacityFrames: 48_000)
            var resampler = LinearResampler(sourceRate: sourceRate, targetRate: MixPlan.sampleRate)
            var scratch = [Float](repeating: 0, count: 48_000)
            for start in stride(from: 0, to: quarterSecondAt16k.count, by: 512) {
                let chunk = Array(quarterSecondAt16k[start..<min(start + 512, quarterSecondAt16k.count)])
                if sourceRate == MixPlan.sampleRate {
                    chunk.withUnsafeBufferPointer { ring.push($0.baseAddress!, count: chunk.count) }
                } else {
                    let produced = chunk.withUnsafeBufferPointer { resampler.resample($0, into: &scratch) }
                    scratch.withUnsafeBufferPointer { ring.push($0.baseAddress!, count: produced) }
                }
            }
            let plan = MixPlan.plan(micAvailable: MixPlan.tickFrames, sysAvailable: ring.availableFrames)
            var sys = [Float](repeating: 0, count: MixPlan.tickFrames)
            let got = ring.pop(into: &sys, count: plan.sysFrames)
            return (got, MixPlan.pad(Array(sys[0..<got]), to: MixPlan.tickFrames))
        }

        let stale = sysFramesAfterTick(resampleFrom: MixPlan.sampleRate)
        XCTAssertEqual(stale.got, 4_000)
        XCTAssertTrue(stale.padded[4_000...].allSatisfy { $0 == 0 })

        let reread = sysFramesAfterTick(resampleFrom: 16_000)
        XCTAssertGreaterThanOrEqual(reread.got, MixPlan.tickFrames - 3)
    }
}
