import Foundation

/// Stateful linear resampler for a continuous mono Float32 stream. Carries the fractional source
/// position and the previous chunk's last sample across calls so output is rate-exact over time and
/// continuous across chunk boundaries (no per-callback restart, no seam discontinuity). Pure: no
/// CoreAudio, no allocation in `resample` beyond writing into the caller's `out`.
struct LinearResampler {
    /// Source samples advanced per output sample (`sourceRate / targetRate`).
    private let step: Double
    /// Next output position in source-sample coordinates, where index 0 is the first sample of the
    /// current chunk and index -1 is `prev`. Stays in [-1, step) at chunk boundaries.
    private var pos: Double = 0
    /// The previous chunk's final source sample, used to interpolate across the seam.
    private var prev: Float = 0

    init(sourceRate: Double, targetRate: Double) {
        step = (sourceRate > 0 && targetRate > 0) ? sourceRate / targetRate : 1
    }

    mutating func reset() {
        pos = 0
        prev = 0
    }

    /// Resamples one chunk into `out`, returning the number of samples written. `out` must have
    /// capacity for the chunk's output (roughly `input.count * targetRate / sourceRate + 1`); the
    /// resampler does not buffer input, so an undersized `out` drops the tail of this chunk.
    mutating func resample(_ input: UnsafeBufferPointer<Float>, into out: inout [Float]) -> Int {
        let n = input.count
        guard n > 0, step > 0 else { return 0 }

        var produced = 0
        out.withUnsafeMutableBufferPointer { dst in
            let cap = dst.count
            while produced < cap {
                let i0 = Int(floor(pos))
                // Need both neighbours (i0 and i0+1) inside the current chunk to interpolate; the
                // final sample stays pending until the next chunk supplies its right neighbour.
                if i0 > n - 2 { break }
                let frac = Float(pos - Double(i0))
                let a = i0 < 0 ? prev : input[i0]
                let b = input[i0 + 1]
                dst[produced] = a * (1 - frac) + b * frac
                produced += 1
                pos += step
            }
        }

        // Rebase into the next chunk's coordinates: index n becomes the next index 0.
        pos -= Double(n)
        prev = input[n - 1]
        return produced
    }
}
