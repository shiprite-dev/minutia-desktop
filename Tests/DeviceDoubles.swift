import Foundation
import XCTest
@testable import Minutia

/// A `SpeechEngine` that answers by audio file name and never touches a model.
final class ScriptedEngine: SpeechEngine, @unchecked Sendable {
    let modelId = "parakeet-ultra@95eaa59"
    private let lock = NSLock()
    private let results: [String: [SpeechSegment]]
    private let failing: Set<String>
    private let hanging: Set<String>
    private var _calls: [String] = []
    private var _cancelled: [String] = []

    /// `hanging` files never finish (until cancelled), like a wedged Core ML call.
    init(_ results: [String: [SpeechSegment]] = [:], failing: Set<String> = [], hanging: Set<String> = []) {
        self.results = results
        self.failing = failing
        self.hanging = hanging
    }

    var calls: [String] { lock.withLock { _calls } }
    /// Hanging calls that were cancelled.
    var cancelled: [String] { lock.withLock { _cancelled } }

    func transcribe(_ audio: SpeechAudio) async throws -> SpeechResult {
        guard case .file(let url) = audio else { throw CocoaError(.fileReadUnsupportedScheme) }
        let name = url.lastPathComponent
        lock.withLock { _calls.append(name) }
        if failing.contains(name) { throw CocoaError(.fileReadCorruptFile) }
        if hanging.contains(name) {
            do { try await Task.sleep(nanoseconds: 3_600_000_000_000) } catch {
                lock.withLock { _cancelled.append(name) }
                throw error
            }
        }
        return SpeechResult(modelId: modelId, segments: results[name] ?? [])
    }
}

/// Holds every engine load until `open()`, and counts loads.
final class LoadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var _loads = 0

    init(open: Bool = false) { isOpen = open }

    var loads: Int { lock.withLock { _loads } }

    func open() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }

    func loader(_ engine: any SpeechEngine, failure: Error? = nil) -> @Sendable () async throws -> any SpeechEngine {
        { [self] in
            lock.withLock { _loads += 1 }
            await withCheckedContinuation { continuation in
                let resumeNow: Bool = lock.withLock {
                    if isOpen { return true }
                    waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
            if let failure { throw failure }
            return engine
        }
    }
}

/// Records every device-transport call in order. `submitStatuses` is consumed one per submit; when
/// it runs out the last status repeats. `failure` makes every call throw it instead. `onMark` runs
/// the moment the mark is called, before `markDelay`.
final class RecordingTransport: DeviceTranscriptTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    private var _bodies: [Data] = []
    private var statuses: [Int]
    private let failure: Error?
    private let markDelay: TimeInterval
    private let onMark: @Sendable () -> Void
    let warmed = XCTestExpectation(description: "summary warmed")
    let ended = XCTestExpectation(description: "meeting ended")

    init(submitStatuses: [Int] = [200], failure: Error? = nil, markDelay: TimeInterval = 0,
         onMark: @escaping @Sendable () -> Void = {}) {
        statuses = submitStatuses
        self.failure = failure
        self.markDelay = markDelay
        self.onMark = onMark
    }

    var log: [String] { lock.withLock { _log } }
    var bodies: [Data] { lock.withLock { _bodies } }
    var submits: Int { log.filter { $0 == "submit" }.count }

    private func record(_ entry: String) { lock.withLock { _log.append(entry) } }

    func markAwaitingDeviceTranscript(meetingId: String, durationSeconds: Double) async throws {
        onMark()
        if markDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(markDelay * 1_000_000_000)) }
        record("mark")
        if let failure { throw failure }
    }

    func submitDeviceTranscript(meetingId: String, body: Data) async throws -> Int {
        record("submit")
        lock.withLock { _bodies.append(body) }
        if let failure { throw failure }
        return lock.withLock { statuses.count > 1 ? statuses.removeFirst() : statuses[0] }
    }

    func warmSummary(meetingId: String) async {
        record("warmSummary")
        warmed.fulfill()
    }

    func endMeeting(meetingId: String) async throws {
        record("endMeeting")
        ended.fulfill()
        if let failure { throw failure }
    }
}

/// Collects `FinishingStep`s reported from any task.
final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _steps: [CaptureSession.FinishingStep] = []
    var steps: [CaptureSession.FinishingStep] { lock.withLock { _steps } }
    func record(_ step: CaptureSession.FinishingStep) { lock.withLock { _steps.append(step) } }
}

/// Records the backoff waits without sleeping.
final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _waits: [TimeInterval] = []
    var waits: [TimeInterval] { lock.withLock { _waits } }
    func record(_ seconds: TimeInterval) { lock.withLock { _waits.append(seconds) } }
}

enum DeviceFixtures {
    static let meetingId = "0f9c2c9a-1a2b-4c3d-8e4f-5a6b7c8d9e0f"
    static let ultra = ModelManifest.pinned.entries.first { $0.id == "parakeet-ultra" }!
    static let source = DeviceTranscript.Source.onDevice(ultra, appVersion: "0.3.0")

    static func speech(_ start: Double, _ end: Double, _ text: String, _ confidence: Double) -> SpeechSegment {
        SpeechSegment(start: start, end: end, text: text, confidence: confidence)
    }

    static func segment(_ seq: Int, in dir: URL, start: Double? = nil, frames: Int64 = 48_000) -> SegmentWriter.ClosedSegment {
        SegmentWriter.ClosedSegment(
            seq: seq, micURL: dir.appendingPathComponent("seg-\(seq)-me.m4a"),
            sysURL: dir.appendingPathComponent("seg-\(seq)-them.m4a"), frames: frames, startSeconds: start)
    }

    /// The engine output behind `Tests/Fixtures/device-transcript.v1.json`: segment 0 at the
    /// meeting start, segment 1 five minutes in.
    static let fixtureEngine: [String: [SpeechSegment]] = [
        "seg-0-me.m4a": [speech(0.42, 3.1, "Let us start with the open items.", 0.93)],
        "seg-0-them.m4a": [speech(3.4, 7.9, "The vendor contract is still blocked.", 0.9)],
        "seg-1-them.m4a": [speech(1.5, 4.25, "Can we move it to next week?", 0.88)],
        "seg-1-me.m4a": [speech(5, 6.5, "Yes, I will follow up.", 0.95)],
    ]
    static let fixtureDuration = 312.75

    /// Bundled as a test resource: the test host must not read the source tree, which can live on
    /// an external volume it cannot open.
    static var fixtureURL: URL {
        Bundle(for: ScriptedEngine.self).url(forResource: "device-transcript.v1", withExtension: "json")!
    }

    static func jsonObject(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    static func tempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: TimeInterval = 3, _ condition: @escaping () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}
