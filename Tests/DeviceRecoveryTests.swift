import XCTest
@testable import Minutia

/// What the next launch (and Retry) does with a device meeting's capture directory. The launch sweep
/// runs `CaptureRecovery.recoverDeviceMeeting`, maps its error through `AppController.recoveryOutcome`
/// and persists `AppController.sweepStep`; these tests compose the same three steps with the logging
/// doubles, so every row shows the calls made, whether the directory survived, the attempts delta and
/// the notice. A killed recording leaves `seg-N-me.m4a`/`seg-N-them.m4a`, maybe some
/// `seg-N.transcript.json`, a fragmented `recording.m4a` and no `transcript.json`.
final class DeviceRecoveryTests: XCTestCase {
    private static let segments = 3
    nonisolated(unsafe) private static var template: URL?
    private var dirs: [URL] = []

    override func tearDownWithError() throws {
        dirs.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Readable segment audio and a readable two-second recording, written once and copied per row.
    private func templateDir() throws -> URL {
        if let template = Self.template { return template }
        let dir = try DeviceFixtures.tempDir("device-recovery-template")
        for seq in 0..<Self.segments {
            try AudioFixtures.writeFragmentedM4A(to: dir.appendingPathComponent("seg-\(seq)-me.m4a"), seconds: 1)
            try AudioFixtures.writeFragmentedM4A(to: dir.appendingPathComponent("seg-\(seq)-them.m4a"), seconds: 1)
        }
        try AudioFixtures.writeFragmentedM4A(to: dir.appendingPathComponent(CaptureRecovery.recordingName), seconds: 2)
        Self.template = dir
        return dir
    }

    private func savedSegment(_ seq: Int) throws -> Data {
        try JSONEncoder().encode(LocalTranscriber.SegmentTranscript(
            seq: seq, modelId: DeviceFixtures.ultra.id,
            segments: [.init(speaker: "me", start: Double(seq) * SegmentWriter.segmentSeconds,
                             end: Double(seq) * SegmentWriter.segmentSeconds + 5, text: "Item \(seq).", confidence: 0.92)]))
    }

    /// A capture directory as a kill (or a failed stop) leaves it.
    private func captureDir(deviceOnly: Bool, notified: Bool = false, priorAttempts: Int = 0, transcriptJSON: Bool = false,
                            saved: Set<Int> = [], corrupt: Set<Int> = [], readableRecording: Bool = true) throws -> (URL, CaptureManifest) {
        let dir = try DeviceFixtures.tempDir("device-recovery")
        dirs.append(dir)
        let template = try templateDir()
        for seq in 0..<Self.segments {
            for name in ["seg-\(seq)-me.m4a", "seg-\(seq)-them.m4a"] {
                try FileManager.default.copyItem(at: template.appendingPathComponent(name), to: dir.appendingPathComponent(name))
            }
        }
        let recording = dir.appendingPathComponent(CaptureRecovery.recordingName)
        if readableRecording {
            try FileManager.default.copyItem(at: template.appendingPathComponent(CaptureRecovery.recordingName), to: recording)
        } else {
            try Data([0]).write(to: recording)
        }
        for seq in saved { try savedSegment(seq).write(to: dir.appendingPathComponent(LocalTranscriber.transcriptName(seq: seq))) }
        for seq in corrupt { try Data("{\"seq\":".utf8).write(to: dir.appendingPathComponent(LocalTranscriber.transcriptName(seq: seq))) }
        if transcriptJSON {
            try Data(contentsOf: DeviceFixtures.fixtureURL).write(to: dir.appendingPathComponent(CaptureRecovery.transcriptName))
        }
        let manifest = CaptureManifest(
            meetingId: DeviceFixtures.meetingId, seriesId: nil, instanceURL: URL(string: "https://minutia.example.com")!,
            userId: "u1", createdAt: Date(timeIntervalSince1970: 0), recoveryAttempts: priorAttempts, notified: notified,
            transcriptionMode: .device, deviceOnly: deviceOnly, language: "en")
        CaptureRecovery.saveManifest(manifest, to: dir)
        return (dir, manifest)
    }

    /// The local model as recovery finds it at launch.
    private enum Model { case none, ready, failsToLoad }

    /// A fresh engine, load gate and factory for one row. The factory hands out a new transcriber per call.
    private struct Local {
        let engine: ScriptedEngine
        let gate: LoadGate
        let factory: @Sendable (CaptureManifest) async -> LocalTranscriber?

        init(_ model: Model) {
            let engine = DeviceFixtures.meetingEngine(DeviceRecoveryTests.segments)
            let gate = LoadGate(open: true)
            self.engine = engine
            self.gate = gate
            switch model {
            case .none:
                factory = { _ in nil }
            case .ready, .failsToLoad:
                let failure: Error? = model == .failsToLoad ? CocoaError(.fileReadCorruptFile) : nil
                factory = { _ in
                    LocalTranscriber(source: DeviceFixtures.source, language: "en", guardFloor: DeviceFixtures.ultra.guardFloor,
                                     loadEngine: gate.loader(engine, failure: failure))
                }
            }
        }
    }

    private final class FlushProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var _submitsAtFlush: [Int] = []
        private var _cloudAtFlush: [[String]] = []
        var submitsAtFlush: [Int] { lock.withLock { _submitsAtFlush } }
        var cloudAtFlush: [[String]] { lock.withLock { _cloudAtFlush } }
        func record(submits: Int, cloud: [String]) { lock.withLock { _submitsAtFlush.append(submits); _cloudAtFlush.append(cloud) } }
    }

