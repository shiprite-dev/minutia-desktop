import Foundation

/// Body of `POST /api/meetings/[meetingId]/transcript`; mirrors the strict Zod schema in the web
/// repo's `src/lib/transcription/device.ts` (schema_version 1).
struct DeviceTranscript: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        var kind = "device"
        let engine: String
        let engineVersion: String
        let model: String
        let modelRevision: String
        let appVersion: String
        let compute: String

        enum CodingKeys: String, CodingKey {
            case kind, engine, model, compute
            case engineVersion = "engine_version"
            case modelRevision = "model_revision"
            case appVersion = "app_version"
        }
    }

    struct Segment: Codable, Equatable, Sendable {
        let speaker: String
        let start: Double
        let end: Double
        let text: String
        let confidence: Double?

        enum CodingKeys: String, CodingKey { case speaker, start, end, text, confidence }
    }

    enum CodingKeys: String, CodingKey {
        case source, language, outcome, segments
        case schemaVersion = "schema_version"
        case durationSeconds = "duration_seconds"
    }

    var schemaVersion = 1
    let source: Source
    let language: String
    let durationSeconds: Double
    let outcome: String
    let segments: [Segment]

    static let maxSegmentText = 2000
    static let maxBodyBytes = 2_097_152
    static let maxSegments = 20_000
    static let maxTotalText = 600_000
    static let maxDurationSeconds = 21_600.0

    /// Merges adjacent same-speaker segments (meeting-clock order, merged text at most
    /// `maxSegmentText`, the joining space counted) only as far as needed for the encoded body, the
    /// segment count and the total text to fit the server limits. Unchanged when it already fits; nil
    /// when it cannot fit.
    func fitted() -> DeviceTranscript? {
        var current = self
        while true {
            let bytes = (try? current.encoded().count) ?? .max
            if current.fits(bytes: bytes) { break }
            guard current.segments.reduce(0, { $0 + $1.text.utf16.count }) <= Self.maxTotalText else { return nil }
            let wanted = max(1, current.segments.count - Self.maxSegments, (bytes - Self.maxBodyBytes) / 200)
            let merged = current.mergedPairs(limit: wanted)
            guard merged.count < current.segments.count else { return nil }
            current = DeviceTranscript(
                source: source, language: language, durationSeconds: durationSeconds, outcome: outcome, segments: merged)
        }
        return current
    }

    private func fits(bytes: Int) -> Bool {
        segments.count <= Self.maxSegments
            && segments.reduce(0) { $0 + $1.text.utf16.count } <= Self.maxTotalText
            && bytes <= Self.maxBodyBytes
    }

    private func mergedPairs(limit: Int) -> [Segment] {
        var out: [Segment] = []
        var lastMergedHere = false
        var merges = 0
        for segment in segments {
            if merges < limit, let previous = out.last, !lastMergedHere, previous.speaker == segment.speaker,
               previous.text.utf16.count + 1 + segment.text.utf16.count <= Self.maxSegmentText {
                let weights = (Double(previous.text.utf16.count), Double(segment.text.utf16.count))
                let confidence = previous.confidence.flatMap { a in
                    segment.confidence.map { b in Self.rounded((a * weights.0 + b * weights.1) / (weights.0 + weights.1)) }
                }
                out[out.count - 1] = Segment(
                    speaker: segment.speaker, start: previous.start, end: segment.end,
                    text: previous.text + " " + segment.text, confidence: confidence)
                lastMergedHere = true
                merges += 1
            } else {
                out.append(segment)
                lastMergedHere = false
            }
        }
        return out
    }

    private static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    /// Sorts by start (me before them on a tie), drops empty text, clamps times into
    /// `0...durationSeconds`, splits text over `maxSegmentText` at word boundaries, and sets the
    /// outcome: speech with at least one segment, else no_speech with none.
    static func build(source: Source, language: String, durationSeconds: Double, segments: [Segment]) -> DeviceTranscript {
        let durationSeconds = min(durationSeconds, maxDurationSeconds)
        let kept = segments.enumerated().flatMap { index, segment -> [(index: Int, segment: Segment)] in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            let start = min(max(segment.start, 0), durationSeconds)
            let end = min(max(segment.end, start), durationSeconds)
            let confidence = segment.confidence.map { min(max($0, 0), 1) }
            return split(text, start: start, end: end).map {
                (index, Segment(speaker: segment.speaker, start: $0.start, end: $0.end, text: $0.text, confidence: confidence))
            }
        }
        let ordered = kept.enumerated().sorted { a, b in
            let (x, y) = (a.element.segment, b.element.segment)
            if x.start != y.start { return x.start < y.start }
            if x.speaker != y.speaker { return x.speaker == "me" }
            return a.offset < b.offset
        }.map(\.element.segment)
        let rounded = ordered.map {
            Segment(speaker: $0.speaker, start: Self.rounded($0.start), end: Self.rounded($0.end), text: $0.text,
                    confidence: $0.confidence.map(Self.rounded))
        }
        return DeviceTranscript(
            source: source, language: language, durationSeconds: durationSeconds,
            outcome: rounded.isEmpty ? "no_speech" : "speech", segments: rounded)
    }

    private static func split(_ text: String, start: Double, end: Double) -> [(text: String, start: Double, end: Double)] {
        var pieces: [String] = []
        var rest = Substring(text)
        while rest.utf16.count > maxSegmentText {
            var units = 0
            var prefixEnd = rest.startIndex
            for i in rest.indices {
                let next = units + String(rest[i]).utf16.count
                if next > maxSegmentText { break }
                units = next
                prefixEnd = rest.index(after: i)
            }
            let window = rest[..<prefixEnd]
            let cut = window.lastIndex(of: " ").flatMap { $0 > window.startIndex ? $0 : nil } ?? prefixEnd
            pieces.append(String(rest[..<cut]))
            rest = rest[cut...].drop { $0 == " " }
        }
        pieces.append(String(rest))
        pieces = pieces.filter { !$0.isEmpty }
        let total = Double(pieces.reduce(0) { $0 + $1.utf16.count })
        var consumed = 0.0
        return pieces.enumerated().map { index, piece in
            let from = index == 0 ? start : start + (end - start) * consumed / total
            consumed += Double(piece.utf16.count)
            let to = index == pieces.count - 1 ? end : start + (end - start) * consumed / total
            return (piece, from, to)
        }
    }

    /// One channel's engine output, labeled and shifted onto the meeting clock.
    static func labeled(_ result: SpeechResult, speaker: SegmentChannel, offset: Double) -> [Segment] {
        result.segments.map {
            Segment(speaker: speaker.rawValue, start: $0.start + offset, end: $0.end + offset, text: $0.text, confidence: $0.confidence)
        }
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

extension DeviceTranscript.Source {
    static let fluidAudioVersion = "0.18.2"

    static func onDevice(_ entry: ModelManifest.Entry, appVersion: String) -> DeviceTranscript.Source {
        DeviceTranscript.Source(
            engine: "fluidaudio", engineVersion: fluidAudioVersion, model: entry.id, modelRevision: entry.revision,
            appVersion: appVersion, compute: "ane")
    }
}

/// The network surface of a device-mode stop. Deliberately has no audio upload, finalize or
/// transcribe call, so the device path cannot reach the audio bucket or the cloud routes.
protocol DeviceTranscriptTransport {
    /// PATCH meetings: transcription_status pending, transcription_provider device, duration.
    func markAwaitingDeviceTranscript(meetingId: String, durationSeconds: Double) async throws
    /// POST the encoded body; returns the HTTP status.
    func submitDeviceTranscript(meetingId: String, body: Data) async throws -> Int
    func warmSummary(meetingId: String) async
    func endMeeting(meetingId: String) async throws
}

extension MinutiaClient: DeviceTranscriptTransport {}
