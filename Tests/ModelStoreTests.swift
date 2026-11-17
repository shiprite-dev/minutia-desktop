import Combine
import CryptoKit
import XCTest
@testable import Minutia

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A tiny two-entry manifest (English-family and Japanese) whose bodies the fake transfer serves.
private enum Fixture {
    static let enFiles: [(String, Data)] = [
        ("Encoder.mlmodelc/coremldata.bin", Data("coreml".utf8)),
        ("Encoder.mlmodelc/weights/weight.bin", Data((0..<64).map { UInt8($0) })),
        ("vocab.json", Data("{\"0\":\"a\"}".utf8)),
    ]
    static let jaFiles: [(String, Data)] = [
        ("Encoder.mlmodelc/coremldata.bin", Data("coreml-ja".utf8)),
        ("vocab.json", Data("{\"0\":\"\u{3042}\"}".utf8)),
    ]

    static func entry(id: String, folder: String, revision: String, languages: Set<String>,
                      files: [(String, Data)], floor: Double) -> ModelManifest.Entry {
        ModelManifest.Entry(
            id: id, repo: "Test/\(folder)", repoFolder: folder, revision: revision,
            files: files.map { .init(path: $0.0, size: Int64($0.1.count), sha256: sha256($0.1)) },
            languages: languages,
            minimumOS: OperatingSystemVersion(majorVersion: 14, minorVersion: 4, patchVersion: 0),
            guardFloor: floor)
    }

    static func manifest(enRevision: String = "en-rev-1") -> ModelManifest {
        ModelManifest(entries: [
            entry(id: "fake-en", folder: "fake-en-coreml", revision: enRevision, languages: ["en", "de"],
                  files: enFiles, floor: 0.78),
            entry(id: "fake-ja", folder: "fake-ja-coreml", revision: "ja-rev-1", languages: ["ja"],
                  files: jaFiles, floor: 0),
        ])
    }

    /// Every URL the manifest names, mapped to its body.
    static func bodies(_ manifest: ModelManifest) -> [URL: Data] {
        var out: [URL: Data] = [:]
        for entry in manifest.entries {
            let all = entry.id == "fake-en" ? enFiles : jaFiles
            for file in entry.files {
                out[entry.url(for: file)] = all.first { $0.0 == file.path }!.1
            }
        }
        return out
    }
}

/// In-process stand-in for the Hugging Face server. Honors the resume offset, can cut a file off after
/// a byte count (once), serve corrupted bytes, and run a hook on each request.
private final class FakeTransfer: ModelTransfer, @unchecked Sendable {
    struct Interrupted: Error {}

    private let lock = NSLock()
    private let bodies: [URL: Data]
    private var interruptAfter: [URL: Int]
    private let corrupt: Set<URL>
    private var _requests: [(url: URL, offset: Int64)] = []
    var onFetch: (@Sendable (URL) -> Void)?

    private var gate: (url: URL, bytes: Int)?
    private var _gateReached = false
    private var _released = false
    private var _cancellations = 0

    /// `gate` holds one fetch of that URL after writing that many bytes, until `release()`, task
    /// cancellation (throws `CancellationError`, keeping the bytes), or a two-second deadline (then it
    /// finishes normally, so a store that never cancels fails its assertions instead of hanging).
    init(manifest: ModelManifest, interruptAfter: [URL: Int] = [:], corrupt: Set<URL> = [],
         gate: (url: URL, bytes: Int)? = nil) {
        bodies = Fixture.bodies(manifest)
        self.interruptAfter = interruptAfter
        self.corrupt = corrupt
        self.gate = gate
    }

    var requests: [(url: URL, offset: Int64)] { lock.lock(); defer { lock.unlock() }; return _requests }
    var cancellations: Int { lock.lock(); defer { lock.unlock() }; return _cancellations }
    private var gateReached: Bool { lock.lock(); defer { lock.unlock() }; return _gateReached }
    private var released: Bool { lock.lock(); defer { lock.unlock() }; return _released }
    func release() { lock.lock(); _released = true; lock.unlock() }

    func waitUntilGateReached() async {
        let deadline = Date().addingTimeInterval(2)
        while !gateReached, Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    private func append(_ chunk: Data, to partial: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: partial)
        try handle.seekToEnd()
        try handle.write(contentsOf: chunk)
        try handle.close()
    }

    func fetch(_ url: URL, appendingTo partial: URL, from offset: Int64,
               progress: @escaping @Sendable (Int64) -> Void) async throws {
        onFetch?(url)
        lock.lock()
        _requests.append((url, offset))
        var body = bodies[url]!
        if corrupt.contains(url) { body = Data(body.map { $0 ^ 0xFF }) }
        let cut = interruptAfter.removeValue(forKey: url)
        var hold: Int?
        if let gate, gate.url == url, Int(offset) < gate.bytes {
            hold = gate.bytes
            self.gate = nil
        }
        lock.unlock()

        var start = Int(offset)
        if let hold {
            try append(body.subdata(in: start..<hold), to: partial)
            progress(Int64(hold))
            start = hold
            lock.lock(); _gateReached = true; lock.unlock()
            let deadline = Date().addingTimeInterval(2)
            while !released, Date() < deadline {
                do { try await Task.sleep(nanoseconds: 2_000_000) } catch {
                    lock.lock(); _cancellations += 1; lock.unlock()
                    throw error
                }
            }
        }
        let end = cut.map { min($0, body.count) } ?? body.count
        try append(body.subdata(in: start..<max(start, end)), to: partial)
        progress(Int64(end))
        if cut != nil { throw Interrupted() }
    }
}