    private func recover(_ dir: URL, _ manifest: CaptureManifest, transport: RecordingTransport, cloud: RecordingCloud,
                         local: Local, flushNotes: @escaping @Sendable () async throws -> Void = {}) async -> Error? {
        do {
            try await CaptureRecovery.recoverDeviceMeeting(
                directory: dir, manifest: manifest, transport: transport, cloud: cloud,
                makeTranscriber: local.factory, flushNotes: flushNotes, sleep: { _ in })
            return nil
        } catch {
            return error
        }
    }

    private enum Attempts: Equatable { case unchanged, plusOne, pinned }

    /// What the launch sweep persists and reports for this recovery result.
    private func sweep(_ manifest: CaptureManifest, _ error: Error?) -> (attempts: Attempts, report: AppController.SweepReport?) {
        let step = AppController.sweepStep(
            manifest: manifest, outcome: AppController.recoveryOutcome(for: error),
            sweep: AppController.recoverySweep(priorAttempts: manifest.recoveryAttempts))
        let saved = step.save?.recoveryAttempts ?? manifest.recoveryAttempts
        let attempts: Attempts
        switch saved {
        case manifest.recoveryAttempts: attempts = .unchanged
        case manifest.recoveryAttempts + 1: attempts = .plusOne
        default:
            XCTAssertEqual(saved, AppController.maxRecoveryAttempts, "attempts move by one or pin at the ceiling")
            attempts = .pinned
        }
        return (attempts, step.report)
    }

    private func texts(_ body: Data?) throws -> [String] {
        try JSONDecoder().decode(DeviceTranscript.self, from: try XCTUnwrap(body)).segments.map(\.text)
    }

    private func calls(_ seqs: [Int]) -> [String] { seqs.flatMap { ["seg-\($0)-me.m4a", "seg-\($0)-them.m4a"] } }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: A kill mid-recording

    /// Automatic and On this Mac only alike: with a usable model, recovery transcribes on this Mac only
    /// the segments without a valid saved transcript, keeps the saved ones, writes the whole meeting,
    /// marks it waiting for this Mac, submits it and ends it. No audio leaves the Mac.
    func test_recovery_afterAKillMidRecording_transcribesOnlyTheMissingSegments_thenSubmitsTheWholeMeeting() async throws {
        for deviceOnly in [false, true] {
            let label = deviceOnly ? "On this Mac only" : "Automatic"
            let (dir, manifest) = try captureDir(deviceOnly: deviceOnly, saved: [0], corrupt: [1])
            let transport = RecordingTransport()
            let cloud = RecordingCloud()
            let local = Local(.ready)
            let error = await recover(dir, manifest, transport: transport, cloud: cloud, local: local)

            XCTAssertNil(error, "\(label): got \(String(describing: error))")
            XCTAssertEqual(local.engine.calls, calls([1, 2]),
                           "\(label): segment 0 has a saved transcript; segment 1's is corrupt, so it runs again")
            XCTAssertEqual(transport.log.filter { $0 == "mark" || $0 == "submit" }, ["mark", "submit"], label)
            XCTAssertEqual(try texts(transport.bodies.first), DeviceFixtures.items(Self.segments),
                           "\(label): the saved and the new segments make one meeting transcript")
            XCTAssertEqual(cloud.log, [], "\(label): a meeting finished on this Mac sends no audio")
            XCTAssertFalse(exists(dir), "\(label): the server 2xx deletes the capture directory")
            let ended = await eventually { transport.log.contains("endMeeting") }
            XCTAssertTrue(ended, "\(label): the recovered meeting is ended on the server; got \(transport.log)")
        }
    }

