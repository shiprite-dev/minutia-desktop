import Foundation
import OSLog
import Supabase

struct Series: Codable, Identifiable {
    let id: UUID
    let name: String
}

struct Meeting: Codable {
    let id: UUID
    let title: String
}

struct AgendaItem: Codable {
    let seriesId: UUID?
    let meetingId: UUID?
    let title: String
    let startAt: Date
    let endAt: Date
    let meetingUrl: String?
}

/// GET /api/calendar/agenda envelope: connection state plus the event list.
private struct AgendaResponse: Codable {
    let events: [AgendaItem]
}

enum SegmentChannel: String { case me, them }

enum MinutiaClientError: Error, Equatable {
    /// A retriable server failure (5xx other than the terminal 503).
    case serverError(status: Int)
    /// The account lacks the AI transcription entitlement: a 403 whose JSON body carries
    /// code "FEATURE_UNAVAILABLE". Terminal (no retry) and surfaced to the user, never swallowed.
    case featureUnavailable
    /// A zero-row notes update: the meeting is gone or the user cannot write it. Terminal.
    case meetingNotWritable
}

struct CheckinClaim: Equatable {
    let meetingId: String
    let seriesId: String
}

enum RecordingResult: Equatable {
    case ok
    case conflict
    case ignored
}

/// API contract layer: pure request builders (unit tested) plus thin async ops
/// that wrap supabase-swift (PostgREST/Storage/RPC) and the Minutia BFF routes.
struct MinutiaClient {
    enum RecordingEvent: String {
        case started
        case failed
        case stopped
    }

    let instance: URL
    let supabase: SupabaseClient
    let tokenProvider: () async throws -> String

    static let audioBucket = "meeting-audio"

    private static let logger = Logger(subsystem: "app.minutia.desktop", category: "MinutiaClient")

