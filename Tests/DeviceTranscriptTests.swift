import CryptoKit
import XCTest
@testable import Minutia

/// The device transcript body. `Tests/Fixtures/device-transcript.v1.json` is committed byte for byte
/// in both repos: here it is what the Swift side must encode, and the web repo's
/// `scripts/verify-device-transcript.test.mjs` proves `parseDeviceTranscript` accepts it. Both sides
/// pin the same sha256, so an edit to either copy fails that repo's own suite.
final class DeviceTranscriptTests: XCTestCase {
    static let fixtureSHA256 = "0670fce48f9b1e3b76997ccd55a0884a10d5187835e7634be7dabdf5cb143e7f"

    private func fixtureData() throws -> Data { try Data(contentsOf: DeviceFixtures.fixtureURL) }

    private func labeledFixtureSegments() -> [DeviceTranscript.Segment] {
        let engine = DeviceFixtures.fixtureEngine
        func result(_ name: String) -> SpeechResult { SpeechResult(modelId: "m", segments: engine[name] ?? []) }
        return DeviceTranscript.labeled(result("seg-0-me.m4a"), speaker: .me, offset: 0)
            + DeviceTranscript.labeled(result("seg-0-them.m4a"), speaker: .them, offset: 0)
            + DeviceTranscript.labeled(result("seg-1-me.m4a"), speaker: .me, offset: 300)
            + DeviceTranscript.labeled(result("seg-1-them.m4a"), speaker: .them, offset: 300)
    }