    /// A second kill (or an unsent submit) after recovery transcribed: the next launch reuses every
    /// saved transcript, so nothing is transcribed twice, and resends the same body without a new mark.
    func test_aSecondLaunchAfterAnUnsentRecovery_transcribesNothingAgain_andResendsTheSameTranscript() async throws {
        let (dir, manifest) = try captureDir(deviceOnly: false, saved: [0])
        let first = RecordingTransport(submitStatuses: [503])
        let firstLocal = Local(.ready)
        let firstError = await recover(dir, manifest, transport: first, cloud: RecordingCloud(), local: firstLocal)
        XCTAssertNotNil(firstError, "precondition: the first submit is not accepted")
        XCTAssertEqual(firstLocal.engine.calls, calls([1, 2]))
        XCTAssertTrue(exists(dir.appendingPathComponent(CaptureRecovery.transcriptName)), "the whole transcript is kept for the next launch")
        for seq in 1..<Self.segments {
            XCTAssertTrue(exists(dir.appendingPathComponent(LocalTranscriber.transcriptName(seq: seq))), "segment \(seq)'s transcript is saved")
        }

        let second = RecordingTransport()
        let secondLocal = Local(.ready)
        let cloud = RecordingCloud()
        let secondError = await recover(dir, manifest, transport: second, cloud: cloud, local: secondLocal)

        XCTAssertNil(secondError, "got \(String(describing: secondError))")
        XCTAssertEqual(secondLocal.engine.calls, [], "nothing is transcribed twice")
        XCTAssertEqual(secondLocal.gate.loads, 0, "the model is not even loaded")
        XCTAssertEqual(second.log.filter { $0 == "mark" || $0 == "submit" }, ["submit"], "a resend never reopens the meeting")
        XCTAssertEqual(second.bodies, first.bodies, "the transcript written by the first launch is what goes out")
        XCTAssertEqual(cloud.log, [])
        XCTAssertFalse(exists(dir))
    }

    // MARK: The decision matrix

    private struct Row {
        let label: String
        var deviceOnly = false
        var notified = false
        var transcriptJSON = false
        var saved: Set<Int> = []
        var readableRecording = true
        var model: Model = .ready
        var submit: [Int] = [200]
        var transcribe = 200
        let engine: [String]
        let device: [String]
        let cloud: [String]
        let deleted: Bool
        let attempts: Attempts
        let report: AppController.SweepReport?
    }

    private static let cloudFinalize = ["uploadRecording", "finalizeMeeting", "requestTranscription"]
    private static let all = Set(0..<segments)

