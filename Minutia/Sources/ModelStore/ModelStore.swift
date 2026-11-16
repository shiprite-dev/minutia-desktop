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
    var settingsText: String { "" }
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
    var menuLabel: String? { nil }
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
    func prepare(language: String) async {}

    /// The entry a meeting in `language` may run on locally: only a healthy one. Warmth is never required.
    func routableEntry(forLanguage language: String) -> ModelManifest.Entry? { nil }

    /// Cancels an in-flight warm-up and keeps new downloads from starting until the recording stops.
    func recordingDidStart() {}

    /// Resumes whatever `recordingDidStart` deferred for the last prepared language.
    func recordingDidStop() async {}
}
