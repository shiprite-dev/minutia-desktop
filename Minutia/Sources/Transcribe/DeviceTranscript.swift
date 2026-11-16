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
    }

    struct Segment: Codable, Equatable, Sendable {
        let speaker: String
        let start: Double
        let end: Double
        let text: String
        let confidence: Double?
    }

    var schemaVersion = 1
    let source: Source
    let language: String
    let durationSeconds: Double
    let outcome: String
    let segments: [Segment]

    static let maxSegmentText = 2000
    static let endSlackSeconds = 5.0

    /// Sorts by start (me before them on a tie), drops empty text, clamps times into
    /// `0...durationSeconds`, splits text over `maxSegmentText` at word boundaries, and sets the
    /// outcome: speech with at least one segment, else no_speech with none.
    static func build(source: Source, language: String, durationSeconds: Double, segments: [Segment]) -> DeviceTranscript {
        DeviceTranscript(source: source, language: language, durationSeconds: durationSeconds, outcome: "", segments: [])
    }

    /// One channel's engine output, labeled and shifted onto the meeting clock.
    static func labeled(_ result: SpeechResult, speaker: SegmentChannel, offset: Double) -> [Segment] {
        []
    }

    func encoded() throws -> Data {
        Data()
    }
}

extension DeviceTranscript.Source {
    static let fluidAudioVersion = ""

    static func onDevice(_ entry: ModelManifest.Entry, appVersion: String) -> DeviceTranscript.Source {
        DeviceTranscript.Source(engine: "", engineVersion: "", model: "", modelRevision: "", appVersion: "", compute: "")
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
