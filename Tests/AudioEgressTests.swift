import XCTest
import Supabase
@testable import Minutia

/// Until on-device transcription ships, a meeting routed to this Mac (or recorded under On this Mac
/// only) keeps its audio on disk: nothing is uploaded, live or by recovery. A blocked decision never
/// starts a capture at all. Manifests from older builds still upload exactly as before.
@MainActor
final class AudioEgressTests: XCTestCase {
    private var dir: URL!
    private let instance = URL(string: "http://127.0.0.1:1")!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-egress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// One client for the suite: each SupabaseClient parks a cooperative thread on a Keychain read
    /// in the unsigned test host, and enough of them starve every later async test.
    private static let client = MinutiaClient(
        instance: URL(string: "http://127.0.0.1:1")!,
        supabase: testSupabase(URL(string: "http://127.0.0.1:1")!),
        tokenProvider: { "token" })

    private func unreachableClient() -> MinutiaClient { Self.client }

    private func manifest(_ mode: TranscriptionMode, deviceOnly: Bool) -> CaptureManifest {
        CaptureManifest(
            meetingId: "0f9c2c9a-1a2b-4c3d-8e4f-5a6b7c8d9e0f", seriesId: nil, instanceURL: instance,
            userId: "u1", createdAt: Date(timeIntervalSince1970: 0),
            transcriptionMode: mode, deviceOnly: deviceOnly, language: "en")
    }

