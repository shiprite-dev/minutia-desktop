import Foundation

/// Pure planning + mixing for one capture tick. No state, no allocation beyond the returned array.
enum MixPlan {
    static let sampleRate: Double = 48_000
    static let tickFrames = 12_000   // 250ms at 48k

    /// Frames to drain from each source this tick. The caller silence-pads any shortfall.
    struct Tick { let micFrames: Int; let sysFrames: Int }

    static func plan(micAvailable: Int, sysAvailable: Int) -> Tick {
        Tick(micFrames: min(tickFrames, micAvailable),
             sysFrames: min(tickFrames, sysAvailable))
    }

    /// Sums the two sources sample-by-sample over `count` frames, treating missing samples as zero,
    /// and hard-clamps the result to [-1, 1].
    static func mix(mic: [Float], sys: [Float], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let m = i < mic.count ? mic[i] : 0
            let s = i < sys.count ? sys[i] : 0
            out[i] = min(1, max(-1, m + s))
        }
        return out
    }
}