    func test_sharedFixture_isTheCopyTheWebVerifierPins() throws {
        let digest = SHA256.hash(data: try fixtureData()).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, Self.fixtureSHA256, "edit both repos' copies and both pinned hashes together")
    }

    func test_aScriptedTwoSegmentMeeting_encodesExactlyTheSharedFixture() throws {
        let transcript = DeviceTranscript.build(
            source: DeviceFixtures.source, language: "en",
            durationSeconds: DeviceFixtures.fixtureDuration, segments: labeledFixtureSegments())
        XCTAssertEqual(try DeviceFixtures.jsonObject(transcript.encoded()), try DeviceFixtures.jsonObject(fixtureData()))
    }

    func test_theSharedFixture_decodesAndReencodesUnchanged() throws {
        let decoded = try JSONDecoder().decode(DeviceTranscript.self, from: fixtureData())
        XCTAssertEqual(decoded.segments.count, 4)
        XCTAssertEqual(decoded.source.modelRevision, DeviceFixtures.ultra.revision)
        XCTAssertEqual(try DeviceFixtures.jsonObject(decoded.encoded()), try DeviceFixtures.jsonObject(fixtureData()))
    }

    func test_encoded_usesExactlyTheServerFieldNames() throws {
        let object = try DeviceFixtures.jsonObject(DeviceTranscript.build(
            source: DeviceFixtures.source, language: "en", durationSeconds: 10,
            segments: [.init(speaker: "me", start: 1, end: 2, text: "Hi.", confidence: 0.9)]).encoded())
        XCTAssertEqual(Set(object.allKeys as! [String]),
                       ["schema_version", "source", "language", "duration_seconds", "outcome", "segments"])
        XCTAssertEqual(Set((object["source"] as! NSDictionary).allKeys as! [String]),
                       ["kind", "engine", "engine_version", "model", "model_revision", "app_version", "compute"])
        let segment = (object["segments"] as! [NSDictionary])[0]
        XCTAssertEqual(Set(segment.allKeys as! [String]), ["speaker", "start", "end", "text", "confidence"])
        XCTAssertEqual(object["schema_version"] as? Int, 1)
    }

    func test_labeled_marksTheChannel_andShiftsEveryTimeByTheSegmentStart() {
        let result = SpeechResult(modelId: "m", segments: [
            DeviceFixtures.speech(1.25, 2.5, "One.", 0.9), DeviceFixtures.speech(3, 4.75, "Two.", 0.8),
        ])
        XCTAssertEqual(DeviceTranscript.labeled(result, speaker: .them, offset: 612.5), [
            .init(speaker: "them", start: 613.75, end: 615, text: "One.", confidence: 0.9),
            .init(speaker: "them", start: 615.5, end: 617.25, text: "Two.", confidence: 0.8),
        ])
        XCTAssertEqual(DeviceTranscript.labeled(result, speaker: .me, offset: 0).map(\.speaker), ["me", "me"])
    }

    func test_silence_buildsNoSpeech_withZeroSegments() throws {
        let transcript = DeviceTranscript.build(source: DeviceFixtures.source, language: "en", durationSeconds: 60, segments: [])
        XCTAssertEqual(transcript.outcome, "no_speech")
        XCTAssertEqual(transcript.segments, [])
        let encoded = try DeviceFixtures.jsonObject(transcript.encoded())
        XCTAssertEqual((encoded["segments"] as? [Any])?.count, 0)
        XCTAssertEqual(encoded["outcome"] as? String, "no_speech")
    }

    func test_build_sortsOnTheMeetingClock_meBeforeThemOnATie_andDropsBlankText() {
        let transcript = DeviceTranscript.build(source: DeviceFixtures.source, language: "en", durationSeconds: 100, segments: [
            .init(speaker: "them", start: 9, end: 10, text: "Later.", confidence: 0.9),
            .init(speaker: "them", start: 2, end: 3, text: "Tie them.", confidence: 0.9),
            .init(speaker: "me", start: 2, end: 3, text: "Tie me.", confidence: 0.9),
            .init(speaker: "me", start: 5, end: 6, text: "  ", confidence: 0.9),
        ])
        XCTAssertEqual(transcript.segments.map(\.text), ["Tie me.", "Tie them.", "Later."])
        XCTAssertEqual(transcript.outcome, "speech")
    }

    func test_build_clampsTimesIntoTheMeeting_soTheServerNeverRejectsAnEnd() {
        let transcript = DeviceTranscript.build(source: DeviceFixtures.source, language: "en", durationSeconds: 100, segments: [
            .init(speaker: "me", start: 98, end: 140, text: "Runs past the end.", confidence: 0.9),
            .init(speaker: "them", start: 130, end: 135, text: "Starts past the end.", confidence: 0.9),
        ])
        for segment in transcript.segments {
            XCTAssertGreaterThanOrEqual(segment.start, 0)
            XCTAssertLessThanOrEqual(segment.start, segment.end, segment.text)
            XCTAssertLessThanOrEqual(segment.end, 100, segment.text)
        }
        XCTAssertEqual(transcript.segments.count, 2)
    }

    func test_build_splitsTextOverTheServerLimitAtWordBoundaries_keepingEveryWordAndTheTimeSpan() {
        let words = (0..<1200).map { "word\($0)" }
        let transcript = DeviceTranscript.build(source: DeviceFixtures.source, language: "en", durationSeconds: 600, segments: [
            .init(speaker: "them", start: 10, end: 310, text: words.joined(separator: " "), confidence: 0.9),
        ])
        XCTAssertGreaterThan(transcript.segments.count, 1)
        XCTAssertTrue(transcript.segments.allSatisfy { (1...DeviceTranscript.maxSegmentText).contains($0.text.count) })
        XCTAssertEqual(transcript.segments.flatMap { $0.text.split(separator: " ").map(String.init) }, words)
        XCTAssertEqual(transcript.segments.first?.start, 10)
        XCTAssertEqual(transcript.segments.last?.end, 310)
        XCTAssertTrue(transcript.segments.allSatisfy { $0.speaker == "them" && $0.start <= $0.end })
        XCTAssertEqual(transcript.segments.map(\.start), transcript.segments.map(\.start).sorted())
    }

    func test_build_clampsConfidenceIntoZeroToOne() {
        let transcript = DeviceTranscript.build(source: DeviceFixtures.source, language: "en", durationSeconds: 10, segments: [
            .init(speaker: "me", start: 1, end: 2, text: "High.", confidence: 1.4),
            .init(speaker: "me", start: 3, end: 4, text: "Low.", confidence: -0.2),
        ])
        XCTAssertEqual(transcript.segments.map(\.confidence), [1, 0])
    }

    /// `fluidAudioVersion` must equal `exactVersion` for FluidAudio in project.yml; DONE WHEN greps both.
    func test_onDeviceSource_namesThePinnedModelAndTheFluidAudioVersion() {
        XCTAssertEqual(DeviceTranscript.Source.fluidAudioVersion, "0.18.2")
        XCTAssertEqual(DeviceFixtures.source, DeviceTranscript.Source(
            engine: "fluidaudio", engineVersion: "0.18.2", model: "parakeet-ultra",
            modelRevision: "95eaa59a39d4394f047a4dc5cce480388a60d1b6", appVersion: "0.3.0", compute: "ane"))
    }
}
