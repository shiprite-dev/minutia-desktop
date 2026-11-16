import XCTest
@testable import Minutia

final class CaptureManifestRoutingTests: XCTestCase {
    private let instance = URL(string: "https://example.com")!

    private func manifest(_ mode: TranscriptionMode, deviceOnly: Bool, language: String?) -> CaptureManifest {
        CaptureManifest(meetingId: "abc", seriesId: nil, instanceURL: instance, userId: "u1",
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                        transcriptionMode: mode, deviceOnly: deviceOnly, language: language)
    }

    func test_routingFields_roundTrip() throws {
        let rows: [(TranscriptionMode, Bool, String?)] = [
            (.device, false, "en"), (.cloud, false, "ja"), (.blocked, true, "ja"), (.device, true, nil),
        ]
        for (mode, deviceOnly, language) in rows {
            let original = manifest(mode, deviceOnly: deviceOnly, language: language)
            let decoded = try JSONDecoder().decode(CaptureManifest.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(decoded, original, "\(mode) \(deviceOnly) \(language ?? "nil")")
        }
    }

    func test_manifestFromAnOlderBuild_decodesAsCloud_notDeviceOnly_noLanguage() throws {
        let json = Data(#"{"meetingId":"abc","instanceURL":"https://example.com","createdAt":0}"#.utf8)

        let decoded = try JSONDecoder().decode(CaptureManifest.self, from: json)

        XCTAssertEqual(decoded.transcriptionMode, .cloud)
        XCTAssertFalse(decoded.deviceOnly)
        XCTAssertNil(decoded.language)
        XCTAssertEqual(decoded.meetingId, "abc")
    }

    func test_unknownModeFromANewerBuild_failsClosed_keepingTheAudioOnThisMac() throws {
        let json = Data(#"""
        {"meetingId":"abc","instanceURL":"https://example.com","createdAt":0,"recoveryAttempts":2,
         "transcriptionMode":"hybrid","deviceOnly":false,"language":"de"}
        """#.utf8)

        let decoded = try JSONDecoder().decode(CaptureManifest.self, from: json)

        XCTAssertEqual(decoded.transcriptionMode, .device)
        XCTAssertFalse(decoded.audioMayLeaveMac, "an unknown mode never uploads after a downgrade")
        XCTAssertFalse(decoded.deviceOnly)
        XCTAssertEqual(decoded.language, "de")
        XCTAssertEqual(decoded.recoveryAttempts, 2)
    }

    /// The record-start decision is frozen: the model turning healthy mid-meeting changes what decide
    /// would say now, but the manifest a recovery sweep rewrites still carries the start-time route.
    func test_recordStartDecision_survivesTheModelBecomingReadyAndARecoveryRewrite() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureManifestRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let entry = ModelManifest.pinned.entry(forLanguage: "en")!
        func decide(healthy: Set<String>) -> TranscriptionDecision {
            TranscriptionRouter.decide(.init(
                isAppleSilicon: true, osVersion: entry.minimumOS, language: "en", manifest: .pinned,
                healthyRevisions: healthy, thermalState: .nominal, setting: .automatic, deviceRoutingEnabled: true))
        }

        let atStart = decide(healthy: [])
        CaptureRecovery.saveManifest(
            manifest(atStart.mode, deviceOnly: false, language: "en"), to: dir)
        XCTAssertEqual(decide(healthy: [entry.revision]), .device, "precondition: the model is ready now")

        var loaded = try XCTUnwrap(CaptureRecovery.loadManifest(from: dir))
        loaded.recoveryAttempts += 1
        CaptureRecovery.saveManifest(loaded, to: dir)

        XCTAssertEqual(CaptureRecovery.loadManifest(from: dir)?.transcriptionMode, .cloud)
        XCTAssertEqual(atStart, .cloud(.modelNotReady))
    }
}
