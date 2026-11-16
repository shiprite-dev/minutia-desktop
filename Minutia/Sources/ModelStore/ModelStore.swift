import CryptoKit
import Foundation

/// Fetches one remote file into a partial file, resuming from `offset` bytes already on disk.
protocol ModelTransfer: Sendable {
    /// Appends the body of `url` from byte `offset` to `partial` (created when missing) and reports the
    /// partial file's cumulative size as bytes arrive. Throws when the transfer is interrupted, leaving
    /// the bytes written so far in place.
    func fetch(_ url: URL, appendingTo partial: URL, from offset: Int64,
               progress: @escaping @Sendable (Int64) -> Void) async throws
}

/// Facts about the Mac the store gates on.
protocol ModelHost: Sendable {
    var isAppleSilicon: Bool { get }
    var osVersion: OperatingSystemVersion { get }
    var appBuild: String { get }
    var osBuild: String { get }
    func isNetworkExpensiveOrConstrained() -> Bool
    func freeDiskBytes(at url: URL) -> Int64
}

/// Loads an entry's engine from its directory and runs one short transcription. Must stop and throw
/// `CancellationError` when its task is cancelled.
protocol ModelWarmer: Sendable {
    func warmUp(_ entry: ModelManifest.Entry, at directory: URL) async throws
}

enum ModelBlockReason: Equatable, Sendable {
    case intelMac
    case unsupportedOS
    case noEntryForLanguage
    case expensiveNetwork
    case lowDisk(requiredBytes: Int64, freeBytes: Int64)
    case recording

    /// Shown in Settings under the on-device model row.
    var settingsText: String {
        switch self {
        case .intelMac: "On-device transcription needs a Mac with Apple silicon."
        case .unsupportedOS: "On-device transcription needs a newer version of macOS."
        case .noEntryForLanguage: "No on-device model is available for this language yet."
        case .expensiveNetwork: "Waiting for a non-metered network to download the on-device model."
        case .lowDisk(let required, let free):
            "Not enough free disk space for the on-device model: \(Self.gigabytes(required)) needed, \(Self.gigabytes(free)) free."
        case .recording: "The on-device model will download after your recording ends."
        }
    }

    private static func gigabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum ModelStatus: Equatable, Sendable {
    case idle
    case blocked(ModelBlockReason)
    case downloading(received: Int64, total: Int64)
    case verifying
    case warming
    case ready(revision: String)
    case failed(String)

    /// Menu line while the model is being fetched, e.g. "Downloading model 42%"; nil otherwise.
    var menuLabel: String? {
        guard case .downloading(let received, let total) = self, total > 0 else { return nil }
        return "Downloading model \(received * 100 / total)%"
    }
}

/// Owns the on-device speech models: download with resume, sha256 verification, health and warm
/// markers, and pruning of superseded revisions.
@MainActor
final class ModelStore: ObservableObject {
    @Published private(set) var status: ModelStatus = .idle

    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Minutia/models", isDirectory: true)
    }

    let manifest: ModelManifest
    let root: URL
    private let transfer: ModelTransfer
    private let host: ModelHost
    private let warmer: ModelWarmer
    private let defaults: UserDefaults

    init(manifest: ModelManifest = .pinned, root: URL = ModelStore.defaultRoot, transfer: ModelTransfer,
         host: ModelHost, warmer: ModelWarmer, defaults: UserDefaults = .standard) {
        self.manifest = manifest
        self.root = root
        self.transfer = transfer
        self.host = host
        self.warmer = warmer
        self.defaults = defaults
    }

    /// `root/<revision>/<repoFolder>`, the directory handed to `ParakeetEngine.load`.
    func directory(for entry: ModelManifest.Entry) -> URL {
        root.appendingPathComponent(entry.revision, isDirectory: true)
            .appendingPathComponent(entry.repoFolder, isDirectory: true)
    }

    /// Makes the entry for `language` healthy and warm: gates, downloads missing files, verifies,
    /// warms up, records health, then prunes superseded revisions. Safe to call on every launch,
    /// after sign-in and whenever the meeting language changes.
    func prepare(language: String) async {
        lastLanguage = language
        while let running { await running.value }
        let task = Task { await run(language) }
        running = task
        await task.value
        running = nil
    }

    func routableEntry(forLanguage language: String) -> ModelManifest.Entry? {
        guard let entry = manifest.entry(forLanguage: language), isHealthy(entry) else { return nil }
        return entry
    }

    func recordingDidStart() {
        recording = true
        warmTask?.cancel()
    }

    func recordingDidStop() async {
        recording = false
        if let lastLanguage { await prepare(language: lastLanguage) }
    }