    private var matrix: [Row] {
        let six = Array(repeating: "submit", count: CaptureSession.submitBackoff.count + 1)
        return [
            // A finished transcript.json is resent as is, in either setting, without the engine.
            Row(label: "Automatic, finished transcript, 2xx", transcriptJSON: true, saved: Self.all,
                engine: [], device: ["submit"], cloud: [], deleted: true, attempts: .unchanged, report: .recovered),
            Row(label: "On this Mac only, finished transcript, 2xx", deviceOnly: true, transcriptJSON: true, saved: Self.all,
                engine: [], device: ["submit"], cloud: [], deleted: true, attempts: .unchanged, report: .recovered),
            Row(label: "Automatic, finished transcript, 409 to the end", transcriptJSON: true, submit: [409],
                engine: [], device: six, cloud: [], deleted: false, attempts: .unchanged, report: nil),
            Row(label: "On this Mac only, finished transcript, 503", deviceOnly: true, transcriptJSON: true, submit: [503],
                engine: [], device: ["submit"], cloud: [], deleted: false, attempts: .plusOne, report: nil),
            Row(label: "Automatic, finished transcript, rejected 422", transcriptJSON: true, submit: [422],
                engine: [], device: ["submit"], cloud: [], deleted: false, attempts: .pinned, report: .exhausted),
            // A kill mid-recording with a usable model finishes on this Mac.
            Row(label: "Automatic, killed, some segments saved, 2xx", saved: [0],
                engine: calls([1, 2]), device: ["mark", "submit"], cloud: [], deleted: true, attempts: .unchanged, report: .recovered),
            Row(label: "On this Mac only, killed, some segments saved, 2xx", deviceOnly: true, saved: [0, 2],
                engine: calls([1]), device: ["mark", "submit"], cloud: [], deleted: true, attempts: .unchanged, report: .recovered),
            Row(label: "Automatic, killed, every segment saved, 2xx", saved: Self.all,
                engine: [], device: ["mark", "submit"], cloud: [], deleted: true, attempts: .unchanged, report: .recovered),
            Row(label: "Automatic, killed, nothing saved, 503", submit: [503],
                engine: calls([0, 1, 2]), device: ["mark", "submit"], cloud: [], deleted: false, attempts: .plusOne, report: nil),
            Row(label: "On this Mac only, killed, nothing saved, 409 to the end", deviceOnly: true, submit: [409],
                engine: calls([0, 1, 2]), device: ["mark"] + six, cloud: [], deleted: false, attempts: .unchanged, report: nil),
            // No usable model: Automatic finishes in the cloud, On this Mac only keeps everything.
            Row(label: "Automatic, killed, no model, cloud 2xx", model: .none,
                engine: [], device: [], cloud: Self.cloudFinalize, deleted: true, attempts: .unchanged, report: .recovered),
            Row(label: "Automatic, killed, no model, cloud 409", model: .none, transcribe: 409,
                engine: [], device: [], cloud: Self.cloudFinalize, deleted: false, attempts: .unchanged, report: nil),
            Row(label: "Automatic, killed, no model, cloud 503", model: .none, transcribe: 503,
                engine: [], device: [], cloud: Self.cloudFinalize, deleted: false, attempts: .plusOne, report: nil),
            Row(label: "Automatic, killed, no model, cloud 500", model: .none, transcribe: 500,
                engine: [], device: [], cloud: Self.cloudFinalize, deleted: false, attempts: .plusOne, report: nil),
            Row(label: "Automatic, killed, the model fails to load, cloud 2xx", model: .failsToLoad,
                engine: [], device: [], cloud: Self.cloudFinalize, deleted: true, attempts: .unchanged, report: .recovered),
            Row(label: "On this Mac only, killed, no model", deviceOnly: true, model: .none,
                engine: [], device: [], cloud: [], deleted: false, attempts: .pinned, report: .keptOnThisMac),
            Row(label: "On this Mac only, killed, the model fails to load", deviceOnly: true, model: .failsToLoad,
                engine: [], device: [], cloud: [], deleted: false, attempts: .pinned, report: .keptOnThisMac),
            Row(label: "On this Mac only, the stop already gave up and told the user", deviceOnly: true, notified: true,
                engine: [], device: [], cloud: [], deleted: false, attempts: .pinned, report: nil),
            // An unreadable recording has no meeting clock to transcribe against.
            Row(label: "Automatic, killed, unreadable recording", readableRecording: false,
                engine: [], device: [], cloud: [], deleted: false, attempts: .pinned, report: .exhausted),
            Row(label: "On this Mac only, killed, unreadable recording", deviceOnly: true, readableRecording: false,
                engine: [], device: [], cloud: [], deleted: false, attempts: .pinned, report: .keptOnThisMac),
        ]
    }

    /// Every device-manifest recovery: which calls happen, whether the directory is deleted (only after a
    /// server 2xx for the transcript or an accepted cloud finalize), the attempts delta and the notice.
    func test_recoveryMatrix_deviceManifests_decideCallsDeletionAttemptsAndNotice() async throws {
        for row in matrix {
            let (dir, manifest) = try captureDir(deviceOnly: row.deviceOnly, notified: row.notified,
                                                 transcriptJSON: row.transcriptJSON, saved: row.saved,
                                                 readableRecording: row.readableRecording)
            let transport = RecordingTransport(submitStatuses: row.submit)
            let cloud = RecordingCloud(transcribeStatus: row.transcribe)
            let local = Local(row.model)
            let error = await recover(dir, manifest, transport: transport, cloud: cloud, local: local)
            let decision = sweep(manifest, error)

            XCTAssertEqual(local.engine.calls, row.engine, "\(row.label): engine calls")
            if row.engine.isEmpty, row.model == .ready {
                XCTAssertEqual(local.gate.loads, 0, "\(row.label): nothing to transcribe, so the model is never loaded")
            }
            XCTAssertEqual(transport.log.filter { $0 == "mark" || $0 == "submit" }, row.device, "\(row.label): device calls")
            XCTAssertEqual(cloud.log, row.cloud, "\(row.label): cloud calls")
            XCTAssertEqual(!exists(dir), row.deleted, "\(row.label): deleted; error \(String(describing: error))")
            XCTAssertEqual(decision.attempts, row.attempts, "\(row.label): attempts; error \(String(describing: error))")
            XCTAssertEqual(decision.report, row.report, "\(row.label): notice; error \(String(describing: error))")
            if row.deviceOnly { XCTAssertEqual(cloud.log, [], "\(row.label): no audio egress under On this Mac only") }
        }
    }

