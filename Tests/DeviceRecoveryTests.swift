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

    /// Five seconds of "Item N." on the mic channel; `lowConfidence` decodes under the parakeet-ultra floor.
    private func savedSegment(_ seq: Int, lowConfidence: Bool = false) throws -> Data {
        try JSONEncoder().encode(LocalTranscriber.SegmentTranscript(
            seq: seq, modelId: DeviceFixtures.ultra.id,
            segments: [.init(speaker: "me", start: Double(seq) * SegmentWriter.segmentSeconds,
                             end: Double(seq) * SegmentWriter.segmentSeconds + 5, text: "Item \(seq).",
                             confidence: lowConfidence ? 0.5 : 0.92)]))
    }

    /// A capture directory as a kill (or a failed stop) leaves it. `lowSaved` segments were saved under
    /// the guard floor; `brokenAudio` names segment audio files left unreadable.
    private func captureDir(deviceOnly: Bool, notified: Bool = false, priorAttempts: Int = 0, transcriptJSON: Bool = false,
                            saved: Set<Int> = [], lowSaved: Set<Int> = [], corrupt: Set<Int> = [], brokenAudio: [String] = [],
                            readableRecording: Bool = true, localFailed: Bool = false) throws -> (URL, CaptureManifest) {
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
        for seq in lowSaved {
            try savedSegment(seq, lowConfidence: true).write(to: dir.appendingPathComponent(LocalTranscriber.transcriptName(seq: seq)))
        }
        for name in brokenAudio { try Data([0]).write(to: dir.appendingPathComponent(name)) }
        for seq in corrupt { try Data("{\"seq\":".utf8).write(to: dir.appendingPathComponent(LocalTranscriber.transcriptName(seq: seq))) }
        if transcriptJSON {
            try Data(contentsOf: DeviceFixtures.fixtureURL).write(to: dir.appendingPathComponent(CaptureRecovery.transcriptName))
        }
        let manifest = CaptureManifest(
            meetingId: DeviceFixtures.meetingId, seriesId: nil, instanceURL: URL(string: "https://minutia.example.com")!,
            userId: "u1", createdAt: Date(timeIntervalSince1970: 0), recoveryAttempts: priorAttempts, notified: notified,
            transcriptionMode: .device, deviceOnly: deviceOnly, language: "en", localFailed: localFailed)
        CaptureRecovery.saveManifest(manifest, to: dir)
        return (dir, manifest)
    }

    /// The local model as recovery finds it at launch. `none`: the manifest has no entry for the
    /// language. `notReady`: there is an entry but the model is still downloading or warming.
    private enum Model { case none, notReady, ready, failsToLoad }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func increment() { lock.withLock { _count += 1 } }
    }

    /// A fresh engine, load gate and factory for one row. The factory hands out a new transcriber per call
    /// and counts the calls.
    private struct Local {
        let engine: ScriptedEngine
        let gate: LoadGate
        let built: Counter
        let factory: @Sendable (CaptureManifest) async throws -> LocalTranscriber?

        init(_ model: Model, engine: ScriptedEngine = DeviceFixtures.meetingEngine(DeviceRecoveryTests.segments)) {
            let gate = LoadGate(open: true)
            let built = Counter()
            self.built = built
            self.engine = engine
            self.gate = gate
            switch model {
            case .none:
                factory = { _ in built.increment(); return nil }
            case .notReady:
                factory = { _ in built.increment(); throw CaptureRecovery.RecoveryError.deferred }
            case .ready, .failsToLoad:
                let failure: Error? = model == .failsToLoad ? CocoaError(.fileReadCorruptFile) : nil
                factory = { _ in
                    built.increment()
                    return LocalTranscriber(source: DeviceFixtures.source, language: "en", guardFloor: DeviceFixtures.ultra.guardFloor,
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
                         local: Local, cloudTimeout: TimeInterval = CaptureSession.recoveryUploadTimeout,
                         segmentSeconds: Double = SegmentWriter.segmentSeconds,
                         onStep: @escaping @Sendable (CaptureSession.FinishingStep) async -> Void = { _ in },
                         flushNotes: @escaping @Sendable () async throws -> Void = {}) async -> Error? {
        do {
            try await CaptureRecovery.recoverDeviceMeeting(
                directory: dir, manifest: manifest, transport: transport, cloud: cloud,
                makeTranscriber: local.factory, flushNotes: flushNotes, sleep: { _ in }, cloudTimeout: cloudTimeout,
                segmentSeconds: segmentSeconds, onStep: onStep)
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
        var brokenAudio: [String] = []
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
    private static let allSegmentAudio = (0..<segments).flatMap { ["seg-\($0)-me.m4a", "seg-\($0)-them.m4a"] }

    private var matrix: [Row] {
        let six = Array(repeating: "submit", count: CaptureSession.submitBackoff.count + 1)
        return [
            // A finished transcript.json is resent as is, in either setting, without the engine.
            Row(label: "Automatic, finished transcript, 2xx", transcriptJSON: true, saved: Self.all,
                engine: [], device: ["submit"], cloud: [], deleted: true, attempts: .unchanged, report: .recovered),
            Row(label: "On this Mac only, finished transcript, 2xx", deviceOnly: true, transcriptJSON: true, saved: Self.all,
                engine: [], device: ["submit"], cloud: [], deleted: true, attempts: .unchanged, report: .recovered),
            Row(label: "Automatic, finished transcript, 409 to the end", transcriptJSON: true, submit: [409],
                engine: [], device: six, cloud: [], deleted: false, attempts: .plusOne, report: nil),
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
                engine: calls([0, 1, 2]), device: ["mark"] + six, cloud: [], deleted: false, attempts: .plusOne, report: nil),
            // No usable model: Automatic finishes in the cloud, On this Mac only keeps everything.
            Row(label: "Automatic, killed, no model, cloud 2xx", model: .none,
                engine: [], device: [], cloud: Self.cloudFinalize, deleted: true, attempts: .unchanged, report: .recovered),
            Row(label: "Automatic, killed, no model, cloud 409", model: .none, transcribe: 409,
                engine: [], device: [], cloud: Self.cloudFinalize, deleted: false, attempts: .plusOne, report: nil),
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
            // The model is still downloading or warming: both settings wait for it, uncounted and silent.
            Row(label: "Automatic, killed, the model is not ready yet", model: .notReady,
                engine: [], device: [], cloud: [], deleted: false, attempts: .unchanged, report: nil),
            Row(label: "On this Mac only, killed, the model is not ready yet", deviceOnly: true, model: .notReady,
                engine: [], device: [], cloud: [], deleted: false, attempts: .unchanged, report: nil),
            // Segment audio that does not cover the recording: empty text must never replace real audio.
            Row(label: "Automatic, killed, every segment unreadable but the recording readable", brokenAudio: Self.allSegmentAudio,
                engine: [], device: [], cloud: Self.cloudFinalize, deleted: true, attempts: .unchanged, report: .recovered),
            Row(label: "On this Mac only, killed, every segment unreadable but the recording readable", deviceOnly: true,
                brokenAudio: Self.allSegmentAudio,
                engine: [], device: [], cloud: [], deleted: false, attempts: .pinned, report: .keptOnThisMac),
            Row(label: "Automatic, killed, two segments' system audio unreadable", brokenAudio: ["seg-1-them.m4a", "seg-2-them.m4a"],
                engine: [], device: [], cloud: Self.cloudFinalize, deleted: true, attempts: .unchanged, report: .recovered),
            Row(label: "On this Mac only, killed, two segments' system audio unreadable", deviceOnly: true,
                brokenAudio: ["seg-1-them.m4a", "seg-2-them.m4a"],
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
                                                 brokenAudio: row.brokenAudio, readableRecording: row.readableRecording)
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

    /// A cloud manifest goes through `recover`'s upload, finalize and transcribe on a live
    /// client; these rows feed the sweep the result each server answer produces there.
    func test_recoveryMatrix_cloudManifests_decideAttemptsAndNotice() {
        let manifest = CaptureManifest(
            meetingId: DeviceFixtures.meetingId, seriesId: nil, instanceURL: URL(string: "https://minutia.example.com")!,
            userId: "u1", createdAt: Date(timeIntervalSince1970: 0))
        let rows: [(label: String, error: Error?, attempts: Attempts, report: AppController.SweepReport?)] = [
            ("2xx", nil, .unchanged, .recovered),
            ("503, transcription not set up", MinutiaClientError.transcriptionNotConfigured, .plusOne, nil),
            ("409", MinutiaClientError.serverError(status: 409), .plusOne, nil),
            ("cancelled by a starting recording", CancellationError(), .unchanged, nil),
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

    /// A server that keeps answering 409 counts toward the ceiling like any other retriable failure, so
    /// a meeting stuck behind a claim that never clears stops at five with the one-time notice, after
    /// which the sweep skips the directory.
    func test_aBusyServer_countsTowardTheAttemptCeiling_likeOtherFailures_andStopsAtFive() async throws {
        let last = AppController.maxRecoveryAttempts - 1
        let rows: [(label: String, submit: [Int], transcribe: Int, json: Bool, model: Model, attempts: Int, report: AppController.SweepReport?)] = [
            ("resend answered 409", [409], 200, true, .ready, AppController.maxRecoveryAttempts, .exhausted),
            ("resend answered 503", [503], 200, true, .ready, AppController.maxRecoveryAttempts, .exhausted),
            ("cloud finalize answered 409", [200], 409, false, .none, AppController.maxRecoveryAttempts, .exhausted),
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
            ("Automatic whose model fails to load, finished in the cloud", false, false, [], .failsToLoad, false),
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
                    deviceOnly: false, cloud: RecordingCloud(), sleep: { _ in })
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

    // MARK: The quality guard judges the whole meeting

    /// The guard tolerates one failed window in a meeting that otherwise passes. Recovery must judge the
    /// saved segments too, or a lone failing missing segment looks like a meeting that failed throughout.
    func test_recovery_aFailingMissingSegmentAmongSavedPasses_isJudgedWithTheSavedOnes_andSubmitted() async throws {
        for deviceOnly in [false, true] {
            let label = deviceOnly ? "On this Mac only" : "Automatic"
            let (dir, manifest) = try captureDir(deviceOnly: deviceOnly, saved: [0, 1])
            let transport = RecordingTransport()
            let cloud = RecordingCloud()
            let local = Local(.ready, engine: DeviceFixtures.meetingEngine(Self.segments, lowConfidence: [2]))
            let error = await recover(dir, manifest, transport: transport, cloud: cloud, local: local)

            XCTAssertNil(error, "\(label): pass, pass, fail passes the guard; got \(String(describing: error))")
            XCTAssertEqual(local.engine.calls, calls([2]), label)
            XCTAssertEqual(transport.log.filter { $0 == "mark" || $0 == "submit" }, ["mark", "submit"], label)
            XCTAssertEqual(try texts(transport.bodies.first), ["Item 0.", "Item 1."], "\(label): the failed segment's text is dropped")
            XCTAssertEqual(cloud.log, [], "\(label): recovered on this Mac, not refused into the cloud")
            XCTAssertFalse(exists(dir), label)
        }
    }

    /// A saved segment that fails the floor counts too: saved fail, missing fail, missing pass is two
    /// failed windows in a row, so the meeting is refused locally.
    func test_recovery_savedFailuresPlusMissingFailures_stillTripTheGuard() async throws {
        for deviceOnly in [false, true] {
            let label = deviceOnly ? "On this Mac only" : "Automatic"
            let (dir, manifest) = try captureDir(deviceOnly: deviceOnly, lowSaved: [0])
            let transport = RecordingTransport()
            let cloud = RecordingCloud()
            let local = Local(.ready, engine: DeviceFixtures.meetingEngine(Self.segments, lowConfidence: [1]))
            let error = await recover(dir, manifest, transport: transport, cloud: cloud, local: local)
            let decision = sweep(manifest, error)

            XCTAssertEqual(transport.submits, 0, "\(label): no transcript is sent")
            if deviceOnly {
                XCTAssertEqual(error as? CaptureRecovery.RecoveryError, .audioStaysOnThisMac, "got \(String(describing: error))")
                XCTAssertEqual(cloud.log, [], "no audio egress under On this Mac only")
                XCTAssertTrue(exists(dir))
                XCTAssertEqual(decision.attempts, .pinned)
                XCTAssertEqual(decision.report, .keptOnThisMac)
            } else {
                XCTAssertNil(error, "got \(String(describing: error))")
                XCTAssertEqual(cloud.log, Self.cloudFinalize, "Automatic falls back to the cloud")
                XCTAssertFalse(exists(dir))
            }
        }
    }

    // MARK: Recovery yields to a recording

    /// A recording starting cancels recovery. Mid-transcription that cancels the transcriber, keeps every
    /// file and throws the cancellation, which the sweep neither counts nor reports.
    func test_recovery_cancelledMidTranscription_cancelsTheTranscriber_deletesNothing_andThrowsCancellation() async throws {
        let (dir, manifest) = try captureDir(deviceOnly: true, saved: [0])
        let transport = RecordingTransport()
        let cloud = RecordingCloud()
        let local = Local(.ready, engine: ScriptedEngine(hanging: ["seg-1-me.m4a"]))
        let finish = Finish()
        let task = Task { finish.record(await self.recover(dir, manifest, transport: transport, cloud: cloud, local: local)) }
        defer { task.cancel() }
        let transcribing = await eventually(timeout: 10) { local.engine.calls.contains("seg-1-me.m4a") }
        XCTAssertTrue(transcribing, "precondition: segment 1 is being transcribed")

        task.cancel()
        let finished = await eventually(timeout: 5) { finish.done }

        XCTAssertTrue(finished, "a cancelled recovery returns promptly instead of waiting out the transcription")
        XCTAssertTrue(finish.error is CancellationError, "got \(String(describing: finish.error))")
        let cancelled = await eventually { local.engine.cancelled == ["seg-1-me.m4a"] }
        XCTAssertTrue(cancelled, "the transcriber is cancelled; got \(local.engine.cancelled)")
        XCTAssertTrue(exists(dir.appendingPathComponent(CaptureRecovery.recordingName)))
        XCTAssertTrue(exists(dir.appendingPathComponent(LocalTranscriber.transcriptName(seq: 0))))
        XCTAssertTrue(exists(dir.appendingPathComponent(CaptureRecovery.manifestName)))
        XCTAssertEqual(transport.submits, 0)
        XCTAssertEqual(cloud.log, [])
        let decision = sweep(manifest, finish.error)
        XCTAssertEqual(decision.attempts, .unchanged)
        XCTAssertNil(decision.report)
    }

    private enum Hook { case mark, submit, flush, cloudTranscribe }

    /// A recording that starts at the last moment cancels recovery. The cancellation is checked right
    /// before each submit, so nothing is sent after it and the directory is kept.
    func test_recovery_cancelledJustBeforeTheServerAccepts_keepsTheDirectory_sendsNothingMore_andThrowsCancellation() async throws {
        let rows: [(label: String, json: Bool, saved: Set<Int>, model: Model, hook: Hook, submits: Int)] = [
            ("a fresh transcript, cancelled as it marks the meeting", false, Self.all, .ready, .mark, 0),
            ("a finished transcript, cancelled as the notes flush", true, [], .ready, .flush, 0),
        ]
        for row in rows {
            let (dir, manifest) = try captureDir(deviceOnly: false, transcriptJSON: row.json, saved: row.saved)
            let canceller = Canceller()
            let transport = RecordingTransport(
                onMark: { if row.hook == .mark { canceller.cancel() } },
                onSubmit: { if row.hook == .submit { canceller.cancel() } })
            let cloud = RecordingCloud(onTranscribe: { if row.hook == .cloudTranscribe { canceller.cancel() } })
            let local = Local(row.model)
            let finish = Finish()
            let task = Task {
                finish.record(await self.recover(dir, manifest, transport: transport, cloud: cloud, local: local) {
                    if row.hook == .flush { canceller.cancel() }
                })
            }
            canceller.hold(task)
            await task.value

            XCTAssertTrue(finish.error is CancellationError, "\(row.label): got \(String(describing: finish.error))")
            XCTAssertTrue(exists(dir), "\(row.label): the directory is kept")
            XCTAssertTrue(exists(dir.appendingPathComponent(CaptureRecovery.recordingName)), row.label)
            XCTAssertEqual(transport.submits, row.submits, row.label)
            XCTAssertEqual(AppController.recoveryOutcome(for: finish.error), .deferred, row.label)
        }
    }

    /// Once the server has answered 2xx it holds the meeting, so a cancellation racing that answer is
    /// too late to matter: the directory is deleted and recovery succeeds. Keeping it would send the
    /// meeting again on the next launch.
    func test_recovery_cancelledWhileTheServerAccepts_deletesTheDirectory_andSucceeds() async throws {
        let rows: [(label: String, json: Bool, saved: Set<Int>, model: Model, hook: Hook)] = [
            ("a fresh transcript submitted", false, Self.all, .ready, .submit),
            ("a finished transcript resent", true, [], .ready, .submit),
            ("no model, finished in the cloud", false, [], .none, .cloudTranscribe),
            ("the model fails to load, finished in the cloud", false, [], .failsToLoad, .cloudTranscribe),
        ]
        for row in rows {
            let (dir, manifest) = try captureDir(deviceOnly: false, transcriptJSON: row.json, saved: row.saved)
            let canceller = Canceller()
            let transport = RecordingTransport(onSubmit: { if row.hook == .submit { canceller.cancel() } })
            let cloud = RecordingCloud(onTranscribe: { if row.hook == .cloudTranscribe { canceller.cancel() } })
            let local = Local(row.model)
            let finish = Finish()
            let task = Task { finish.record(await self.recover(dir, manifest, transport: transport, cloud: cloud, local: local)) }
            canceller.hold(task)
            await task.value

            XCTAssertNil(finish.error, "\(row.label): the server accepted it; got \(String(describing: finish.error))")
            XCTAssertFalse(exists(dir), "\(row.label): the directory is deleted after the 2xx")
            XCTAssertEqual(AppController.recoveryOutcome(for: finish.error), .recovered, row.label)
            if row.hook == .submit {
                XCTAssertEqual(transport.submits, 1, "\(row.label): sent once")
            } else {
                XCTAssertEqual(cloud.log, Self.cloudFinalize, "\(row.label): finalized once")
            }
        }
    }

    // MARK: Outcomes that never count an attempt

    func test_recoveryOutcome_cancellationAndANotReadyModel_areDeferred_andSaveAndReportNothing() {
        let manifest = CaptureManifest(
            meetingId: DeviceFixtures.meetingId, seriesId: nil, instanceURL: URL(string: "https://minutia.example.com")!,
            userId: "u1", createdAt: Date(timeIntervalSince1970: 0), recoveryAttempts: 2, transcriptionMode: .device,
            deviceOnly: true, language: "en")
        for error in [CancellationError() as Error, CaptureRecovery.RecoveryError.deferred] {
            XCTAssertEqual(AppController.recoveryOutcome(for: error), .deferred, "\(error)")
        }
        let step = AppController.sweepStep(
            manifest: manifest, outcome: .deferred, sweep: AppController.recoverySweep(priorAttempts: manifest.recoveryAttempts))
        XCTAssertNil(step.save, "a deferred recovery persists nothing")
        XCTAssertNil(step.report, "and tells the user nothing")
    }

    func test_recoveryOutcome_a409_isRetriedLater_likeAnyRetriableFailure() {
        XCTAssertEqual(AppController.recoveryOutcome(for: MinutiaClientError.serverError(status: 409)), .retryLater)
        XCTAssertEqual(AppController.recoveryOutcome(for: CaptureSession.submitFailure(MinutiaClientError.serverError(status: 409))), .retryLater)
    }

    func test_submitFailure_rethrowsCancellation_insteadOfReportingAnUnsentTranscript() {
        let mapped: Error = CaptureSession.submitFailure(CancellationError())
        XCTAssertTrue(mapped is CancellationError, "got \(mapped)")
    }

    // MARK: A local failure in Automatic goes straight to the cloud next time

    func test_manifest_localFailed_decodesFalseFromALegacyManifest_andRoundTrips() throws {
        let legacy = Data("""
        {"meetingId":"\(DeviceFixtures.meetingId)","instanceURL":"https://minutia.example.com","createdAt":0,
         "transcriptionMode":"device","deviceOnly":false,"language":"en"}
        """.utf8)
        XCTAssertFalse(try JSONDecoder().decode(CaptureManifest.self, from: legacy).localFailed)

        let failed = CaptureManifest(
            meetingId: DeviceFixtures.meetingId, seriesId: nil, instanceURL: URL(string: "https://minutia.example.com")!,
            userId: "u1", createdAt: Date(timeIntervalSince1970: 0), transcriptionMode: .device, language: "en", localFailed: true)
        let decoded = try JSONDecoder().decode(CaptureManifest.self, from: try JSONEncoder().encode(failed))
        XCTAssertTrue(decoded.localFailed)
        XCTAssertEqual(decoded, failed)
    }

    /// A stop whose local transcription fails in Automatic records that on the manifest before trying
    /// the cloud, so a crash or a failed upload never makes recovery run the local model again.
    func test_anAutomaticStopsLocalFailure_persistsLocalFailed_beforeTheCloudFallback() async throws {
        let rows: [(label: String, engine: ScriptedEngine, loadFailure: Error?, timeout: TimeInterval?)] = [
            ("the model fails to load", DeviceFixtures.meetingEngine(1), CocoaError(.fileReadCorruptFile), nil),
            ("local transcription times out", ScriptedEngine(hanging: ["seg-0-me.m4a"]), nil, 0.5),
        ]
        for row in rows {
            let (dir, _) = try captureDir(deviceOnly: false)
            let local = LocalTranscriber(source: DeviceFixtures.source, language: "en", guardFloor: DeviceFixtures.ultra.guardFloor,
                                         loadEngine: LoadGate(open: true).loader(row.engine, failure: row.loadFailure))
            do {
                _ = try await CaptureSession.finishOnDevice(
                    meetingId: DeviceFixtures.meetingId, directory: dir, tail: [DeviceFixtures.segment(0, in: dir)],
                    durationSeconds: 600, transcriber: local, transport: RecordingTransport(), deviceOnly: false, cloud: RecordingCloud(failure: URLError(.notConnectedToInternet)),
                    transcribeTimeout: row.timeout, sleep: { _ in })
                XCTFail("\(row.label): precondition: the cloud fallback fails")
            } catch {}

            XCTAssertTrue(exists(dir), row.label)
            XCTAssertEqual(CaptureRecovery.loadManifest(from: dir)?.localFailed, true, row.label)
        }
    }

    /// After a local failure, Automatic recovery never builds a transcriber and finishes in the cloud. On
    /// this Mac only ignores the flag: it has nowhere else to go.
    func test_recovery_ofALocalFailedMeeting_inAutomatic_goesStraightToTheCloud_onThisMacOnlyStillTranscribesLocally() async throws {
        for deviceOnly in [false, true] {
            let label = deviceOnly ? "On this Mac only" : "Automatic"
            let (dir, manifest) = try captureDir(deviceOnly: deviceOnly, saved: [0], localFailed: true)
            let transport = RecordingTransport()
            let cloud = RecordingCloud()
            let local = Local(.ready)
            let error = await recover(dir, manifest, transport: transport, cloud: cloud, local: local)

            XCTAssertNil(error, "\(label): got \(String(describing: error))")
            XCTAssertFalse(exists(dir), label)
            if deviceOnly {
                XCTAssertEqual(local.built.count, 1)
                XCTAssertEqual(local.engine.calls, calls([1, 2]))
                XCTAssertEqual(cloud.log, [])
            } else {
                XCTAssertEqual(local.built.count, 0, "no transcriber is built")
                XCTAssertEqual(local.engine.calls, [])
                XCTAssertEqual(transport.log.filter { $0 == "mark" || $0 == "submit" }, [])
                XCTAssertEqual(cloud.log, Self.cloudFinalize)
            }
        }
    }

    // MARK: Timeouts and progress

    /// Both recovery cloud paths are bounded by the timeout recovery passes (900 s by default, not the
    /// live stop's 60 s); a stalled upload ends as a retriable failure with the directory kept.
    func test_recoveryCloudPaths_areBoundedByTheRecoveryUploadTimeout() async throws {
        XCTAssertEqual(CaptureSession.recoveryUploadTimeout, 900)
        XCTAssertEqual(CaptureSession.finalizeTimeout, 60, "the live stop keeps its own ceiling")
        let rows: [(label: String, model: Model)] = [("no model", .none), ("the model fails to load", .failsToLoad)]
        for row in rows {
            let (dir, manifest) = try captureDir(deviceOnly: false)
            let cloud = RecordingCloud(uploadHangs: true)
            let local = Local(row.model)
            let finish = Finish()
            let task = Task {
                finish.record(await self.recover(dir, manifest, transport: RecordingTransport(), cloud: cloud, local: local, cloudTimeout: 0.3))
            }
            let finished = await eventually(timeout: 5) { finish.done }
            task.cancel()

            XCTAssertTrue(finished, "\(row.label): the upload is cut off at the timeout recovery passed")
            XCTAssertEqual(cloud.log, ["uploadRecording"], row.label)
            XCTAssertNotNil(finish.error, row.label)
            XCTAssertFalse(finish.error is CancellationError, "\(row.label): a timeout is a failure, not a cancellation")
            XCTAssertEqual(AppController.recoveryOutcome(for: finish.error), .retryLater, row.label)
            XCTAssertTrue(exists(dir), row.label)
        }
    }

    /// Retry shows the same progress as a stop: recovery reports its finishing steps.
    func test_recovery_reportsItsFinishingSteps() async throws {
        let (dir, manifest) = try captureDir(deviceOnly: false, saved: [0])
        let steps = StepLog()
        let error = await recover(dir, manifest, transport: RecordingTransport(), cloud: RecordingCloud(), local: Local(.ready),
                                  onStep: { steps.record($0) })

        XCTAssertNil(error, "got \(String(describing: error))")
        XCTAssertTrue(steps.steps.contains { if case .transcribing = $0 { return true }; return false }, "got \(steps.steps)")
        XCTAssertEqual(steps.steps.last, .submitting)
    }

    // MARK: A kill during the stop's local transcription keeps the tail pieces

    /// The segment length the tail fixtures run at: 2 s for each minute of meeting, so a full segment is
    /// 10 s of audio and the pieces of the last partial segment stay shorter than one.
    private static let scaledSegment = SegmentWriter.segmentSeconds / 30

    /// What the stop leaves on disk once `SegmentWriter.finish()` kept the tail pieces: full segments
    /// `seg-0` to `seg-(N-1)`, each `scaledSegment` long, no `seg-N` files (finish deleted them), and the
    /// last partial segment as `tail-N`, `tail-(N+1)`, ... pieces, each mic and system file
    /// `pieceSeconds[i]` long. `unreadablePieces` are piece indexes whose mic file is left unreadable.
    private func postFinishDir(deviceOnly: Bool, fullSegments: Int, pieceSeconds: [Int], recordingSeconds: Int,
                               savedPieces: Set<Int> = [], unreadablePieces: Set<Int> = [],
                               keepPartialSegment: Bool = false) async throws -> (URL, CaptureManifest) {
        let dir = try DeviceFixtures.tempDir("device-recovery-tail")
        dirs.append(dir)
        for seq in 0..<fullSegments {
            for channel in ["me", "them"] {
                try AudioFixtures.writeFragmentedM4A(
                    to: dir.appendingPathComponent("seg-\(seq)-\(channel).m4a"), seconds: Int(Self.scaledSegment))
            }
        }
        if keepPartialSegment {
            for channel in ["me", "them"] {
                try AudioFixtures.writeFragmentedM4A(
                    to: dir.appendingPathComponent("seg-\(fullSegments)-\(channel).m4a"), seconds: pieceSeconds.reduce(0, +))
            }
        }
        for (index, seconds) in pieceSeconds.enumerated() {
            for channel in ["me", "them"] {
                try AudioFixtures.writeFragmentedM4A(
                    to: dir.appendingPathComponent("tail-\(fullSegments + index)-\(channel).m4a"), seconds: seconds)
            }
        }
        try AudioFixtures.writeFragmentedM4A(to: dir.appendingPathComponent(CaptureRecovery.recordingName), seconds: recordingSeconds)
        let starts = try await pieceStarts(in: dir, fullSegments: fullSegments, count: pieceSeconds.count)
        for seq in savedPieces {
            let start = starts[seq - fullSegments] + 0.5
            try JSONEncoder().encode(LocalTranscriber.SegmentTranscript(
                seq: seq, modelId: DeviceFixtures.ultra.id,
                segments: [.init(speaker: "me", start: start, end: start + 0.4, text: "Tail \(seq).", confidence: 0.92)]))
                .write(to: dir.appendingPathComponent(LocalTranscriber.transcriptName(seq: seq)))
        }
        for index in unreadablePieces {
            try Data([0]).write(to: dir.appendingPathComponent("tail-\(fullSegments + index)-me.m4a"))
        }
        let manifest = CaptureManifest(
            meetingId: DeviceFixtures.meetingId, seriesId: nil, instanceURL: URL(string: "https://minutia.example.com")!,
            userId: "u1", createdAt: Date(timeIntervalSince1970: 0), transcriptionMode: .device, deviceOnly: deviceOnly, language: "en")
        CaptureRecovery.saveManifest(manifest, to: dir)
        return (dir, manifest)
    }

    /// Where each piece starts on the meeting clock, from the test-side duration oracle: the first where
    /// the last full segment ended, each later one where the piece before it ended.
    private func pieceStarts(in dir: URL, fullSegments: Int, count: Int) async throws -> [Double] {
        var starts: [Double] = []
        var start = Double(fullSegments) * Self.scaledSegment
        for index in 0..<count {
            starts.append(start)
            let seconds = await AudioFixtures.assetDuration(dir.appendingPathComponent("tail-\(fullSegments + index)-me.m4a"))
            start += try XCTUnwrap(seconds, "piece \(index) is readable")
        }
        return starts
    }

    /// "Item N." over five seconds for each full segment, "Tail N." from 0.5 s to 0.9 s into each piece.
    private func tailEngine(fullSegments: Int, pieces: Int) -> ScriptedEngine {
        var results: [String: [SpeechSegment]] = [:]
        for seq in 0..<fullSegments { results["seg-\(seq)-me.m4a"] = [DeviceFixtures.speech(0, 5, "Item \(seq).", 0.92)] }
        for seq in fullSegments..<(fullSegments + pieces) {
            results["tail-\(seq)-me.m4a"] = [DeviceFixtures.speech(0.5, 0.9, "Tail \(seq).", 0.92)]
        }
        return ScriptedEngine(results)
    }

    private func tailCalls(_ seqs: [Int]) -> [String] { seqs.flatMap { ["tail-\($0)-me.m4a", "tail-\($0)-them.m4a"] } }

    /// After finish() the last partial segment exists only as pieces; recovery reads them as the segments
    /// that follow the full ones, on the meeting clock the stop gave them. The pieces have unequal lengths,
    /// so a start that assumed equal pieces would be off.
    func test_readableSegments_afterFinishKeptTheTailPieces_returnsThePiecesAfterTheFullSegments_onTheMeetingClock() async throws {
        let (dir, _) = try await postFinishDir(deviceOnly: false, fullSegments: 2, pieceSeconds: [2, 1, 3], recordingSeconds: 26)
        let segments = await CaptureRecovery.readableSegments(in: dir, segmentSeconds: Self.scaledSegment)
        let starts = try await pieceStarts(in: dir, fullSegments: 2, count: 3)

        XCTAssertEqual(segments.map(\.seq), [0, 1, 2, 3, 4])
        XCTAssertEqual(segments.map(\.micURL.lastPathComponent),
                       ["seg-0-me.m4a", "seg-1-me.m4a", "tail-2-me.m4a", "tail-3-me.m4a", "tail-4-me.m4a"])
        XCTAssertEqual(segments.map(\.sysURL.lastPathComponent),
                       ["seg-0-them.m4a", "seg-1-them.m4a", "tail-2-them.m4a", "tail-3-them.m4a", "tail-4-them.m4a"])
        XCTAssertEqual(starts[0], 20, accuracy: 0.001, "fixture: the first piece starts where the second full segment ends")
        XCTAssertEqual(starts[1] - starts[0], 2, accuracy: 0.1, "fixture: the first piece is about 2 s")
        XCTAssertEqual(starts[2] - starts[1], 1, accuracy: 0.1, "fixture: the second piece is about 1 s")
        guard segments.count == 5 else { return }
        XCTAssertEqual(segments[0].offsetSeconds, 0)
        XCTAssertEqual(segments[1].offsetSeconds, Self.scaledSegment, "a full segment starts at seq times the segment length")
        for (index, start) in starts.enumerated() {
            XCTAssertEqual(segments[2 + index].offsetSeconds, start, accuracy: 0.000_001,
                           "piece \(index) starts exactly where the pieces before it end")
        }
    }

    /// A piece in the middle that cannot be read has an unknown length, so every piece after it has an
    /// unknown start. Only the leading run of readable pieces is kept, on the exact clock.
    func test_readableSegments_anUnreadableMiddlePiece_keepsOnlyTheLeadingPieces_neverShiftsTheLaterOnes() async throws {
        let (dir, _) = try await postFinishDir(deviceOnly: false, fullSegments: 0, pieceSeconds: [2, 1, 3], recordingSeconds: 6,
                                               unreadablePieces: [1])
        let segments = await CaptureRecovery.readableSegments(in: dir, segmentSeconds: Self.scaledSegment)

        XCTAssertEqual(segments.map(\.micURL.lastPathComponent), ["tail-0-me.m4a"],
                       "the piece after the unreadable one is dropped, not moved up into its place")
        XCTAssertEqual(segments.first?.offsetSeconds, 0)
        let first = await AudioFixtures.assetDuration(dir.appendingPathComponent("tail-0-me.m4a"))
        XCTAssertEqual(segments.first?.frames, Int64(try XCTUnwrap(first) * MixPlan.sampleRate))
    }

    /// A kill mid-recording leaves the partial segment's own files beside the live pieces; the segment
    /// file covers the same audio, so the pieces are ignored.
    func test_readableSegments_midRecording_prefersThePartialSegment_overTheLivePieces() async throws {
        let (dir, _) = try await postFinishDir(deviceOnly: false, fullSegments: 2, pieceSeconds: [2, 1, 3], recordingSeconds: 26,
                                               keepPartialSegment: true)
        let segments = await CaptureRecovery.readableSegments(in: dir, segmentSeconds: Self.scaledSegment)
        XCTAssertEqual(segments.map(\.micURL.lastPathComponent), ["seg-0-me.m4a", "seg-1-me.m4a", "seg-2-me.m4a"])
        XCTAssertEqual(segments.map(\.offsetSeconds), [0, Self.scaledSegment, 2 * Self.scaledSegment])
    }

    /// A kill while the stop transcribed on this Mac: the tail pieces count toward coverage, the missing
    /// ones are transcribed and the saved ones reused, so the submitted transcript reaches the end of the
    /// meeting. The meeting is marked and sent with the recording's own duration. In On this Mac only a
    /// 13-minute meeting whose last 3 minutes are pieces is recovered, not kept forever.
    func test_recovery_afterAKillDuringTheStopsTranscription_includesTheTailPieces_andSubmitsTheWholeMeeting() async throws {
        let rows: [(label: String, deviceOnly: Bool, saved: Set<Int>, engine: [String])] = [
            ("Automatic, no piece saved", false, [], calls([0, 1]) + tailCalls([2, 3, 4])),
            ("Automatic, the first piece saved", false, [2], calls([0, 1]) + tailCalls([3, 4])),
            ("On this Mac only, 13 minutes with a 3-minute tail", true, [], calls([0, 1]) + tailCalls([2, 3, 4])),
        ]
        for row in rows {
            let (dir, manifest) = try await postFinishDir(deviceOnly: row.deviceOnly, fullSegments: 2, pieceSeconds: [2, 1, 3],
                                                          recordingSeconds: 26, savedPieces: row.saved)
            let recordingDuration = await AudioFixtures.assetDuration(dir.appendingPathComponent(CaptureRecovery.recordingName))
            let recording = try XCTUnwrap(recordingDuration)
            let starts = try await pieceStarts(in: dir, fullSegments: 2, count: 3)
            let transport = RecordingTransport()
            let cloud = RecordingCloud()
            let local = Local(.ready, engine: tailEngine(fullSegments: 2, pieces: 3))
            let error = await recover(dir, manifest, transport: transport, cloud: cloud, local: local, segmentSeconds: Self.scaledSegment)
            let decision = sweep(manifest, error)

            XCTAssertNil(error, "\(row.label): got \(String(describing: error))")
            XCTAssertEqual(local.engine.calls, row.engine, "\(row.label): engine calls")
            XCTAssertEqual(transport.log.filter { $0 == "mark" || $0 == "submit" }, ["mark", "submit"], row.label)
            XCTAssertEqual(transport.marks.count, 1, row.label)
            for mark in transport.marks {
                XCTAssertEqual(mark, recording, accuracy: 0.000_001, "\(row.label): the meeting is marked with the recording's duration")
            }
            XCTAssertEqual(try texts(transport.bodies.first), ["Item 0.", "Item 1.", "Tail 2.", "Tail 3.", "Tail 4."],
                           "\(row.label): the transcript reaches the end of the meeting")
            if let body = transport.bodies.first {
                let sent = try JSONDecoder().decode(DeviceTranscript.self, from: body)
                XCTAssertEqual(sent.durationSeconds, recording, accuracy: 0.01, "\(row.label): the transcript carries the recording's duration")
                let tails = sent.segments.filter { $0.text.hasPrefix("Tail") }.map(\.start)
                XCTAssertEqual(tails.count, starts.count, row.label)
                for (got, start) in zip(tails, starts) {
                    XCTAssertEqual(got, start + 0.5, accuracy: 0.006, "\(row.label): piece exactly on the meeting clock")
                }
            }
            XCTAssertEqual(cloud.log, [], "\(row.label): no audio leaves the Mac")
            XCTAssertFalse(exists(dir), "\(row.label): the server 2xx deletes the directory")
            XCTAssertEqual(decision.report, .recovered, row.label)
        }
    }

    /// With the middle piece unreadable only the first piece counts, so the segment audio no longer covers
    /// the recording: Automatic finishes in the cloud from the recording, On this Mac only keeps the audio.
    /// Neither sends a transcript with the last piece moved into the gap.
    func test_recovery_anUnreadableMiddlePiece_letsTheCoverageCheckDecide_neverSubmitsShiftedText() async throws {
        for deviceOnly in [false, true] {
            let label = deviceOnly ? "On this Mac only" : "Automatic"
            let (dir, manifest) = try await postFinishDir(deviceOnly: deviceOnly, fullSegments: 2, pieceSeconds: [2, 1, 3],
                                                          recordingSeconds: 26, unreadablePieces: [1])
            let transport = RecordingTransport()
            let cloud = RecordingCloud()
            let local = Local(.ready, engine: tailEngine(fullSegments: 2, pieces: 3))
            let error = await recover(dir, manifest, transport: transport, cloud: cloud, local: local, segmentSeconds: Self.scaledSegment)
            let decision = sweep(manifest, error)

            XCTAssertEqual(transport.submits, 0, "\(label): no transcript is sent; got \(String(describing: error))")
            XCTAssertEqual(local.engine.calls, [], "\(label): nothing is transcribed for a meeting the segments do not cover")
            if deviceOnly {
                XCTAssertEqual(error as? CaptureRecovery.RecoveryError, .audioStaysOnThisMac, "got \(String(describing: error))")
                XCTAssertEqual(cloud.log, [], "no audio egress under On this Mac only")
                XCTAssertTrue(exists(dir))
                XCTAssertEqual(decision.report, .keptOnThisMac)
            } else {
                XCTAssertNil(error, "got \(String(describing: error))")
                XCTAssertEqual(cloud.log, Self.cloudFinalize)
                XCTAssertFalse(exists(dir))
                XCTAssertEqual(decision.report, .recovered)
            }
        }
    }

    // MARK: A stuck engine never holds recovery

    /// Runs a device stop of one segment on `engine` in a task, waits until the engine is transcribing,
    /// cancels the task and returns what it finished with, the seconds from cancel to return and the
    /// engine calls still running at the return. nil when it did not return within `wait`.
    private func cancelMidTranscription(engine: StubbornEngine, engineStopTimeout: TimeInterval,
                                        wait: TimeInterval) async throws -> (error: Error?, seconds: TimeInterval, inFlight: Int)? {
        let dir = try DeviceFixtures.tempDir("device-recovery-stuck")
        dirs.append(dir)
        let local = LocalTranscriber(source: DeviceFixtures.source, language: "en", loadEngine: LoadGate(open: true).loader(engine))
        await local.startLoading()
        let finish = Finish()
        let inFlightAtReturn = InFlightBox()
        let task = Task {
            do {
                _ = try await CaptureSession.finishOnDevice(
                    meetingId: DeviceFixtures.meetingId, directory: dir, tail: [DeviceFixtures.segment(0, in: dir)],
                    durationSeconds: 600, transcriber: local, transport: RecordingTransport(), engineStopTimeout: engineStopTimeout, sleep: { _ in })
                inFlightAtReturn.set(engine.inFlight)
                finish.record(nil)
            } catch {
                inFlightAtReturn.set(engine.inFlight)
                finish.record(error)
            }
        }
        let running = await eventually(timeout: 5) { engine.inFlight == 1 }
        XCTAssertTrue(running, "precondition: the engine is transcribing")
        let cancelledAt = Date()
        task.cancel()
        let finished = await eventually(timeout: wait) { finish.done }
        guard finished else { return nil }
        return (finish.error, Date().timeIntervalSince(cancelledAt), inFlightAtReturn.value)
    }

    private final class InFlightBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = -1
        var value: Int { lock.withLock { _value } }
        func set(_ value: Int) { lock.withLock { _value = value } }
    }

    /// A Core ML call that never returns must not hold recovery (and with it Retry and the next recording)
    /// for the rest of the session: past the bound the cancelled stop stops waiting for the engine and
    /// still throws the cancellation, which is never counted.
    func test_aCancelledStop_whoseEngineNeverReturns_rethrowsCancellationWithinTheBound() async throws {
        let result = try await cancelMidTranscription(engine: StubbornEngine(milliseconds: 3_600_000), engineStopTimeout: 0.3, wait: 3)

        let returned = try XCTUnwrap(result, "a cancelled stop returns within the bound instead of waiting on the engine forever")
        XCTAssertTrue(returned.error is CancellationError, "got \(String(describing: returned.error))")
        XCTAssertLessThan(returned.seconds, 2, "it gives up at the 0.3 s bound")
        XCTAssertEqual(AppController.recoveryOutcome(for: returned.error), .deferred)
    }

    /// Within the bound the cancelled stop still waits for the engine to return, so a recording that starts
    /// next never shares the Neural Engine with it.
    func test_aCancelledStop_whoseEngineReturnsWithinTheBound_waitsForIt() async throws {
        let result = try await cancelMidTranscription(engine: StubbornEngine(milliseconds: 500), engineStopTimeout: 5, wait: 5)

        let returned = try XCTUnwrap(result, "a cancelled stop returns once the engine has")
        XCTAssertTrue(returned.error is CancellationError, "got \(String(describing: returned.error))")
        XCTAssertEqual(returned.inFlight, 0, "it returns only after the engine call has returned")
    }

    // MARK: Segments are judged in meeting order

    /// The guard's "two failures in a row" is about neighbouring windows of the meeting. Segment 2 failed
    /// live and left no transcript, segments 0, 1 and 3 to 9 are saved and pass, segment 10 was never
    /// transcribed and fails. In meeting order that is P P F P P P P P P P F: no two in a row, 2 of 11
    /// failing, so the meeting passes. Judged in arrival order (saved first) the two failures look adjacent.
    func test_recovery_judgesSavedAndNewSegmentsInMeetingOrder_notInTheOrderTheyWereJudged() async throws {
        let count = 11
        let template = try templateDir()
        for deviceOnly in [false, true] {
            let label = deviceOnly ? "On this Mac only" : "Automatic"
            let dir = try DeviceFixtures.tempDir("device-recovery-order")
            dirs.append(dir)
            for seq in 0..<count {
                for channel in ["me", "them"] {
                    try FileManager.default.copyItem(at: template.appendingPathComponent("seg-0-\(channel).m4a"),
                                                     to: dir.appendingPathComponent("seg-\(seq)-\(channel).m4a"))
                }
            }
            try FileManager.default.copyItem(at: template.appendingPathComponent(CaptureRecovery.recordingName),
                                             to: dir.appendingPathComponent(CaptureRecovery.recordingName))
            for seq in (0..<count) where seq != 2 && seq != 10 {
                try savedSegment(seq).write(to: dir.appendingPathComponent(LocalTranscriber.transcriptName(seq: seq)))
            }
            let manifest = CaptureManifest(
                meetingId: DeviceFixtures.meetingId, seriesId: nil, instanceURL: URL(string: "https://minutia.example.com")!,
                userId: "u1", createdAt: Date(timeIntervalSince1970: 0), transcriptionMode: .device, deviceOnly: deviceOnly, language: "en")
            CaptureRecovery.saveManifest(manifest, to: dir)
            let transport = RecordingTransport()
            let cloud = RecordingCloud()
            let local = Local(.ready, engine: DeviceFixtures.meetingEngine(count, lowConfidence: [2, 10]))
            let error = await recover(dir, manifest, transport: transport, cloud: cloud, local: local)

            XCTAssertNil(error, "\(label): P P F P...P F passes the guard; got \(String(describing: error))")
            XCTAssertEqual(local.engine.calls, calls([2, 10]), label)
            XCTAssertEqual(try texts(transport.bodies.first), DeviceFixtures.items(count, except: [2, 10]), label)
            XCTAssertEqual(cloud.log, [], "\(label): recovered on this Mac")
            XCTAssertFalse(exists(dir), label)
        }
    }

    // MARK: Whether recovery may use the local model now, later, or never

    /// The model status at launch decides whether recovery transcribes now, waits (the status is on its
    /// way to ready, or ready for another language while this one still has work), or gives up on the
    /// local model for good (Automatic then finishes in the cloud, On this Mac only keeps the audio and
    /// says so once).
    func test_modelDecision_mapsTheModelStatus_toReadyDeferredOrUnusable() {
        let lowDisk = ModelBlockReason.lowDisk(requiredBytes: 2_000_000_000, freeBytes: 1_000_000_000)
        let rows: [(label: String, status: ModelStatus, hasEntry: Bool, routable: Bool, decision: CaptureRecovery.ModelDecision)] = [
            ("ready and routable", .ready(revision: "r1"), true, true, .ready),
            ("ready for another language, this one not routable yet", .ready(revision: "r1"), true, false, .deferred),
            ("routable while another language downloads", .downloading(received: 1, total: 2), true, true, .ready),
            ("idle", .idle, true, false, .deferred),
            ("downloading", .downloading(received: 1, total: 2), true, false, .deferred),
            ("warming", .warming, true, false, .deferred),
            ("blocked by a recording", .blocked(.recording), true, false, .deferred),
            ("warming after a recording", .blocked(.warmingAfterRecording), true, false, .deferred),
            ("waiting for a non-metered network", .blocked(.expensiveNetwork), true, false, .deferred),
            ("waiting for disk space", .blocked(lowDisk), true, false, .deferred),
            ("failed", .failed("verification failed"), true, false, .unusable),
            ("an Intel Mac", .blocked(.intelMac), true, false, .unusable),
            ("an Intel Mac, even with a healthy entry", .blocked(.intelMac), true, true, .unusable),
            ("an unsupported macOS", .blocked(.unsupportedOS), true, false, .unusable),
            ("an unsupported macOS, even with a healthy entry", .blocked(.unsupportedOS), true, true, .unusable),
            ("no entry for the language per the store, while the manifest has one", .blocked(.noEntryForLanguage), true, false, .deferred),
            ("no manifest entry, while ready", .ready(revision: "r1"), false, false, .unusable),
            ("no manifest entry, while downloading", .downloading(received: 1, total: 2), false, false, .unusable),
            ("no manifest entry, while idle", .idle, false, false, .unusable),
        ]
        for row in rows {
            XCTAssertEqual(CaptureRecovery.modelDecision(status: row.status, hasEntry: row.hasEntry, isRoutable: row.routable),
                           row.decision, row.label)
        }
    }
}