private struct FakeHost: ModelHost {
    var isAppleSilicon = true
    var osVersion = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
    var appBuild = "100"
    var osBuild = "24A335"
    var expensive = false
    var freeBytes: Int64 = 500 * 1_000_000_000

    func isNetworkExpensiveOrConstrained() -> Bool { expensive }
    func freeDiskBytes(at url: URL) -> Int64 { freeBytes }
    func observeConditions(_ handler: @escaping @Sendable () -> Void) {}
}

/// A host whose network and free space change mid-test, and whose condition observer the test fires.
private final class ChangingHost: ModelHost, @unchecked Sendable {
    let isAppleSilicon = true
    let osVersion = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
    let appBuild = "100"
    let osBuild = "24A335"
    private let lock = NSLock()
    private var _expensive: Bool
    private var _freeBytes: Int64
    private var handler: (@Sendable () -> Void)?

    init(expensive: Bool = false, freeBytes: Int64 = 500 * 1_000_000_000) {
        _expensive = expensive
        _freeBytes = freeBytes
    }

    var expensive: Bool {
        get { lock.withLock { _expensive } }
        set { lock.withLock { _expensive = newValue } }
    }

    var freeBytes: Int64 {
        get { lock.withLock { _freeBytes } }
        set { lock.withLock { _freeBytes = newValue } }
    }

    func isNetworkExpensiveOrConstrained() -> Bool { expensive }
    func freeDiskBytes(at url: URL) -> Int64 { freeBytes }
    func observeConditions(_ handler: @escaping @Sendable () -> Void) { lock.withLock { self.handler = handler } }
    func change() { lock.withLock { handler }?() }
}

/// Counts warm-ups. When `gated`, a warm-up waits until `release()` or task cancellation.
private final class FakeWarmer: ModelWarmer, @unchecked Sendable {
    struct Failed: Error {}

    private let lock = NSLock()
    private var _calls: [String] = []
    private var _cancellations = 0
    private var _gated: Bool
    private let fails: Bool
    private let ignoresCancellation: Bool
    var onWarm: (@Sendable (URL) -> Void)?

    /// `ignoresCancellation` models a warmer stuck in a Core ML call: it waits out the gate and
    /// returns normally even when cancelled. A gate gives up after three seconds either way.
    init(gated: Bool = false, fails: Bool = false, ignoresCancellation: Bool = false) {
        _gated = gated
        self.fails = fails
        self.ignoresCancellation = ignoresCancellation
    }

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    var cancellations: Int { lock.lock(); defer { lock.unlock() }; return _cancellations }
    private var gated: Bool { lock.lock(); defer { lock.unlock() }; return _gated }
    func release() { lock.lock(); _gated = false; lock.unlock() }

    func warmUp(_ entry: ModelManifest.Entry, at directory: URL) async throws {
        lock.lock(); _calls.append(entry.id); lock.unlock()
        onWarm?(directory)
        let deadline = Date().addingTimeInterval(3)
        if ignoresCancellation {
            while gated, Date() < deadline { usleep(2_000) }
        } else {
            do {
                while gated, Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
            } catch {
                lock.lock(); _cancellations += 1; lock.unlock()
                throw error
            }
        }
        if fails { throw Failed() }
    }

    /// Gives up after two seconds so a store that never warms fails its assertions instead of hanging.
    func waitUntilStarted(count: Int = 1) async {
        let deadline = Date().addingTimeInterval(2)
        while calls.count < count, Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
    }
}