    private struct VerificationFailed: LocalizedError {
        var errorDescription: String? { "A downloaded model file failed verification." }
    }

    private var lastLanguage: String?
    private var recording = false
    private var running: Task<Void, Never>?
    private var warmTask: Task<Void, Error>?

    private func healthKey(_ entry: ModelManifest.Entry) -> String { "ModelStore.healthy.\(entry.revision)" }
    private func warmKey(_ entry: ModelManifest.Entry) -> String { "ModelStore.warm.\(entry.revision)" }
    private func isHealthy(_ entry: ModelManifest.Entry) -> Bool { defaults.bool(forKey: healthKey(entry)) }

    private func run(_ language: String) async {
        guard host.isAppleSilicon else { return status = .blocked(.intelMac) }
        guard let entry = manifest.entry(forLanguage: language) else { return status = .blocked(.noEntryForLanguage) }
        guard Self.isAtLeast(host.osVersion, entry.minimumOS) else { return status = .blocked(.unsupportedOS) }
        let healthy = isHealthy(entry)
        if recording {
            if !healthy { status = .blocked(.recording) }
            return
        }
        if !healthy, !(await install(entry)) { return }
        let marker = "\(host.appBuild)|\(host.osBuild)"
        if healthy, defaults.string(forKey: warmKey(entry)) == marker {
            status = .ready(revision: entry.revision)
            return prune()
        }
        status = .warming
        let directory = directory(for: entry)
        let warmer = warmer
        let task = Task(priority: .utility) { try await warmer.warmUp(entry, at: directory) }
        warmTask = task
        defer { warmTask = nil }
        do { try await task.value } catch is CancellationError { return } catch {
            return status = .failed("The on-device model could not be loaded: \(error.localizedDescription)")
        }
        if task.isCancelled { return }
        defaults.set(true, forKey: healthKey(entry))
        defaults.set(marker, forKey: warmKey(entry))
        status = .ready(revision: entry.revision)
        prune()
    }

    private func install(_ entry: ModelManifest.Entry) async -> Bool {
        let directory = directory(for: entry)
        let fm = FileManager.default
        let total = entry.totalBytes
        let missing = entry.files.contains { Self.size(of: directory.appendingPathComponent($0.path)) != $0.size }
        if missing {
            if host.isNetworkExpensiveOrConstrained() { status = .blocked(.expensiveNetwork); return false }
            let required = 2 * total + 1_000_000_000
            let free = host.freeDiskBytes(at: root)
            if free < required { status = .blocked(.lowDisk(requiredBytes: required, freeBytes: free)); return false }
        }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            var excluded = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            var done: Int64 = 0
            for file in entry.files {
                let final = directory.appendingPathComponent(file.path)
                let partial = URL(fileURLWithPath: final.path + ".partial")
                if Self.size(of: final) == file.size, try await Self.sha256(of: final) == file.sha256 {
                    done += file.size
                    continue
                }
                try? fm.removeItem(at: final)
                var offset = max(0, Self.size(of: partial))
                if offset > file.size { try? fm.removeItem(at: partial); offset = 0 }
                let base = done
                status = .downloading(received: base + offset, total: total)
                if offset < file.size {
                    try await transfer.fetch(entry.url(for: file), appendingTo: partial, from: offset) { [weak self] received in
                        Task { @MainActor in self?.advance(to: base + received, of: total) }
                    }
                }
                status = .verifying
                guard try await Self.sha256(of: partial) == file.sha256 else {
                    try? fm.removeItem(at: partial)
                    throw VerificationFailed()
                }
                try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: partial, to: final)
                done += file.size
                status = .downloading(received: done, total: total)
            }
            try Data((entry.revision + "\n").utf8).write(to: directory.appendingPathComponent(".fluidaudio-revision"))
            return true
        } catch {
            status = .failed("The on-device model could not be downloaded: \(error.localizedDescription)")
            return false
        }
    }

    private func advance(to received: Int64, of total: Int64) {
        guard case .downloading(let current, _) = status, received > current else { return }
        status = .downloading(received: received, total: total)
    }

    private func prune() {
        let keep = Set(manifest.entries.map(\.revision))
        let stale = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for url in stale where !keep.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
    }

    private static func isAtLeast(_ a: OperatingSystemVersion, _ b: OperatingSystemVersion) -> Bool {
        (a.majorVersion, a.minorVersion, a.patchVersion) >= (b.majorVersion, b.minorVersion, b.patchVersion)
    }

    private nonisolated static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? -1
    }

    private nonisolated static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
