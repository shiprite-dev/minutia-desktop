import FluidAudio
import Foundation

struct ParakeetWarmer: ModelWarmer {
    func warmUp(_ entry: ModelManifest.Entry, at directory: URL) async throws {
        ModelHub.offlineMode = true
        try Task.checkCancellation()
        let engine = try await ParakeetEngine.load(ParakeetEngine.Model(rawValue: entry.id)!, from: directory)
        try Task.checkCancellation()
        _ = try await engine.transcribe(.samples([Float](repeating: 0, count: 16_000)))
        try Task.checkCancellation()
    }
}
