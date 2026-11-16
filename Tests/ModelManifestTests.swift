import XCTest
@testable import Minutia

final class ModelManifestTests: XCTestCase {
    private let manifest = ModelManifest.pinned

    func test_pinnedManifest_shipsUltraForEnglishAndJapaneseSeparately_withTheirGuardFloors() {
        XCTAssertEqual(manifest.entries.map(\.id), ["parakeet-ultra", "parakeet-ja"])
        XCTAssertEqual(manifest.entry(forLanguage: "en")?.id, "parakeet-ultra")
        XCTAssertEqual(manifest.entry(forLanguage: "de")?.id, "parakeet-ultra")
        XCTAssertEqual(manifest.entry(forLanguage: "ja")?.id, "parakeet-ja")
        XCTAssertEqual(manifest.entry(forLanguage: "en")?.guardFloor, 0.78)
        XCTAssertEqual(manifest.entry(forLanguage: "ja")?.guardFloor, 0)
    }

    func test_pinnedManifest_marksOnlyTheJapaneseModelAsEgressForbiddenOnly() {
        XCTAssertEqual(manifest.entries.filter(\.egressForbiddenOnly).map(\.id), ["parakeet-ja"])
    }

    func test_pinnedRevisions_matchWhatParakeetEnginePinsFluidAudioTo() {
        for entry in manifest.entries {
            let model = ParakeetEngine.Model(rawValue: entry.id)
            XCTAssertNotNil(model, entry.id)
            XCTAssertEqual(entry.revision, model?.revision, entry.id)
            XCTAssertEqual(entry.repo, model?.repo.remotePath, entry.id)
            XCTAssertEqual(entry.repoFolder, model?.repo.folderName, entry.id)
        }
    }

    func test_pinnedFiles_coverEveryBundleFluidAudioLoads_withRealDigests() {
        let required: [String: [String]] = [
            "parakeet-ultra": ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
                               "JointDecisionv3.mlmodelc", "parakeet_vocab.json"],
            "parakeet-ja": ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoderv2.mlmodelc",
                            "Jointerv2.mlmodelc", "vocab.json"],
        ]
        for entry in manifest.entries {
            XCTAssertEqual(entry.revision.count, 40, entry.id)
            for name in required[entry.id]! {
                let needle = name.hasSuffix(".json") ? name : "\(name)/coremldata.bin"
                XCTAssertTrue(entry.files.contains { $0.path == needle }, "\(entry.id) misses \(needle)")
            }
            for file in entry.files {
                XCTAssertEqual(file.sha256.count, 64, file.path)
                XCTAssertTrue(file.sha256.allSatisfy(\.isHexDigit), file.path)
                XCTAssertGreaterThan(file.size, 0, file.path)
            }
        }
    }
}