    /// Tolerant decoder for BFF JSON: accepts ISO8601 timestamps with or without
    /// fractional seconds, matching the web `GoogleCalendarAgendaItem` shape.
    static let jsonDecoder: JSONDecoder = {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = withFractional.date(from: raw) ?? plain.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(raw)")
        }
        return decoder
    }()

    // MARK: - Pure request builders

    // Storage object paths and meeting routes are lowercased at construction: the storage.objects
    // RLS policy compares the path's meeting folder to the (lowercase, canonical) meeting id
    // case-sensitively, so a Swift `UUID.uuidString` (uppercase) would be denied on every upload.

    static func segmentPath(meetingId: String, seq: Int, channel: SegmentChannel) -> String {
        "\(meetingId.lowercased())/seg-\(seq)-\(channel.rawValue).m4a"
    }

    static func recordingPath(meetingId: String) -> String {
        "\(meetingId.lowercased())/recording.m4a"
    }

    static func registerSegmentRequest(instance: URL, meetingId: String, seq: Int, offsetSeconds: Double? = nil, token: String) -> URLRequest {
        let meetingId = meetingId.lowercased()
        var request = bearerRequest(
            instance.appendingPathComponent("api/meetings/\(meetingId)/segments/\(seq)/transcribe"),
            method: "POST",
            token: token
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "paths": [
                "me": segmentPath(meetingId: meetingId, seq: seq, channel: .me),
                "them": segmentPath(meetingId: meetingId, seq: seq, channel: .them),
            ],
            "offset_seconds": offsetSeconds ?? Double(seq) * SegmentWriter.segmentSeconds,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func finalTranscribeRequest(instance: URL, meetingId: String, expectedSegments: Int?, deferExtraction: Bool = false, token: String) -> URLRequest {
        let meetingId = meetingId.lowercased()
        var request = bearerRequest(
            instance.appendingPathComponent("api/meetings/\(meetingId)/transcribe"),
            method: "POST",
            token: token
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = expectedSegments.map { ["expected_segments": $0] } ?? [:]
        if deferExtraction { body["defer_extraction"] = true }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    struct CompanionNotesUpdate: Encodable, Equatable {
        let companion_notes_markdown: String
    }

    static func companionNotesUpdate(text: String) -> CompanionNotesUpdate {
        CompanionNotesUpdate(companion_notes_markdown: NotepadDraft.clamp(text))
    }

    struct EndMeetingUpdate: Encodable {
        let status: String
        let completed_at: String
    }

    static func endMeetingUpdate(now: Date = Date()) -> EndMeetingUpdate {
        EndMeetingUpdate(status: "completed", completed_at: ISO8601DateFormatter().string(from: now))
    }

    func endMeeting(meetingId: String) async throws {
        try await supabase
            .from("meetings")
            .update(Self.endMeetingUpdate())
            .eq("id", value: Self.meetingLookupId(meetingId))
            .neq("status", value: "completed")
            .execute()
    }

    static func summaryWarmupRequest(instance: URL, meetingId: String, token: String) -> URLRequest {
        bearerRequest(
            instance.appendingPathComponent("api/meetings/\(meetingId.lowercased())/summary/stream"),
            method: "POST",
            token: token
        )
    }

    static func agendaRequest(instance: URL, token: String) -> URLRequest {
        bearerRequest(instance.appendingPathComponent("api/calendar/agenda"), method: "GET", token: token)
    }

    static func heartbeatRequest(instance: URL, token: String) -> URLRequest {
        bearerRequest(instance.appendingPathComponent("api/companion/heartbeat"), method: "POST", token: token)
    }

    static func checkinRequest(instance: URL, token: String, deviceId: String, deviceName: String, canClaim: Bool) -> URLRequest {
        var request = bearerRequest(instance.appendingPathComponent("api/companion/checkin"), method: "POST", token: token)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "device_id": deviceId, "device_name": deviceName, "can_claim": canClaim,
        ] as [String: Any])
        return request
    }

    static func decodeCheckin(_ data: Data) -> CheckinClaim? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let claim = object["claim"] as? [String: Any],
              let meetingId = (claim["meeting_id"] as? String).flatMap(UUID.init(uuidString:)),
              let seriesId = (claim["series_id"] as? String).flatMap(UUID.init(uuidString:))
        else { return nil }
        return CheckinClaim(
            meetingId: meetingId.uuidString.lowercased(), seriesId: seriesId.uuidString.lowercased())
    }

    static func recordingEventRequest(
        instance: URL, token: String, meetingId: String, deviceId: String, deviceName: String,
        event: RecordingEvent, reason: String?
    ) -> URLRequest {
        var request = bearerRequest(instance.appendingPathComponent("api/companion/recording"), method: "POST", token: token)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "meeting_id": meetingId.lowercased(), "device_id": deviceId,
            "device_name": deviceName, "event": event.rawValue,
        ]
        if let reason { body["reason"] = reason }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func decodeRecordingResult(_ data: Data) -> RecordingResult {
        let raw = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? String
        switch raw {
        case "ok": return .ok
        case "conflict": return .conflict
        default: return .ignored
        }
    }

    /// Browser sign-in entry point: the instance mints a companion magic link that redirects back
    /// to `minutia://auth-callback`. `device` labels the session in the web UI (percent-encoded by
    /// URLComponents). `state` carries the locally-generated nonce that binds the callback to this
    /// sign-in attempt; appended only when present so the server can echo it back.
    static func companionAuthorizeURL(instance: URL, device: String, state: String? = nil) -> URL {
        var components = URLComponents(
            url: instance.appendingPathComponent("companion/authorize"),
            resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "device", value: device)]
        if let state { items.append(URLQueryItem(name: "state", value: state)) }
        components.queryItems = items
        return components.url!
    }

    private static func bearerRequest(_ url: URL, method: String, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Response classification

    /// The single classification of a transcribe-route HTTP response, shared by `registerSegment`
    /// and `requestTranscription` so the terminal-vs-retry decision lives in one tested place.
    enum ResponseClass: Equatable {
        case ok
        /// 403 with body code "FEATURE_UNAVAILABLE": the account has no AI entitlement. Terminal.
        case featureUnavailable
        /// Bare 401: supabase-swift refreshes the token transparently, so this retries.
        case authExpired
        /// 5xx (other than the legacy terminal 503) and network/timeout: retry with backoff.
        case transientRetryable
        /// A 403 without the entitlement code, other terminal 4xx, and 503: retrying will not succeed.
        case terminalOther
    }

    /// Pure: depends only on the status and the optional JSON body. A 403 carrying
    /// {"code":"FEATURE_UNAVAILABLE"} is the entitlement failure; a bare 401 is a token expiry, but a
    /// 403 without that code is terminal (a proxy-mangled or genuinely-forbidden body, not a
    /// refreshable token) so it never degrades into a silent retry storm.
    static func classify(status: Int, body: Data?) -> ResponseClass {
        if (200...299).contains(status) { return .ok }
        if status == 403 {
            return Self.errorCode(from: body) == "FEATURE_UNAVAILABLE" ? .featureUnavailable : .terminalOther
        }
        if status == 401 { return .authExpired }
        if status == 503 { return .terminalOther }
        if (500...599).contains(status) { return .transientRetryable }
        if (400...499).contains(status) { return .terminalOther }
        return .transientRetryable
    }

    private static func errorCode(from body: Data?) -> String? {
        guard let body, !body.isEmpty else { return nil }
        struct ErrorEnvelope: Decodable { let code: String? }
        return (try? JSONDecoder().decode(ErrorEnvelope.self, from: body))?.code
    }

    // MARK: - Async ops

    func ownedSeries() async throws -> [Series] {
        let uid = try await supabase.auth.session.user.id
        let response: PostgrestResponse<[Series]> = try await supabase
            .from("meeting_series")
            .select("id,name")
            .eq("owner_id", value: uid.uuidString)
            .order("name")
            .execute()
        return response.value
    }

    func startOrJoinMeeting(seriesId: UUID) async throws -> Meeting {
        let response: PostgrestResponse<Meeting> = try await supabase
            .rpc("start_or_join_meeting", params: ["target_series_id": seriesId.uuidString])
            .execute()
        return response.value
    }

    func uploadSegment(meetingId: String, segment: SegmentWriter.ClosedSegment) async throws {
        for (channel, fileURL) in [(SegmentChannel.me, segment.micURL), (.them, segment.sysURL)] {
            try await supabase.storage
                .from(Self.audioBucket)
                .upload(
                    Self.segmentPath(meetingId: meetingId, seq: segment.seq, channel: channel),
                    fileURL: fileURL,
                    options: FileOptions(contentType: "audio/mp4", upsert: true)
                )
        }
    }

    func registerSegment(meetingId: String, seq: Int, offsetSeconds: Double) async throws -> Bool {
        let token = try await tokenProvider()
        let request = Self.registerSegmentRequest(instance: instance, meetingId: meetingId, seq: seq, offsetSeconds: offsetSeconds, token: token)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 409 { return true }
        switch Self.classify(status: status, body: data) {
        case .ok:
            return true
        case .featureUnavailable:
            // Terminal and account-wide: the entitlement will not appear mid-retry. Throw so
            // UploadQueue stops retrying and surfaces it once, rather than spinning to the ceiling.
            throw MinutiaClientError.featureUnavailable
        case .authExpired, .transientRetryable:
            // authExpired throws so the backoff retries with a token supabase-swift refreshes.
            throw MinutiaClientError.serverError(status: status)
        case .terminalOther:
            Self.logger.notice("Segment transcription terminal status \(status, privacy: .public) for meeting \(meetingId, privacy: .public) seq \(seq)")
            return false
        }
    }

    func uploadRecording(meetingId: String, fileURL: URL) async throws -> String {
        let path = Self.recordingPath(meetingId: meetingId)
        try await supabase.storage
            .from(Self.audioBucket)
            .upload(path, fileURL: fileURL, options: FileOptions(contentType: "audio/mp4", upsert: true))
        return path
    }

    func finalizeMeeting(meetingId: String, audioPath: String, duration: Double, sizeBytes: Int64) async throws {
        struct FinalizeUpdate: Encodable {
            let audio_file_path: String
            let audio_duration_seconds: Int
            let audio_file_size_bytes: Int64
            let transcription_status: String
        }
        let update = FinalizeUpdate(
            audio_file_path: audioPath,
            audio_duration_seconds: Int(duration.rounded()),
            audio_file_size_bytes: sizeBytes,
            transcription_status: "pending"
        )
        try await supabase
            .from("meetings")
            .update(update)
            .eq("id", value: meetingId)
            .execute()
    }

    func syncCompanionNotes(meetingId: String, text: String) async throws {
        struct Row: Decodable { let id: UUID }
        let response: PostgrestResponse<[Row]> = try await supabase
            .from("meetings")
            .update(Self.companionNotesUpdate(text: text))
            .eq("id", value: Self.meetingLookupId(meetingId))
            .select("id")
            .execute()
        if response.value.isEmpty { throw MinutiaClientError.meetingNotWritable }
    }

    func requestTranscription(meetingId: String, expectedSegments: Int?, deferExtraction: Bool = false) async throws {
        let token = try await tokenProvider()
        let request = Self.finalTranscribeRequest(instance: instance, meetingId: meetingId, expectedSegments: expectedSegments, deferExtraction: deferExtraction, token: token)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(status) {
            Self.logger.notice("requestTranscription non-2xx status \(status, privacy: .public) for meeting \(meetingId, privacy: .public)")
        }
        switch Self.classify(status: status, body: data) {
        case .ok:
            return
        case .featureUnavailable:
            // The stop path must tell the user and keep the local audio, never delete it silently.
            throw MinutiaClientError.featureUnavailable
        case .authExpired, .transientRetryable:
            throw MinutiaClientError.serverError(status: status)
        case .terminalOther:
            // 503 is the legacy "transcription not configured" signal: the transcript can still be
            // assembled from the fast-lane segments, so it alone is not a hard failure. Every other
            // terminal 4xx must throw so the caller never treats the request as accepted and deletes
            // the local audio with no server transcript (data loss).
            if status == 503 { return }
            throw MinutiaClientError.serverError(status: status)
        }
    }

    /// Resolves a meeting's parent series id so the recap URL can be built for a web-triggered
    /// record (which carries no series at start). Decodes tolerant of a null `series_id`. The id is
    /// lowercased through `meetingLookupId` to match the canonical DB row.
    func meetingSeriesId(meetingId: String) async throws -> UUID? {
        struct Row: Decodable { let series_id: UUID? }
        let response: PostgrestResponse<Row> = try await supabase
            .from("meetings")
            .select("series_id")
            .eq("id", value: Self.meetingLookupId(meetingId))
            .single()
            .execute()
        return response.value.series_id
    }

    /// Reads a meeting's status so a recording can follow the meeting's end: the web app ends a
    /// meeting by setting this to "completed". A single-row select of the recording user's own
    /// meeting row (RLS lets them read it); the id is lowercased through `meetingLookupId` to match
    /// the canonical DB row.
    func meetingStatus(meetingId: String) async throws -> String? {
        struct Row: Decodable { let status: String? }
        let response: PostgrestResponse<Row> = try await supabase
            .from("meetings")
            .select("status")
            .eq("id", value: Self.meetingLookupId(meetingId))
            .single()
            .execute()
        return response.value.status
    }

    /// The meetings-table lookup id: lowercased to match the canonical DB id (Swift `UUID.uuidString`
    /// is uppercase). The shared seam so a recap-resolution query is never issued with an uppercase id.
    static func meetingLookupId(_ meetingId: String) -> String { meetingId.lowercased() }

    /// The web app's recap route for a meeting (src/app/(app)/series/[id]/meetings/[meetingId] on
    /// the server). The single builder for every place that opens a recap, so the shape and the
    /// lowercase-id rule cannot drift between call sites.
    static func recapURL(instance: URL, seriesId: UUID, meetingId: UUID, autoRecap: Bool = false) -> URL {
        let url = instance.appendingPathComponent(
            "series/\(seriesId.uuidString.lowercased())/meetings/\(meetingId.uuidString.lowercased())")
        guard autoRecap, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = [URLQueryItem(name: "recap", value: "auto")]
        return components.url ?? url
    }

    func checkin(deviceId: String, deviceName: String, canClaim: Bool) async -> CheckinClaim? {
        do {
            let token = try await tokenProvider()
            let request = Self.checkinRequest(
                instance: instance, token: token, deviceId: deviceId, deviceName: deviceName, canClaim: canClaim)
            let (data, _) = try await URLSession.shared.data(for: request)
            return Self.decodeCheckin(data)
        } catch {
            Self.logger.debug("checkin skipped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func recordingEvent(
        meetingId: String, deviceId: String, deviceName: String, event: RecordingEvent, reason: String? = nil
    ) async -> RecordingResult {
        do {
            let token = try await tokenProvider()
            let request = Self.recordingEventRequest(
                instance: instance, token: token, meetingId: meetingId, deviceId: deviceId,
                deviceName: deviceName, event: event, reason: reason)
            let (data, _) = try await URLSession.shared.data(for: request)
            return Self.decodeRecordingResult(data)
        } catch {
            Self.logger.debug("recording event skipped: \(error.localizedDescription, privacy: .public)")
            return .ignored
        }
    }

    func warmSummary(meetingId: String) async {
        do {
            let token = try await tokenProvider()
            let request = Self.summaryWarmupRequest(instance: instance, meetingId: meetingId, token: token)
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            // Fire-and-drain: kick the recap generation warm, discard the stream.
            for try await _ in bytes.lines {}
        } catch {
            Self.logger.debug("warmSummary drained with error: \(error.localizedDescription, privacy: .public)")
        }
    }

    func agenda() async throws -> [AgendaItem] {
        let token = try await tokenProvider()
        let request = Self.agendaRequest(instance: instance, token: token)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try Self.jsonDecoder.decode(AgendaResponse.self, from: data).events
    }
}
