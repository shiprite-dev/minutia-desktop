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
    /// True once a terminal notice was posted for this directory. Decodes false.
    var notified: Bool
    let transcriptionMode: TranscriptionMode
    let deviceOnly: Bool
    let language: String?
    var localFailed: Bool

    init(meetingId: String, seriesId: String?, instanceURL: URL, userId: String?, createdAt: Date,
         recoveryAttempts: Int = 0, notified: Bool = false, transcriptionMode: TranscriptionMode = .cloud,
         deviceOnly: Bool = false, language: String? = nil, localFailed: Bool = false) {
        self.meetingId = meetingId
        self.seriesId = seriesId
        self.instanceURL = instanceURL
        self.userId = userId
        self.createdAt = createdAt
        self.recoveryAttempts = recoveryAttempts
        self.notified = notified
        self.transcriptionMode = transcriptionMode
        self.deviceOnly = deviceOnly
        self.language = language
        self.localFailed = localFailed
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
        transcriptionMode = c.contains(.transcriptionMode)
            ? (try? c.decode(TranscriptionMode.self, forKey: .transcriptionMode)) ?? .device
            : .cloud
        deviceOnly = try c.decodeIfPresent(Bool.self, forKey: .deviceOnly) ?? false
        language = try c.decodeIfPresent(String.self, forKey: .language)
        localFailed = try c.decodeIfPresent(Bool.self, forKey: .localFailed) ?? false
    }

    var audioMayLeaveMac: Bool { transcriptionMode == .cloud && !deviceOnly }
}

/// Startup salvage for capture directories left behind by a quit, crash, or fatal mid-recording.
/// A directory is recoverable once it holds both a manifest and the full `recording.m4a`; the
/// sweep mirrors `CaptureSession.stop`'s finalize so a rescued meeting reaches the same server
/// state as a cleanly stopped one.
enum CaptureRecovery {
    static let manifestName = "manifest.json"
    static let recordingName = "recording.m4a"

    enum RecoveryError: Error, Equatable { case unreadableRecording, audioStaysOnThisMac, transcriptNotFinished, deferred }

    static let transcriptName = "transcript.json"

    /// Segment audio must cover this share of the recording before its transcript may stand for the meeting.
    static let minimumCoverage = 0.9

