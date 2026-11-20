import XCTest
@testable import Minutia

/// What a device-mode stop does when local transcription fails, per setting. Automatic hands the
/// meeting to the existing cloud finalize over `recording.m4a`; On this Mac only keeps everything on
/// disk and tells the user once. Both doubles log every call, so an empty `RecordingCloud.log` means
/// no audio left the Mac.
final class DeviceFallbackTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { try freshDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func freshDirectory() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        dir = try DeviceFixtures.tempDir("device-fallback")
        try Data([0]).write(to: dir.appendingPathComponent(CaptureRecovery.recordingName))
    }

    private var dirExists: Bool { FileManager.default.fileExists(atPath: dir.path) }
    private var recordingExists: Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(CaptureRecovery.recordingName).path)
    }

    /// One way local transcription can fail, and the failure it must be reported as.
    private struct Breakage {
        let label: String
        let engine: ScriptedEngine
        let segments: Int
        var loadFailure: Error? = nil
        var loadTimeout: TimeInterval = LocalTranscriber.loadTimeoutSeconds
        var gate = LoadGate(open: true)
        let expected: LocalTranscriber.Failure
        /// Audio files the engine must never be asked to transcribe.
        var untouched: [String] = []
    }

    private var breakages: [Breakage] {
        [
            Breakage(label: "the model fails to load", engine: DeviceFixtures.meetingEngine(3), segments: 3,
                     loadFailure: CocoaError(.fileReadCorruptFile), expected: .modelLoad),
            Breakage(label: "the model load runs past its timeout", engine: DeviceFixtures.meetingEngine(3), segments: 3,
                     loadTimeout: 0.3, gate: LoadGate(), expected: .modelLoadTimedOut),
            Breakage(label: "the quality guard trips", engine: DeviceFixtures.meetingEngine(4, lowConfidence: [0, 1]),
                     segments: 4, expected: .qualityGuard),
            Breakage(label: "the first four segments all fail", engine: DeviceFixtures.meetingEngine(8, failing: [0, 1, 2, 3]),
                     segments: 8, expected: .qualityGuard,
                     untouched: (4..<8).flatMap { ["seg-\($0)-me.m4a", "seg-\($0)-them.m4a"] }),
        ]
    }

    private func transcriber(_ engine: ScriptedEngine, gate: LoadGate = LoadGate(open: true), loadFailure: Error? = nil,
                             loadTimeout: TimeInterval = LocalTranscriber.loadTimeoutSeconds) -> LocalTranscriber {
        LocalTranscriber(source: DeviceFixtures.source, language: "en", guardFloor: DeviceFixtures.ultra.guardFloor,
                         loadTimeout: loadTimeout, loadEngine: gate.loader(engine, failure: loadFailure))
    }

    /// Records segments 0 to count-2, then stops with the last as the tail. Never hangs: a stop that
    /// does not settle within `within` seconds fails the test.
    private func stop(_ local: LocalTranscriber, segments count: Int, deviceOnly: Bool, transport: RecordingTransport,
                      cloud: RecordingCloud, failures: FailureLog = FailureLog(), outcomes: OutcomeLog = OutcomeLog(),
                      transcribeTimeout: TimeInterval? = nil,
                      within seconds: TimeInterval = 10) async -> Result<CaptureSession.StopResult, Error>? {
        await local.startLoading()
        for seq in 0..<(count - 1) { local.enqueue(DeviceFixtures.segment(seq, in: dir)) }
        let directory = dir!
        let box = ResultBox()
        Task {
            do {
                box.set(.success(try await CaptureSession.finishOnDevice(
                    meetingId: DeviceFixtures.meetingId, directory: directory,
                    tail: [DeviceFixtures.segment(count - 1, in: directory)], durationSeconds: Double(count) * 300,
                    transcriber: local, transport: transport, deviceOnly: deviceOnly, cloud: cloud, transcribeTimeout: transcribeTimeout, sleep: { _ in },
                    notifyLocalFailure: { failures.record($0) }, onLocalOutcome: { outcomes.record($0) })))
            } catch {
                box.set(.failure(error))
            }
        }
        let settled = await eventually(timeout: seconds) { box.result != nil }
        XCTAssertTrue(settled, "the stop must settle within \(seconds)s")
        return box.result
    }

    private func texts(_ body: Data?) throws -> [String] {
        try JSONDecoder().decode(DeviceTranscript.self, from: try XCTUnwrap(body)).segments.map(\.text)
    }

    // MARK: Automatic falls back to the cloud

    func test_automatic_aLocalFailure_sendsTheRecordingOnDiskThroughTheCloudFinalize() async throws {
        for breakage in breakages {
            try freshDirectory()
            let recording = dir.appendingPathComponent(CaptureRecovery.recordingName)
            let transport = RecordingTransport()
            let cloud = RecordingCloud()
            let local = transcriber(breakage.engine, gate: breakage.gate, loadFailure: breakage.loadFailure,
                                    loadTimeout: breakage.loadTimeout)
            let outcome = await stop(local, segments: breakage.segments, deviceOnly: false, transport: transport, cloud: cloud)
            breakage.gate.open()

            guard case .success(let result)? = outcome else {
                XCTFail("\(breakage.label): Automatic must finish in the cloud, got \(String(describing: outcome))")
                continue
            }
            XCTAssertTrue(result.transcriptRequested, breakage.label)
            XCTAssertEqual(result.localFailure, breakage.expected, breakage.label)
            XCTAssertEqual(cloud.log, ["uploadRecording", "finalizeMeeting", "requestTranscription"], breakage.label)
            XCTAssertEqual(cloud.uploaded, [recording], "\(breakage.label): the full recording still on disk is what goes up")
            XCTAssertEqual(cloud.expectedSegments, [nil], "\(breakage.label): no fast-lane segments were registered")
            XCTAssertFalse(transport.log.contains("mark") || transport.log.contains("submit"),
                           "\(breakage.label): a failed local transcript is never marked or sent; got \(transport.log)")
            XCTAssertFalse(dirExists, "\(breakage.label): the cloud 2xx deletes the capture directory")
            XCTAssertTrue(Set(breakage.engine.calls).isDisjoint(with: breakage.untouched),
                          "\(breakage.label): the early abort skips the rest; got \(breakage.engine.calls)")
        }
    }

    func test_automatic_aCloudFallbackThatFails_keepsTheRecording_andThrows() async throws {
        let transport = RecordingTransport()
        let cloud = RecordingCloud(failure: URLError(.cannotConnectToHost))
        let local = transcriber(DeviceFixtures.meetingEngine(4, lowConfidence: [0, 1]))
        let outcome = await stop(local, segments: 4, deviceOnly: false, transport: transport, cloud: cloud)

        guard case .failure? = outcome else { return XCTFail("an unsent fallback must throw, got \(String(describing: outcome))") }
        XCTAssertEqual(cloud.log, ["uploadRecording"])
        XCTAssertTrue(dirExists, "no server 2xx, so the directory stays")
        XCTAssertTrue(recordingExists)
        XCTAssertFalse(transport.log.contains("submit"))
    }

    /// The server answers 503 when transcription is not configured, has no API key or fails provider
    /// auth. A device meeting has no fast-lane segments to assemble a transcript from, so a 503 is a
    /// failure here: deleting the directory would lose the only copy of the meeting.
    func test_automatic_aCloudFallbackTheServerCannotTranscribe_keepsTheRecording_andThrows() async throws {
        for status in [503, 401, 500] {
            try freshDirectory()
            let transport = RecordingTransport()
            let cloud = RecordingCloud(transcribeStatus: status)
            let local = transcriber(DeviceFixtures.meetingEngine(4, lowConfidence: [0, 1]))
            let outcome = await stop(local, segments: 4, deviceOnly: false, transport: transport, cloud: cloud)

            guard case .failure? = outcome else {
                XCTFail("status \(status): an untranscribed fallback must throw, got \(String(describing: outcome))")
                continue
            }
            XCTAssertEqual(cloud.log, ["uploadRecording", "finalizeMeeting", "requestTranscription"], "status \(status)")
            XCTAssertTrue(dirExists, "status \(status): no transcription accepted, so the directory stays")
            XCTAssertTrue(recordingExists, "status \(status)")
        }
    }

    func test_automatic_aLocalTranscriptionTimeout_finishesInTheCloudFromTheRecordingOnDisk() async throws {
        let recording = dir.appendingPathComponent(CaptureRecovery.recordingName)
        let engine = ScriptedEngine(DeviceFixtures.fixtureEngine, hanging: ["seg-1-me.m4a"])
        let transport = RecordingTransport()
        let cloud = RecordingCloud()
        let outcome = await stop(transcriber(engine), segments: 2, deviceOnly: false, transport: transport, cloud: cloud,
                                 transcribeTimeout: 0.5)

        guard case .success(let result)? = outcome else {
            return XCTFail("a timed-out local transcription finishes in the cloud, got \(String(describing: outcome))")
        }
        XCTAssertTrue(result.transcriptRequested)
        XCTAssertEqual(cloud.log, ["uploadRecording", "finalizeMeeting", "requestTranscription"])
        XCTAssertEqual(cloud.uploaded, [recording])
        XCTAssertFalse(transport.log.contains("mark") || transport.log.contains("submit"), "got \(transport.log)")
        XCTAssertFalse(dirExists, "the cloud 2xx deletes the capture directory")
    }

    func test_automatic_aSlowModelLoadUnderTheTimeout_staysOnThisMac() async throws {
        let gate = LoadGate()
        let transport = RecordingTransport()
        let cloud = RecordingCloud()
        let local = transcriber(DeviceFixtures.meetingEngine(2), gate: gate, loadTimeout: 5)
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            gate.open()
        }
        let outcome = await stop(local, segments: 2, deviceOnly: false, transport: transport, cloud: cloud)

        guard case .success(let result)? = outcome else { return XCTFail("got \(String(describing: outcome))") }
        XCTAssertNil(result.localFailure)
        XCTAssertEqual(cloud.log, [], "a slow load is not a failure")
        XCTAssertEqual(transport.submits, 1)
        XCTAssertEqual(try texts(transport.bodies.first), DeviceFixtures.items(2))
    }

    // MARK: On this Mac only never uploads

    func test_onThisMacOnly_aLocalFailure_uploadsNothing_keepsTheDirectory_andNotifiesOnce() async throws {
        for breakage in breakages {
            try freshDirectory()
            let transport = RecordingTransport()
            let cloud = RecordingCloud()
            let failures = FailureLog()
            let local = transcriber(breakage.engine, gate: breakage.gate, loadFailure: breakage.loadFailure,
                                    loadTimeout: breakage.loadTimeout)
            let outcome = await stop(local, segments: breakage.segments, deviceOnly: true, transport: transport,
                                     cloud: cloud, failures: failures)
            breakage.gate.open()

            guard case .failure(let error)? = outcome else {
                XCTFail("\(breakage.label): must throw, got \(String(describing: outcome))")
                continue
            }
            XCTAssertEqual(error as? LocalTranscriber.Failure, breakage.expected, "\(breakage.label): got \(error)")
            XCTAssertEqual(cloud.log, [], "\(breakage.label): no audio egress under On this Mac only")
            XCTAssertFalse(transport.log.contains("mark") || transport.log.contains("submit"),
                           "\(breakage.label): nothing is marked or sent; got \(transport.log)")
            XCTAssertTrue(dirExists, breakage.label)
            XCTAssertTrue(recordingExists, breakage.label)
            XCTAssertEqual(failures.failures, [breakage.expected], "\(breakage.label): exactly one notification")
            XCTAssertTrue(Set(breakage.engine.calls).isDisjoint(with: breakage.untouched),
                          "\(breakage.label): the early abort skips the rest; got \(breakage.engine.calls)")
        }
    }

    func test_onThisMacOnly_aLocalTranscriptionTimeout_uploadsNothing_andKeepsTheDirectory() async throws {
        let engine = ScriptedEngine(DeviceFixtures.fixtureEngine, hanging: ["seg-1-me.m4a"])
        let transport = RecordingTransport()
        let cloud = RecordingCloud()
        let failures = FailureLog()
        let outcome = await stop(transcriber(engine), segments: 2, deviceOnly: true, transport: transport, cloud: cloud,
                                 failures: failures, transcribeTimeout: 0.5)

        guard case .failure(let error)? = outcome, case .localTranscriptionTimedOut? = error as? CaptureSession.CaptureError else {
            return XCTFail("got \(String(describing: outcome))")
        }
        XCTAssertEqual(cloud.log, [], "no audio egress under On this Mac only")
        XCTAssertFalse(transport.log.contains("mark") || transport.log.contains("submit"), "got \(transport.log)")
        XCTAssertTrue(dirExists)
        XCTAssertTrue(recordingExists)
        XCTAssertEqual(failures.failures, [.transcriptionTimedOut], "exactly one notification")
    }

    /// Runs every On this Mac only local failure (each breakage, then a local transcription timeout) in
    /// a fresh directory holding an On this Mac only manifest, handing each row's doubles to `check`.
    private func eachOnThisMacOnlyFailure(
        _ check: (_ label: String, _ transport: RecordingTransport, _ cloud: RecordingCloud, _ failures: FailureLog,
                  _ outcome: Result<CaptureSession.StopResult, Error>?) async throws -> Void
    ) async throws {
        for breakage in breakages {
            try freshDirectory()
            _ = writeManifest(deviceOnly: true)
            let transport = RecordingTransport()
            let cloud = RecordingCloud()
            let failures = FailureLog()
            let local = transcriber(breakage.engine, gate: breakage.gate, loadFailure: breakage.loadFailure,
                                    loadTimeout: breakage.loadTimeout)
            let outcome = await stop(local, segments: breakage.segments, deviceOnly: true, transport: transport,
                                     cloud: cloud, failures: failures)
            breakage.gate.open()
            try await check(breakage.label, transport, cloud, failures, outcome)
        }
        try freshDirectory()
        _ = writeManifest(deviceOnly: true)
        let transport = RecordingTransport()
        let cloud = RecordingCloud()
        let failures = FailureLog()
        let engine = ScriptedEngine(DeviceFixtures.fixtureEngine, hanging: ["seg-1-me.m4a"])
        let outcome = await stop(transcriber(engine), segments: 2, deviceOnly: true, transport: transport, cloud: cloud,
                                 failures: failures, transcribeTimeout: 0.5)
        try await check("local transcription times out", transport, cloud, failures, outcome)
    }

    /// The web shows a meeting live until it is ended. A failed On this Mac only meeting has nothing to
    /// send, so the stop ends it on the server, with no audio and no cloud call, before reporting the failure.
    func test_onThisMacOnly_aLocalFailure_endsTheMeetingOnTheServerOnce_withoutAnyCloudCall() async throws {
        try await eachOnThisMacOnlyFailure { label, transport, cloud, _, outcome in
            guard case .failure? = outcome else { return XCTFail("\(label): must throw, got \(String(describing: outcome))") }
            let ended = await eventually { transport.log.contains("endMeeting") }
            XCTAssertTrue(ended, "\(label): the meeting is ended on the server; got \(transport.log)")
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(transport.log, ["endMeeting"], "\(label): ended once, nothing marked or sent")
            XCTAssertEqual(cloud.log, [], "\(label): no audio egress under On this Mac only")
        }
    }

    /// The stop's one notice is recorded in the manifest, so the launch sweep never posts a second one.
    func test_onThisMacOnly_aLocalFailure_recordsItsOneNoticeInTheManifest() async throws {
        try await eachOnThisMacOnlyFailure { label, _, _, failures, outcome in
            guard case .failure? = outcome else { return XCTFail("\(label): must throw, got \(String(describing: outcome))") }
            XCTAssertEqual(failures.failures.count, 1, "\(label): one notice at stop")
            let manifest = try XCTUnwrap(CaptureRecovery.loadManifest(from: dir), "\(label): the manifest stays")
            XCTAssertTrue(manifest.notified, "\(label): the notice is persisted with the recording")
            XCTAssertEqual(manifest.recoveryAttempts, 0, label)
        }
    }

    /// Cancelling is not failing: a stop whose local work was cancelled reports no local outcome, posts no
    /// notice, counts nothing toward the model re-verify, and sends nothing anywhere.
    func test_aStopWhoseLocalWorkIsCancelled_isNotAFailure_noOutcomeNoNoticeNothingSent() async throws {
        for deviceOnly in [false, true] {
            let rows: [(label: String, local: LocalTranscriber)] = [
                ("the model load is cancelled", transcriber(DeviceFixtures.meetingEngine(3), loadFailure: CancellationError())),
                ("a segment job is cancelled", transcriber(ScriptedEngine(cancelling: ["seg-0-me.m4a"]))),
            ]
            for row in rows {
                try freshDirectory()
                let label = "\(deviceOnly ? "On this Mac only" : "Automatic"), \(row.label)"
                let transport = RecordingTransport()
                let cloud = RecordingCloud()
                let failures = FailureLog()
                let outcomes = OutcomeLog()
                let outcome = await stop(row.local, segments: 3, deviceOnly: deviceOnly, transport: transport, cloud: cloud,
                                         failures: failures, outcomes: outcomes)

                guard case .failure(let error)? = outcome else {
                    XCTFail("\(label): a cancelled stop throws, got \(String(describing: outcome))")
                    continue
                }
                XCTAssertTrue(error is CancellationError, "\(label): reported as cancelled, never as a failure; got \(error)")
                XCTAssertEqual(outcomes.outcomes, [], "\(label): no local outcome, so no re-verify count")
                XCTAssertEqual(failures.failures, [], "\(label): no notice")
                try await Task.sleep(nanoseconds: 200_000_000)
                XCTAssertEqual(cloud.log, [], label)
                XCTAssertEqual(transport.log, [], "\(label): nothing marked, sent or ended")
                XCTAssertTrue(dirExists, label)
            }
        }
    }

    // MARK: The local outcome is counted at the source

    /// Every local failure counts toward the model re-verify exactly once, whatever the network does next:
    /// an Automatic fallback that finished in the cloud, one whose upload failed, and a timeout.
    func test_aLocalFailure_isReportedOnce_whetherTheCloudFallbackLandsFailsOrNeverRuns() async throws {
        var rows: [(label: String, deviceOnly: Bool, cloud: RecordingCloud, breakage: Breakage?)] = []
        for deviceOnly in [false, true] {
            for breakage in breakages {
                rows.append(("\(deviceOnly ? "On this Mac only" : "Automatic"), \(breakage.label)", deviceOnly, RecordingCloud(), breakage))
            }
        }
        rows.append(("Automatic, the fallback upload fails", false, RecordingCloud(failure: URLError(.cannotConnectToHost)),
                     Breakage(label: "guard", engine: DeviceFixtures.meetingEngine(4, lowConfidence: [0, 1]), segments: 4,
                              expected: .qualityGuard)))
        rows.append(("Automatic, local transcription times out", false, RecordingCloud(), nil))
        rows.append(("On this Mac only, local transcription times out", true, RecordingCloud(), nil))

        for row in rows {
            try freshDirectory()
            let outcomes = OutcomeLog()
            if let breakage = row.breakage {
                let local = transcriber(breakage.engine, gate: breakage.gate, loadFailure: breakage.loadFailure,
                                        loadTimeout: breakage.loadTimeout)
                _ = await stop(local, segments: breakage.segments, deviceOnly: row.deviceOnly, transport: RecordingTransport(),
                               cloud: row.cloud, outcomes: outcomes)
                breakage.gate.open()
            } else {
                let engine = ScriptedEngine(DeviceFixtures.fixtureEngine, hanging: ["seg-1-me.m4a"])
                _ = await stop(transcriber(engine), segments: 2, deviceOnly: row.deviceOnly, transport: RecordingTransport(),
                               cloud: row.cloud, outcomes: outcomes, transcribeTimeout: 0.5)
            }
            XCTAssertEqual(outcomes.outcomes, [false], row.label)
        }
    }

    /// A good local transcript is a local success even when the server then rejects or loses it.
    func test_aLocalSuccess_isReportedOnce_evenWhenTheServerRejectsTheTranscript() async throws {
        for status in [200, 400] {
            try freshDirectory()
            let outcomes = OutcomeLog()
            _ = await stop(transcriber(DeviceFixtures.meetingEngine(3)), segments: 3, deviceOnly: false,
                           transport: RecordingTransport(submitStatuses: [status]), cloud: RecordingCloud(), outcomes: outcomes)
            XCTAssertEqual(outcomes.outcomes, [true], "submit \(status)")
        }
    }

    // MARK: Retry and the launch sweep finish a failed fallback

    private func writeManifest(deviceOnly: Bool) -> CaptureManifest {
        let manifest = CaptureManifest(
            meetingId: DeviceFixtures.meetingId, seriesId: nil, instanceURL: URL(string: "https://minutia.example.com")!,
            userId: "u1", createdAt: Date(timeIntervalSince1970: 0), transcriptionMode: .device, deviceOnly: deviceOnly,
            language: "en")
        CaptureRecovery.saveManifest(manifest, to: dir)
        return manifest
    }

    private func writeReadableRecording() throws {
        try AudioFixtures.writeFragmentedM4A(to: dir.appendingPathComponent(CaptureRecovery.recordingName), seconds: 2)
    }

    /// `recover` (Retry and the launch sweep) runs this for every device manifest.
    private func recover(_ manifest: CaptureManifest, transport: RecordingTransport, cloud: RecordingCloud) async -> Error? {
        do {
            try await CaptureRecovery.recoverDeviceMeeting(
                directory: dir, manifest: manifest, transport: transport, cloud: cloud, sleep: { _ in })
            return nil
        } catch {
            return error
        }
    }

    func test_recovery_ofAnAutomaticMeetingWithNoTranscript_finishesInTheCloud_thenDeletesTheDirectory() async throws {
        try writeReadableRecording()
        let recording = dir.appendingPathComponent(CaptureRecovery.recordingName)
        let transport = RecordingTransport()
        let cloud = RecordingCloud()
        let error = await recover(writeManifest(deviceOnly: false), transport: transport, cloud: cloud)

        XCTAssertNil(error)
        XCTAssertEqual(cloud.log, ["uploadRecording", "finalizeMeeting", "requestTranscription"])
        XCTAssertEqual(cloud.uploaded, [recording], "the full recording on disk is what goes up")
        XCTAssertEqual(cloud.expectedSegments, [nil])
        XCTAssertFalse(transport.log.contains("mark") || transport.log.contains("submit"), "got \(transport.log)")
        XCTAssertFalse(dirExists, "the cloud 2xx deletes the capture directory")
        let ended = await eventually { transport.log.contains("endMeeting") }
        XCTAssertTrue(ended, "a meeting finished by recovery is ended on the server, like the stop path")
    }

    func test_recovery_whoseCloudFinalizeFails_keepsTheDirectory_forTheNextAttempt() async throws {
        for cloud in [RecordingCloud(failure: URLError(.cannotConnectToHost)), RecordingCloud(transcribeStatus: 503)] {
            try freshDirectory()
            try writeReadableRecording()
            let error = await recover(writeManifest(deviceOnly: false), transport: RecordingTransport(), cloud: cloud)

            XCTAssertNotNil(error, "cloud log \(cloud.log): must throw")
            XCTAssertTrue(dirExists, "cloud log \(cloud.log): no server 2xx, so the directory stays")
            XCTAssertTrue(recordingExists, "cloud log \(cloud.log)")
        }
    }

    /// On this Mac only never sends audio. Recovery (a crash, or Retry) keeps the directory, ends the
    /// meeting on the server so the web stops showing it live, and is terminal: not retried every launch.
    func test_recovery_ofAnOnThisMacOnlyMeetingWithNoTranscript_uploadsNothing_endsTheMeeting_andIsKept() async throws {
        try writeReadableRecording()
        let transport = RecordingTransport()
        let cloud = RecordingCloud()
        let error = await recover(writeManifest(deviceOnly: true), transport: transport, cloud: cloud)

        XCTAssertEqual(error as? CaptureRecovery.RecoveryError, .audioStaysOnThisMac, "got \(String(describing: error))")
        XCTAssertEqual(cloud.log, [], "no audio egress under On this Mac only")
        let ended = await eventually { transport.log.contains("endMeeting") }
        XCTAssertTrue(ended, "the meeting is ended on the server; got \(transport.log)")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.log, ["endMeeting"], "ended once, nothing marked or sent")
        XCTAssertTrue(dirExists)
        XCTAssertTrue(recordingExists)
        XCTAssertEqual(AppController.recoveryOutcome(for: error), .keptOnThisMac, "terminal: not retried every launch")
    }

    /// Retry of an On this Mac only meeting with no transcript cannot finish it: the app stays in its
    /// failure state with the device copy instead of saying it is done with nothing transcribed.
    func test_retry_ofAnOnThisMacOnlyMeetingWithNoTranscript_staysFailed_withTheDeviceTranscriptCopy() async throws {
        try writeReadableRecording()
        let error = await recover(writeManifest(deviceOnly: true), transport: RecordingTransport(), cloud: RecordingCloud())

        XCTAssertEqual(AppController.refinalizeOutcome(for: error, host: "minutia.example.com"),
                       .failed("This meeting could not be transcribed on this Mac. The recording is kept on this Mac."),
                       "got \(String(describing: error))")
        XCTAssertTrue(dirExists, "the recording is kept for a later Retry")
    }

    func test_retry_outcome_isFinishedOnlyWhenRecoverySucceeds() {
        let host = "minutia.example.com"
        XCTAssertEqual(AppController.refinalizeOutcome(for: nil, host: host), .finalized)
        let network = URLError(.cannotConnectToHost)
        XCTAssertEqual(AppController.refinalizeOutcome(for: network, host: host),
                       .failed(AppController.finalizeFailureMessage(for: network, host: host)))
        XCTAssertEqual(AppController.refinalizeOutcome(for: CaptureRecovery.RecoveryError.transcriptNotFinished, host: host),
                       .failed("This meeting could not be transcribed on this Mac. The recording is kept on this Mac."))
    }

    func test_retry_cancelledBySignOut_showsNoErrorAndArmsNoRetry() {
        XCTAssertEqual(AppController.refinalizeOutcome(for: CancellationError(), host: "minutia.example.com"), .cancelled)
    }

    /// One notice per failed On this Mac only meeting in total: the stop's notice, or for a meeting that
    /// crashed before its stop could post one, a single notice from the launch sweep. Either way the sweep
    /// pins the attempts so it never tries again.
    func test_launchSweep_ofAnOnThisMacOnlyMeeting_noticesOnlyWhenTheStopDidNot_andStopsTrying() {
        let fresh = writeManifest(deviceOnly: true)
        var told = fresh
        told.notified = true
        let first = AppController.recoverySweep(priorAttempts: 0)

        let crashed = AppController.sweepStep(manifest: fresh, outcome: .keptOnThisMac, sweep: first)
        XCTAssertEqual(crashed.report, .keptOnThisMac, "a crash before the stop's notice gets exactly one, the not-transcribed notice")
        XCTAssertEqual(crashed.save?.recoveryAttempts, AppController.maxRecoveryAttempts)
        XCTAssertEqual(crashed.save?.notified, true, "the sweep's notice is persisted too")

        let stopped = AppController.sweepStep(manifest: told, outcome: .keptOnThisMac, sweep: first)
        XCTAssertNil(stopped.report, "the stop already told the user")
        XCTAssertEqual(stopped.save?.recoveryAttempts, AppController.maxRecoveryAttempts)
        XCTAssertEqual(stopped.save?.notified, true)

        XCTAssertTrue(AppController.recoverySweep(priorAttempts: AppController.maxRecoveryAttempts).skip,
                      "pinned attempts mean the next launch skips the directory")
    }

    /// The rest of the sweep's per-directory decisions, unchanged by moving them behind `sweepStep`.
    func test_launchSweep_otherOutcomes_keepTheirNoticesAndAttemptCounts() {
        let fresh = writeManifest(deviceOnly: false)
        var told = fresh
        told.notified = true
        let first = AppController.recoverySweep(priorAttempts: 0)
        let last = AppController.recoverySweep(priorAttempts: AppController.maxRecoveryAttempts - 1)

        XCTAssertEqual(AppController.sweepStep(manifest: fresh, outcome: .recovered, sweep: first),
                       AppController.SweepStep(save: nil, report: .recovered))

        var unavailable = fresh
        unavailable.notified = true
        XCTAssertEqual(AppController.sweepStep(manifest: fresh, outcome: .transcriptionUnavailable, sweep: first),
                       AppController.SweepStep(save: unavailable, report: .transcriptionUnavailable))
        XCTAssertEqual(AppController.sweepStep(manifest: told, outcome: .transcriptionUnavailable, sweep: first),
                       AppController.SweepStep(save: nil, report: nil))

        var dead = fresh
        dead.recoveryAttempts = AppController.maxRecoveryAttempts
        XCTAssertEqual(AppController.sweepStep(manifest: fresh, outcome: .unreadable, sweep: first),
                       AppController.SweepStep(save: dead, report: .exhausted))

        var once = fresh
        once.recoveryAttempts = 1
        XCTAssertEqual(AppController.sweepStep(manifest: fresh, outcome: .retryLater, sweep: first),
                       AppController.SweepStep(save: once, report: nil))
        XCTAssertEqual(AppController.sweepStep(manifest: fresh, outcome: .retryLater, sweep: last),
                       AppController.SweepStep(save: dead, report: .exhausted))
    }

    func test_retry_ofAnAutomaticFallbackWhoseUploadFailed_finishesInTheCloud() async throws {
        try writeReadableRecording()
        let manifest = writeManifest(deviceOnly: false)
        let local = transcriber(DeviceFixtures.meetingEngine(4, lowConfidence: [0, 1]))
        let failed = await stop(local, segments: 4, deviceOnly: false, transport: RecordingTransport(),
                                cloud: RecordingCloud(failure: URLError(.cannotConnectToHost)))
        guard case .failure? = failed else { return XCTFail("precondition: the fallback upload fails, got \(String(describing: failed))") }
        XCTAssertTrue(dirExists, "precondition: the failed fallback kept the directory")

        let cloud = RecordingCloud()
        let error = await recover(manifest, transport: RecordingTransport(), cloud: cloud)

        XCTAssertNil(error, "Retry finishes the meeting instead of failing as unfinished forever")
        XCTAssertEqual(cloud.log, ["uploadRecording", "finalizeMeeting", "requestTranscription"])
        XCTAssertFalse(dirExists)
    }

    func test_recovery_withAFinishedTranscript_resubmitsIt_andNeverUploadsAudio() async throws {
        for deviceOnly in [false, true] {
            try freshDirectory()
            let saved = try Data(contentsOf: DeviceFixtures.fixtureURL)
            try saved.write(to: dir.appendingPathComponent(CaptureRecovery.transcriptName))
            let transport = RecordingTransport()
            let cloud = RecordingCloud()
            let error = await recover(writeManifest(deviceOnly: deviceOnly), transport: transport, cloud: cloud)

            XCTAssertNil(error, "deviceOnly=\(deviceOnly)")
            XCTAssertEqual(transport.log, ["submit"], "deviceOnly=\(deviceOnly)")
            XCTAssertEqual(transport.bodies, [saved], "deviceOnly=\(deviceOnly)")
            XCTAssertEqual(cloud.log, [], "deviceOnly=\(deviceOnly): a finished transcript never sends audio")
            XCTAssertFalse(dirExists, "deviceOnly=\(deviceOnly)")
        }
    }

    func test_onThisMacOnly_segmentsThatFailWithoutTrippingTheGuard_areLeftOutOfTheSubmittedTranscript() async throws {
        let transport = RecordingTransport()
        let cloud = RecordingCloud()
        let failures = FailureLog()
        let local = transcriber(DeviceFixtures.meetingEngine(10, failing: [2], lowConfidence: [6]))
        let outcome = await stop(local, segments: 10, deviceOnly: true, transport: transport, cloud: cloud, failures: failures)

        guard case .success(let result)? = outcome else { return XCTFail("got \(String(describing: outcome))") }
        XCTAssertNil(result.localFailure)
        XCTAssertEqual(try texts(transport.bodies.first), DeviceFixtures.items(10, except: [2, 6]),
                       "the thrown segment and the one under the floor are both left out")
        XCTAssertEqual(cloud.log, [])
        XCTAssertEqual(failures.failures, [], "a meeting that passes the guard posts no failure notification")
    }

    // MARK: Any setting

    func test_oneFailedSegment_stillWritesTranscriptJsonFromTheRest() async throws {
        let transport = RecordingTransport(submitStatuses: [400])
        let cloud = RecordingCloud()
        let local = transcriber(DeviceFixtures.meetingEngine(8, failing: [3]))
        let outcome = await stop(local, segments: 8, deviceOnly: false, transport: transport, cloud: cloud)

        guard case .failure? = outcome else { return XCTFail("a rejected submit throws, got \(String(describing: outcome))") }
        let saved = try Data(contentsOf: dir.appendingPathComponent(CaptureRecovery.transcriptName))
        XCTAssertEqual(try texts(saved), DeviceFixtures.items(8, except: [3]))
        XCTAssertEqual(cloud.log, [], "a server rejection of a good local transcript is not a local failure")
    }

    func test_aMeetingWithNoSpeech_completesAsNoSpeechOnDevice_andNeverReachesTheCloud() async throws {
        for deviceOnly in [false, true] {
            try freshDirectory()
            let transport = RecordingTransport()
            let cloud = RecordingCloud()
            let outcome = await stop(transcriber(ScriptedEngine()), segments: 3, deviceOnly: deviceOnly, transport: transport, cloud: cloud)

            guard case .success(let result)? = outcome else {
                XCTFail("deviceOnly=\(deviceOnly): got \(String(describing: outcome))")
                continue
            }
            XCTAssertNil(result.localFailure, "deviceOnly=\(deviceOnly)")
            let body = try DeviceFixtures.jsonObject(try XCTUnwrap(transport.bodies.first))
            XCTAssertEqual(body["outcome"] as? String, "no_speech", "deviceOnly=\(deviceOnly)")
            XCTAssertEqual(cloud.log, [], "deviceOnly=\(deviceOnly): silence is never sent to a cloud provider")
            XCTAssertFalse(dirExists, "deviceOnly=\(deviceOnly)")
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _result: Result<CaptureSession.StopResult, Error>?
    var result: Result<CaptureSession.StopResult, Error>? { lock.withLock { _result } }
    func set(_ result: Result<CaptureSession.StopResult, Error>) { lock.withLock { _result = result } }
}