    private func olderBuildManifest() throws -> CaptureManifest {
        let json = Data(#"{"meetingId":"0f9c2c9a-1a2b-4c3d-8e4f-5a6b7c8d9e0f","instanceURL":"http://127.0.0.1:1","userId":"u1","createdAt":0}"#.utf8)
        return try JSONDecoder().decode(CaptureManifest.self, from: json)
    }

    // MARK: Which manifests may upload

    func test_onlyACloudManifestWithoutDeviceOnly_mayUploadAudio() throws {
        let rows: [(TranscriptionMode, Bool, Bool)] = [
            (.cloud, false, true),
            (.cloud, true, false),
            (.device, false, false),
            (.device, true, false),
            (.blocked, false, false),
            (.blocked, true, false),
        ]
        for (mode, deviceOnly, expected) in rows {
            XCTAssertEqual(manifest(mode, deviceOnly: deviceOnly).audioMayLeaveMac, expected, "\(mode) deviceOnly=\(deviceOnly)")
        }
        XCTAssertTrue(try olderBuildManifest().audioMayLeaveMac, "an older build's recording uploads as before")
    }

    // MARK: Recovery

    /// Device recordings go through the sweep to resend their transcript (DeviceResubmitTests); a
    /// manifest that may not upload and is not a device recording is never picked up.
    func test_recoverySweep_skipsANonDeviceRecordingThatMayNotUpload_evenOnTheSameInstanceAndUser() {
        for (mode, deviceOnly) in [(TranscriptionMode.blocked, true), (.cloud, true)] {
            XCTAssertFalse(
                CaptureRecovery.shouldRecover(
                    manifest: manifest(mode, deviceOnly: deviceOnly), connectedInstance: instance, connectedUserId: "u1"),
                "\(mode) deviceOnly=\(deviceOnly)")
        }
    }

    func test_recoverySweep_stillRecoversAnOlderBuildOrCloudRecording() throws {
        XCTAssertTrue(CaptureRecovery.shouldRecover(
            manifest: try olderBuildManifest(), connectedInstance: instance, connectedUserId: "u1"))
        XCTAssertTrue(CaptureRecovery.shouldRecover(
            manifest: manifest(.cloud, deviceOnly: false), connectedInstance: instance, connectedUserId: "u1"))
    }

    /// The egress refusal comes before every other step, so a recording that may not upload never
    /// reaches the segment upload loop, the recording upload, or the readability gate. Device
    /// recordings take the resubmit path instead (DeviceResubmitTests).
    func test_recover_aRecordingThatMayNotUpload_refusesBeforeAnyUploadOrReadabilityCheck() async throws {
        try AudioFixtures.writeFragmentedM4A(to: dir.appendingPathComponent("seg-0-me.m4a"), seconds: 2)
        try AudioFixtures.writeFragmentedM4A(to: dir.appendingPathComponent("seg-0-them.m4a"), seconds: 2)
        try AudioFixtures.writeUnfinalizedM4A(to: dir.appendingPathComponent("recording.m4a"))
        for (mode, deviceOnly) in [(TranscriptionMode.blocked, true), (.cloud, true)] {
            do {
                try await CaptureRecovery.recover(
                    directory: dir, manifest: manifest(mode, deviceOnly: deviceOnly), client: unreachableClient())
                XCTFail("\(mode) deviceOnly=\(deviceOnly): recovery must refuse")
            } catch {
                XCTAssertEqual(error as? CaptureRecovery.RecoveryError, .audioStaysOnThisMac,
                               "\(mode) deviceOnly=\(deviceOnly): got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("seg-0-me.m4a").path),
                      "the audio stays on disk")
    }

    func test_recover_anOlderBuildRecording_stillGoesThroughTheReadabilityGate() async throws {
        try AudioFixtures.writeUnfinalizedM4A(to: dir.appendingPathComponent("recording.m4a"))
        do {
            try await CaptureRecovery.recover(directory: dir, manifest: try olderBuildManifest(), client: unreachableClient())
            XCTFail("an unreadable recording must not recover")
        } catch {
            XCTAssertEqual(error as? CaptureRecovery.RecoveryError, .unreadableRecording, "got \(error)")
        }
    }

    func test_recoveryOutcome_aRefusedDeviceRecordingIsTerminal_notRetriedEveryLaunch() {
        XCTAssertNotEqual(AppController.recoveryOutcome(for: CaptureRecovery.RecoveryError.audioStaysOnThisMac), .retryLater)
    }

    // MARK: Blocked decision

    func test_blockedDecision_refusesToStartCapture_withTheReasonShownToTheUser() {
        for reason in TranscriptionReason.allCases {
            let message = AppController.captureRefusal(for: .blocked(reason))
            XCTAssertNotNil(message, "\(reason)")
            XCTAssertTrue(message?.contains(reason.settingsText) ?? false, "\(reason): \(message ?? "nil")")
            XCTAssertNil(AppController.captureRefusal(for: .cloud(reason)), "\(reason): cloud records")
        }
        XCTAssertNil(AppController.captureRefusal(for: .device), "device records (audio stays local)")
    }

    /// The session refuses a blocked decision before anything else, so no directory, manifest or
    /// pipeline is ever created. An invalid meeting id proves the order: the blocked check wins.
    func test_captureSessionStart_refusesABlockedDecisionBeforeCreatingAnything() {
        let session = CaptureSession()
        XCTAssertThrowsError(try session.start(
            meetingId: "not-a-uuid", seriesId: nil, userId: "u1", client: unreachableClient(),
            decision: .blocked(.modelNotReady), deviceOnly: true, language: "en")) { error in
            guard case .transcriptionBlocked(let reason)? = error as? CaptureSession.CaptureError else {
                return XCTFail("expected transcriptionBlocked, got \(error)")
            }
            XCTAssertEqual(reason, .modelNotReady)
        }
        XCTAssertTrue(CaptureSession.failureMessage(for: CaptureSession.CaptureError.transcriptionBlocked(.modelNotReady))
            .contains(TranscriptionReason.modelNotReady.settingsText))
    }

    /// A device decision with no transcriber (an egress-forbidden-only entry, or a model id the
    /// engine does not know) would record a meeting that can never be transcribed. The session
    /// refuses it before anything is created; the invalid id proves the order.
    /// A cloud decision recorded under On this Mac only writes a manifest whose audio may not leave
    /// the Mac; without a transcriber its stop would fall into the upload path. The invalid id proves
    /// the refusal comes before anything is created.
    func test_captureSessionStart_refusesACloudDecisionMarkedDeviceOnly_withoutATranscriber_beforeCreatingAnything() {
        let session = CaptureSession()
        XCTAssertThrowsError(try session.start(
            meetingId: "not-a-uuid", seriesId: nil, userId: "u1", client: unreachableClient(),
            decision: .cloud(.userChoseCloud), deviceOnly: true, language: "en", transcriber: nil)) { error in
            guard case .transcriptionBlocked(let reason)? = error as? CaptureSession.CaptureError else {
                return XCTFail("expected transcriptionBlocked, got \(error)")
            }
            XCTAssertEqual(reason, .modelNotReady)
        }
        XCTAssertThrowsError(try session.start(
            meetingId: "not-a-uuid", seriesId: nil, userId: "u1", client: unreachableClient(),
            decision: .cloud(.userChoseCloud), deviceOnly: false, language: "en", transcriber: nil)) { error in
            guard case .invalidMeetingId? = error as? CaptureSession.CaptureError else {
                return XCTFail("a cloud recording that may upload needs no transcriber, got \(error)")
            }
        }
    }

    func test_captureSessionStart_refusesADeviceDecisionWithoutATranscriber_beforeCreatingAnything() {
        for deviceOnly in [false, true] {
            let session = CaptureSession()
            XCTAssertThrowsError(try session.start(
                meetingId: "not-a-uuid", seriesId: nil, userId: "u1", client: unreachableClient(),
                decision: .device, deviceOnly: deviceOnly, language: "en", transcriber: nil)) { error in
                guard case .transcriptionBlocked(let reason)? = error as? CaptureSession.CaptureError else {
                    return XCTFail("deviceOnly=\(deviceOnly): expected transcriptionBlocked, got \(error)")
                }
                XCTAssertEqual(reason, .modelNotReady)
            }
        }
    }
}
