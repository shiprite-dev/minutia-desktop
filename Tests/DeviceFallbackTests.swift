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
    }

    private var breakages: [Breakage] {
        [
            Breakage(label: "the model fails to load", engine: DeviceFixtures.meetingEngine(3), segments: 3,
                     loadFailure: CocoaError(.fileReadCorruptFile), expected: .modelLoad),
            Breakage(label: "the model load runs past its timeout", engine: DeviceFixtures.meetingEngine(3), segments: 3,
                     loadTimeout: 0.3, gate: LoadGate(), expected: .modelLoadTimedOut),
            Breakage(label: "the quality guard trips", engine: DeviceFixtures.meetingEngine(4, lowConfidence: [0, 1]),
                     segments: 4, expected: .qualityGuard),
            Breakage(label: "the first four segments all fail", engine: DeviceFixtures.meetingEngine(6, failing: [0, 1, 2, 3, 4, 5]),
                     segments: 6, expected: .qualityGuard),
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
                      cloud: RecordingCloud, failures: FailureLog = FailureLog(),
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
                    transcriber: local, transport: transport, recapOpened: true,
                    deviceOnly: deviceOnly, cloud: cloud, sleep: { _ in },
                    notifyLocalFailure: { failures.record($0) })))
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
            XCTAssertEqual(transport.log, [], "\(breakage.label): nothing is marked or sent")
            XCTAssertTrue(dirExists, breakage.label)
            XCTAssertTrue(recordingExists, breakage.label)
            XCTAssertEqual(failures.failures, [breakage.expected], "\(breakage.label): exactly one notification")
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