    /// A cloud manifest goes through `recover`'s upload, finalize and non-strict transcribe on a live
    /// client; these rows feed the sweep the result each server answer produces there.
    func test_recoveryMatrix_cloudManifests_decideAttemptsAndNotice() {
        let manifest = CaptureManifest(
            meetingId: DeviceFixtures.meetingId, seriesId: nil, instanceURL: URL(string: "https://minutia.example.com")!,
            userId: "u1", createdAt: Date(timeIntervalSince1970: 0))
        let rows: [(label: String, error: Error?, attempts: Attempts, report: AppController.SweepReport?)] = [
            ("2xx", nil, .unchanged, .recovered),
            ("503, assembled from the fast-lane segments", nil, .unchanged, .recovered),
            ("409", MinutiaClientError.serverError(status: 409), .unchanged, nil),
            ("500", MinutiaClientError.serverError(status: 500), .plusOne, nil),
            ("unreachable", URLError(.cannotConnectToHost), .plusOne, nil),
            ("unreadable recording", CaptureRecovery.RecoveryError.unreadableRecording, .pinned, .exhausted),
        ]
        for row in rows {
            let decision = sweep(manifest, row.error)
            XCTAssertEqual(decision.attempts, row.attempts, row.label)
            XCTAssertEqual(decision.report, row.report, row.label)
        }
    }

    // MARK: Attempts

    /// A 409 means another claim on the meeting is still running, not that this recording is broken:
    /// it never counts toward the ceiling. Any other failure does, and the attempt that reaches the
    /// ceiling posts the one-time notice, after which the sweep skips the directory.
    func test_aBusyServer_neverCountsTowardTheAttemptCeiling_otherFailuresDoAndStopAtFive() async throws {
        let last = AppController.maxRecoveryAttempts - 1
        let rows: [(label: String, submit: [Int], transcribe: Int, json: Bool, model: Model, attempts: Int, report: AppController.SweepReport?)] = [
            ("resend answered 409", [409], 200, true, .ready, last, nil),
            ("resend answered 503", [503], 200, true, .ready, AppController.maxRecoveryAttempts, .exhausted),
            ("cloud finalize answered 409", [200], 409, false, .none, last, nil),
            ("cloud finalize answered 500", [200], 500, false, .none, AppController.maxRecoveryAttempts, .exhausted),
        ]
        for row in rows {
            let (dir, manifest) = try captureDir(deviceOnly: false, priorAttempts: last, transcriptJSON: row.json)
            let error = await recover(dir, manifest, transport: RecordingTransport(submitStatuses: row.submit),
                                      cloud: RecordingCloud(transcribeStatus: row.transcribe), local: Local(row.model))
            let step = AppController.sweepStep(
                manifest: manifest, outcome: AppController.recoveryOutcome(for: error),
                sweep: AppController.recoverySweep(priorAttempts: last))

            XCTAssertNotNil(error, row.label)
            XCTAssertEqual(step.save?.recoveryAttempts ?? manifest.recoveryAttempts, row.attempts, "\(row.label): error \(String(describing: error))")
            XCTAssertEqual(step.report, row.report, row.label)
            XCTAssertTrue(exists(dir), "\(row.label): no 2xx, so the directory stays")
        }
        XCTAssertTrue(AppController.recoverySweep(priorAttempts: AppController.maxRecoveryAttempts).skip)
    }

    // MARK: Notes