    /// Sends a device meeting's finished `transcript.json` again without marking the meeting pending
    /// (a completed meeting replays as 200). Throws `transcriptNotFinished` (no request made,
    /// directory kept) when there is no transcript.
    static func resubmitDeviceTranscript(
        directory: URL, meetingId: String, transport: any DeviceTranscriptTransport,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) async throws {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(transcriptName)),
              (try? JSONDecoder().decode(DeviceTranscript.self, from: data)) != nil else {
            throw RecoveryError.transcriptNotFinished
        }
        do {
            try await CaptureSession.submitDeviceTranscript(meetingId: meetingId, body: data, transport: transport, sleep: sleep)
        } catch CaptureSession.CaptureError.transcriptRejected {
            throw CaptureSession.CaptureError.transcriptRejected
        } catch {
            throw CaptureSession.submitFailure(error)
        }
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: directory)
    }

    static func recoverDeviceMeeting(
        directory: URL, manifest: CaptureManifest, transport: any DeviceTranscriptTransport, cloud: any CloudFinalizeTransport,
        makeTranscriber: @escaping @Sendable (CaptureManifest) async throws -> LocalTranscriber? = { _ in nil },
        flushNotes: @escaping @Sendable () async throws -> Void = {},
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        cloudTimeout: TimeInterval = CaptureSession.recoveryUploadTimeout,
        onStep: @escaping @Sendable (CaptureSession.FinishingStep) async -> Void = { _ in }
    ) async throws {
        let finished = try? Data(contentsOf: directory.appendingPathComponent(transcriptName))
        if let finished, (try? JSONDecoder().decode(DeviceTranscript.self, from: finished)) != nil {
            try? await flushNotes()
            try Task.checkCancellation()
            return try await resubmitDeviceTranscript(directory: directory, meetingId: manifest.meetingId, transport: transport, sleep: sleep)
        }
        let endMeeting = { _ = Task { await CaptureSession.endMeetingIfAllowed { try await transport.endMeeting(meetingId: manifest.meetingId) } } }
        if manifest.deviceOnly && manifest.notified {
            endMeeting()
            throw RecoveryError.audioStaysOnThisMac
        }
        var transcriber: LocalTranscriber?
        if !(manifest.localFailed && !manifest.deviceOnly) {
            do { transcriber = try await makeTranscriber(manifest) } catch RecoveryError.deferred where !manifest.deviceOnly {}
        }
        if transcriber == nil && manifest.deviceOnly {
            endMeeting()
            throw RecoveryError.audioStaysOnThisMac
        }
        let recordingURL = directory.appendingPathComponent(recordingName)
        guard let duration = await readableAudioDuration(of: recordingURL) else {
            if manifest.deviceOnly { endMeeting() }
            throw manifest.deviceOnly ? RecoveryError.audioStaysOnThisMac : RecoveryError.unreadableRecording
        }
        if let transcriber {
            var missing: [SegmentWriter.ClosedSegment] = []
            var saved: [LocalTranscriber.SegmentTranscript] = []
            var covered = 0.0
            for segment in await readableSegments(in: directory) {
                let seconds = await readableAudioDuration(of: segment.micURL) ?? 0
                covered += seconds
                if let transcript = savedTranscript(in: directory, seq: segment.seq) {
                    saved.append(transcript)
                } else {
                    missing.append(SegmentWriter.ClosedSegment(
                        seq: segment.seq, micURL: segment.micURL, sysURL: segment.sysURL, frames: Int64(seconds * MixPlan.sampleRate)))
                }
            }
            if covered >= minimumCoverage * duration {
                await transcriber.seed(saved)
                do {
                    _ = try await CaptureSession.finishOnDevice(
                        meetingId: manifest.meetingId, directory: directory, tail: missing, durationSeconds: duration,
                        transcriber: transcriber, transport: transport, recapOpened: true, deviceOnly: manifest.deviceOnly,
                        cloud: cloud, cloudTimeout: cloudTimeout, sleep: sleep, flushNotes: flushNotes,
                        saved: saved.flatMap(\.segments), onStep: onStep)
                    return
                } catch is LocalTranscriber.Failure, CaptureSession.CaptureError.localTranscriptionTimedOut {
                    throw RecoveryError.audioStaysOnThisMac
                } catch is CancellationError {
                    await transcriber.cancel()
                    throw CancellationError()
                }
            } else if manifest.deviceOnly {
                endMeeting()
                throw RecoveryError.audioStaysOnThisMac
            }
        }
        try await withTimeout(seconds: cloudTimeout) {
            try await CaptureSession.finalizeRecordingInCloud(
                meetingId: manifest.meetingId, recording: recordingURL, duration: duration, cloud: cloud,
                deferExtraction: false, flushNotes: flushNotes)
        }
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: directory)
        endMeeting()
    }

    private static func savedTranscript(in directory: URL, seq: Int) -> LocalTranscriber.SegmentTranscript? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(LocalTranscriber.transcriptName(seq: seq))),
              let saved = try? JSONDecoder().decode(LocalTranscriber.SegmentTranscript.self, from: data),
              saved.seq == seq else { return nil }
        return saved
    }

    /// nil when the file is missing, has no audio track, or has no positive finite duration.
    static func readableAudioDuration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// Segment pairs whose mic AND system files are both readable, sorted by seq ascending.
    static func readableSegments(in directory: URL) async -> [SegmentWriter.ClosedSegment] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var segments: [SegmentWriter.ClosedSegment] = []
        for segment in names.compactMap({ recoveredSegment(in: directory, name: $0) }).sorted(by: { $0.seq < $1.seq }) {
            guard await readableAudioDuration(of: segment.micURL) != nil,
                  await readableAudioDuration(of: segment.sysURL) != nil else { continue }
            segments.append(segment)
        }
        return segments
    }

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
        guard manifest.audioMayLeaveMac || manifest.transcriptionMode == .device else { return false }
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
    static func recover(
        directory: URL, manifest: CaptureManifest, client: MinutiaClient,
        makeTranscriber: @escaping @Sendable (CaptureManifest) async throws -> LocalTranscriber? = { _ in nil },
        flushNotes: @escaping @Sendable () async throws -> Void = {},
        onStep: @escaping @Sendable (CaptureSession.FinishingStep) async -> Void = { _ in }
    ) async throws {
        if manifest.transcriptionMode == .device {
            try await recoverDeviceMeeting(
                directory: directory, manifest: manifest, transport: client, cloud: client,
                makeTranscriber: makeTranscriber, flushNotes: flushNotes, onStep: onStep)
            return
        }
        guard manifest.audioMayLeaveMac else { throw RecoveryError.audioStaysOnThisMac }
        let recordingURL = directory.appendingPathComponent(recordingName)
        guard let duration = await readableAudioDuration(of: recordingURL) else { throw RecoveryError.unreadableRecording }

        for segment in await readableSegments(in: directory) {
            try? await client.uploadSegment(meetingId: manifest.meetingId, segment: segment)
            _ = try? await client.registerSegment(meetingId: manifest.meetingId, seq: segment.seq, offsetSeconds: segment.offsetSeconds)
        }

        let path = try await client.uploadRecording(meetingId: manifest.meetingId, fileURL: recordingURL)
        let attrs = try? FileManager.default.attributesOfItem(atPath: recordingURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        try await client.finalizeMeeting(meetingId: manifest.meetingId, audioPath: path, duration: duration, sizeBytes: size)
        _ = try await NotepadFinalize.flushThenTranscribe(
            flush: flushNotes,
            requestTranscription: { try await client.requestTranscription(meetingId: manifest.meetingId, expectedSegments: nil) })
    }

    /// "seg-3-me.m4a" -> 3; nil for the system file, legacy mixed segments, the recording or any other entry.
    static func segmentSeq(from name: String) -> Int? {
        guard name.hasPrefix("seg-"), name.hasSuffix("-me.m4a") else { return nil }
        return Int(name.dropFirst(4).dropLast(7))
    }

    /// Pairs a recovered mic file with its system file; frames are unknown (0) after a crash.
    static func recoveredSegment(in directory: URL, name: String) -> SegmentWriter.ClosedSegment? {
        guard let seq = segmentSeq(from: name) else { return nil }
        return SegmentWriter.ClosedSegment(
            seq: seq,
            micURL: directory.appendingPathComponent(name),
            sysURL: directory.appendingPathComponent("seg-\(seq)-them.m4a"),
            frames: 0)
    }
}
