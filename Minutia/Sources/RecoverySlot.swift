/// Single-flight bookkeeping for the recovery sweep.
struct RecoverySlot {
    mutating func requestRun() -> Bool { false }
    mutating func captureWillStart() {}
    mutating func captureDidEnd(recording: Bool) -> Bool { false }
    mutating func runDidFinish() -> Bool { false }
}
