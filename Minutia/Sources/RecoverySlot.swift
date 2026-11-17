/// Single-flight bookkeeping for the recovery sweep.
struct RecoverySlot {
    private var busy = false
    private var starting = false
    private var pending = false

    mutating func requestRun() -> Bool {
        if busy || starting { pending = true; return false }
        busy = true
        return true
    }

    mutating func captureWillStart() {
        starting = true
        if busy { pending = true }
    }

    mutating func captureDidEnd(recording: Bool) -> Bool {
        starting = false
        if recording { pending = false; return false }
        if pending && !busy { pending = false; return true }
        return false
    }

    mutating func runDidFinish() -> Bool {
        busy = false
        if pending && !starting { pending = false; return true }
        return false
    }
}
