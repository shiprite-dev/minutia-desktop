import XCTest
@testable import Minutia

/// The device-mode stop (`CaptureSession.finishOnDevice`, which `stop()` runs after
/// `finishCapture()` when audio may not leave the Mac) against a transport double. The transport
/// protocol has no audio upload, finalize or transcribe call, so the double's log is every request
/// the device path can make.
final class DeviceStopTests: XCTestCase {
    private var dir: URL!
    private let instance = URL(string: "https://minutia.example.com")!

    override func setUpWithError() throws {
        dir = try DeviceFixtures.tempDir("device-stop")
        for name in ["seg-0-me.m4a", "seg-0-them.m4a", "seg-1-me.m4a", "seg-1-them.m4a", "recording.m4a"] {
            try Data([0]).write(to: dir.appendingPathComponent(name))
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private var dirExists: Bool { FileManager.default.fileExists(atPath: dir.path) }

    private func startedTranscriber(_ engine: ScriptedEngine = ScriptedEngine(DeviceFixtures.fixtureEngine),
                                    gate: LoadGate = LoadGate(open: true)) async -> LocalTranscriber {
        let local = LocalTranscriber(source: DeviceFixtures.source, language: "en", loadEngine: gate.loader(engine))
        await local.startLoading()
        local.enqueue(DeviceFixtures.segment(0, in: dir))
        return local
    }

    private func finish(_ local: LocalTranscriber, _ transport: RecordingTransport, recapOpened: Bool = false,
                        sleeps: SleepLog = SleepLog(), steps: StepLog = StepLog()) async throws -> CaptureSession.StopResult {
        try await CaptureSession.finishOnDevice(
            meetingId: DeviceFixtures.meetingId, directory: dir,
            tail: [DeviceFixtures.segment(1, in: dir, start: 300)], durationSeconds: DeviceFixtures.fixtureDuration,
            transcriber: local, transport: transport, recapOpened: recapOpened,
            sleep: { sleeps.record($0) }, onStep: { steps.record($0) })
    }

    // MARK: Happy path

    func test_deviceStop_marksTheMeetingWaitingForThisMac_submitsTheFixtureBody_thenDeletesTheDirectory() async throws {
        let transport = RecordingTransport()
        let result = try await finish(await startedTranscriber(), transport)

        XCTAssertTrue(result.transcriptRequested, "a submitted device transcript opens the recap like cloud mode")
        XCTAssertNil(result.expectedSegments)
        XCTAssertEqual(Array(transport.log.prefix(2)), ["mark", "submit"])
        XCTAssertEqual(transport.submits, 1)
        let body = try XCTUnwrap(transport.bodies.first)
        XCTAssertEqual(try DeviceFixtures.jsonObject(body), try DeviceFixtures.jsonObject(Data(contentsOf: DeviceFixtures.fixtureURL)),
                       "the submitted body is the shared fixture the web verifier accepts")
        XCTAssertFalse(dirExists, "a 2xx deletes the capture directory")
    }

    /// A mark sent before the transcript exists strands the meeting as pending on this device when
    /// transcription then fails; a mark landing after the submit would reopen a completed meeting.
    func test_deviceStop_marksTheMeetingOnlyAfterTheTranscriptIsWritten_immediatelyBeforeTheSubmit() async throws {
        let transcriptPath = dir.appendingPathComponent(CaptureRecovery.transcriptName).path
        let sawTranscript = OutcomeBox()
        let transport = RecordingTransport(markDelay: 0.3, onMark: {
            sawTranscript.set(FileManager.default.fileExists(atPath: transcriptPath) ? nil : CocoaError(.fileNoSuchFile))
        })
        _ = try await finish(await startedTranscriber(), transport)
        XCTAssertEqual(Array(transport.log.prefix(2)), ["mark", "submit"], "got \(transport.log)")
        XCTAssertTrue(sawTranscript.settled)
        XCTAssertNil(sawTranscript.error, "transcript.json must be on disk when the mark is sent")
    }

    func test_deviceStop_warmsTheSummaryAfterTheSubmit_andEndsTheMeeting() async throws {
        let transport = RecordingTransport()
        _ = try await finish(await startedTranscriber(), transport)
        await fulfillment(of: [transport.warmed, transport.ended], timeout: 3)
        let log = transport.log
        XCTAssertLessThan(try XCTUnwrap(log.firstIndex(of: "submit")), try XCTUnwrap(log.firstIndex(of: "warmSummary")))
    }

    func test_deviceStop_skipsTheWarmUp_whenTheRecapAlreadyOpened() async throws {
        let transport = RecordingTransport()
        _ = try await finish(await startedTranscriber(), transport, recapOpened: true)
        await fulfillment(of: [transport.ended], timeout: 3)
        XCTAssertFalse(transport.log.contains("warmSummary"))
    }

    func test_deviceStop_reportsSubmittingLast() async throws {
        let steps = StepLog()
        _ = try await finish(await startedTranscriber(), RecordingTransport(), steps: steps)
        XCTAssertEqual(steps.steps.last, .submitting, "got \(steps.steps)")
    }

    func test_aSilentMeeting_submitsNoSpeech_withZeroSegments() async throws {
        let transport = RecordingTransport()
        _ = try await finish(await startedTranscriber(ScriptedEngine()), transport)
        let body = try DeviceFixtures.jsonObject(try XCTUnwrap(transport.bodies.first))
        XCTAssertEqual(body["outcome"] as? String, "no_speech")
        XCTAssertEqual((body["segments"] as? [Any])?.count, 0)
    }

    // MARK: Cold load

    func test_aStopDuringAColdLoad_waitsForTheModel_thenSubmitsTheDeviceTranscript() async throws {
        let gate = LoadGate()
        let transport = RecordingTransport()
        let local = await startedTranscriber(gate: gate)
        let steps = StepLog()
        let stopping = Task { try await self.finish(local, transport, steps: steps) }

        let preparing = await eventually { steps.steps.contains(.preparingModel) }
        XCTAssertTrue(preparing, "the finishing state names the model preparation step; got \(steps.steps)")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.log, [], "nothing reaches the server, not even the mark, before the model has transcribed")
        XCTAssertTrue(dirExists)

        gate.open()
        let result = try await stopping.value
        XCTAssertTrue(result.transcriptRequested)
        XCTAssertEqual(transport.submits, 1)
        XCTAssertFalse(dirExists)
    }

    // MARK: Failure keeps the audio

    /// The device counterpart of "stop with an unreachable client never uploads": every request the
    /// device path can make fails, nothing reaches an audio route (the transport has none), the stop
    /// throws instead of reporting a requested transcript, and the audio plus the finished
    /// transcript stay on disk.
    func test_deviceStop_withAnUnreachableServer_makesNoAudioRequest_throws_andKeepsTheDirectory() async throws {
        let transport = RecordingTransport(failure: URLError(.cannotConnectToHost))
        do {
            _ = try await finish(await startedTranscriber(), transport)
            XCTFail("an unsubmitted transcript must never read as transcriptRequested")
        } catch {}
        XCTAssertTrue(transport.log.allSatisfy { ["mark", "submit"].contains($0) }, "got \(transport.log)")
        XCTAssertGreaterThan(transport.submits, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("seg-0-me.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("recording.m4a").path))
    }

    func test_aRejectedSubmit_keepsTheDirectory_withTheTranscriptWrittenBeforeAnyNetworkCall() async throws {
        let transport = RecordingTransport(submitStatuses: [400])
        do {
            _ = try await finish(await startedTranscriber(), transport)
            XCTFail("a 400 must throw")
        } catch {}
        XCTAssertEqual(transport.submits, 1, "a terminal 4xx is not retried")
        XCTAssertTrue(dirExists)
        let saved = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        XCTAssertEqual(try DeviceFixtures.jsonObject(saved), try DeviceFixtures.jsonObject(try XCTUnwrap(transport.bodies.first)),
                       "submit retries reuse the payload written at stop")
        await Task.yield()
        XCTAssertFalse(transport.log.contains("warmSummary"))
    }

    // MARK: Submit classification

    private func submit(_ statuses: [Int], failure: Error? = nil) async -> (RecordingTransport, SleepLog, Error?) {
        let transport = RecordingTransport(submitStatuses: statuses, failure: failure)
        let sleeps = SleepLog()
        do {
            try await CaptureSession.submitDeviceTranscript(
                meetingId: DeviceFixtures.meetingId, body: Data("{}".utf8), transport: transport, sleep: { sleeps.record($0) })
            return (transport, sleeps, nil)
        } catch {
            return (transport, sleeps, error)
        }
    }

    func test_submit_aCompletedReplay_isSuccess() async {
        let (transport, sleeps, error) = await submit([200])
        XCTAssertNil(error)
        XCTAssertEqual(transport.submits, 1)
        XCTAssertEqual(sleeps.waits, [])
    }

    func test_submit_a409_retriesWithBackoff_thenSucceeds() async {
        let (transport, sleeps, error) = await submit([409, 409, 200])
        XCTAssertNil(error)
        XCTAssertEqual(transport.submits, 3)
        XCTAssertEqual(sleeps.waits, Array(CaptureSession.submitBackoff.prefix(2)))
    }

    func test_submit_retriesAuthExpiryAndServerErrors() async {
        for status in [401, 500, 502] {
            let (transport, _, error) = await submit([status, 200])
            XCTAssertNil(error, "\(status)")
            XCTAssertEqual(transport.submits, 2, "\(status)")
        }
    }

    func test_submit_retriesANetworkError_untilTheBackoffRunsOut_thenThrows() async {
        let (transport, sleeps, error) = await submit([200], failure: URLError(.notConnectedToInternet))
        XCTAssertNotNil(error)
        XCTAssertEqual(transport.submits, CaptureSession.submitBackoff.count + 1)
        XCTAssertEqual(sleeps.waits, CaptureSession.submitBackoff)
    }

    func test_submit_neverRetriesARequestTheServerWillNotAccept() async {
        for status in [400, 403, 404, 413] {
            let (transport, sleeps, error) = await submit([status])
            XCTAssertNotNil(error, "\(status)")
            XCTAssertEqual(transport.submits, 1, "\(status)")
            XCTAssertEqual(sleeps.waits, [], "\(status)")
        }
    }

    func test_submit_givesUpAfterTheLastBackoff_whileTheClaimStaysBusy() async {
        let (transport, _, error) = await submit([409])
        XCTAssertNotNil(error)
        XCTAssertEqual(transport.submits, CaptureSession.submitBackoff.count + 1)
    }

    func test_submitBackoff_doublesFromOneSecond_andFitsInsideTheStopWindow() {
        XCTAssertEqual(CaptureSession.submitBackoff, [1, 2, 4, 8, 16])
        XCTAssertLessThan(CaptureSession.submitBackoff.reduce(0, +), CaptureSession.finalizeTimeout)
    }

    // MARK: Client requests

    func test_transcriptRequest_postsTheBodyToTheLowercasedMeetingRoute_withBearerAuth() {
        let body = Data(#"{"schema_version":1}"#.utf8)
        let request = MinutiaClient.deviceTranscriptRequest(
            instance: instance, meetingId: "0F9C2C9A-1A2B-4C3D-8E4F-5A6B7C8D9E0F", body: body, token: "tok")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://minutia.example.com/api/meetings/0f9c2c9a-1a2b-4c3d-8e4f-5a6b7c8d9e0f/transcript")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.httpBody, body)
    }

    func test_awaitingDeviceUpdate_marksPendingOnThisDevice_withTheDurationAndNoAudioPath() throws {
        let data = try JSONEncoder().encode(MinutiaClient.awaitingDeviceUpdate(durationSeconds: 312.75))
        XCTAssertEqual(try DeviceFixtures.jsonObject(data), [
            "transcription_status": "pending", "transcription_provider": "device", "audio_duration_seconds": 313,
        ] as NSDictionary)
    }

    // MARK: Finishing state and Settings

    func test_finishingLabels_nameEachDeviceStep() {
        XCTAssertEqual(CaptureSession.FinishingStep.preparingModel.label, "Preparing the speech model")
        XCTAssertEqual(CaptureSession.FinishingStep.transcribing(completed: 3, total: 12).label, "Transcribing on this Mac, 3 of 12")
        XCTAssertEqual(CaptureSession.FinishingStep.submitting.label, "Sending the transcript")
    }

    func test_transcriptionPicker_isVisibleWheneverTheStoredSettingIsNotAutomatic() {
        for setting in TranscriptionSetting.allCases {
            XCTAssertTrue(setting.pickerVisible(deviceRoutingEnabled: true), "\(setting)")
            XCTAssertEqual(setting.pickerVisible(deviceRoutingEnabled: false), setting != .automatic,
                           "\(setting): a stored On this Mac only must never be stuck refusing with the picker hidden")
        }
    }

    // MARK: Review fixes

    func test_aSubmitThatMaySucceedLater_surfacesAsTranscriptNotSent() async throws {
        for transport in [RecordingTransport(submitStatuses: [503]), RecordingTransport(submitStatuses: [403]),
                          RecordingTransport(failure: URLError(.cannotConnectToHost))] {
            do {
                _ = try await finish(await startedTranscriber(), transport)
                XCTFail("must throw")
            } catch {
                guard case .transcriptNotSent? = error as? CaptureSession.CaptureError else {
                    return XCTFail("device copy needs its own error, got \(error)")
                }
            }
            XCTAssertTrue(dirExists)
        }
    }

    /// Resending the same bytes can never turn a 400, 413 or 422 into a success, so Retry is not offered.
    func test_aPermanentlyRejectedTranscript_surfacesAsRejected_keepingTheDirectory() async throws {
        for status in [400, 413, 422] {
            let transport = RecordingTransport(submitStatuses: [status])
            do {
                _ = try await finish(await startedTranscriber(), transport)
                XCTFail("\(status): must throw")
            } catch {
                guard case .transcriptRejected? = error as? CaptureSession.CaptureError else {
                    return XCTFail("\(status): got \(error)")
                }
            }
            XCTAssertEqual(transport.submits, 1, "\(status)")
            XCTAssertTrue(dirExists, "\(status)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("recording.m4a").path), "\(status)")
        }
    }

    func test_submit_aPermanentRejection_throwsTranscriptRejected_withoutRetrying() async {
        for status in [400, 404, 413, 422] {
            let (transport, sleeps, error) = await submit([status])
            guard case .transcriptRejected? = error as? CaptureSession.CaptureError else {
                return XCTFail("\(status): got \(String(describing: error))")
            }
            XCTAssertEqual(transport.submits, 1, "\(status)")
            XCTAssertEqual(sleeps.waits, [], "\(status)")
        }
    }

    /// 401 and 409 keep retrying; 403, 408, 429 and 503 are not retried but are not a verdict on the transcript.
    func test_submit_authClaimThrottleAndUnavailable_areNeverReportedAsRejected() async {
        for status in [401, 403, 408, 409, 429, 503] {
            let (_, _, error) = await submit([status])
            XCTAssertNotNil(error, "\(status)")
            if case .transcriptRejected? = error as? CaptureSession.CaptureError { XCTFail("\(status) is not a permanent rejection") }
        }
    }

    // MARK: Finishing step from the first moment

    private func loadedTranscriber(_ engine: ScriptedEngine) async -> LocalTranscriber {
        let local = LocalTranscriber(source: DeviceFixtures.source, language: "en", loadEngine: LoadGate(open: true).loader(engine))
        await local.startLoading()
        _ = await eventually { await local.isEngineLoaded }
        local.enqueue(DeviceFixtures.segment(0, in: dir))
        return local
    }

    /// With the engine already loaded and a job still running, the finishing view names the work at
    /// once instead of falling back to the cloud "Uploading" copy until the first job lands.
    func test_finish_withALoadedEngineAndABacklog_reportsTranscribingZeroOfAll_beforeAnyJobFinishes() async throws {
        let local = await loadedTranscriber(ScriptedEngine(DeviceFixtures.fixtureEngine, hanging: ["seg-0-me.m4a"]))
        let steps = StepLog()
        let finishing = Task {
            try await local.finish(tail: [DeviceFixtures.segment(1, in: dir, start: 300)], durationSeconds: DeviceFixtures.fixtureDuration,
                                   onStep: { steps.record($0) })
        }
        let reported = await eventually { !steps.steps.isEmpty }
        await local.cancel()
        _ = await finishing.result
        XCTAssertTrue(reported, "a step is reported before the first job finishes")
        XCTAssertEqual(steps.steps.first, .transcribing(completed: 0, total: 2), "got \(steps.steps)")
    }

    func test_finish_withNoEngine_reportsPreparingTheModelFirst() async throws {
        let gate = LoadGate()
        let local = await startedTranscriber(gate: gate)
        let steps = StepLog()
        let finishing = Task {
            try await local.finish(tail: [], durationSeconds: DeviceFixtures.fixtureDuration, onStep: { steps.record($0) })
        }
        let reported = await eventually { !steps.steps.isEmpty }
        gate.open()
        _ = try await finishing.value
        XCTAssertTrue(reported)
        XCTAssertEqual(steps.steps.first, .preparingModel, "got \(steps.steps)")
    }

    /// A slow notes flush must not leave the finishing view on the cloud copy: the step is reported
    /// while the flush is still in flight, and the notes still land before the meeting is marked.
    func test_aDeviceStop_reportsItsStepWhileTheNotesFlushIsStillRunning_andMarksOnlyAfterTheNotesLand() async throws {
        let local = await loadedTranscriber(ScriptedEngine(DeviceFixtures.fixtureEngine))
        let notesGate = LoadGate()
        let holdNotes = notesGate.loader(ScriptedEngine())
        let notesLanded = OutcomeBox()
        let markedAfterNotes = OutcomeBox()
        let transport = RecordingTransport(onMark: { markedAfterNotes.set(notesLanded.settled ? nil : CocoaError(.featureUnsupported)) })
        let steps = StepLog()
        let stopping = Task {
            try await CaptureSession.finishOnDevice(
                meetingId: DeviceFixtures.meetingId, directory: self.dir,
                tail: [DeviceFixtures.segment(1, in: self.dir, start: 300)], durationSeconds: DeviceFixtures.fixtureDuration,
                transcriber: local, transport: transport, recapOpened: true, sleep: { _ in },
                flushNotes: { _ = try await holdNotes(); notesLanded.set(nil) },
                onStep: { steps.record($0) })
        }
        let flushing = await eventually { notesGate.loads == 1 }
        let reported = await eventually { !steps.steps.isEmpty }
        XCTAssertTrue(flushing, "the notes flush started")
        XCTAssertTrue(reported, "a step is shown while the notes flush is still running; got \(steps.steps)")
        XCTAssertEqual(transport.log, [], "nothing is marked or sent before the notes land")

        notesGate.open()
        let result = try await stopping.value
        XCTAssertTrue(result.transcriptRequested)
        XCTAssertTrue(markedAfterNotes.settled)
        XCTAssertNil(markedAfterNotes.error, "the meeting is marked only after the notes land")
        XCTAssertEqual(steps.steps.last, .submitting)
    }

    // MARK: Quit

    /// Quit during a device stop waits as long as the stop itself may take, so the transcript is
    /// written before the app exits; a cloud stop keeps the finalize window.
    func test_quitDeadline_coversLocalTranscription_onlyWhenTheAudioStaysOnThisMac() {
        XCTAssertEqual(CaptureSession.quitDeadline(audioMayLeaveMac: true, elapsedSeconds: 3_600), 65)
        XCTAssertEqual(CaptureSession.quitDeadline(audioMayLeaveMac: false, elapsedSeconds: 600), 255)
        XCTAssertEqual(CaptureSession.quitDeadline(audioMayLeaveMac: false, elapsedSeconds: 3_600), 435)
        XCTAssertEqual(CaptureSession.quitDeadline(audioMayLeaveMac: false, elapsedSeconds: 3_600, finalizeTimeout: 10), 385)
        for elapsed in [0.0, 1_800, 7_200, 21_600] {
            XCTAssertGreaterThan(
                CaptureSession.quitDeadline(audioMayLeaveMac: false, elapsedSeconds: elapsed),
                CaptureSession.localTranscriptionTimeout(durationSeconds: elapsed) + CaptureSession.finalizeTimeout,
                "\(elapsed)s: quit must outlast the slowest device stop")
        }
    }

    /// The server rejects duration_seconds 0, so a stop with no frames makes no request at all.
    func test_aStopWithNoRecordedFrames_failsClearly_withoutAnyRequest() async throws {
        let transport = RecordingTransport()
        do {
            _ = try await CaptureSession.finishOnDevice(
                meetingId: DeviceFixtures.meetingId, directory: dir, tail: [], durationSeconds: 0,
                transcriber: await startedTranscriber(), transport: transport, recapOpened: false, sleep: { _ in })
            XCTFail("a zero-length recording must not be submitted")
        } catch {
            guard case .nothingRecorded? = error as? CaptureSession.CaptureError else { return XCTFail("got \(error)") }
        }
        XCTAssertEqual(transport.log, [])
        XCTAssertTrue(dirExists)
    }

    func test_localTranscriptionTimeout_scalesWithTheMeeting_withAThreeMinuteFloor() {
        XCTAssertEqual(CaptureSession.localTranscriptionTimeout(durationSeconds: 0), 180)
        XCTAssertEqual(CaptureSession.localTranscriptionTimeout(durationSeconds: 1_800), 180)
        XCTAssertEqual(CaptureSession.localTranscriptionTimeout(durationSeconds: 3_600), 360)
        XCTAssertEqual(CaptureSession.localTranscriptionTimeout(durationSeconds: 21_600), 2_160)
    }

    /// A wedged engine ends in a retryable error, never an endless finishing spinner.
    func test_aWedgedEngine_endsInATimedOutError_withinTheBound_keepingTheDirectory() async throws {
        let engine = ScriptedEngine(DeviceFixtures.fixtureEngine, hanging: ["seg-1-me.m4a"])
        let local = await startedTranscriber(engine)
        let transport = RecordingTransport()
        let outcome = OutcomeBox()
        Task {
            do {
                _ = try await CaptureSession.finishOnDevice(
                    meetingId: DeviceFixtures.meetingId, directory: dir,
                    tail: [DeviceFixtures.segment(1, in: dir, start: 300)], durationSeconds: DeviceFixtures.fixtureDuration,
                    transcriber: local, transport: transport, recapOpened: false, transcribeTimeout: 0.5, sleep: { _ in })
                outcome.set(nil)
            } catch {
                outcome.set(error)
            }
        }
        let settled = await eventually(timeout: 5) { outcome.settled }
        XCTAssertTrue(settled, "the stop must settle within the injected bound, not hang")
        guard case .localTranscriptionTimedOut? = outcome.error as? CaptureSession.CaptureError else {
            return XCTFail("got \(String(describing: outcome.error))")
        }
        XCTAssertFalse(transport.log.contains("mark") || transport.log.contains("submit"),
                       "a timed-out stop never strands the server meeting as pending; got \(transport.log)")
        XCTAssertTrue(dirExists)
    }

    /// A timed-out stop must not leave the wedged call running and ~600 MB of model resident.
    func test_aTimedOutStop_cancelsTheWedgedEngineCall_andUnloadsTheModel() async throws {
        let engine = ScriptedEngine(DeviceFixtures.fixtureEngine, hanging: ["seg-1-me.m4a"])
        let local = await startedTranscriber(engine)
        let outcome = OutcomeBox()
        Task {
            do {
                _ = try await CaptureSession.finishOnDevice(
                    meetingId: DeviceFixtures.meetingId, directory: dir,
                    tail: [DeviceFixtures.segment(1, in: dir, start: 300)], durationSeconds: DeviceFixtures.fixtureDuration,
                    transcriber: local, transport: RecordingTransport(), recapOpened: false, transcribeTimeout: 0.5, sleep: { _ in })
                outcome.set(nil)
            } catch {
                outcome.set(error)
            }
        }
        let settled = await eventually(timeout: 5) { outcome.settled }
        XCTAssertTrue(settled)
        let cancelled = await eventually { engine.cancelled == ["seg-1-me.m4a"] }
        XCTAssertTrue(cancelled, "the wedged engine call is cancelled; got \(engine.cancelled)")
        let unloaded = await eventually { await local.isEngineLoaded == false }
        XCTAssertTrue(unloaded, "the timed-out transcriber drops its engine")
    }

    func test_boundedTranscription_cancelsItsTimer_onceTheWorkFinishes() async throws {
        let timerCancelled = OutcomeBox()
        let transcript = try await CaptureSession.transcribeBounded(seconds: 60, timer: { _ in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch {
                timerCancelled.set(nil)
                throw error
            }
        }) {
            DeviceTranscript.build(source: DeviceFixtures.source, language: "en", durationSeconds: 1, segments: [])
        }
        XCTAssertEqual(transcript.outcome, "no_speech")
        let cancelled = await eventually(timeout: 2) { timerCancelled.settled }
        XCTAssertTrue(cancelled, "the timeout timer must not outlive the work")
    }

    func test_anEngineFailure_failsTheStop_withoutAnyRequest_andKeepsTheDirectory() async throws {
        let transport = RecordingTransport()
        do {
            _ = try await finish(await startedTranscriber(
                ScriptedEngine(DeviceFixtures.fixtureEngine, failing: ["seg-0-them.m4a", "seg-1-them.m4a"])), transport)
            XCTFail("a failed engine must fail the stop")
        } catch {}
        XCTAssertFalse(transport.log.contains("mark") || transport.log.contains("submit"), "no mark, no submit; got \(transport.log)")
        XCTAssertTrue(dirExists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(CaptureRecovery.transcriptName).path))
    }

    /// A step from a device stop that already ended must never paint the next meeting's finishing view.
    @MainActor
    func test_aStepFromAnEndedStop_neverUpdatesTheFinishingStep() async {
        let session = CaptureSession()
        let first = session.finishingStepReporter()
        await first(.preparingModel)
        XCTAssertEqual(session.finishingStep, .preparingModel, "the live stop reports its step")
        session.endFinishing()
        XCTAssertNil(session.finishingStep)
        await first(.transcribing(completed: 1, total: 2))
        XCTAssertNil(session.finishingStep, "a late step from the ended stop is dropped")

        let second = session.finishingStepReporter()
        await second(.submitting)
        XCTAssertEqual(session.finishingStep, .submitting)
        await first(.transcribing(completed: 2, total: 2))
        XCTAssertEqual(session.finishingStep, .submitting, "the ended stop cannot overwrite the current one")
    }

    func test_aTranscriptThatCannotFit_failsAsTooLarge_withoutSubmitting() async throws {
        let long = String(repeating: "x", count: 1_999)
        let results = Dictionary(uniqueKeysWithValues: (0..<301).map { i in
            ("seg-\(i)-\(i % 2 == 0 ? "me" : "them").m4a", [DeviceFixtures.speech(0, 0.5, long, 0.9)])
        })
        let local = LocalTranscriber(source: DeviceFixtures.source, language: "en",
                                     loadEngine: LoadGate(open: true).loader(ScriptedEngine(results)))
        await local.startLoading()
        for i in 0..<300 { local.enqueue(DeviceFixtures.segment(i, in: dir, start: Double(i))) }
        let transport = RecordingTransport()
        do {
            _ = try await CaptureSession.finishOnDevice(
                meetingId: DeviceFixtures.meetingId, directory: dir,
                tail: [DeviceFixtures.segment(300, in: dir, start: 300)], durationSeconds: 400,
                transcriber: local, transport: transport, recapOpened: false, sleep: { _ in })
            XCTFail("must throw")
        } catch {
            guard case .transcriptTooLarge? = error as? CaptureSession.CaptureError else { return XCTFail("got \(error)") }
        }
        XCTAssertEqual(transport.log, [], "a transcript that cannot fit never marks the meeting pending")
        XCTAssertTrue(dirExists)
    }

    func test_cancellingDuringBackoff_makesNoFurtherAttempts() async throws {
        let transport = RecordingTransport(submitStatuses: [409])
        let sleeps = SleepLog()
        let submitting = Task {
            try await CaptureSession.submitDeviceTranscript(
                meetingId: DeviceFixtures.meetingId, body: Data("{}".utf8), transport: transport,
                sleep: { seconds in
                    sleeps.record(seconds)
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                })
        }
        let waiting = await eventually { sleeps.waits.count == 1 }
        XCTAssertTrue(waiting)
        submitting.cancel()
        let started = Date()
        let result = await submitting.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        if case .success = result { XCTFail("a cancelled submit must not report success") }
        XCTAssertEqual(transport.submits, 1, "no attempt after cancellation")
    }
}

final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _error: Error?
    private var _settled = false
    var error: Error? { lock.withLock { _error } }
    var settled: Bool { lock.withLock { _settled } }
    func set(_ error: Error?) { lock.withLock { _error = error; _settled = true } }
}
