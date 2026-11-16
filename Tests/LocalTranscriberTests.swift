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
        XCTAssertTrue(written, "the job persists its result so an interrupted meeting can resume (MIN-216)")
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

    func test_theEngineUnloads_afterTheIdleWindowFollowingTheLastJob_andReloadsForTheNext() async throws {
        let gate = LoadGate(open: true)
        let engine = ScriptedEngine(DeviceFixtures.fixtureEngine)
        let local = transcriber(engine, gate: gate, idle: 0.2)
        await local.startLoading()
        local.enqueue(DeviceFixtures.segment(0, in: dir))
        let ranFirst = await eventually { engine.calls.count == 2 }
        XCTAssertTrue(ranFirst)
        let stillLoaded = await local.isEngineLoaded
        XCTAssertTrue(stillLoaded, "the engine stays loaded inside the idle window")
        let unloaded = await eventually { await local.isEngineLoaded == false }
        XCTAssertTrue(unloaded, "the engine unloads after the idle window")

        local.enqueue(DeviceFixtures.segment(1, in: dir, start: 300))
        let ranSecond = await eventually { engine.calls.count == 4 }
        XCTAssertTrue(ranSecond, "a later job reloads the engine")
        XCTAssertEqual(gate.loads, 2)
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

    func test_aModelLoadFailure_failsFinish() async {
        let local = transcriber(ScriptedEngine(DeviceFixtures.fixtureEngine), gate: LoadGate(open: true),
                                loadFailure: CocoaError(.fileReadCorruptFile))
        await local.startLoading()
        do {
            _ = try await local.finish(tail: [DeviceFixtures.segment(0, in: dir)], durationSeconds: 60)
            XCTFail("a load failure must surface")
        } catch {}
    }
}
