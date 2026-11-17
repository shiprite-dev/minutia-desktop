import XCTest
@testable import Minutia

/// LocalTranscriber driven by a scripted engine: no model, no audio decoding, no network.
final class LocalTranscriberTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try DeviceFixtures.tempDir("local-transcriber") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func transcriber(_ engine: ScriptedEngine, gate: LoadGate, idle: TimeInterval = 60, loadFailure: Error? = nil) -> LocalTranscriber {
        LocalTranscriber(source: DeviceFixtures.source, language: "en", idleUnloadSeconds: idle,
                         loadEngine: gate.loader(engine, failure: loadFailure))
    }

    func test_theIdleUnloadWindow_isSixtySeconds() {
        XCTAssertEqual(LocalTranscriber.idleUnloadSeconds, 60)
    }

    func test_aSegmentTranscript_isNamedForItsSeq() {
        XCTAssertEqual(LocalTranscriber.transcriptName(seq: 3), "seg-3.transcript.json")
    }

    func test_theModelLoadStartsAtRecordStart_andSegmentJobsQueueUntilItFinishes() async throws {
        let engine = ScriptedEngine(DeviceFixtures.fixtureEngine)
        let gate = LoadGate()
        let local = transcriber(engine, gate: gate)
        await local.startLoading()
        let loadStarted = await eventually { gate.loads == 1 }
        XCTAssertTrue(loadStarted, "the load begins at record start, before any segment exists")

        local.enqueue(DeviceFixtures.segment(0, in: dir))
        local.enqueue(DeviceFixtures.segment(1, in: dir))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(engine.calls, [], "no job runs before the engine is loaded")

        gate.open()
        let ran = await eventually { Set(engine.calls).count == 4 }
        XCTAssertTrue(ran, "both channels of both segments ran once loaded; got \(engine.calls)")
        XCTAssertEqual(gate.loads, 1, "one load serves every queued job")
    }

    func test_eachSegmentJob_writesItsTranscriptBesideTheAudio_labeledByChannelAndOffsetByItsStart() async throws {
        let engine = ScriptedEngine([
            "seg-4-me.m4a": [DeviceFixtures.speech(1, 2, "Mine.", 0.9)],
            "seg-4-them.m4a": [DeviceFixtures.speech(0.5, 1.5, "Theirs.", 0.8)],
        ])
        let local = transcriber(engine, gate: LoadGate(open: true))
        await local.startLoading()
        local.enqueue(DeviceFixtures.segment(4, in: dir, start: 1_234.5))

        let file = dir.appendingPathComponent("seg-4.transcript.json")
        let written = await eventually { FileManager.default.fileExists(atPath: file.path) }
        XCTAssertTrue(written, "the job persists its result so an interrupted meeting can resume from it")
        guard written else { return }
        let saved = try JSONDecoder().decode(LocalTranscriber.SegmentTranscript.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.seq, 4)
        XCTAssertEqual(saved.modelId, engine.modelId)
        XCTAssertEqual(Set(saved.segments.map { "\($0.speaker)|\($0.start)|\($0.end)|\($0.text)" }), [
            "me|1235.5|1236.5|Mine.", "them|1235.0|1236.0|Theirs.",
        ])
    }

    func test_finish_returnsEverySegmentAndTheTail_onTheMeetingClock_asTheSharedFixture() async throws {
        let local = transcriber(ScriptedEngine(DeviceFixtures.fixtureEngine), gate: LoadGate(open: true))
        await local.startLoading()
        local.enqueue(DeviceFixtures.segment(0, in: dir))
        let transcript = try await local.finish(
            tail: [DeviceFixtures.segment(1, in: dir, start: 300)], durationSeconds: DeviceFixtures.fixtureDuration)
        XCTAssertEqual(try DeviceFixtures.jsonObject(transcript.encoded()),
                       try DeviceFixtures.jsonObject(Data(contentsOf: DeviceFixtures.fixtureURL)))
        for seq in [0, 1] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("seg-\(seq).transcript.json").path), "seq \(seq)")
        }
    }

    func test_finish_onAColdModel_reportsPreparingTheModel_thenTranscribingProgress() async throws {
        let gate = LoadGate()
        let local = transcriber(ScriptedEngine(DeviceFixtures.fixtureEngine), gate: gate)
        await local.startLoading()
        local.enqueue(DeviceFixtures.segment(0, in: dir))
        let steps = StepLog()
        let finishing = Task {
            try await local.finish(tail: [DeviceFixtures.segment(1, in: dir, start: 300)],
                                   durationSeconds: DeviceFixtures.fixtureDuration, onStep: { steps.record($0) })
        }
        let preparing = await eventually { steps.steps.first == .preparingModel }
        XCTAssertTrue(preparing, "a stop during the cold load names the model preparation step; got \(steps.steps)")
        gate.open()
        _ = try await finishing.value
        XCTAssertTrue(steps.steps.contains(.transcribing(completed: 2, total: 2)), "got \(steps.steps)")
        XCTAssertEqual(steps.steps.filter { $0 == .preparingModel }.count, 1)
    }

    func test_finish_onAWarmModel_neverReportsPreparing() async throws {
        let gate = LoadGate(open: true)
        let local = transcriber(ScriptedEngine(DeviceFixtures.fixtureEngine), gate: gate)
        await local.startLoading()
        let loaded = await eventually { await local.isEngineLoaded }
        XCTAssertTrue(loaded)
        let steps = StepLog()
        _ = try await local.finish(tail: [DeviceFixtures.segment(0, in: dir)], durationSeconds: 60, onStep: { steps.record($0) })
        XCTAssertFalse(steps.steps.contains(.preparingModel), "got \(steps.steps)")
    }

    /// Segments close every five minutes; unloading in the gaps would reload the model for each one.
    func test_theEngineStaysLoadedBetweenSegmentsWhileRecording() async throws {
        let gate = LoadGate(open: true)
        let engine = ScriptedEngine(DeviceFixtures.fixtureEngine)
        let local = transcriber(engine, gate: gate, idle: 0.2)
        await local.startLoading()
        local.enqueue(DeviceFixtures.segment(0, in: dir))
        let ranFirst = await eventually { engine.calls.count == 2 }
        XCTAssertTrue(ranFirst)
        try await Task.sleep(nanoseconds: 700_000_000)
        let loaded = await local.isEngineLoaded
        XCTAssertTrue(loaded, "no unload while the meeting is still recording, even past the idle window")

        local.enqueue(DeviceFixtures.segment(1, in: dir, start: 300))
        let ranSecond = await eventually { engine.calls.count == 4 }
        XCTAssertTrue(ranSecond)
        XCTAssertEqual(gate.loads, 1, "one load for the whole meeting")
    }

    func test_theEngineUnloads_theIdleWindowAfterFinish() async throws {
        let local = transcriber(ScriptedEngine(DeviceFixtures.fixtureEngine), gate: LoadGate(open: true), idle: 0.3)
        await local.startLoading()
        local.enqueue(DeviceFixtures.segment(0, in: dir))
        _ = try await local.finish(tail: [DeviceFixtures.segment(1, in: dir, start: 300)], durationSeconds: DeviceFixtures.fixtureDuration)
        let loadedRightAfter = await local.isEngineLoaded
        XCTAssertTrue(loadedRightAfter, "the engine stays inside the idle window after finish")
        let unloaded = await eventually { await local.isEngineLoaded == false }
        XCTAssertTrue(unloaded, "the engine unloads once the idle window after finish passes")
    }

    func test_theShortestTranscribableSegment_matchesFluidAudiosMinimum() {
        XCTAssertEqual(LocalTranscriber.minimumSegmentSeconds, 0.3)
    }

    /// FluidAudio throws invalidAudioData under 0.3 s; a tiny tail must not fail the whole meeting.
    func test_aSegmentShorterThanTheEngineMinimum_isSkipped_withoutFailingFinish() async throws {
        let engine = ScriptedEngine(DeviceFixtures.fixtureEngine, failing: ["seg-1-me.m4a", "seg-1-them.m4a"])
        let local = transcriber(engine, gate: LoadGate(open: true))
        await local.startLoading()
        local.enqueue(DeviceFixtures.segment(0, in: dir))
        let shortTail = DeviceFixtures.segment(1, in: dir, start: 300, frames: 14_399)
        let transcript = try await local.finish(tail: [shortTail], durationSeconds: 300.3)
        XCTAssertFalse(engine.calls.contains("seg-1-me.m4a"), "a sub-minimum segment never reaches the engine; got \(engine.calls)")
        XCTAssertFalse(engine.calls.contains("seg-1-them.m4a"))
        XCTAssertEqual(transcript.segments.map(\.text),
                       ["Let us start with the open items.", "The vendor contract is still blocked."])
    }

    func test_aSegmentAtExactlyTheMinimum_isTranscribed() async throws {
        let engine = ScriptedEngine(DeviceFixtures.fixtureEngine)
        let local = transcriber(engine, gate: LoadGate(open: true))
        await local.startLoading()
        _ = try await local.finish(tail: [DeviceFixtures.segment(1, in: dir, start: 300, frames: 14_400)], durationSeconds: 300.3)
        XCTAssertEqual(Set(engine.calls), ["seg-1-me.m4a", "seg-1-them.m4a"])
    }

    func test_aSilentMeeting_finishesAsNoSpeech_withZeroSegments() async throws {
        let local = transcriber(ScriptedEngine(), gate: LoadGate(open: true))
        await local.startLoading()
        local.enqueue(DeviceFixtures.segment(0, in: dir))
        let transcript = try await local.finish(tail: [DeviceFixtures.segment(1, in: dir, start: 300)], durationSeconds: 400)
        XCTAssertEqual(transcript.outcome, "no_speech")
        XCTAssertEqual(transcript.segments, [])
        XCTAssertEqual(transcript.durationSeconds, 400)
        XCTAssertEqual(transcript.language, "en")
    }

    func test_anEngineFailureOnAnySegment_failsFinish() async {
        let local = transcriber(ScriptedEngine(DeviceFixtures.fixtureEngine, failing: ["seg-0-them.m4a"]), gate: LoadGate(open: true))
        await local.startLoading()
        local.enqueue(DeviceFixtures.segment(0, in: dir))
        do {
            _ = try await local.finish(tail: [], durationSeconds: 60)
            XCTFail("a failed job must not produce a transcript that silently drops a channel")
        } catch {}
    }

    func test_cancel_cancelsThePendingJobs_failsFinish_andDropsTheEngine() async throws {
        let engine = ScriptedEngine(DeviceFixtures.fixtureEngine, hanging: ["seg-0-me.m4a"])
        let local = transcriber(engine, gate: LoadGate(open: true))
        await local.startLoading()
        local.enqueue(DeviceFixtures.segment(0, in: dir))
        let outcome = OutcomeBox()
        Task {
            do {
                _ = try await local.finish(tail: [DeviceFixtures.segment(1, in: dir, start: 300)], durationSeconds: 400)
                outcome.set(nil)
            } catch {
                outcome.set(error)
            }
        }
        let wedged = await eventually { engine.calls.contains("seg-0-me.m4a") }
        XCTAssertTrue(wedged)

        await local.cancel()
        let settled = await eventually(timeout: 2) { outcome.settled }
        XCTAssertTrue(settled, "finish ends once its jobs are cancelled")
        XCTAssertNotNil(outcome.error, "a cancelled finish never returns a transcript")
        XCTAssertEqual(engine.cancelled, ["seg-0-me.m4a"])
        XCTAssertFalse(engine.calls.contains("seg-1-me.m4a"), "a queued job never starts after cancel; got \(engine.calls)")
        let loaded = await local.isEngineLoaded
        XCTAssertFalse(loaded, "cancel drops the engine")
    }

    func test_aModelLoadFailure_failsFinish() async {
        let local = transcriber(ScriptedEngine(DeviceFixtures.fixtureEngine), gate: LoadGate(open: true),
                                loadFailure: CocoaError(.fileReadCorruptFile))
        await local.startLoading()
        do {
            _ = try await local.finish(tail: [DeviceFixtures.segment(0, in: dir)], durationSeconds: 60)
            XCTFail("a load failure must surface")
        } catch {}
    }

    // MARK: Segment failures, the stop guard, and the load bound

    private func guarded(_ engine: ScriptedEngine, gate: LoadGate = LoadGate(open: true), loadFailure: Error? = nil,
                         loadTimeout: TimeInterval = LocalTranscriber.loadTimeoutSeconds) -> LocalTranscriber {
        LocalTranscriber(source: DeviceFixtures.source, language: "en", guardFloor: DeviceFixtures.ultra.guardFloor,
                         loadTimeout: loadTimeout, loadEngine: gate.loader(engine, failure: loadFailure))
    }

    /// Enqueues segments 0 to count-2 as if recorded, and finishes with the last as the tail.
    private func finishMeeting(_ local: LocalTranscriber, segments count: Int) async throws -> DeviceTranscript {
        await local.startLoading()
        for seq in 0..<(count - 1) { local.enqueue(DeviceFixtures.segment(seq, in: dir)) }
        return try await local.finish(tail: [DeviceFixtures.segment(count - 1, in: dir)], durationSeconds: Double(count) * 300)
    }

    private func failure(of work: @escaping @Sendable () async throws -> DeviceTranscript,
                         within seconds: TimeInterval = 5) async -> Error? {
        let outcome = OutcomeBox()
        Task {
            do { _ = try await work(); outcome.set(nil) } catch { outcome.set(error) }
        }
        let settled = await eventually(timeout: seconds) { outcome.settled }
        XCTAssertTrue(settled, "finish must settle within \(seconds)s")
        return outcome.error
    }

    func test_oneFailedSegment_isDroppedFromTheTranscript_andTheRestStillTranscribe() async throws {
        let local = guarded(DeviceFixtures.meetingEngine(8, failing: [3]))
        let transcript = try await finishMeeting(local, segments: 8)
        XCTAssertEqual(transcript.segments.map(\.text), DeviceFixtures.items(8, except: [3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("seg-3.transcript.json").path),
                       "a failed segment leaves no partial transcript beside its audio")
    }

    func test_aMeetingThatTripsTheStopGuard_failsFinishAsQualityGuard() async {
        let rows: [(String, ScriptedEngine, Int)] = [
            ("two failed segments in a row", DeviceFixtures.meetingEngine(10, failing: [4, 5]), 10),
            ("a quarter of eight segments under the floor", DeviceFixtures.meetingEngine(8, lowConfidence: [2, 6]), 8),
            ("the only segment failing", DeviceFixtures.meetingEngine(1, failing: [0]), 1),
        ]
        for (label, engine, count) in rows {
            let local = guarded(engine)
            let error = await failure { try await self.finishMeeting(local, segments: count) }
            XCTAssertEqual(error as? LocalTranscriber.Failure, .qualityGuard, "\(label): got \(String(describing: error))")
        }
    }

    func test_theFirstFourSegmentsAllFailing_skipsLocalTranscriptionOfTheRest() async {
        let engine = DeviceFixtures.meetingEngine(7, failing: [0, 1, 2, 3, 4, 5, 6])
        let local = guarded(engine)
        let error = await failure { try await self.finishMeeting(local, segments: 7) }
        XCTAssertEqual(error as? LocalTranscriber.Failure, .qualityGuard, "got \(String(describing: error))")
        XCTAssertEqual(engine.calls.filter { ["seg-4", "seg-5", "seg-6"].contains(String($0.prefix(5))) }, [],
                       "segments after the early abort never reach the engine; got \(engine.calls)")
    }

    func test_aModelLoadError_failsFinishAsModelLoad_withoutRetryingTheLoadPerSegment() async {
        let gate = LoadGate(open: true)
        let local = guarded(DeviceFixtures.meetingEngine(3), gate: gate, loadFailure: CocoaError(.fileReadCorruptFile))
        let error = await failure { try await self.finishMeeting(local, segments: 3) }
        XCTAssertEqual(error as? LocalTranscriber.Failure, .modelLoad, "got \(String(describing: error))")
        XCTAssertEqual(gate.loads, 1)
    }

    func test_theModelLoadTimeout_isTwoMinutes() {
        XCTAssertEqual(LocalTranscriber.loadTimeoutSeconds, 120)
    }

    func test_aModelLoadPastItsTimeout_failsFinishAsTimedOut_withoutWaitingForTheLoad() async {
        let gate = LoadGate()
        let local = guarded(DeviceFixtures.meetingEngine(2), gate: gate, loadTimeout: 0.3)
        let error = await failure { try await self.finishMeeting(local, segments: 2) }
        gate.open()
        XCTAssertEqual(error as? LocalTranscriber.Failure, .modelLoadTimedOut, "got \(String(describing: error))")
    }

    func test_aSlowModelLoadUnderItsTimeout_isNotAFailure() async throws {
        let gate = LoadGate()
        let local = guarded(DeviceFixtures.meetingEngine(2), gate: gate, loadTimeout: 5)
        let finishing = Task { try await self.finishMeeting(local, segments: 2) }
        try await Task.sleep(nanoseconds: 500_000_000)
        gate.open()
        let transcript = try await finishing.value
        XCTAssertEqual(transcript.segments.map(\.text), DeviceFixtures.items(2))
    }

    // MARK: Cancel stops the engine before a recording starts

    /// A recording starting cancels recovery, and the recording must not share the Neural Engine with a
    /// transcription still running. A Core ML call does not stop when its task is cancelled, so cancel
    /// waits for it to return, and the cancelled job never starts its next engine call.
    func test_cancel_returnsOnlyOnceTheEngineCallInFlightHasReturned_evenWhenTheEngineIgnoresCancellation() async throws {
        let engine = StubbornEngine(milliseconds: 600)
        let local = LocalTranscriber(source: DeviceFixtures.source, language: "en", loadEngine: LoadGate(open: true).loader(engine))
        await local.startLoading()
        local.enqueue(DeviceFixtures.segment(0, in: dir))
        let running = await eventually { engine.inFlight == 1 }
        XCTAssertTrue(running, "precondition: the mic channel is being transcribed")

        await local.cancel()

        XCTAssertEqual(engine.inFlight, 0, "cancel returns only when no engine call is running")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(engine.started, 1, "the cancelled job never starts its system channel")
        let loaded = await local.isEngineLoaded
        XCTAssertFalse(loaded, "cancel drops the engine")
    }

    /// A model load cannot be interrupted either. Cancel waits for it, and an engine that arrives after
    /// cancel is released instead of kept.
    func test_anEngineThatFinishesLoadingAfterCancel_isReleased_neverKept() async throws {
        let gate = LoadGate()
        let handedOut = WeakEngine()
        let local = LocalTranscriber(source: DeviceFixtures.source, language: "en", loadEngine: {
            let engine = ScriptedEngine()
            handedOut.engine = engine
            return try await gate.loader(engine)()
        })
        await local.startLoading()
        let loading = await eventually { gate.loads == 1 }
        XCTAssertTrue(loading, "precondition: the model is loading")

        let cancelled = Finish()
        let cancelling = Task { await local.cancel(); cancelled.record(nil) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(cancelled.done, "cancel waits for the load in flight")
        gate.open()
        await cancelling.value

        let loaded = await local.isEngineLoaded
        XCTAssertFalse(loaded, "an engine that arrives after cancel is not kept")
        let released = await eventually { handedOut.engine == nil }
        XCTAssertTrue(released, "and nothing else holds it")
        XCTAssertEqual(gate.loads, 1, "cancel never starts another load")
    }
}
