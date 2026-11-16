import XCTest
import Supabase
@testable import Minutia

/// Retry and the startup sweep resend a device meeting's finished `transcript.json`
/// (`CaptureRecovery.resubmitDeviceTranscript`, which `recover` runs for a device manifest). A
/// device directory with no finished transcript is a real failure, never a silent "finalized".
final class DeviceResubmitTests: XCTestCase {
    private var dir: URL!
    private let instance = URL(string: "http://127.0.0.1:1")!

    override func setUpWithError() throws {
        dir = try DeviceFixtures.tempDir("device-resubmit")
        for name in ["seg-0-me.m4a", "seg-0-them.m4a", "recording.m4a"] {
            try Data([0]).write(to: dir.appendingPathComponent(name))
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private var dirExists: Bool { FileManager.default.fileExists(atPath: dir.path) }

    private func writeTranscript() throws -> Data {
        let data = try Data(contentsOf: DeviceFixtures.fixtureURL)
        try data.write(to: dir.appendingPathComponent(CaptureRecovery.transcriptName))
        return data
    }

    private func resubmit(_ transport: RecordingTransport, sleeps: SleepLog = SleepLog()) async -> Error? {
        do {
            try await CaptureRecovery.resubmitDeviceTranscript(
                directory: dir, meetingId: DeviceFixtures.meetingId, transport: transport, sleep: { sleeps.record($0) })
            return nil
        } catch {
            return error
        }
    }

    private func manifest(_ mode: TranscriptionMode, deviceOnly: Bool, userId: String? = "u1") -> CaptureManifest {
        CaptureManifest(
            meetingId: DeviceFixtures.meetingId, seriesId: nil, instanceURL: instance, userId: userId,
            createdAt: Date(timeIntervalSince1970: 0), transcriptionMode: mode, deviceOnly: deviceOnly, language: "en")
    }

    private func unreachableClient() -> MinutiaClient {
        MinutiaClient(instance: instance, supabase: SupabaseClient(supabaseURL: instance, supabaseKey: "anon-key"),
                      tokenProvider: { "token" })
    }

    func test_theTranscriptFileName_isWhatTheStopWrites() {
        XCTAssertEqual(CaptureRecovery.transcriptName, "transcript.json")
    }

    /// The stop's POST may have landed with its response lost. A pending mark here would reopen
    /// that completed meeting past the server's replay fence, so resubmit only POSTs.
    func test_resubmit_sendsTheSavedBodyUnchanged_withoutReopeningTheMeeting_thenDeletesTheDirectory() async throws {
        let saved = try writeTranscript()
        let transport = RecordingTransport()
        let error = await resubmit(transport)
        XCTAssertNil(error)
        XCTAssertEqual(transport.log, ["submit"], "a resubmit never marks the meeting pending")
        XCTAssertEqual(transport.bodies, [saved], "Retry sends the payload written at stop, not a rebuilt one")
        XCTAssertFalse(dirExists, "a 2xx deletes the capture directory")
    }

    func test_resubmit_a409_retriesWithTheStopsBackoff() async throws {
        _ = try writeTranscript()
        let transport = RecordingTransport(submitStatuses: [409, 200])
        let sleeps = SleepLog()
        let error = await resubmit(transport, sleeps: sleeps)
        XCTAssertNil(error)
        XCTAssertEqual(transport.submits, 2)
        XCTAssertEqual(sleeps.waits, [CaptureSession.submitBackoff[0]])
        XCTAssertFalse(dirExists)
    }

    func test_resubmit_aRejectedSubmit_keepsTheDirectory_andSurfacesTranscriptNotSent() async throws {
        _ = try writeTranscript()
        let transport = RecordingTransport(submitStatuses: [400])
        let error = await resubmit(transport)
        guard case .transcriptNotSent? = error as? CaptureSession.CaptureError else { return XCTFail("got \(String(describing: error))") }
        XCTAssertTrue(dirExists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(CaptureRecovery.transcriptName).path))
    }

    func test_resubmit_withNoFinishedTranscript_failsWithoutAnyRequest_andKeepsTheAudio() async {
        let transport = RecordingTransport()
        let error = await resubmit(transport)
        XCTAssertEqual(error as? CaptureRecovery.RecoveryError, .transcriptNotFinished)
        XCTAssertEqual(transport.log, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("seg-0-me.m4a").path))
    }

    /// `recover` (Retry and the startup sweep) routes a device manifest to the resubmit path, so with
    /// no transcript it fails as unfinished before any network call, never as "audio stays here".
    func test_recover_aDeviceManifestWithoutATranscript_failsAsUnfinished_beforeAnyNetworkCall() async {
        for deviceOnly in [false, true] {
            do {
                try await CaptureRecovery.recover(directory: dir, manifest: manifest(.device, deviceOnly: deviceOnly), client: unreachableClient())
                XCTFail("deviceOnly=\(deviceOnly): must fail")
            } catch {
                XCTAssertEqual(error as? CaptureRecovery.RecoveryError, .transcriptNotFinished, "deviceOnly=\(deviceOnly): got \(error)")
            }
        }
        XCTAssertTrue(dirExists)
    }

    func test_recoverySweep_picksUpADeviceRecording_onTheSameInstanceAndUserOnly() {
        for deviceOnly in [false, true] {
            XCTAssertTrue(CaptureRecovery.shouldRecover(
                manifest: manifest(.device, deviceOnly: deviceOnly), connectedInstance: instance, connectedUserId: "u1"),
                "deviceOnly=\(deviceOnly)")
            XCTAssertFalse(CaptureRecovery.shouldRecover(
                manifest: manifest(.device, deviceOnly: deviceOnly), connectedInstance: instance, connectedUserId: "u2"))
            XCTAssertFalse(CaptureRecovery.shouldRecover(
                manifest: manifest(.device, deviceOnly: deviceOnly), connectedInstance: URL(string: "https://other.example.com")!,
                connectedUserId: "u1"))
        }
    }

    /// Not `.unreadable`: that pins the attempt count at the ceiling, so a later build that can
    /// re-transcribe from the segment files would never pick the directory up again.
    func test_recoveryOutcome_anUnfinishedDeviceTranscript_isRetriedLater_notMarkedDead() {
        XCTAssertEqual(AppController.recoveryOutcome(for: CaptureRecovery.RecoveryError.transcriptNotFinished), .retryLater)
    }

    // MARK: Copy

    func test_deviceFailureCopy_saysWhatHappened_andNeverMentionsUploading() {
        let rows: [(Error, String)] = [
            (CaptureSession.CaptureError.transcriptNotSent, "Could not send the transcript. Retry to send it again."),
            (CaptureRecovery.RecoveryError.transcriptNotFinished,
             "This meeting could not be transcribed on this Mac. The recording is kept on this Mac."),
            (CaptureSession.CaptureError.localTranscriptionTimedOut,
             "This meeting could not be transcribed on this Mac. The recording is kept on this Mac."),
            (CaptureSession.CaptureError.nothingRecorded, "Nothing was recorded, so there is no transcript to send."),
            (CaptureSession.CaptureError.transcriptTooLarge,
             "This meeting could not be transcribed on this Mac. The recording is kept on this Mac."),
        ]
        for (error, copy) in rows {
            let message = AppController.finalizeFailureMessage(for: error, host: "minutia.example.com")
            XCTAssertEqual(message, copy)
            XCTAssertFalse(message.lowercased().contains("upload"), message)
            XCTAssertFalse(message.contains("\u{2014}"), message)
        }
    }
}
