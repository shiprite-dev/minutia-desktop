import XCTest
@testable import Minutia

/// In-memory transport that never touches the network. Programs a fixed number of leading failures
/// per phase, then succeeds; thread-safe because the actor may invoke it re-entrantly.
private final class StubTransport: SegmentTransport, @unchecked Sendable {
    struct Behavior {
        var uploadFailures = 0        // upload throws this many times before succeeding
        var uploadAlwaysFails = false
        var registerFailures = 0      // register throws this many times before succeeding
        var registerAlwaysThrows = false
        var registerResult = true     // terminal return once register stops throwing
    }

    struct StubError: Error {}

    private let lock = NSLock()
    private let behavior: Behavior
    private var _uploadAttempts = 0
    private var _registerAttempts = 0
    private var _uploaded = 0
    private var _registered = 0

    init(behavior: Behavior = Behavior()) { self.behavior = behavior }

    var uploadAttempts: Int { lock.lock(); defer { lock.unlock() }; return _uploadAttempts }
    var registerAttempts: Int { lock.lock(); defer { lock.unlock() }; return _registerAttempts }
    var uploadedCount: Int { lock.lock(); defer { lock.unlock() }; return _uploaded }
    var registeredCount: Int { lock.lock(); defer { lock.unlock() }; return _registered }

    func uploadSegment(meetingId: String, seq: Int, fileURL: URL) async throws {
        lock.lock(); defer { lock.unlock() }
        _uploadAttempts += 1
        if behavior.uploadAlwaysFails { throw StubError() }
        if _uploadAttempts <= behavior.uploadFailures { throw StubError() }
        _uploaded += 1
    }

    func registerSegment(meetingId: String, seq: Int) async throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        _registerAttempts += 1
        if behavior.registerAlwaysThrows { throw StubError() }
        if _registerAttempts <= behavior.registerFailures { throw StubError() }
        _registered += 1
        return behavior.registerResult
    }
}

/// Collects the reconnecting toggles the queue emits, in order, for assertion.
private actor ReconnectRecorder {
    private(set) var events: [Bool] = []
    func record(_ value: Bool) { events.append(value) }
}

final class UploadQueueBackoffTests: XCTestCase {
    func test_backoffSchedule_doublesThenCapsAt60() {
        XCTAssertEqual(UploadQueue.backoffSchedule(attempt: 1), 1)
        XCTAssertEqual(UploadQueue.backoffSchedule(attempt: 2), 2)
        XCTAssertEqual(UploadQueue.backoffSchedule(attempt: 3), 4)
        XCTAssertEqual(UploadQueue.backoffSchedule(attempt: 4), 8)
        XCTAssertEqual(UploadQueue.backoffSchedule(attempt: 5), 16)
        XCTAssertEqual(UploadQueue.backoffSchedule(attempt: 6), 32)
        XCTAssertEqual(UploadQueue.backoffSchedule(attempt: 7), 60)
        XCTAssertEqual(UploadQueue.backoffSchedule(attempt: 8), 60)
        XCTAssertEqual(UploadQueue.backoffSchedule(attempt: 100), 60)
    }
}

final class UploadQueueBehaviorTests: XCTestCase {
    private func segment(_ seq: Int) -> SegmentWriter.ClosedSegment {
        SegmentWriter.ClosedSegment(seq: seq, fileURL: URL(fileURLWithPath: "/tmp/seg-\(seq).m4a"), frames: 48_000)
    }

    /// No sleeping in tests: retries resolve instantly.
    private func makeQueue(_ transport: StubTransport) -> UploadQueue {
        UploadQueue(transport: transport, meetingId: "m1", sleep: { _ in })
    }

    func test_happyPath_uploadsAndRegistersEachSegment() async {
        let transport = StubTransport()
        let queue = makeQueue(transport)
        queue.enqueue(segment(0))
        queue.enqueue(segment(1))
        let counts = await queue.drainAndWait()

        XCTAssertEqual(counts.uploaded, 2)
        XCTAssertEqual(counts.registered, 2)
        XCTAssertEqual(counts.failed, 0)
        XCTAssertEqual(transport.uploadedCount, 2)
        XCTAssertEqual(transport.registeredCount, 2)
    }

    func test_oneUploadFailure_thenSucceedsOnRetry() async {
        let transport = StubTransport(behavior: .init(uploadFailures: 1))
        let queue = makeQueue(transport)
        queue.enqueue(segment(0))
        let counts = await queue.drainAndWait()

        XCTAssertEqual(counts.uploaded, 1)
        XCTAssertEqual(counts.registered, 1)
        XCTAssertEqual(counts.failed, 0)
        XCTAssertEqual(transport.uploadAttempts, 2, "should retry once after the first failure")
    }

    func test_oneRegisterFailure_thenSucceedsWithoutReuploading() async {
        let transport = StubTransport(behavior: .init(registerFailures: 1))
        let queue = makeQueue(transport)
        queue.enqueue(segment(0))
        let counts = await queue.drainAndWait()

        XCTAssertEqual(counts.uploaded, 1)
        XCTAssertEqual(counts.registered, 1)
        XCTAssertEqual(counts.failed, 0)
        XCTAssertEqual(transport.uploadAttempts, 1, "upload must not repeat once it succeeded")
        XCTAssertEqual(transport.registerAttempts, 2)
    }

