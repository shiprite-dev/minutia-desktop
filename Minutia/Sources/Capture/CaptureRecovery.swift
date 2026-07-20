import Foundation
import AVFoundation

/// Resolves the durable captures root. Recordings live under Application Support (survives quit and
/// crash) rather than the purgeable temporary directory, so an interrupted meeting can be salvaged
/// on the next launch. The base directory is injectable so tests never touch the real container.
enum CaptureStore {
    static func capturesRoot(appSupport: URL? = nil) throws -> URL {
        let base = try appSupport ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = base
            .appendingPathComponent("Minutia", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

/// Written into each capture directory at start so an orphaned recording carries everything the
/// recovery sweep needs to finalize it without any live session state. `seriesId` is nil for
/// web-triggered records (no series is known at that entry point).
struct CaptureManifest: Codable, Equatable {
    let meetingId: String
    let seriesId: String?
    let instanceURL: URL
    /// The lowercased uuid of the user who recorded this meeting, so cross-account recovery can be
    /// gated (a recording captured by user A must not be re-uploaded while user B is signed in on the
    /// same instance). Nil-tolerant: manifests written by older builds have no user id and are
    /// treated as recoverable.
    let userId: String?
    let createdAt: Date
    /// How many startup recovery finalizes have already failed for this capture. Bounds the sweep: at
    /// the ceiling the directory is left alone so a deterministically-dead recording never retries on
    /// every launch forever. Older manifests have no field and decode as 0.
    var recoveryAttempts: Int
    /// True once the terminal "transcription unavailable" notification has been posted for this
    /// directory, so it is not re-posted on every later launch or auth transition. Decodes false.
    var notified: Bool

    init(meetingId: String, seriesId: String?, instanceURL: URL, userId: String?, createdAt: Date,
         recoveryAttempts: Int = 0, notified: Bool = false) {
        self.meetingId = meetingId
        self.seriesId = seriesId
        self.instanceURL = instanceURL
        self.userId = userId
        self.createdAt = createdAt
        self.recoveryAttempts = recoveryAttempts
        self.notified = notified
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meetingId = try c.decode(String.self, forKey: .meetingId)
        seriesId = try c.decodeIfPresent(String.self, forKey: .seriesId)
        instanceURL = try c.decode(URL.self, forKey: .instanceURL)
        userId = try c.decodeIfPresent(String.self, forKey: .userId)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        recoveryAttempts = try c.decodeIfPresent(Int.self, forKey: .recoveryAttempts) ?? 0
        notified = try c.decodeIfPresent(Bool.self, forKey: .notified) ?? false
    }
}

/// Startup salvage for capture directories left behind by a quit, crash, or fatal mid-recording.
/// A directory is recoverable once it holds both a manifest and the full `recording.m4a`; the
/// sweep mirrors `CaptureSession.stop`'s finalize so a rescued meeting reaches the same server
/// state as a cleanly stopped one.
enum CaptureRecovery {
    static let manifestName = "manifest.json"
    static let recordingName = "recording.m4a"

    /// Subdirectories of `root` that hold both a manifest and a recording, excluding the active
    /// meeting's own directory (matched case-insensitively, since a Swift UUID string is uppercase
    /// but the on-disk directory is the lowercased id). Pure and sorted for deterministic sweeps.
    nonisolated static func recoverableDirectories(in root: URL, excluding activeMeetingId: String?) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        let active = activeMeetingId?.lowercased()
        return entries.filter { dir in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return false }
            if let active, dir.lastPathComponent.lowercased() == active { return false }
            let hasManifest = fm.fileExists(atPath: dir.appendingPathComponent(manifestName).path)
            let hasRecording = fm.fileExists(atPath: dir.appendingPathComponent(recordingName).path)
            return hasManifest && hasRecording
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func loadManifest(from directory: URL) -> CaptureManifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(manifestName)) else { return nil }
        return try? JSONDecoder().decode(CaptureManifest.self, from: data)
    }

    /// Rewrites the manifest in place so the sweep's persisted counters (recoveryAttempts, notified)
    /// survive across launches. Best-effort: a write failure just means the next launch re-derives.
    static func saveManifest(_ manifest: CaptureManifest, to directory: URL) {
        try? JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent(manifestName))
    }

    /// Recovery is scoped to the connected instance: a recording captured against instance A must
    /// never be re-uploaded while signed into instance B (no such meeting row exists there, so every
    /// attempt throws and the directory orphans forever, re-uploading on every launch). True only
    /// when the manifest's instance matches the connected one, compared through InstanceConfig
    /// .normalize so a trailing slash or scheme/host casing difference never splits an otherwise
    /// identical instance.
    nonisolated static func shouldRecover(
        manifest: CaptureManifest, connectedInstance: URL, connectedUserId: String?
    ) -> Bool {
        let manifestInstance = InstanceConfig.normalize(manifest.instanceURL.absoluteString) ?? manifest.instanceURL
        let connected = InstanceConfig.normalize(connectedInstance.absoluteString) ?? connectedInstance
        guard manifestInstance == connected else { return false }
        // Cross-account gate: only refuse when both ids are known and differ. A nil on either side
        // (older manifest, or an unavailable session) stays recoverable so the instance match alone
        // still salvages the recording.
        if let manifestUser = manifest.userId, let connectedUserId, manifestUser != connectedUserId {
            return false
        }
        return true
    }

    /// Finalize an orphaned recording: best-effort re-upload of any fast-lane segments (server
    /// register is idempotent by seq), then upload the full recording, finalize the meeting, and
    /// request transcription. On success the CALLER deletes the directory; a throw leaves it intact
    /// for the next launch to retry.
    static func recover(directory: URL, manifest: CaptureManifest, client: MinutiaClient) async throws {
        let fm = FileManager.default

        let segments = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in segments {
            guard let seq = segmentSeq(from: url.lastPathComponent) else { continue }
            try? await client.uploadSegment(meetingId: manifest.meetingId, seq: seq, fileURL: url)
            _ = try? await client.registerSegment(meetingId: manifest.meetingId, seq: seq)
        }

        let recordingURL = directory.appendingPathComponent(recordingName)
        let path = try await client.uploadRecording(meetingId: manifest.meetingId, fileURL: recordingURL)
        let duration = (try? Self.duration(of: recordingURL)) ?? 0
        let attrs = try? fm.attributesOfItem(atPath: recordingURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        try await client.finalizeMeeting(meetingId: manifest.meetingId, audioPath: path, duration: duration, sizeBytes: size)
        try await client.requestTranscription(meetingId: manifest.meetingId, expectedSegments: nil)
    }

    /// "seg-3.m4a" -> 3; nil for the recording file or any other entry.
    static func segmentSeq(from name: String) -> Int? {
        guard name.hasPrefix("seg-"), name.hasSuffix(".m4a") else { return nil }
        return Int(name.dropFirst(4).dropLast(4))
    }

    private static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
