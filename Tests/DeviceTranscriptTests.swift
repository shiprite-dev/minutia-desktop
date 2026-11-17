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

    // MARK: Server limits (web repo src/lib/transcription/device.ts)

    func test_limits_matchTheServerSchema() {
        XCTAssertEqual(DeviceTranscript.maxBodyBytes, 2 * 1024 * 1024)
        XCTAssertEqual(DeviceTranscript.maxSegments, 20_000)
        XCTAssertEqual(DeviceTranscript.maxTotalText, 600_000)
        XCTAssertEqual(DeviceTranscript.maxSegmentText, 2_000)
    }

    func test_build_roundsTimesAndConfidenceToTwoDecimals() throws {
        let transcript = DeviceTranscript.build(source: DeviceFixtures.source, language: "en", durationSeconds: 100, segments: [
            .init(speaker: "me", start: 1.23456, end: 2.98765, text: "Rounded.", confidence: 0.876543),
        ])
        let segment = try XCTUnwrap((try DeviceFixtures.jsonObject(transcript.encoded())["segments"] as? [NSDictionary])?.first)
        XCTAssertEqual(segment["start"] as? Double, 1.23)
        XCTAssertEqual(segment["end"] as? Double, 2.99)
        XCTAssertEqual(segment["confidence"] as? Double, 0.88)
        let raw = try XCTUnwrap(String(data: transcript.encoded(), encoding: .utf8))
        XCTAssertFalse(raw.contains("1.23456") || raw.contains("0.876543"), raw)
    }

    func test_fitted_leavesATranscriptThatAlreadyFitsUnchanged() throws {
        let fixture = try JSONDecoder().decode(DeviceTranscript.self, from: fixtureData())
        XCTAssertEqual(fixture.fitted(), fixture)
    }

    private func words(_ segments: [DeviceTranscript.Segment], _ speaker: String) -> [Substring] {
        segments.filter { $0.speaker == speaker }.flatMap { $0.text.split(separator: " ") }
    }

    /// Six hours of short alternating turns: 43,200 segments overflow the count and the 2 MB body,
    /// while the words themselves fit. Merging same-speaker runs must bring every limit under.
    func test_fitted_aDenseSixHourMeeting_mergesSameSpeakerRunsUntilEveryLimitFits() throws {
        let segments = (0..<43_200).map { i -> DeviceTranscript.Segment in
            let start = Double(i) * 0.5
            return .init(speaker: (i / 6) % 2 == 0 ? "me" : "them", start: start, end: start + 0.4,
                         text: "Yes, agreed.", confidence: 0.91)
        }
        let dense = DeviceTranscript.build(source: DeviceFixtures.source, language: "en", durationSeconds: 21_600, segments: segments)
        XCTAssertGreaterThan(dense.segments.count, DeviceTranscript.maxSegments, "precondition: over the count before merging")
        XCTAssertGreaterThan(try dense.encoded().count, DeviceTranscript.maxBodyBytes, "precondition: over 2 MB before merging")

        let fitted = try XCTUnwrap(dense.fitted(), "same-speaker runs can always be merged under the limits here")
        XCTAssertLessThanOrEqual(fitted.segments.count, DeviceTranscript.maxSegments)
        XCTAssertLessThanOrEqual(try fitted.encoded().count, DeviceTranscript.maxBodyBytes)
        XCTAssertLessThanOrEqual(fitted.segments.reduce(0) { $0 + $1.text.count }, DeviceTranscript.maxTotalText)
        XCTAssertTrue(fitted.segments.allSatisfy { (1...DeviceTranscript.maxSegmentText).contains($0.text.count) })
        XCTAssertEqual(words(fitted.segments, "me"), words(dense.segments, "me"), "no word is lost or reordered")
        XCTAssertEqual(words(fitted.segments, "them"), words(dense.segments, "them"))
        XCTAssertEqual(fitted.segments.map(\.start), fitted.segments.map(\.start).sorted())
        XCTAssertEqual(fitted.outcome, "speech")
        XCTAssertEqual(fitted.durationSeconds, 21_600)
    }

    /// Five segments over the count with 599,990 UTF-16 units of text: every merge adds a joining space,
    /// so merging every pair would push the text past 600,000 and refuse a meeting that fits after five.
    func test_fitted_justOverTheCountNearTheTextLimit_mergesOnlyThePairsItNeeds_andIsNotRefused() throws {
        let segments = (0..<(DeviceTranscript.maxSegments + 5)).map { i in
            DeviceTranscript.Segment(speaker: "me", start: Double(i), end: Double(i) + 0.5,
                                     text: String(repeating: i < 10 ? "y" : "x", count: i < 10 ? 14 : 30), confidence: nil)
        }
        let transcript = DeviceTranscript(source: DeviceFixtures.source, language: "en", durationSeconds: 21_600, outcome: "speech", segments: segments)
        let text = { (t: DeviceTranscript) in t.segments.reduce(0) { $0 + $1.text.utf16.count } }
        XCTAssertEqual(text(transcript), 599_990, "precondition: just under the text limit")
        XCTAssertLessThanOrEqual(try transcript.encoded().count, DeviceTranscript.maxBodyBytes, "precondition: only the count is over")

        let fitted = try XCTUnwrap(transcript.fitted(), "five merges fit every limit, so the transcript is never refused")
        XCTAssertEqual(fitted.segments.count, DeviceTranscript.maxSegments, "exactly the five merges it needs, no more")
        XCTAssertLessThanOrEqual(text(fitted), DeviceTranscript.maxTotalText)
        XCTAssertLessThanOrEqual(try fitted.encoded().count, DeviceTranscript.maxBodyBytes)
        XCTAssertEqual(fitted.segments.map(\.text).joined(separator: " "), segments.map(\.text).joined(separator: " "),
                       "no text is lost or reordered")
    }

    // MARK: The server counts UTF-16 code units (Zod .max, String.length)

    func test_build_splitsEmojiTextByUTF16Units_keepingEveryWord() {
        let words = (0..<400).map { _ in "\u{1F600}\u{1F600}\u{1F600}\u{1F600}" }
        let text = words.joined(separator: " ")
        XCTAssertLessThanOrEqual(text.count, DeviceTranscript.maxSegmentText, "precondition: under the limit in graphemes")
        XCTAssertGreaterThan(text.utf16.count, DeviceTranscript.maxSegmentText, "precondition: over the limit in UTF-16")
        let transcript = DeviceTranscript.build(source: DeviceFixtures.source, language: "en", durationSeconds: 60, segments: [
            .init(speaker: "me", start: 1, end: 50, text: text, confidence: 0.9),
        ])
        XCTAssertTrue(transcript.segments.allSatisfy { (1...DeviceTranscript.maxSegmentText).contains($0.text.utf16.count) },
                      "got \(transcript.segments.map(\.text.utf16.count))")
        XCTAssertEqual(transcript.segments.flatMap { $0.text.split(separator: " ").map(String.init) }, words)
    }

    func test_fitted_isNil_whenDecomposedTextExceedsTheTotalLimitInUTF16Units() {
        let decomposed = String(repeating: "e\u{0301}", count: 1_000)
        let segments = (0..<301).map { i in
            DeviceTranscript.Segment(speaker: i % 2 == 0 ? "me" : "them", start: Double(i), end: Double(i) + 0.5, text: decomposed, confidence: 0.9)
        }
        let transcript = DeviceTranscript(source: DeviceFixtures.source, language: "en", durationSeconds: 400, outcome: "speech", segments: segments)
        XCTAssertLessThanOrEqual(segments.reduce(0) { $0 + $1.text.count }, DeviceTranscript.maxTotalText, "precondition: under in graphemes")
        XCTAssertGreaterThan(segments.reduce(0) { $0 + $1.text.utf16.count }, DeviceTranscript.maxTotalText, "precondition: over in UTF-16")
        XCTAssertNil(transcript.fitted(), "602,000 UTF-16 units is a body the server rejects")
    }

    func test_fitted_neverMergesASegmentPastTheTextLimitInUTF16Units() throws {
        let big = String(repeating: "\u{1F600}", count: 700)
        var segments: [DeviceTranscript.Segment] = [
            .init(speaker: "them", start: 0, end: 1, text: big, confidence: 0.9),
            .init(speaker: "them", start: 1, end: 2, text: big, confidence: 0.9),
        ]
        segments += (0..<19_999).map { i in
            let start = 2 + Double(i) * 0.5
            return .init(speaker: (i / 2) % 2 == 0 ? "me" : "them", start: start, end: start + 0.4, text: "ok", confidence: 0.9)
        }
        let transcript = DeviceTranscript(source: DeviceFixtures.source, language: "en", durationSeconds: 21_600, outcome: "speech", segments: segments)
        XCTAssertGreaterThan(transcript.segments.count, DeviceTranscript.maxSegments, "precondition: merging is needed")

        let fitted = try XCTUnwrap(transcript.fitted())
        XCTAssertLessThanOrEqual(fitted.segments.count, DeviceTranscript.maxSegments)
        let over = fitted.segments.filter { $0.text.utf16.count > DeviceTranscript.maxSegmentText }
        XCTAssertEqual(over.count, 0, "merged texts of \(over.map(\.text.utf16.count)) UTF-16 units fail the server's .max(2000)")
    }

    // MARK: Server range checks

    func test_build_clampsTheDurationToTheServerMaximum_andEveryTimeWithIt() throws {
        let transcript = DeviceTranscript.build(source: DeviceFixtures.source, language: "en", durationSeconds: 25_000, segments: [
            .init(speaker: "me", start: 21_590, end: 21_640, text: "Runs past six hours.", confidence: 0.9),
            .init(speaker: "them", start: 22_000, end: 22_010, text: "Past the cap.", confidence: 0.9),
        ])
        XCTAssertEqual(transcript.durationSeconds, 21_600)
        XCTAssertEqual(try DeviceFixtures.jsonObject(transcript.encoded())["duration_seconds"] as? Double, 21_600)
        XCTAssertTrue(transcript.segments.allSatisfy { $0.start <= $0.end && $0.end <= 21_600 }, "\(transcript.segments)")
    }

    /// The server requires `language` and accepts only `^[a-z]{2}$`; the router sends device work
    /// only for manifest languages, so this keeps every one submittable.
    func test_everyOnDeviceLanguage_isACodeTheServerAccepts() throws {
        let pattern = try NSRegularExpression(pattern: "^[a-z]{2}$")
        for language in ModelManifest.pinned.entries.flatMap(\.languages) {
            XCTAssertNotNil(pattern.firstMatch(in: language, range: NSRange(language.startIndex..., in: language)), language)
        }
    }

    func test_fitted_isNil_whenTheWordsAloneExceedTheTextLimit() {
        let long = String(repeating: "x", count: 1_999)
        let segments = (0..<301).map { i in
            DeviceTranscript.Segment(speaker: i % 2 == 0 ? "me" : "them", start: Double(i), end: Double(i) + 0.5, text: long, confidence: 0.9)
        }
        let transcript = DeviceTranscript.build(source: DeviceFixtures.source, language: "en", durationSeconds: 400, segments: segments)
        XCTAssertNil(transcript.fitted(), "602k characters cannot be merged under 600k; the stop must fail, not send a rejected body")
    }
}
