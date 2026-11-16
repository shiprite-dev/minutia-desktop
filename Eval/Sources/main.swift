import Darwin
import Foundation

struct Manifest: Decodable {
    struct Item: Codable {
        let id: String
        let fixture: String
        let channel: String
        let `class`: String
        let lang: String
        let path: String
        let durationSeconds: Double
    }
    let items: [Item]
}

struct ItemResult: Encodable {
    let id: String
    let durationSeconds: Double
    let wallSeconds: Double
    let xRealtime: Double
    let noSpeech: Bool
    let text: String
    let segments: [SpeechSegment]
    let guardWindows: [QualityGuard.Window]
    let guardFailingWindowStarts: [Double]
    let guardPasses: Bool
    let error: String?
}

struct EngineRun: Encodable {
    let engine: String
    let modelId: String
    let loadSeconds: Double?
    let baselineFootprintMB: Double
    let peakFootprintMB: Double
    let items: [ItemResult]
}

struct Prepared: Encodable {
    let engine: String
    let modelId: String
    let modelDir: String
    let modelBytes: Int64
    let downloadSeconds: Double
    let loadSeconds: Double
    let peakFootprintMB: Double
}

func footprintMB() -> (current: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return (0, 0) }
    return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
}

func directoryBytes(_ url: URL) -> Int64 {
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
    guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
    return walker.compactMap { $0 as? URL }.reduce(Int64(0)) { sum, file in
        let values = try? file.resourceValues(forKeys: Set(keys))
        return sum + Int64(values?.isRegularFile == true ? values?.totalFileAllocatedSize ?? 0 : 0)
    }
}

func timed<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
    let start = Date()
    return (try await body(), Date().timeIntervalSince(start))
}

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--\(name)"), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func require(_ name: String) throws -> String {
    guard let value = argument(name) else { throw EvalError("missing --\(name)") }
    return value
}

func write<T: Encodable>(_ value: T, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: URL(fileURLWithPath: path), options: .atomic)
}

func modelDirectory(_ model: ParakeetEngine.Model, root: String) -> URL {
    URL(fileURLWithPath: root).appendingPathComponent(model.repo.folderName, isDirectory: true)
}

func run() async throws {
    let command = CommandLine.arguments.dropFirst().first ?? ""
    let engineName = try require("engine")
    let out = try require("out")

    switch command {
    case "prepare":
        guard let model = ParakeetEngine.Model(rawValue: engineName) else { throw EvalError("unknown local engine \(engineName)") }
        let dir = modelDirectory(model, root: try require("models"))
        let (_, downloadSeconds) = try await timed { try await ParakeetEngine.download(model, to: dir) }
        let (_, loadSeconds) = try await timed { try await ParakeetEngine.load(model, from: dir) }
        try write(Prepared(engine: engineName, modelId: model.modelId, modelDir: dir.path,
                           modelBytes: directoryBytes(dir), downloadSeconds: downloadSeconds,
                           loadSeconds: loadSeconds, peakFootprintMB: footprintMB().peak), to: out)

    case "transcribe":
        let fixtures = URL(fileURLWithPath: try require("fixtures"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
        let baseline = footprintMB().current
        let engine: SpeechEngine
        var loadSeconds: Double?
        var floor = 0.0
        var items = manifest.items
        if let model = ParakeetEngine.Model(rawValue: engineName) {
            let dir = modelDirectory(model, root: try require("models"))
            (engine, loadSeconds) = try await timed { try await ParakeetEngine.load(model, from: dir) }
            floor = model.guardFloor
            if model == .ja { items = items.filter { $0.lang == "ja" || $0.lang == "en+ja" } }
        } else if engineName == "groq-turbo" {
            guard let key = ProcessInfo.processInfo.environment["GROQ_API_KEY"], !key.isEmpty else {
                throw EvalError("GROQ_API_KEY is not set")
            }
            engine = GroqEngine(apiKey: key)
        } else {
            throw EvalError("unknown engine \(engineName)")
        }

        var results: [ItemResult] = []
        for item in items {
            let url = fixtures.appendingPathComponent(item.path)
            do {
                let (result, wall) = try await timed { try await engine.transcribe(.file(url)) }
                let windows = QualityGuard.windows(result.segments)
                results.append(ItemResult(id: item.id, durationSeconds: item.durationSeconds, wallSeconds: wall,
                                          xRealtime: item.durationSeconds / wall, noSpeech: result.noSpeech,
                                          text: result.text, segments: result.segments, guardWindows: windows,
                                          guardFailingWindowStarts: windows.filter { $0.fails(floor: floor) }.map(\.start),
                                          guardPasses: QualityGuard.passes(windows, floor: floor), error: nil))
            } catch {
                results.append(ItemResult(id: item.id, durationSeconds: item.durationSeconds, wallSeconds: 0, xRealtime: 0,
                                          noSpeech: false, text: "", segments: [], guardWindows: [], guardFailingWindowStarts: [],
                                          guardPasses: false,
                                          error: String(describing: error)))
            }
            FileHandle.standardError.write("\(engineName) \(item.id) done\n".data(using: .utf8)!)
        }
        try write(EngineRun(engine: engineName, modelId: engine.modelId, loadSeconds: loadSeconds,
                            baselineFootprintMB: baseline, peakFootprintMB: footprintMB().peak, items: results), to: out)

    default:
        throw EvalError("usage: minutia-eval prepare|transcribe --engine <id> --out <json> [--models <dir>] [--fixtures <dir>]")
    }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write("minutia-eval: \(error)\n".data(using: .utf8)!)
    exit(1)
}
