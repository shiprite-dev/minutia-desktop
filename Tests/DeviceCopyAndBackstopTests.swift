import XCTest
@testable import Minutia

/// What a device meeting tells the user, and the structural guards that keep its audio on this Mac.
/// Device meetings say what actually happens ("Transcribing on this Mac"); cloud meetings keep their
/// upload copy; an Automatic meeting that fell back to the cloud may say it is uploading, because it is.
final class DeviceCopyAndBackstopTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try DeviceFixtures.tempDir("device-copy")
        try Data([0]).write(to: dir.appendingPathComponent(CaptureRecovery.recordingName))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private var dirExists: Bool { FileManager.default.fileExists(atPath: dir.path) }

    private func assertNoUpload(_ text: String, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let lowered = text.lowercased()
        XCTAssertFalse(lowered.contains("upload"), "\(context): \(text)", file: file, line: line)
        XCTAssertFalse(lowered.contains("sending the recording") || lowered.contains("sending audio"),
                       "\(context): \(text)", file: file, line: line)
    }

    // MARK: Finishing view

    func test_finishingLabel_perStep_forDeviceAndCloudMeetings() {
        let rows: [(CaptureSession.FinishingStep?, Bool, String)] = [
            (nil, true, "Uploading and requesting transcript"),
            (nil, false, "Transcribing on this Mac"),
            (.uploadingRecording, true, "Uploading and requesting transcript"),
            (.uploadingRecording, false, "Uploading and requesting transcript"),
            (.startingOnDevice, false, "Transcribing on this Mac"),
            (.fallingBackToCloud, false, "Couldn't transcribe on this Mac. Uploading instead."),
            (.preparingModel, false, "Preparing the speech model"),
            (.transcribing(completed: 2, total: 5), false, "Transcribing on this Mac, 2 of 5"),
            (.submitting, false, "Sending the transcript"),
        ]
        for (step, audioMayLeaveMac, expected) in rows {
            XCTAssertEqual(CaptureSession.finishingLabel(step: step, audioMayLeaveMac: audioMayLeaveMac), expected,
                           "\(String(describing: step)) audioMayLeaveMac=\(audioMayLeaveMac)")
        }
    }

    func test_everyDeviceFinishingLabel_neverMentionsUploading() {
        let deviceSteps: [CaptureSession.FinishingStep?] = [
            nil, .startingOnDevice, .preparingModel, .transcribing(completed: 0, total: 3), .submitting,
        ]
        for step in deviceSteps {
            assertNoUpload(CaptureSession.finishingLabel(step: step, audioMayLeaveMac: false), "\(String(describing: step))")
        }
    }

    @MainActor
    func test_aDeviceStop_showsTheDeviceStepFromItsFirstFrame_neverTheCloudUploadingCopy() {
        let session = CaptureSession()
        session.beginFinishing(audioMayLeaveMac: false)
        XCTAssertEqual(session.finishingStep, .startingOnDevice, "set synchronously, before any await")
        XCTAssertEqual(CaptureSession.finishingLabel(step: session.finishingStep, audioMayLeaveMac: false),
                       "Transcribing on this Mac")
    }

    @MainActor
    func test_aCloudStop_showsTheUploadingStepFromItsFirstFrame() {
        let session = CaptureSession()
        session.beginFinishing(audioMayLeaveMac: true)
        XCTAssertEqual(session.finishingStep, .uploadingRecording)
        XCTAssertEqual(CaptureSession.finishingLabel(step: session.finishingStep, audioMayLeaveMac: true),
                       "Uploading and requesting transcript")
    }

    @MainActor
    func test_theFirstStep_isReplacedByTheReportedSteps_andClearedWhenTheStopEnds() async {
        let session = CaptureSession()
        session.beginFinishing(audioMayLeaveMac: false)
        let report = session.finishingStepReporter()
        await report(.transcribing(completed: 1, total: 3))
        XCTAssertEqual(session.finishingStep, .transcribing(completed: 1, total: 3))
        session.endFinishing()
        XCTAssertNil(session.finishingStep)
        await report(.submitting)
        XCTAssertNil(session.finishingStep, "the ended stop cannot bring its step back")
    }

    // MARK: Automatic fallback step

    private func qualityGuardTranscriber() async -> LocalTranscriber {
        let local = LocalTranscriber(source: DeviceFixtures.source, language: "en", guardFloor: DeviceFixtures.ultra.guardFloor,
                                     loadEngine: LoadGate(open: true).loader(DeviceFixtures.meetingEngine(4, lowConfidence: [0, 1])))
        await local.startLoading()
        for seq in 0..<3 { local.enqueue(DeviceFixtures.segment(seq, in: dir)) }
        return local
    }

    private func finishOnDevice(_ local: LocalTranscriber, deviceOnly: Bool, transport: RecordingTransport, cloud: RecordingCloud,
                                steps: StepLog, flushNotes: @escaping @Sendable () async throws -> Void = {},
                                notesFlushTimeout: TimeInterval = CaptureSession.notesFlushTimeout) async throws -> CaptureSession.StopResult {
        try await CaptureSession.finishOnDevice(
            meetingId: DeviceFixtures.meetingId, directory: dir, tail: [DeviceFixtures.segment(3, in: dir)],
            durationSeconds: 1_200, transcriber: local, transport: transport, recapOpened: true,
            deviceOnly: deviceOnly, cloud: cloud, notesFlushTimeout: notesFlushTimeout, sleep: { _ in },
            flushNotes: flushNotes, onStep: { steps.record($0) })
    }

    func test_automatic_aFallbackToTheCloud_saysItIsUploading_onceTheLocalWorkStops() async throws {
        let steps = StepLog()
        let cloud = RecordingCloud()
        let result = try await finishOnDevice(await qualityGuardTranscriber(), deviceOnly: false,
                                              transport: RecordingTransport(), cloud: cloud, steps: steps)
        XCTAssertEqual(result.localFailure, .qualityGuard)
        XCTAssertEqual(steps.steps.last, .fallingBackToCloud, "got \(steps.steps)")
        XCTAssertEqual(cloud.log, ["uploadRecording", "finalizeMeeting", "requestTranscription"])
    }

    func test_onThisMacOnly_aLocalFailure_neverShowsAnUploadingStep() async throws {
        let steps = StepLog()
        let cloud = RecordingCloud()
        do {
            _ = try await finishOnDevice(await qualityGuardTranscriber(), deviceOnly: true,
                                         transport: RecordingTransport(), cloud: cloud, steps: steps)
            XCTFail("On this Mac only cannot finish a failed local transcription")
        } catch {}
        XCTAssertFalse(steps.steps.contains(.uploadingRecording) || steps.steps.contains(.fallingBackToCloud), "got \(steps.steps)")
        XCTAssertEqual(cloud.log, [])
    }

    func test_recovery_ofAnAutomaticMeetingThatGoesToTheCloud_saysItIsUploading() async throws {
        try AudioFixtures.writeFragmentedM4A(to: dir.appendingPathComponent(CaptureRecovery.recordingName), seconds: 2)
        let manifest = CaptureManifest(
            meetingId: DeviceFixtures.meetingId, seriesId: nil, instanceURL: URL(string: "https://minutia.example.com")!,
            userId: "u1", createdAt: Date(timeIntervalSince1970: 0), transcriptionMode: .device, deviceOnly: false,
            language: "en", localFailed: true)
        CaptureRecovery.saveManifest(manifest, to: dir)
        let steps = StepLog()
        let cloud = RecordingCloud()
        try await CaptureRecovery.recoverDeviceMeeting(
            directory: dir, manifest: manifest, transport: RecordingTransport(), cloud: cloud, sleep: { _ in },
            onStep: { steps.record($0) })
        XCTAssertEqual(cloud.log, ["uploadRecording", "finalizeMeeting", "requestTranscription"])
        XCTAssertEqual(steps.steps, [.fallingBackToCloud])
    }

    // MARK: Recording view

    func test_recordingProgressLine_namesTheUploadOnlyForCloudMeetings() {
        XCTAssertEqual(RecordingView.progressLine(uploaded: 2, total: 3, audioMayLeaveMac: true, deviceOnly: false), "2 of 3 segments uploaded")
        let automatic = RecordingView.progressLine(uploaded: 0, total: 3, audioMayLeaveMac: false, deviceOnly: false)
        XCTAssertEqual(automatic, "Transcribing on this Mac as you record", "Automatic promises nothing a later fallback could break")
        let onThisMacOnly = RecordingView.progressLine(uploaded: 0, total: 3, audioMayLeaveMac: false, deviceOnly: true)
        XCTAssertEqual(onThisMacOnly, "Transcribing as you record. Audio stays on this Mac.")
        assertNoUpload(automatic, "recording view")
        assertNoUpload(onThisMacOnly, "recording view")
    }

    // MARK: Quit alert

    func test_quitAlertUploads_followsTheMeetingAndItsCloudFallback() {
        XCTAssertEqual(AppController.quitAlertUploads(phase: .recording, audioMayLeaveMac: true, step: nil), true)
        XCTAssertEqual(AppController.quitAlertUploads(phase: .finalizing, audioMayLeaveMac: false, step: .startingOnDevice), false)
        XCTAssertEqual(AppController.quitAlertUploads(phase: .finalizing, audioMayLeaveMac: false, step: .fallingBackToCloud), true)
        XCTAssertNil(AppController.quitAlertUploads(phase: .idle, audioMayLeaveMac: false, step: nil))
    }

    func test_quitAlert_perMeetingKind() {
        let cloud = AppController.quitAlert(capturingAudioMayLeaveMac: true)
        XCTAssertEqual(cloud.title, "Finishing upload")
        XCTAssertEqual(cloud.message, "Minutia is still finishing a recording upload. Finish and quit, or keep it running?")

        let device = AppController.quitAlert(capturingAudioMayLeaveMac: false)
        XCTAssertEqual(device.title, "Finishing transcription")
        XCTAssertEqual(device.message, "Minutia is still transcribing a meeting on this Mac. Finish and quit, or keep it running?")

        let recoveryOnly = AppController.quitAlert(capturingAudioMayLeaveMac: nil)
        XCTAssertEqual(recoveryOnly.title, "Finishing a recording")
        XCTAssertEqual(recoveryOnly.message, "Minutia is still finishing a previous recording. Finish and quit, or keep it running?")

        for alert in [device, recoveryOnly] {
            assertNoUpload(alert.title, "quit title")
            assertNoUpload(alert.message, "quit message")
        }
    }

    // MARK: Recovery row and notification

    /// The sweep can be finishing device and cloud meetings at once, so the row names neither.
    func test_recoveryRow_neverMentionsUploading() {
        XCTAssertEqual(AppController.recoveryRowLabel, "Finishing a previous recording…")
        assertNoUpload(AppController.recoveryRowLabel, "recovery row")
    }

    // MARK: Failure and Retry messages

    func test_aTimedOutFinish_ofADeviceMeeting_neverSaysUploading_andACloudMeetingKeepsItsCopy() {
        XCTAssertEqual(AppController.finalizeFailureMessage(for: TimeoutError(), host: "minutia.example.com", audioMayLeaveMac: true),
                       "Finishing the recording timed out. Your audio is saved locally; Retry to finish uploading.")
        XCTAssertEqual(AppController.finalizeFailureMessage(for: TimeoutError(), host: "minutia.example.com", audioMayLeaveMac: false),
                       "Finishing the recording timed out. Your audio is saved on this Mac. Retry to finish.")
        XCTAssertEqual(AppController.refinalizeOutcome(for: TimeoutError(), host: "minutia.example.com", audioMayLeaveMac: false),
                       .failed("Finishing the recording timed out. Your audio is saved on this Mac. Retry to finish."))
    }

    func test_everyFailureMessage_forADeviceMeeting_neverMentionsUploading() {
        let errors: [Error] = [
            TimeoutError(), URLError(.cannotConnectToHost), MinutiaClientError.featureUnavailable,
            CaptureSession.CaptureError.transcriptNotSent, CaptureSession.CaptureError.transcriptRejected,
            CaptureSession.CaptureError.localTranscriptionTimedOut, CaptureSession.CaptureError.transcriptTooLarge,
            CaptureSession.CaptureError.nothingRecorded, CaptureRecovery.RecoveryError.transcriptNotFinished,
            CaptureRecovery.RecoveryError.audioStaysOnThisMac, LocalTranscriber.Failure.qualityGuard,
        ]
        for error in errors {
            assertNoUpload(AppController.finalizeFailureMessage(for: error, host: "minutia.example.com", audioMayLeaveMac: false),
                           "finalize \(error)")
            if case .failed(let message) = AppController.refinalizeOutcome(for: error, host: "minutia.example.com", audioMayLeaveMac: false) {
                assertNoUpload(message, "refinalize \(error)")
            }
        }
    }

    // MARK: Structural backstop

    private final class FastLaneLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _enqueued: [Int] = []
        private var _drains = 0
        var enqueued: [Int] { lock.withLock { _enqueued } }
        var drains: Int { lock.withLock { _drains } }
        func enqueue(_ segment: SegmentWriter.ClosedSegment) { lock.withLock { _enqueued.append(segment.seq) } }
        func drain() { lock.withLock { _drains += 1 } }
    }

    private func fastLane(audioMayLeaveMac: Bool, cloud: RecordingCloud, log: FastLaneLog,
                          counts: (uploaded: Int, registered: Int, failed: Int, enqueued: Int) = (3, 3, 0, 3),
                          segmentsDropped: Bool = false) async throws -> Int? {
        try await CaptureSession.finishFastLane(
            audioMayLeaveMac: audioMayLeaveMac, meetingId: DeviceFixtures.meetingId,
            recording: dir.appendingPathComponent(CaptureRecovery.recordingName), durationSeconds: 900,
            tail: [DeviceFixtures.segment(2, in: dir)], segmentsDropped: segmentsDropped,
            enqueue: { log.enqueue($0) }, drain: { log.drain(); return counts }, cloud: cloud).expected
    }

    /// Even if routing state were wrong and the device branch were skipped, a stop whose audio may not
    /// leave the Mac never enqueues a segment, drains the upload queue, or touches the cloud.
    func test_fastLane_withAudioThatMustStayOnThisMac_refusesBeforeAnyUpload() async {
        let cloud = RecordingCloud()
        let log = FastLaneLog()
        do {
            _ = try await fastLane(audioMayLeaveMac: false, cloud: cloud, log: log)
            XCTFail("a device stop must never run the fast-lane upload")
        } catch {
            XCTAssertEqual(error as? CaptureRecovery.RecoveryError, .audioStaysOnThisMac, "got \(error)")
        }
        XCTAssertEqual(cloud.log, [], "no upload, finalize or transcribe request")
        XCTAssertEqual(log.enqueued, [], "no segment handed to the upload queue")
        XCTAssertEqual(log.drains, 0)
        XCTAssertTrue(dirExists)
    }

    func test_fastLane_forACloudMeeting_enqueuesTheTail_uploads_finalizes_andAnnouncesTheRegisteredSegments() async throws {
        let cloud = RecordingCloud()
        let log = FastLaneLog()
        let expected = try await fastLane(audioMayLeaveMac: true, cloud: cloud, log: log)
        XCTAssertEqual(expected, 3)
        XCTAssertEqual(log.enqueued, [2])
        XCTAssertEqual(log.drains, 1)
        XCTAssertEqual(cloud.log, ["uploadRecording", "finalizeMeeting", "requestTranscription"])
        XCTAssertEqual(cloud.expectedSegments, [3])
        XCTAssertEqual(cloud.strict, [false], "a 503 still counts: the transcript assembles from fast-lane segments")
    }

    func test_fastLane_withDroppedSegments_announcesNone() async throws {
        let cloud = RecordingCloud()
        let expected = try await fastLane(audioMayLeaveMac: true, cloud: cloud, log: FastLaneLog(), segmentsDropped: true)
        XCTAssertNil(expected)
        XCTAssertEqual(cloud.expectedSegments, [nil])
    }

    /// A notes flush that never returns (and ignores cancellation) cannot hold the device stop past its bound.
    func test_aNotesFlushThatNeverReturns_doesNotBlockTheDeviceStop() async throws {
        let notesGate = LoadGate()
        defer { notesGate.open() }
        let holdNotes = notesGate.loader(ScriptedEngine())
        let local = LocalTranscriber(source: DeviceFixtures.source, language: "en",
                                     loadEngine: LoadGate(open: true).loader(ScriptedEngine(DeviceFixtures.fixtureEngine)))
        await local.startLoading()
        local.enqueue(DeviceFixtures.segment(0, in: dir))
        let transport = RecordingTransport()
        let box = ResultHolder()
        let directory = dir!
        Task {
            do {
                box.set(.success(try await CaptureSession.finishOnDevice(
                    meetingId: DeviceFixtures.meetingId, directory: directory,
                    tail: [DeviceFixtures.segment(1, in: directory, start: 300)], durationSeconds: DeviceFixtures.fixtureDuration,
                    transcriber: local, transport: transport, recapOpened: true, notesFlushTimeout: 0.3, sleep: { _ in },
                    flushNotes: { _ = try await holdNotes() })))
            } catch {
                box.set(.failure(error))
            }
        }
        let settled = await eventually(timeout: 5) { box.result != nil }
        XCTAssertTrue(settled, "the stop settles soon after the 0.3s notes bound")
        guard case .success(let result)? = box.result else { return XCTFail("got \(String(describing: box.result))") }
        XCTAssertTrue(result.transcriptRequested)
        XCTAssertEqual(notesGate.loads, 1, "the flush was attempted")
        XCTAssertEqual(transport.submits, 1)
    }

    func test_automatic_aNotesFlushThatNeverReturns_doesNotBlockTheCloudFallback() async throws {
        let notesGate = LoadGate()
        defer { notesGate.open() }
        let holdNotes = notesGate.loader(ScriptedEngine())
        let local = await qualityGuardTranscriber()
        let cloud = RecordingCloud()
        let box = ResultHolder()
        Task {
            do {
                box.set(.success(try await self.finishOnDevice(local, deviceOnly: false, transport: RecordingTransport(), cloud: cloud,
                                                               steps: StepLog(), flushNotes: { _ = try await holdNotes() },
                                                               notesFlushTimeout: 0.3)))
            } catch {
                box.set(.failure(error))
            }
        }
        let settled = await eventually(timeout: 5) { box.result != nil }
        XCTAssertTrue(settled, "the fallback settles soon after the 0.3s notes bound")
        guard case .success? = box.result else { return XCTFail("got \(String(describing: box.result))") }
        XCTAssertEqual(cloud.log, ["uploadRecording", "finalizeMeeting", "requestTranscription"])
    }

    // MARK: Provenance of a cloud fallback

    /// The server writes `transcription_provider` and `transcription_model` itself when the transcribe
    /// route runs. The desktop must not leave the meeting marked as a device transcript, and the
    /// transcribe request carries no provider, model or source of its own that could contradict it.
    func test_automatic_aCloudFallback_neverMarksTheMeetingAsADeviceTranscript_andSendsNoProvenanceOfItsOwn() async throws {
        let transport = RecordingTransport()
        _ = try await finishOnDevice(await qualityGuardTranscriber(), deviceOnly: false, transport: transport,
                                     cloud: RecordingCloud(), steps: StepLog())
        XCTAssertEqual(transport.marks, [], "the transcription_provider 'device' marker is never written before a fallback")
        XCTAssertFalse(transport.log.contains("submit"))

        let request = MinutiaClient.finalTranscribeRequest(
            instance: URL(string: "https://minutia.example.com")!, meetingId: DeviceFixtures.meetingId,
            expectedSegments: nil, deferExtraction: true, token: "t")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["defer_extraction"])
    }
}

private final class ResultHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _result: Result<CaptureSession.StopResult, Error>?
    var result: Result<CaptureSession.StopResult, Error>? { lock.withLock { _result } }
    func set(_ result: Result<CaptureSession.StopResult, Error>) { lock.withLock { _result = result } }
}
