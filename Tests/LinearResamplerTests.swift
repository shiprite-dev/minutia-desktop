import XCTest
@testable import Minutia

final class LinearResamplerTests: XCTestCase {
    private func run(_ resampler: inout LinearResampler, chunks: [[Float]]) -> [Float] {
        var out = [Float](repeating: 0, count: 200_000)
        var collected: [Float] = []
        for chunk in chunks {
            let produced = chunk.withUnsafeBufferPointer { resampler.resample($0, into: &out) }
            collected.append(contentsOf: out[0..<produced])
        }
        return collected
    }

    private func splitUneven(_ ramp: [Float], sizes: [Int]) -> [[Float]] {
        var chunks: [[Float]] = []
        var i = 0
        var s = 0
        while i < ramp.count {
            let size = sizes[s % sizes.count]
            let end = min(i + size, ramp.count)
            chunks.append(Array(ramp[i..<end]))
            i = end
            s += 1
        }
        return chunks
    }

    func test_upsample44to48_rateExactWithinOneSample() {
        let total = 44_100
        let ramp = (0..<total).map { Float($0) }
        var resampler = LinearResampler(sourceRate: 44_100, targetRate: 48_000)
        let out = run(&resampler, chunks: splitUneven(ramp, sizes: [512, 1000, 333, 4096, 71]))
        let expected = Double(total) * 48_000.0 / 44_100.0
        XCTAssertLessThanOrEqual(abs(Double(out.count) - expected), 1.0)
    }

    func test_upsample44to48_monotonicNoSeamSpike() {
        let total = 20_000
        let ramp = (0..<total).map { Float($0) }
        var resampler = LinearResampler(sourceRate: 44_100, targetRate: 48_000)
        let out = run(&resampler, chunks: splitUneven(ramp, sizes: [128, 777, 2048, 91]))
        XCTAssertGreaterThan(out.count, 1)
        // A per-callback restart (the old bug) produces a sawtooth: each chunk restarts near its
        // first value, giving a large negative jump at every seam. Continuity means the output stays
        // strictly increasing with a bounded per-sample slope (~0.92) and no spike anywhere.
        for i in 1..<out.count {
            let diff = out[i] - out[i - 1]
            XCTAssertGreaterThan(diff, 0, "backward jump / seam discontinuity at \(i)")
            XCTAssertLessThan(diff, 2, "seam spike at \(i)")
        }
    }

    func test_upsample44to48_constantInputConstantOutput() {
        let chunks: [[Float]] = [[0.42, 0.42, 0.42], [0.42, 0.42], [0.42, 0.42, 0.42, 0.42]]
        var resampler = LinearResampler(sourceRate: 44_100, targetRate: 48_000)
        let out = run(&resampler, chunks: chunks)
        XCTAssertGreaterThan(out.count, 0)
        for v in out { XCTAssertEqual(v, 0.42, accuracy: 1e-6) }
    }

    func test_equalRate_passthroughValuesWithinOneSample() {
        let chunks: [[Float]] = [[1, 2, 3, 4], [5, 6, 7, 8]]
        var resampler = LinearResampler(sourceRate: 48_000, targetRate: 48_000)
        let out = run(&resampler, chunks: chunks)
        // Passthrough at equal rate: values are exact, trailing sample stays pending (within 1).
        XCTAssertLessThanOrEqual(abs(out.count - 8), 1)
        for (i, v) in out.enumerated() {
            XCTAssertEqual(v, Float(i + 1), accuracy: 1e-6)
        }
    }

    func test_reset_restartsPhase() {
        var resampler = LinearResampler(sourceRate: 44_100, targetRate: 48_000)
        _ = run(&resampler, chunks: [[1, 2, 3, 4, 5]])
        resampler.reset()
        let out = run(&resampler, chunks: [[9, 9, 9, 9]])
        for v in out { XCTAssertEqual(v, 9, accuracy: 1e-6) }
    }
}
