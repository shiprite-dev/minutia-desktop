import XCTest
@testable import Minutia

final class CaptureManifestTests: XCTestCase {
    func test_roundTrip_encodesAndDecodesEqually() throws {
        let manifest = CaptureManifest(
            meetingId: "0f9c2c9a-1a2b-4c3d-8e4f-5a6b7c8d9e0f",
            seriesId: "11111111-2222-3333-4444-555555555555",
            instanceURL: URL(string: "https://app.minutia.example")!,
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
            createdAt: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(CaptureManifest.self, from: data)
        XCTAssertNil(decoded.seriesId)
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
            createdAt: Date(timeIntervalSince1970: 42))
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        XCTAssertEqual(CaptureRecovery.loadManifest(from: dir), manifest)
    }
}