@MainActor
final class ModelStoreTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStoreTests-\(UUID().uuidString)/models", isDirectory: true)
        suiteName = "ModelStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore(manifest: ModelManifest = Fixture.manifest(), transfer: FakeTransfer? = nil,
                           host: ModelHost = FakeHost(), warmer: FakeWarmer = FakeWarmer()) -> ModelStore {
        ModelStore(manifest: manifest, root: root, transfer: transfer ?? FakeTransfer(manifest: manifest),
                   host: host, warmer: warmer, defaults: defaults)
    }

    private func en(_ manifest: ModelManifest = Fixture.manifest()) -> ModelManifest.Entry {
        manifest.entry(forLanguage: "en")!
    }

    private func url(_ path: String, in entry: ModelManifest.Entry) -> URL {
        entry.url(for: entry.files.first { $0.path == path }!)
    }

    private func readyEnglishStore() async -> ModelStore {
        let store = makeStore()
        await store.prepare(language: "en")
        XCTAssertEqual(store.status, .ready(revision: "en-rev-1"), "precondition: English entry ready")
        return store
    }

    // MARK: Download on a supported Mac

    func test_prepare_onASupportedMacWithNoModel_downloadsTheLanguageEntryWithoutUserAction() async {
        let manifest = Fixture.manifest()
        let transfer = FakeTransfer(manifest: manifest)
        let store = makeStore(manifest: manifest, transfer: transfer)

        await store.prepare(language: "en")

        XCTAssertEqual(Set(transfer.requests.map(\.url)), Set(en().files.map { en().url(for: $0) }))
        XCTAssertEqual(store.status, .ready(revision: "en-rev-1"))
        for file in en().files {
            let installed = store.directory(for: en()).appendingPathComponent(file.path)
            XCTAssertEqual(try? sha256(Data(contentsOf: installed)), file.sha256, file.path)
        }
    }

    func test_download_publishesProgress_andTheMenuShowsAPercentage() async {
        let store = makeStore()
        var seen: [ModelStatus] = []
        let sink = store.$status.sink { seen.append($0) }
        defer { sink.cancel() }

        await store.prepare(language: "en")

        XCTAssertTrue(seen.contains { if case .downloading = $0 { true } else { false } }, "\(seen)")
        XCTAssertEqual(ModelStatus.downloading(received: 42, total: 100).menuLabel, "Downloading model 42%")
        XCTAssertNil(ModelStatus.ready(revision: "r").menuLabel)
    }

    func test_readyEntry_carriesTheFluidAudioRevisionMarker_soItLoadsOffline() async throws {
        let store = await readyEnglishStore()
        let marker = store.directory(for: en()).appendingPathComponent(".fluidaudio-revision")
        let stored = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(stored, "en-rev-1")
    }

    func test_modelDirectory_isExcludedFromBackup() async throws {
        _ = await readyEnglishStore()
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    // MARK: Verification

    func test_shaMismatch_deletesTheFile_andNeverLoadsTheModel() async {
        let manifest = Fixture.manifest()
        let bad = url("Encoder.mlmodelc/weights/weight.bin", in: en(manifest))
        let warmer = FakeWarmer()
        let store = makeStore(manifest: manifest, transfer: FakeTransfer(manifest: manifest, corrupt: [bad]),
                              warmer: warmer)

        await store.prepare(language: "en")

        let installed = store.directory(for: en()).appendingPathComponent("Encoder.mlmodelc/weights/weight.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path + ".partial"))
        XCTAssertTrue(warmer.calls.isEmpty, "a mismatched model must never be loaded")
        XCTAssertNil(store.routableEntry(forLanguage: "en"))
        guard case .failed = store.status else { return XCTFail("expected failed, got \(store.status)") }
    }

    // MARK: Resume

    func test_interruptedDownload_resumesOnNextLaunch_fromTheBytesOnDisk() async {
        let manifest = Fixture.manifest()
        let weight = url("Encoder.mlmodelc/weights/weight.bin", in: en(manifest))
        let first = makeStore(manifest: manifest, transfer: FakeTransfer(manifest: manifest, interruptAfter: [weight: 20]))
        await first.prepare(language: "en")
        XCTAssertNil(first.routableEntry(forLanguage: "en"))

        let transfer = FakeTransfer(manifest: manifest)
        let relaunched = makeStore(manifest: manifest, transfer: transfer)
        await relaunched.prepare(language: "en")

        let coreml = url("Encoder.mlmodelc/coremldata.bin", in: en(manifest))
        XCTAssertFalse(transfer.requests.contains { $0.url == coreml }, "a verified file is not fetched again")
        XCTAssertEqual(transfer.requests.first { $0.url == weight }?.offset, 20)
        XCTAssertEqual(relaunched.status, .ready(revision: "en-rev-1"))
    }

    // MARK: Gates

    func test_expensiveOrConstrainedNetwork_blocksTheDownload_andSettingsStatesWhy() async {
        let transfer = FakeTransfer(manifest: Fixture.manifest())
        var host = FakeHost()
        host.expensive = true
        let store = makeStore(transfer: transfer, host: host)

        await store.prepare(language: "en")

        XCTAssertTrue(transfer.requests.isEmpty)
        XCTAssertEqual(store.status, .blocked(.expensiveNetwork))
        XCTAssertFalse(ModelBlockReason.expensiveNetwork.settingsText.isEmpty)
    }

    func test_freeDiskBelowTwiceTheModelPlusOneGigabyte_blocksTheDownload() async {
        let required = 2 * en().totalBytes + 1_000_000_000
        let transfer = FakeTransfer(manifest: Fixture.manifest())
        var host = FakeHost()
        host.freeBytes = required - 1
        let store = makeStore(transfer: transfer, host: host)

        await store.prepare(language: "en")

        XCTAssertTrue(transfer.requests.isEmpty)
        XCTAssertEqual(store.status, .blocked(.lowDisk(requiredBytes: required, freeBytes: required - 1)))
    }

    func test_freeDiskAtExactlyTheThreshold_allowsTheDownload() async {
        var host = FakeHost()
        host.freeBytes = 2 * en().totalBytes + 1_000_000_000
        let store = makeStore(host: host)

        await store.prepare(language: "en")

        XCTAssertEqual(store.status, .ready(revision: "en-rev-1"))
    }

    func test_intelMac_neverDownloads() async {
        let transfer = FakeTransfer(manifest: Fixture.manifest())
        var host = FakeHost()
        host.isAppleSilicon = false
        let store = makeStore(transfer: transfer, host: host)

        await store.prepare(language: "en")

        XCTAssertTrue(transfer.requests.isEmpty)
        XCTAssertEqual(store.status, .blocked(.intelMac))
    }

    func test_entryAboveTheMacsOSVersion_neverDownloads() async {
        let transfer = FakeTransfer(manifest: Fixture.manifest())
        var host = FakeHost()
        host.osVersion = OperatingSystemVersion(majorVersion: 14, minorVersion: 3, patchVersion: 0)
        let store = makeStore(transfer: transfer, host: host)

        await store.prepare(language: "en")

        XCTAssertTrue(transfer.requests.isEmpty)
        XCTAssertEqual(store.status, .blocked(.unsupportedOS))
    }

    func test_everyBlockReason_hasSettingsText() {
        let reasons: [ModelBlockReason] = [.intelMac, .unsupportedOS, .noEntryForLanguage, .expensiveNetwork,
                                           .lowDisk(requiredBytes: 3_000_000_000, freeBytes: 1_000_000_000),
                                           .recording, .warmingAfterRecording]
        for reason in reasons {
            XCTAssertFalse(reason.settingsText.isEmpty, "\(reason)")
        }
    }

    // MARK: Recording

    func test_noDownloadBeginsWhileRecording_andItStartsWhenRecordingStops() async {
        let transfer = FakeTransfer(manifest: Fixture.manifest())
        let store = makeStore(transfer: transfer)
        store.recordingDidStart()

        await store.prepare(language: "en")
        XCTAssertTrue(transfer.requests.isEmpty)
        XCTAssertEqual(store.status, .blocked(.recording))

        await store.recordingDidStop()
        XCTAssertEqual(store.status, .ready(revision: "en-rev-1"))
    }

    func test_launchWarmUp_yieldsToARecordingStart_andResumesAfterIt() async {
        _ = await readyEnglishStore()
        var host = FakeHost()
        host.appBuild = "101"
        let warmer = FakeWarmer(gated: true)
        let store = makeStore(host: host, warmer: warmer)

        let launch = Task { await store.prepare(language: "en") }
        await warmer.waitUntilStarted()
        store.recordingDidStart()
        await launch.value
        XCTAssertEqual(warmer.cancellations, 1)

        warmer.release()
        await store.recordingDidStop()
        XCTAssertEqual(warmer.calls.count, 2, "the yielded warm-up runs again once recording stops")
        XCTAssertEqual(store.status, .ready(revision: "en-rev-1"))
    }

    // MARK: Health and warmth

    func test_health_isRecordedAfterVerifyAndWarmUp_andSurvivesRelaunch() async {
        _ = await readyEnglishStore()

        let relaunched = makeStore()

        XCTAssertEqual(relaunched.routableEntry(forLanguage: "en")?.revision, "en-rev-1")
    }

    func test_healthyRevisions_listsOnlyVerifiedAndWarmedEntries_acrossRelaunch() async {
        XCTAssertEqual(makeStore().healthyRevisions, [])
        _ = await readyEnglishStore()

        XCTAssertEqual(makeStore().healthyRevisions, ["en-rev-1"])
        XCTAssertEqual(makeStore(manifest: Fixture.manifest(enRevision: "en-rev-2")).healthyRevisions, [])
    }

    func test_health_isPerRevision() async {
        _ = await readyEnglishStore()

        let upgraded = makeStore(manifest: Fixture.manifest(enRevision: "en-rev-2"))

        XCTAssertNil(upgraded.routableEntry(forLanguage: "en"))
    }

    func test_failedWarmUp_neverRecordsHealth() async {
        let manifest = Fixture.manifest()
        let transfer = FakeTransfer(manifest: manifest)
        let warmer = FakeWarmer(fails: true)
        let store = makeStore(manifest: manifest, transfer: transfer, warmer: warmer)

        await store.prepare(language: "en")

        XCTAssertEqual(transfer.requests.count, en().files.count, "precondition: files downloaded")
        XCTAssertEqual(warmer.calls, ["fake-en"], "precondition: verified files reach warm-up")
        guard case .failed = store.status else { return XCTFail("expected failed, got \(store.status)") }
        XCTAssertNil(store.routableEntry(forLanguage: "en"))
        XCTAssertNil(makeStore().routableEntry(forLanguage: "en"))
    }

    func test_routing_neverRequiresWarmth() async {
        _ = await readyEnglishStore()
        var host = FakeHost()
        host.appBuild = "101"
        host.osBuild = "25A100"

        let coldStore = makeStore(host: host)

        XCTAssertEqual(coldStore.routableEntry(forLanguage: "en")?.id, "fake-en")
    }

    func test_launch_withUnchangedBuildsAndRevision_skipsWarmUp() async {
        _ = await readyEnglishStore()
        let warmer = FakeWarmer()
        let transfer = FakeTransfer(manifest: Fixture.manifest())
        let store = makeStore(transfer: transfer, warmer: warmer)

        await store.prepare(language: "en")

        XCTAssertTrue(warmer.calls.isEmpty)
        XCTAssertTrue(transfer.requests.isEmpty)
        XCTAssertEqual(store.status, .ready(revision: "en-rev-1"))
    }

    func test_launch_withChangedAppBuild_warmsUpImmediately() async {
        _ = await readyEnglishStore()
        var host = FakeHost()
        host.appBuild = "101"
        let warmer = FakeWarmer()
        let transfer = FakeTransfer(manifest: Fixture.manifest())

        await makeStore(transfer: transfer, host: host, warmer: warmer).prepare(language: "en")

        XCTAssertEqual(warmer.calls, ["fake-en"])
        XCTAssertTrue(transfer.requests.isEmpty)
    }

    func test_launch_withChangedOSBuild_warmsUpImmediately() async {
        _ = await readyEnglishStore()
        var host = FakeHost()
        host.osBuild = "25A100"
        let warmer = FakeWarmer()

        await makeStore(host: host, warmer: warmer).prepare(language: "en")

        XCTAssertEqual(warmer.calls, ["fake-en"])
    }

    // MARK: Revisions

    func test_newPinnedRevision_downloadsBesideTheOld_andDeletesTheOldOnlyWhenReady() async {
        let old = await readyEnglishStore()
        let oldDir = old.directory(for: en())
        let manifest = Fixture.manifest(enRevision: "en-rev-2")
        let transfer = FakeTransfer(manifest: manifest)
        let oldPresentDuringFetch = LockedFlags()
        transfer.onFetch = { _ in oldPresentDuringFetch.record(FileManager.default.fileExists(atPath: oldDir.path)) }
        let warmer = FakeWarmer()
        warmer.onWarm = { _ in oldPresentDuringFetch.record(FileManager.default.fileExists(atPath: oldDir.path)) }
        let store = makeStore(manifest: manifest, transfer: transfer, warmer: warmer)

        await store.prepare(language: "en")

        XCTAssertFalse(oldPresentDuringFetch.values.isEmpty)
        XCTAssertTrue(oldPresentDuringFetch.values.allSatisfy { $0 }, "old revision must survive until the new one is ready")
        XCTAssertEqual(store.status, .ready(revision: "en-rev-2"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("en-rev-1").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory(for: en(manifest)).path))
    }

    // MARK: Language

    func test_onlyTheResolvedLanguageEntry_downloads() async {
        let manifest = Fixture.manifest()
        let transfer = FakeTransfer(manifest: manifest)

        await makeStore(manifest: manifest, transfer: transfer).prepare(language: "de")

        let ja = manifest.entry(forLanguage: "ja")!
        XCTAssertFalse(transfer.requests.contains { $0.url.path.contains(ja.repoFolder) })
        XCTAssertFalse(transfer.requests.isEmpty)
    }

    func test_changingLanguage_downloadsTheOtherEntry_andStaysOnCloudUntilItIsHealthy() async {
        _ = await readyEnglishStore()
        let manifest = Fixture.manifest()
        let transfer = FakeTransfer(manifest: manifest)
        let warmer = FakeWarmer(gated: true)
        let store = makeStore(manifest: manifest, transfer: transfer, warmer: warmer)

        let switching = Task { await store.prepare(language: "ja") }
        await warmer.waitUntilStarted()
        XCTAssertNil(store.routableEntry(forLanguage: "ja"), "Japanese meetings stay on cloud until the entry is healthy")
        warmer.release()
        await switching.value

        let ja = manifest.entry(forLanguage: "ja")!
        XCTAssertEqual(Set(transfer.requests.map(\.url)), Set(ja.files.map { ja.url(for: $0) }))
        XCTAssertEqual(store.routableEntry(forLanguage: "ja")?.id, "fake-ja")
        XCTAssertEqual(store.routableEntry(forLanguage: "en")?.id, "fake-en")
    }

    func test_languageWithNoEntry_downloadsNothing() async {
        let transfer = FakeTransfer(manifest: Fixture.manifest())
        let store = makeStore(transfer: transfer)

        await store.prepare(language: "zh")

        XCTAssertTrue(transfer.requests.isEmpty)
        XCTAssertEqual(store.status, .blocked(.noEntryForLanguage))
    }

    // MARK: Review fixes

    /// Hangs here spin the main actor, which no in-process watchdog can interrupt; the run is bounded
    /// by `executionTimeAllowance` with `-test-timeouts-enabled YES` (see the executor DONE WHEN).
    func test_concurrentPrepares_withAReadyModel_allReturn() async {
        executionTimeAllowance = 60
        _ = await readyEnglishStore()
        let store = makeStore()

        async let a: Void = store.prepare(language: "en")
        async let b: Void = store.prepare(language: "en")
        async let c: Void = store.prepare(language: "en")
        _ = await (a, b, c)

        XCTAssertEqual(store.status, .ready(revision: "en-rev-1"))
    }

    func test_concurrentPrepares_duringADownload_allReturn_andFetchEachFileOnce() async {
        executionTimeAllowance = 60
        let manifest = Fixture.manifest()
        let weight = url("Encoder.mlmodelc/weights/weight.bin", in: en(manifest))
        let transfer = FakeTransfer(manifest: manifest, gate: (weight, 20))
        let store = makeStore(manifest: manifest, transfer: transfer)

        let first = Task { await store.prepare(language: "en") }
        await transfer.waitUntilGateReached()
        let second = Task { await store.prepare(language: "en") }
        let third = Task { await store.prepare(language: "en") }
        transfer.release()
        await first.value
        await second.value
        await third.value

        XCTAssertEqual(store.status, .ready(revision: "en-rev-1"))
        let fetched = transfer.requests.map(\.url)
        XCTAssertEqual(fetched.count, Set(fetched).count, "no file is fetched twice: \(fetched)")
    }

    func test_waitersForAnEarlierLanguage_neverOverrideANewerLanguageRequest() async {
        executionTimeAllowance = 60
        let manifest = Fixture.manifest()
        let weight = url("Encoder.mlmodelc/weights/weight.bin", in: en(manifest))
        let transfer = FakeTransfer(manifest: manifest, gate: (weight, 20))
        let store = makeStore(manifest: manifest, transfer: transfer)

        let first = Task { await store.prepare(language: "en") }
        await transfer.waitUntilGateReached()
        let staleEnglish = Task { await store.prepare(language: "en") }
        await Task.yield()
        let japanese = Task { await store.prepare(language: "ja") }
        await Task.yield()
        transfer.release()
        await first.value
        await staleEnglish.value
        await japanese.value

        XCTAssertEqual(store.routableEntry(forLanguage: "ja")?.id, "fake-ja", "the newest language request is prepared")
        XCTAssertEqual(store.status, .ready(revision: manifest.entry(forLanguage: "ja")!.revision))
    }

    func test_recordingStartMidDownload_cancelsTheTransfer_andResumesFromDiskWhenItStops() async {
        let manifest = Fixture.manifest()
        let weight = url("Encoder.mlmodelc/weights/weight.bin", in: en(manifest))
        let vocab = url("vocab.json", in: en(manifest))
        let transfer = FakeTransfer(manifest: manifest, gate: (weight, 20))
        let store = makeStore(manifest: manifest, transfer: transfer)

        let download = Task { await store.prepare(language: "en") }
        await transfer.waitUntilGateReached()
        store.recordingDidStart()
        await download.value

        XCTAssertEqual(transfer.cancellations, 1, "the in-flight transfer is cancelled")
        XCTAssertFalse(transfer.requests.contains { $0.url == vocab }, "no further file is fetched while recording")
        XCTAssertEqual(store.status, .blocked(.recording))
        XCTAssertNil(store.routableEntry(forLanguage: "en"))

        await store.recordingDidStop()

        XCTAssertEqual(transfer.requests.last { $0.url == weight }?.offset, 20, "resumes from the bytes on disk")
        XCTAssertEqual(store.status, .ready(revision: "en-rev-1"))
    }

    func test_recordingStartDuringWarmUpOfAHealthyModel_saysItIsGettingReady_notThatItWillDownload() async {
        _ = await readyEnglishStore()
        var host = FakeHost()
        host.appBuild = "101"
        let warmer = FakeWarmer(gated: true)
        let store = makeStore(host: host, warmer: warmer)

        let launch = Task { await store.prepare(language: "en") }
        await warmer.waitUntilStarted()
        store.recordingDidStart()
        await launch.value

        XCTAssertEqual(store.status, .blocked(.warmingAfterRecording))
        XCTAssertEqual(ModelBlockReason.warmingAfterRecording.settingsText,
                       "The on-device model will finish getting ready after your recording ends.")
        XCTAssertEqual(ModelBlockReason.recording.settingsText,
                       "The on-device model will download after your recording ends.")
    }

    func test_warmUpThatIgnoresCancellation_recordsNeitherHealthNorMarker_whenARecordingStarted() async {
        let manifest = Fixture.manifest()
        let warmer = FakeWarmer(gated: true, ignoresCancellation: true)
        let store = makeStore(manifest: manifest, warmer: warmer)

        let install = Task { await store.prepare(language: "en") }
        await warmer.waitUntilStarted()
        store.recordingDidStart()
        warmer.release()
        await install.value

        XCTAssertNil(store.routableEntry(forLanguage: "en"), "a warm-up that finished after a recording start is not trusted")
        XCTAssertEqual(store.status, .blocked(.warmingAfterRecording), "the files are verified; only the warm-up is left")

        let nextLaunchWarmer = FakeWarmer()
        let transfer = FakeTransfer(manifest: manifest)
        await makeStore(manifest: manifest, transfer: transfer, warmer: nextLaunchWarmer).prepare(language: "en")
        XCTAssertEqual(nextLaunchWarmer.calls, ["fake-en"], "no warm marker was written, so the next launch warms")
        XCTAssertTrue(transfer.requests.isEmpty, "verified files are kept")
    }

    func test_failedWarmUpOfAHealthyEntry_clearsHealth_andTheNextPrepareRefetchesTheCorruptFile() async throws {
        let ready = await readyEnglishStore()
        let installed = ready.directory(for: en()).appendingPathComponent("Encoder.mlmodelc/weights/weight.bin")
        try Data(repeating: 0xAB, count: 64).write(to: installed)
        var host = FakeHost()
        host.appBuild = "101"

        let broken = makeStore(host: host, warmer: FakeWarmer(fails: true))
        await broken.prepare(language: "en")

        guard case .failed = broken.status else { return XCTFail("expected failed, got \(broken.status)") }
        XCTAssertNil(broken.routableEntry(forLanguage: "en"), "a model that fails to load is no longer healthy")
        XCTAssertNil(makeStore(host: host).routableEntry(forLanguage: "en"), "cleared health survives relaunch")

        let manifest = Fixture.manifest()
        let transfer = FakeTransfer(manifest: manifest)
        let healed = makeStore(manifest: manifest, transfer: transfer, host: host)
        await healed.prepare(language: "en")

        XCTAssertEqual(transfer.requests.map(\.url), [url("Encoder.mlmodelc/weights/weight.bin", in: en(manifest))])
        XCTAssertEqual(healed.status, .ready(revision: "en-rev-1"))
    }

    func test_menuLabel_holdsTheLastPercentageThroughVerification_andClearsOnlyAtWarming() async {
        let store = makeStore()
        var seen: [ModelStatus] = []
        let sink = store.$status.sink { seen.append($0) }
        defer { sink.cancel() }

        await store.prepare(language: "en")

        guard let first = seen.firstIndex(where: { $0.menuLabel != nil }),
              let warming = seen.firstIndex(of: .warming) else { return XCTFail("\(seen)") }
        let labels = seen[first..<warming].map(\.menuLabel)
        XCTAssertFalse(labels.contains(nil), "the menu row never blanks between files: \(seen[first..<warming])")
        let percents = labels.compactMap { $0?.split(separator: " ").last.flatMap { Int($0.dropLast()) } }
        XCTAssertEqual(percents, percents.sorted(), "the percentage never goes backwards")
        XCTAssertEqual(labels.last, "Downloading model 100%")
        XCTAssertNil(ModelStatus.warming.menuLabel)
    }

    // MARK: Recovery without a relaunch

    func test_meetingEndWithoutResume_neverPrepares_andTheNextPrepareIsNotHeldByTheRecording() async {
        let transfer = FakeTransfer(manifest: Fixture.manifest())
        let store = makeStore(transfer: transfer)
        store.recordingDidStart()
        await store.prepare(language: "en")
        XCTAssertEqual(store.status, .blocked(.recording), "precondition")

        await store.recordingDidStop(resume: false)

        XCTAssertTrue(transfer.requests.isEmpty, "a sign-out never starts a download")
        await store.prepare(language: "en")
        XCTAssertEqual(store.status, .ready(revision: "en-rev-1"))
    }

    func test_blockedOnAnExpensiveNetwork_downloadsOnItsOwn_whenThePathBecomesInexpensive() async {
        let manifest = Fixture.manifest()
        let transfer = FakeTransfer(manifest: manifest)
        let host = ChangingHost(expensive: true)
        let store = makeStore(manifest: manifest, transfer: transfer, host: host)
        await store.prepare(language: "en")
        XCTAssertEqual(store.status, .blocked(.expensiveNetwork), "precondition")

        host.expensive = false
        host.change()

        let ready = await eventually(timeout: 2) { await MainActor.run { store.status == .ready(revision: "en-rev-1") } }
        XCTAssertTrue(ready, "the store retries from the host's path change: \(store.status)")
        XCTAssertEqual(Set(transfer.requests.map(\.url)), Set(en().files.map { en().url(for: $0) }))
    }

    func test_blockedOnLowDisk_downloadsOnItsOwn_whenFreeSpaceRises() async {
        let required = 2 * en().totalBytes + 1_000_000_000
        let host = ChangingHost(freeBytes: required - 1)
        let store = makeStore(host: host)
        await store.prepare(language: "en")
        XCTAssertEqual(store.status, .blocked(.lowDisk(requiredBytes: required, freeBytes: required - 1)), "precondition")

        host.freeBytes = required
        await store.conditionsDidChange()

        XCTAssertEqual(store.status, .ready(revision: "en-rev-1"))
    }

    func test_conditionChanges_retryOncePerChange_neverWhileStillBlocked_andNeverFetchTwice() async {
        executionTimeAllowance = 60
        let manifest = Fixture.manifest()
        let transfer = FakeTransfer(manifest: manifest)
        let host = ChangingHost(expensive: true)
        let store = makeStore(manifest: manifest, transfer: transfer, host: host)
        await store.prepare(language: "en")
        var emissions = 0
        let sink = store.$status.dropFirst().sink { _ in emissions += 1 }
        defer { sink.cancel() }

        await store.conditionsDidChange()
        await store.conditionsDidChange()
        XCTAssertEqual(emissions, 0, "no re-run while the network is still expensive")

        host.expensive = false
        async let a: Void = store.conditionsDidChange()
        async let b: Void = store.conditionsDidChange()
        async let c: Void = store.conditionsDidChange()
        _ = await (a, b, c)

        XCTAssertEqual(store.status, .ready(revision: "en-rev-1"))
        let fetched = transfer.requests.map(\.url)
        XCTAssertEqual(fetched.count, en().files.count, "each file is fetched once: \(fetched)")
        XCTAssertEqual(Set(fetched).count, fetched.count)

        await store.conditionsDidChange()
        XCTAssertEqual(transfer.requests.count, en().files.count, "a ready model ignores further changes")
        XCTAssertEqual(store.status, .ready(revision: "en-rev-1"))
    }

    func test_conditionChange_whileRecording_neverRetries_andRecoveryStillWorksAfterIt() async {
        let manifest = Fixture.manifest()
        let transfer = FakeTransfer(manifest: manifest)
        let host = ChangingHost(expensive: true)
        let store = makeStore(manifest: manifest, transfer: transfer, host: host)
        await store.prepare(language: "en")
        store.recordingDidStart()

        host.expensive = false
        await store.conditionsDidChange()
        XCTAssertTrue(transfer.requests.isEmpty, "no download competes with a recording or its upload")

        host.expensive = true
        await store.recordingDidStop()
        XCTAssertEqual(store.status, .blocked(.expensiveNetwork))

        host.expensive = false
        await store.conditionsDidChange()
        XCTAssertEqual(store.status, .ready(revision: "en-rev-1"))
    }

    // MARK: Sign-out

    func test_afterSignOut_aNetworkOrDiskChange_neverDownloads() async {
        let manifest = Fixture.manifest()
        let transfer = FakeTransfer(manifest: manifest)
        let network = ChangingHost(expensive: true)
        let offline = makeStore(manifest: manifest, transfer: transfer, host: network)
        await offline.prepare(language: "en")
        XCTAssertEqual(offline.status, .blocked(.expensiveNetwork), "precondition")

        await offline.recordingDidStop(resume: false)
        network.expensive = false
        network.change()
        await offline.conditionsDidChange()
        _ = await eventually(timeout: 0.3) { !transfer.requests.isEmpty }

        XCTAssertTrue(transfer.requests.isEmpty, "a signed-out store never downloads on a path change: \(transfer.requests)")
        XCTAssertNotEqual(offline.status, .ready(revision: "en-rev-1"))

        let upgraded = Fixture.manifest(enRevision: "en-rev-2")
        let required = 2 * en(upgraded).totalBytes + 1_000_000_000
        let diskTransfer = FakeTransfer(manifest: upgraded)
        let disk = ChangingHost(freeBytes: required - 1)
        let full = makeStore(manifest: upgraded, transfer: diskTransfer, host: disk)
        await full.prepare(language: "en")
        XCTAssertEqual(full.status, .blocked(.lowDisk(requiredBytes: required, freeBytes: required - 1)), "precondition")

        await full.recordingDidStop(resume: false)
        disk.freeBytes = required
        disk.change()
        await full.conditionsDidChange()
        _ = await eventually(timeout: 0.3) { !diskTransfer.requests.isEmpty }

        XCTAssertTrue(diskTransfer.requests.isEmpty, "a signed-out store never downloads when space frees up: \(diskTransfer.requests)")
        XCTAssertNotEqual(full.status, .ready(revision: "en-rev-2"))
    }

    func test_afterSignOut_theNextSignInStillPrepares() async {
        let manifest = Fixture.manifest()
        let transfer = FakeTransfer(manifest: manifest)
        let host = ChangingHost(expensive: true)
        let store = makeStore(manifest: manifest, transfer: transfer, host: host)
        await store.prepare(language: "en")
        await store.recordingDidStop(resume: false)
        host.expensive = false
        await store.conditionsDidChange()
        XCTAssertTrue(transfer.requests.isEmpty, "precondition: nothing downloads while signed out")

        await store.prepare(language: "en")

        XCTAssertEqual(store.status, .ready(revision: "en-rev-1"))
        XCTAssertEqual(Set(transfer.requests.map(\.url)), Set(en().files.map { en().url(for: $0) }))
    }

    func test_signOutMidDownload_cancelsTheTransfer_andNeverReachesReady() async {
        let manifest = Fixture.manifest()
        let weight = url("Encoder.mlmodelc/weights/weight.bin", in: en(manifest))
        let transfer = FakeTransfer(manifest: manifest, gate: (weight, 20))
        let store = makeStore(manifest: manifest, transfer: transfer)

        let download = Task { await store.prepare(language: "en") }
        await transfer.waitUntilGateReached()
        await store.recordingDidStop(resume: false)
        await download.value

        XCTAssertEqual(transfer.cancellations, 1, "the in-flight transfer is cancelled on sign-out")
        XCTAssertNotEqual(store.status, .ready(revision: "en-rev-1"))
        XCTAssertNil(store.routableEntry(forLanguage: "en"))
    }

    // MARK: Local transcription failures

    func test_twoLocalFailuresInARow_reverifyTheModelOnce_redownloadingACorruptFile() async throws {
        XCTAssertEqual(ModelStore.failuresBeforeReverify, 2)
        let manifest = Fixture.manifest()
        let transfer = FakeTransfer(manifest: manifest)
        let warmer = FakeWarmer()
        let store = makeStore(manifest: manifest, transfer: transfer, warmer: warmer)
        await store.prepare(language: "en")
        XCTAssertEqual(store.status, .ready(revision: "en-rev-1"), "precondition: English entry ready")
        let installRequests = transfer.requests.count
        try Data(repeating: 0xAB, count: 64).write(
            to: store.directory(for: en(manifest)).appendingPathComponent("Encoder.mlmodelc/weights/weight.bin"))

        await store.recordLocalTranscription(succeeded: false, language: "en")
        XCTAssertEqual(transfer.requests.count, installRequests, "one failure does not re-verify")
        XCTAssertEqual(warmer.calls, ["fake-en"])
        XCTAssertTrue(store.healthyRevisions.contains("en-rev-1"), "one failure keeps the model routable")

        await store.recordLocalTranscription(succeeded: false, language: "en")
        XCTAssertEqual(transfer.requests.dropFirst(installRequests).map(\.url), [url("Encoder.mlmodelc/weights/weight.bin", in: en(manifest))],
                       "the second failure in a row re-verifies every file and re-downloads the corrupt one")
        XCTAssertEqual(warmer.calls, ["fake-en", "fake-en"], "the re-verified model is warmed again")
        XCTAssertEqual(store.status, .ready(revision: "en-rev-1"))

        await store.recordLocalTranscription(succeeded: false, language: "en")
        XCTAssertEqual(warmer.calls.count, 2, "the re-verify resets the count, so the next failure alone does not repeat it")
    }

    func test_twoLocalFailuresInARow_markTheModelUnhealthy_whenItCannotBeRevived() async {
        _ = await readyEnglishStore()
        let broken = makeStore(warmer: FakeWarmer(fails: true))
        XCTAssertNotNil(broken.routableEntry(forLanguage: "en"), "precondition: healthy across relaunch")

        await broken.recordLocalTranscription(succeeded: false, language: "en")
        await broken.recordLocalTranscription(succeeded: false, language: "en")

        XCTAssertFalse(broken.healthyRevisions.contains("en-rev-1"))
        XCTAssertNil(broken.routableEntry(forLanguage: "en"), "the next meeting is not routed to a model that keeps failing")
        XCTAssertNil(makeStore().routableEntry(forLanguage: "en"), "unhealthy survives relaunch")
    }

    func test_aLocalSuccessBetweenFailures_resetsTheCount() async {
        let manifest = Fixture.manifest()
        let transfer = FakeTransfer(manifest: manifest)
        let warmer = FakeWarmer()
        let store = makeStore(manifest: manifest, transfer: transfer, warmer: warmer)
        await store.prepare(language: "en")
        let installRequests = transfer.requests.count

        await store.recordLocalTranscription(succeeded: false, language: "en")
        await store.recordLocalTranscription(succeeded: true, language: "en")
        await store.recordLocalTranscription(succeeded: false, language: "en")

        XCTAssertEqual(transfer.requests.count, installRequests)
        XCTAssertEqual(warmer.calls, ["fake-en"], "no re-verify")
        XCTAssertTrue(store.healthyRevisions.contains("en-rev-1"))
    }

    func test_localFailuresInARow_countAcrossMeetingsAndRelaunches() async {
        let first = await readyEnglishStore()
        await first.recordLocalTranscription(succeeded: false, language: "en")

        let warmer = FakeWarmer()
        let relaunched = makeStore(warmer: warmer)
        await relaunched.recordLocalTranscription(succeeded: false, language: "en")

        XCTAssertEqual(warmer.calls, ["fake-en"], "the failure before the relaunch counts toward the re-verify")
        XCTAssertEqual(relaunched.status, .ready(revision: "en-rev-1"))
    }
}

private final class LockedFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Bool] = []
    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return _values }
    func record(_ value: Bool) { lock.lock(); _values.append(value); lock.unlock() }
}
