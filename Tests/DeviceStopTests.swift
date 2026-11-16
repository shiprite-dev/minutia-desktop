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

    func test_deviceStop_marksTheMeetingBeforeTheSubmitCanClaimIt() async throws {
        let transport = RecordingTransport(markDelay: 0.3)
        _ = try await finish(await startedTranscriber(), transport)
        XCTAssertEqual(transport.log.first, "mark", "a pending mark landing after the submit would reopen a completed meeting; got \(transport.log)")
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
        XCTAssertEqual(transport.submits, 0, "nothing is submitted before the model has transcribed")
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

    func test_aFailedSubmit_surfacesAsTranscriptNotSent() async throws {
        for transport in [RecordingTransport(submitStatuses: [400]), RecordingTransport(failure: URLError(.cannotConnectToHost))] {
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
        XCTAssertEqual(transport.submits, 0)
        XCTAssertTrue(dirExists)
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
        XCTAssertEqual(transport.submits, 0)
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