    /// Notes typed during the meeting reach the server before the transcript or the transcribe request
    /// that summarizes them: on the resend, on a local re-transcription and on the cloud finalize. A
    /// flush that fails never blocks the resend.
    func test_deviceRecovery_flushesTheMeetingNotes_beforeResending_onEveryPath() async throws {
        let rows: [(label: String, deviceOnly: Bool, json: Bool, saved: Set<Int>, model: Model, flushFails: Bool)] = [
            ("Automatic, a finished transcript is resent", false, true, [], .ready, false),
            ("On this Mac only, a finished transcript is resent", true, true, [], .ready, false),
            ("a killed meeting transcribed on this Mac", false, false, [0], .ready, false),
            ("Automatic with no model, finished in the cloud", false, false, [], .none, false),
            ("a resend whose notes flush fails", false, true, [], .ready, true),
        ]
        for row in rows {
            let (dir, manifest) = try captureDir(deviceOnly: row.deviceOnly, transcriptJSON: row.json, saved: row.saved)
            let transport = RecordingTransport()
            let cloud = RecordingCloud()
            let probe = FlushProbe()
            let error = await recover(dir, manifest, transport: transport, cloud: cloud, local: Local(row.model)) { [flushFails = row.flushFails] in
                probe.record(submits: transport.submits, cloud: cloud.log)
                if flushFails { throw URLError(.notConnectedToInternet) }
            }

            XCTAssertNil(error, "\(row.label): got \(String(describing: error))")
            XCTAssertEqual(probe.submitsAtFlush, [0], "\(row.label): flushed once, before any transcript was sent")
            XCTAssertFalse(probe.cloudAtFlush.contains { $0.contains("requestTranscription") }, "\(row.label): flushed before the transcribe request")
            XCTAssertTrue(transport.submits == 1 || cloud.log.contains("requestTranscription"), "\(row.label): the meeting was still resent")
            XCTAssertFalse(exists(dir), row.label)
        }
    }

    // MARK: Retry

    /// Retry after a stop whose submit was not accepted resends the transcript the stop wrote, and the
    /// app reports the meeting finished only when that resend is accepted.
    func test_retryAfterAFailedDeviceSubmit_resendsTheStopsTranscript_andIsFinishedOnlyOnA2xx() async throws {
        let retries: [(Int, AppController.RefinalizeOutcome)] = [
            (200, .finalized),
            (503, .failed("Could not send the transcript. Retry to send it again.")),
        ]
        for (retryStatus, expected) in retries {
            let (dir, manifest) = try captureDir(deviceOnly: false)
            let stopLocal = LocalTranscriber(source: DeviceFixtures.source, language: "en", guardFloor: DeviceFixtures.ultra.guardFloor,
                                             loadEngine: LoadGate(open: true).loader(DeviceFixtures.meetingEngine(2)))
            await stopLocal.startLoading()
            stopLocal.enqueue(DeviceFixtures.segment(0, in: dir))
            do {
                _ = try await CaptureSession.finishOnDevice(
                    meetingId: DeviceFixtures.meetingId, directory: dir, tail: [DeviceFixtures.segment(1, in: dir)],
                    durationSeconds: 600, transcriber: stopLocal, transport: RecordingTransport(submitStatuses: [503]),
                    recapOpened: true, deviceOnly: false, cloud: RecordingCloud(), sleep: { _ in })
                XCTFail("precondition: the stop's submit is not accepted")
            } catch {}
            let written = try Data(contentsOf: dir.appendingPathComponent(CaptureRecovery.transcriptName))

            let transport = RecordingTransport(submitStatuses: [retryStatus])
            let cloud = RecordingCloud()
            let local = Local(.ready)
            let error = await recover(dir, manifest, transport: transport, cloud: cloud, local: local)

            XCTAssertEqual(AppController.refinalizeOutcome(for: error, host: "minutia.example.com"), expected, "retry \(retryStatus)")
            XCTAssertEqual(transport.log.filter { $0 == "mark" || $0 == "submit" }, ["submit"], "retry \(retryStatus): resent, never re-marked")
            XCTAssertEqual(transport.bodies, [written], "retry \(retryStatus): the stop's transcript is what goes out")
            XCTAssertEqual(local.engine.calls, [], "retry \(retryStatus)")
            XCTAssertEqual(cloud.log, [], "retry \(retryStatus)")
            XCTAssertEqual(exists(dir), retryStatus != 200, "retry \(retryStatus)")
        }
    }
}