    func test_permanentUploadFailure_parksFileAfterMaxAttempts() async {
        let transport = StubTransport(behavior: .init(uploadAlwaysFails: true))
        let queue = makeQueue(transport)
        queue.enqueue(segment(0))
        let counts = await queue.drainAndWait()

        XCTAssertEqual(counts.uploaded, 0)
        XCTAssertEqual(counts.registered, 0)
        XCTAssertEqual(counts.failed, 1)
        XCTAssertEqual(transport.uploadAttempts, UploadQueue.maxAttempts)
    }

    func test_permanentRegisterFailure_uploadsButParksAsFailed() async {
        let transport = StubTransport(behavior: .init(registerAlwaysThrows: true))
        let queue = makeQueue(transport)
        queue.enqueue(segment(0))
        let counts = await queue.drainAndWait()

        XCTAssertEqual(counts.uploaded, 1, "upload succeeded before register began throwing")
        XCTAssertEqual(counts.registered, 0)
        XCTAssertEqual(counts.failed, 1)
        XCTAssertEqual(transport.registerAttempts, UploadQueue.maxAttempts)
    }

    func test_terminalRegister_countsUploadedNotRegisteredNotFailed() async {
        let transport = StubTransport(behavior: .init(registerResult: false))
        let queue = makeQueue(transport)
        queue.enqueue(segment(0))
        let counts = await queue.drainAndWait()

        XCTAssertEqual(counts.uploaded, 1)
        XCTAssertEqual(counts.registered, 0)
        XCTAssertEqual(counts.failed, 0)
        XCTAssertEqual(transport.registerAttempts, 1, "a terminal (false) register is not retried")
    }

    func test_syncEnqueue_beforeDrain_alwaysIncludedInCounts() async {
        // Regression: enqueue is synchronous, so every segment handed over before drainAndWait is
        // called must appear in its counts. A detached-Task enqueue could strand the final segment.
        let transport = StubTransport()
        let queue = makeQueue(transport)
        let n = 50
        for i in 0..<n { queue.enqueue(segment(i)) }
        let counts = await queue.drainAndWait()

        XCTAssertEqual(counts.enqueued, n, "all synchronously enqueued segments are tracked")
        XCTAssertEqual(counts.uploaded, n)
        XCTAssertEqual(counts.registered, n)
        XCTAssertEqual(counts.failed, 0)
        XCTAssertEqual(transport.uploadedCount, n)
        XCTAssertEqual(transport.registeredCount, n)
    }

    func test_segmentRetriesPastOldCapOfSix_thenRecovers() async {
        // Old behavior parked a segment permanently after 6 attempts. A normal outage that clears
        // on the 11th try must now upload successfully rather than silently lose the segment.
        let transport = StubTransport(behavior: .init(uploadFailures: 10))
        let queue = makeQueue(transport)
        queue.enqueue(segment(0))
        let counts = await queue.drainAndWait()

        XCTAssertEqual(counts.failed, 0)
        XCTAssertEqual(counts.uploaded, 1)
        XCTAssertEqual(transport.uploadAttempts, 11)
        XCTAssertGreaterThan(transport.uploadAttempts, 6, "retries continue past the old 6-attempt cap")
    }

    func test_reconnecting_staysSilentOnHappyPath() async {
        let transport = StubTransport()
        let recorder = ReconnectRecorder()
        let queue = UploadQueue(
            transport: transport, meetingId: "m1",
            sleep: { _ in }, onReconnecting: { await recorder.record($0) })
        queue.enqueue(segment(0))
        _ = await queue.drainAndWait()

        let events = await recorder.events
        XCTAssertEqual(events, [], "no failures means no reconnecting signal")
    }

    func test_reconnecting_trueAfterThresholdFailuresThenFalseOnSuccess() async {
        let transport = StubTransport(behavior: .init(uploadFailures: 3))
        let recorder = ReconnectRecorder()
        let queue = UploadQueue(
            transport: transport, meetingId: "m1",
            sleep: { _ in }, onReconnecting: { await recorder.record($0) })
        queue.enqueue(segment(0))
        let counts = await queue.drainAndWait()

        XCTAssertEqual(counts.uploaded, 1)
        XCTAssertEqual(counts.failed, 0)
        let events = await recorder.events
        XCTAssertEqual(events, [true, false], "true after the 3rd failed attempt, false once upload succeeds")
    }

    func test_drainAndWait_returnsOnlyAfterInFlightRetriesSettle() async {
        // A real (tiny) sleep forces genuine suspension between retries; drainAndWait must still
        // observe the eventual success, proving it awaits the full retry chain.
        let transport = StubTransport(behavior: .init(registerFailures: 3))
        let queue = UploadQueue(
            transport: transport,
            meetingId: "m1",
            sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) }
        )
        queue.enqueue(segment(0))
        let counts = await queue.drainAndWait()

        XCTAssertEqual(counts.uploaded, 1)
        XCTAssertEqual(counts.registered, 1)
        XCTAssertEqual(counts.failed, 0)
        XCTAssertEqual(transport.registerAttempts, 4, "3 failures then a success, all awaited")
    }
}
