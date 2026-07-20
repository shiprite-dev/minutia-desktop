import XCTest
@testable import Minutia

final class CaptureManifestTests: XCTestCase {
    func test_roundTrip_encodesAndDecodesEqually() throws {
        let manifest = CaptureManifest(
            meetingId: "0f9c2c9a-1a2b-4c3d-8e4f-5a6b7c8d9e0f",
            seriesId: "11111111-2222-3333-4444-555555555555",
            instanceURL: URL(string: "https://app.minutia.example")!,
            userId: "aaaa1111-2222-3333-4444-555566667777",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(CaptureManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
    }

    func test_roundTrip_nilSeriesId() throws {
        let manifest = CaptureManifest(
            meetingId: "abc",
            seriesId: nil,
            instanceURL: URL(string: "https://x.example")!,
            userId: nil,
            createdAt: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(CaptureManifest.self, from: data)
        XCTAssertNil(decoded.seriesId)
        XCTAssertEqual(decoded, manifest)
    }

    // Manifests written by builds before the userId field must still decode (nil), so an older
    // orphaned recording is never lost just because its manifest predates cross-account gating.
    func test_decode_missingUserIdKeyDecodesAsNil() throws {
        let json = """
        {"meetingId":"abc","seriesId":null,"instanceURL":"https://x.example","createdAt":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CaptureManifest.self, from: json)
        XCTAssertNil(decoded.userId)
        XCTAssertEqual(decoded.meetingId, "abc")
    }

    // Manifests written before the recovery-bound fields must decode with defaults (0 attempts, not
    // notified), so an orphaned recording from an older build is swept normally, not skipped or lost.
    func test_decode_missingRecoveryFieldsDefaultToZeroAndFalse() throws {
        let json = """
        {"meetingId":"abc","seriesId":null,"instanceURL":"https://x.example","userId":null,"createdAt":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CaptureManifest.self, from: json)
        XCTAssertEqual(decoded.recoveryAttempts, 0)
        XCTAssertFalse(decoded.notified)
    }

    func test_roundTrip_preservesRecoveryAttemptsAndNotified() throws {
        let manifest = CaptureManifest(
            meetingId: "abc", seriesId: nil,
            instanceURL: URL(string: "https://x.example")!,
            userId: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            recoveryAttempts: 4, notified: true)
        let decoded = try JSONDecoder().decode(
            CaptureManifest.self, from: try JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded.recoveryAttempts, 4)
        XCTAssertTrue(decoded.notified)
        XCTAssertEqual(decoded, manifest)
    }
}

final class CaptureRecoveryDirectoriesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func makeDir(_ name: String, manifest: Bool, recording: Bool) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if manifest { try Data("{}".utf8).write(to: dir.appendingPathComponent("manifest.json")) }
        if recording { try Data("x".utf8).write(to: dir.appendingPathComponent("recording.m4a")) }
        return dir
    }

    func test_includesDirWithBothFiles() throws {
        let dir = try makeDir("m-both", manifest: true, recording: true)
        let result = CaptureRecovery.recoverableDirectories(in: root, excluding: nil)
        XCTAssertEqual(result.map(\.lastPathComponent), [dir.lastPathComponent])
    }

    func test_excludesDirMissingManifest() throws {
        try makeDir("m-noman", manifest: false, recording: true)
        XCTAssertTrue(CaptureRecovery.recoverableDirectories(in: root, excluding: nil).isEmpty)
    }

    func test_excludesDirMissingRecording() throws {
        try makeDir("m-norec", manifest: true, recording: false)
        XCTAssertTrue(CaptureRecovery.recoverableDirectories(in: root, excluding: nil).isEmpty)
    }

    func test_excludesActiveMeetingId_caseInsensitively() throws {
        try makeDir("aaaa", manifest: true, recording: true)
        try makeDir("bbbb", manifest: true, recording: true)
        let result = CaptureRecovery.recoverableDirectories(in: root, excluding: "AAAA")
        XCTAssertEqual(result.map(\.lastPathComponent), ["bbbb"])
    }

    func test_loadManifest_roundTripsThroughDirectory() throws {
        let dir = try makeDir("with-manifest", manifest: false, recording: true)
        let manifest = CaptureManifest(
            meetingId: "with-manifest", seriesId: nil,
            instanceURL: URL(string: "https://x.example")!,
            userId: nil,
            createdAt: Date(timeIntervalSince1970: 42))
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        XCTAssertEqual(CaptureRecovery.loadManifest(from: dir), manifest)
    }
}

/// BUG A: recovery is scoped to the connected instance so a recording captured against instance A
/// is never re-uploaded (and orphaned forever) while signed into instance B.
final class CaptureRecoveryScopingTests: XCTestCase {
    private func manifest(instance: String, userId: String? = nil) -> CaptureManifest {
        CaptureManifest(
            meetingId: "m", seriesId: nil,
            instanceURL: URL(string: instance)!,
            userId: userId,
            createdAt: Date(timeIntervalSince1970: 0))
    }

