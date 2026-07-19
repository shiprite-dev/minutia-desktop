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

enum MinutiaClientError: Error {
    /// A retriable server failure (5xx other than the terminal 503).
    case serverError(status: Int)
}

/// API contract layer: pure request builders (unit tested) plus thin async ops
/// that wrap supabase-swift (PostgREST/Storage/RPC) and the Minutia BFF routes.
struct MinutiaClient {
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

    static func segmentPath(meetingId: String, seq: Int) -> String {
        "\(meetingId.lowercased())/seg-\(seq).m4a"
    }

    static func recordingPath(meetingId: String) -> String {
        "\(meetingId.lowercased())/recording.m4a"
    }

    static func registerSegmentRequest(instance: URL, meetingId: String, seq: Int, token: String) -> URLRequest {
        let meetingId = meetingId.lowercased()
        var request = bearerRequest(
            instance.appendingPathComponent("api/meetings/\(meetingId)/segments/\(seq)/transcribe"),
            method: "POST",
            token: token
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["path": segmentPath(meetingId: meetingId, seq: seq)])
        return request
    }

    static func finalTranscribeRequest(instance: URL, meetingId: String, expectedSegments: Int?, token: String) -> URLRequest {
        let meetingId = meetingId.lowercased()
        var request = bearerRequest(
            instance.appendingPathComponent("api/meetings/\(meetingId)/transcribe"),
            method: "POST",
            token: token
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Int] = expectedSegments.map { ["expected_segments": $0] } ?? [:]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
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

    func uploadSegment(meetingId: String, seq: Int, fileURL: URL) async throws {
        try await supabase.storage
            .from(Self.audioBucket)
            .upload(
                Self.segmentPath(meetingId: meetingId, seq: seq),
                fileURL: fileURL,
                options: FileOptions(contentType: "audio/mp4", upsert: true)
            )
    }

    func registerSegment(meetingId: String, seq: Int) async throws -> Bool {
        let token = try await tokenProvider()
        let request = Self.registerSegmentRequest(instance: instance, meetingId: meetingId, seq: seq, token: token)
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if (200...299).contains(status) || status == 409 { return true }
        if status == 503 || (400...499).contains(status) {
            Self.logger.notice("Segment transcription terminal status \(status, privacy: .public) for meeting \(meetingId, privacy: .public) seq \(seq)")
            return false
        }
        throw MinutiaClientError.serverError(status: status)
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

    func requestTranscription(meetingId: String, expectedSegments: Int?) async throws {
        let token = try await tokenProvider()
        let request = Self.finalTranscribeRequest(instance: instance, meetingId: meetingId, expectedSegments: expectedSegments, token: token)
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(status) {
            Self.logger.notice("requestTranscription non-2xx status \(status, privacy: .public) for meeting \(meetingId, privacy: .public)")
        }
        // 503 is terminal-not-configured; the transcript can still be assembled from
        // fast-lane segments, so it is not a hard failure. Retriable 5xx throws.
        if status >= 500 && status != 503 {
            throw MinutiaClientError.serverError(status: status)
        }
    }

    /// Announces this companion instance to the web app. Fire-and-forget: failures are ignored so a
    /// flaky network or a not-yet-deployed route never blocks sign-in or launch.
    func heartbeat() async {
        do {
            let token = try await tokenProvider()
            let request = Self.heartbeatRequest(instance: instance, token: token)
            _ = try await URLSession.shared.data(for: request)
        } catch {
            Self.logger.debug("heartbeat skipped: \(error.localizedDescription, privacy: .public)")
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
