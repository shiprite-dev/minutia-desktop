import XCTest
import Supabase
@testable import Minutia

/// Recovery uploads only files that are readable audio: an unreadable segment is skipped, and an
/// unreadable full recording ends recovery without uploading or finalizing anything.
final class CaptureRecoveryReadabilityTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recov-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    /// Points at a closed local port so any network call fails fast with a transport error, which
    /// is distinguishable from the readability gate's own error.
    private func unreachableClient() -> MinutiaClient {
        MinutiaClient(
            instance: URL(string: "http://127.0.0.1:1")!,
            supabase: SupabaseClient(supabaseURL: URL(string: "http://127.0.0.1:1")!, supabaseKey: "anon-key"),
            tokenProvider: { "token" })
    }

    private func manifest() -> CaptureManifest {
        CaptureManifest(
            meetingId: "0f9c2c9a-1a2b-4c3d-8e4f-5a6b7c8d9e0f", seriesId: nil,
            instanceURL: URL(string: "http://127.0.0.1:1")!, userId: nil,
            createdAt: Date(timeIntervalSince1970: 0))
    }

    func test_readableAudioDuration_readsAFragmentedFile() async throws {
        try AudioFixtures.writeFragmentedM4A(to: url("frag.m4a"), seconds: 5)
        let duration = await CaptureRecovery.readableAudioDuration(of: url("frag.m4a"))
        XCTAssertEqual(try XCTUnwrap(duration), 5, accuracy: 0.1)
    }

    func test_readableAudioDuration_nilForAFileWhoseIndexWasNeverWritten() async throws {
        try AudioFixtures.writeUnfinalizedM4A(to: url("dead.m4a"))
        let duration = await CaptureRecovery.readableAudioDuration(of: url("dead.m4a"))
        XCTAssertNil(duration)
    }

    func test_readableAudioDuration_nilForAMissingFile() async {
        let duration = await CaptureRecovery.readableAudioDuration(of: url("missing.m4a"))
        XCTAssertNil(duration)
    }

    func test_readableSegments_skipsUnreadableAndIncompletePairs_keepsReadableOnes() async throws {
        try AudioFixtures.writeFragmentedM4A(to: url("seg-0-me.m4a"), seconds: 3)
        try AudioFixtures.writeFragmentedM4A(to: url("seg-0-them.m4a"), seconds: 3)
        try AudioFixtures.writeFragmentedM4A(to: url("seg-1-me.m4a"), seconds: 3)
        try AudioFixtures.writeUnfinalizedM4A(to: url("seg-1-them.m4a"))
        try AudioFixtures.writeUnfinalizedM4A(to: url("seg-2-me.m4a"))
        try AudioFixtures.writeFragmentedM4A(to: url("seg-2-them.m4a"), seconds: 3)
        try AudioFixtures.writeFragmentedM4A(to: url("seg-3-me.m4a"), seconds: 3)
        try AudioFixtures.writeFragmentedM4A(to: url("seg-4-me.m4a"), seconds: 3)
        try AudioFixtures.writeFragmentedM4A(to: url("seg-4-them.m4a"), seconds: 3)
        try AudioFixtures.writeUnfinalizedM4A(to: url("recording.m4a"))

        let segments = await CaptureRecovery.readableSegments(in: dir)
        XCTAssertEqual(segments.map(\.seq), [0, 4])
        XCTAssertEqual(segments.map(\.micURL.lastPathComponent), ["seg-0-me.m4a", "seg-4-me.m4a"])
        XCTAssertEqual(segments.map(\.sysURL.lastPathComponent), ["seg-0-them.m4a", "seg-4-them.m4a"])
    }

    func test_recover_unreadableRecording_failsBeforeUploadingOrFinalizing() async throws {
        try AudioFixtures.writeFragmentedM4A(to: url("seg-0-me.m4a"), seconds: 2)
        try AudioFixtures.writeFragmentedM4A(to: url("seg-0-them.m4a"), seconds: 2)
        try AudioFixtures.writeUnfinalizedM4A(to: url("recording.m4a"))
        do {
            try await CaptureRecovery.recover(
                directory: dir, manifest: manifest(), client: unreachableClient())
            XCTFail("recovery must not succeed with an unreadable recording")
        } catch {
            XCTAssertEqual(error as? CaptureRecovery.RecoveryError, .unreadableRecording, "got \(error)")
        }
    }

    func test_recover_readableRecording_passesTheGateAndReachesTheNetwork() async throws {
        try AudioFixtures.writeFragmentedM4A(to: url("recording.m4a"), seconds: 2)
        let (dir, manifest, client) = (dir!, manifest(), unreachableClient())
        let recovery = Task { try await CaptureRecovery.recover(directory: dir, manifest: manifest, client: client) }
        let gateRejected = Task { () -> Bool in
            do { try await recovery.value } catch { return error as? CaptureRecovery.RecoveryError == .unreadableRecording }
            return false
        }
        // Past the readability gate the client retries an unreachable host for a long time; a gate
        // rejection would surface within milliseconds, so a few seconds is enough to tell them apart.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        recovery.cancel()
        let rejected = await gateRejected.value
        XCTAssertFalse(rejected)
    }

    func test_recoveryOutcome_unreadableRecordingIsTerminalNotRetried() {
        XCTAssertEqual(
            AppController.recoveryOutcome(for: CaptureRecovery.RecoveryError.unreadableRecording),
            .unreadable)
    }
}