    func test_shouldRecover_trueWhenInstancesMatch() {
        XCTAssertTrue(CaptureRecovery.shouldRecover(
            manifest: manifest(instance: "https://a.example"),
            connectedInstance: URL(string: "https://a.example")!,
            connectedUserId: nil))
    }

    func test_shouldRecover_falseWhenInstancesDiffer() {
        XCTAssertFalse(CaptureRecovery.shouldRecover(
            manifest: manifest(instance: "https://a.example"),
            connectedInstance: URL(string: "https://b.example")!,
            connectedUserId: nil))
    }

    func test_shouldRecover_trueAcrossTrailingSlashDifference() {
        XCTAssertTrue(CaptureRecovery.shouldRecover(
            manifest: manifest(instance: "https://a.example/"),
            connectedInstance: URL(string: "https://a.example")!,
            connectedUserId: nil))
    }

    // Cross-account gate matrix (instances already matched): only refuse when both user ids are
    // known and differ; a nil on either side stays recoverable.
    private let instance = URL(string: "https://a.example")!
    private let userA = "aaaa1111-2222-3333-4444-555566667777"
    private let userB = "bbbb1111-2222-3333-4444-555566667777"

    func test_shouldRecover_trueWhenUserIdsEqual() {
        XCTAssertTrue(CaptureRecovery.shouldRecover(
            manifest: manifest(instance: "https://a.example", userId: userA),
            connectedInstance: instance, connectedUserId: userA))
    }

    func test_shouldRecover_falseWhenUserIdsDiffer() {
        XCTAssertFalse(CaptureRecovery.shouldRecover(
            manifest: manifest(instance: "https://a.example", userId: userA),
            connectedInstance: instance, connectedUserId: userB))
    }

    func test_shouldRecover_trueWhenManifestUserIdNil() {
        XCTAssertTrue(CaptureRecovery.shouldRecover(
            manifest: manifest(instance: "https://a.example", userId: nil),
            connectedInstance: instance, connectedUserId: userA))
    }

    func test_shouldRecover_trueWhenConnectedUserIdNil() {
        XCTAssertTrue(CaptureRecovery.shouldRecover(
            manifest: manifest(instance: "https://a.example", userId: userA),
            connectedInstance: instance, connectedUserId: nil))
    }

    func test_shouldRecover_falseWhenInstancesDifferEvenIfUsersMatch() {
        XCTAssertFalse(CaptureRecovery.shouldRecover(
            manifest: manifest(instance: "https://a.example", userId: userA),
            connectedInstance: URL(string: "https://b.example")!, connectedUserId: userA))
    }
}

/// BUG C: a mic-start failure preserves the capture dir whenever the tick has already written
/// system audio during the permission prompt; only a zero-frame denial deletes it.
final class CapturePreserveTests: XCTestCase {
    func test_shouldPreserve_falseWhenNoFramesWritten() {
        XCTAssertFalse(CaptureSession.shouldPreserve(framesWritten: 0))
    }

    func test_shouldPreserve_trueWhenSystemAudioAlreadyWritten() {
        XCTAssertTrue(CaptureSession.shouldPreserve(framesWritten: 1))
        XCTAssertTrue(CaptureSession.shouldPreserve(framesWritten: 48_000))
    }
}
