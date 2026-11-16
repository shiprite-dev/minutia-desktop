import Foundation

/// Compiled-in list of on-device speech models. Each entry is pinned to a Hugging Face commit; its files
/// install to `models/<revision>/<repoFolder>/` because FluidAudio resolves `<directory>/<repoFolder>`.
struct ModelManifest: Sendable {
    struct File: Sendable, Equatable {
        let path: String
        let size: Int64
        let sha256: String
    }

    struct Entry: Sendable {
        /// Matches `ParakeetEngine.Model.rawValue`.
        let id: String
        /// Hugging Face repo, `owner/name`.
        let repo: String
        /// FluidAudio's `Repo.folderName`, which is not the Hugging Face repo name.
        let repoFolder: String
        let revision: String
        let files: [File]
        let languages: Set<String>
        let minimumOS: OperatingSystemVersion
        let guardFloor: Double
        /// Used only when audio may not leave the Mac; Automatic never routes to it.
        var egressForbiddenOnly = false

        var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

        func url(for file: File) -> URL {
            URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
        }
    }

    let entries: [Entry]

    func entry(forLanguage language: String) -> Entry? {
        entries.first { $0.languages.contains(language) }
    }

    static let pinned = ModelManifest(entries: [
        Entry(
            id: "parakeet-ultra",
            repo: "FluidInference/parakeet-ultra-coreml",
            repoFolder: "parakeet-ultra",
            revision: "95eaa59a39d4394f047a4dc5cce480388a60d1b6",
            files: [
                .init(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "fe92b6cfaa012abd5248c0bc877832f19807015abffc60d87b8ccc8ccb48b3b5"),
                .init(path: "Decoder.mlmodelc/coremldata.bin", size: 560, sha256: "3b06e66768f0df7e21795f50e2b29300e33eeb1a2579dc42c695279c2d308497"),
                .init(path: "Decoder.mlmodelc/model.mil", size: 13110, sha256: "956f600207f88396017ca5c96cfa3acd5bfee60835a5b44b762e033a8fb28955"),
                .init(path: "Decoder.mlmodelc/weights/weight.bin", size: 23604992, sha256: "02a0d219f281b9665bc10c8768649403b2eebbbf4b44c627041d948e0de11bb4"),
                .init(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "d87101d824d6723cf95304da33755c3c60e762663b9ef2b0c4bd0aa166a09a0d"),
                .init(path: "Encoder.mlmodelc/coremldata.bin", size: 514, sha256: "397a84a4062f563cbc5f56077c674f09a61d85be5090f61d2f1932afb92ac0fe"),
                .init(path: "Encoder.mlmodelc/model.mil", size: 1002653, sha256: "f5d601568a4171d99a314c0fe3f6bc67715da2623732a3fb566e050ea83e5848"),
                .init(path: "Encoder.mlmodelc/weights/weight.bin", size: 594211328, sha256: "315ba01f33cadbf601d43ac7f5c86208b7aa75fdaa34705c9869d5abe3521c9b"),
                .init(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "68d38ca646aebafa7a9329e2efda50f5767c49e89fdb5f77f212072bb66f97c4"),
                .init(path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 592, sha256: "5e3af5a4ce686f6c237cadbd9284e10d333bc0e1546633cd0e430e6194044bc4"),
                .init(path: "JointDecisionv3.mlmodelc/model.mil", size: 11777, sha256: "791b3c3cf3eb2079c84623fc880f6bba008d1366e5f8b03e9a8ed8bd4d7194a0"),
                .init(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12642764, sha256: "3f310b85b82341c53ec383025ab094a4e462ee1c592e1ad7c6bfe39cff66ca25"),
                .init(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
                .init(path: "Preprocessor.mlmodelc/coremldata.bin", size: 486, sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
                .init(path: "Preprocessor.mlmodelc/metadata.json", size: 2841, sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
                .init(path: "Preprocessor.mlmodelc/model.mil", size: 28181, sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
                .init(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 491072, sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
                .init(path: "parakeet_vocab.json", size: 151122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
            ],
            languages: ["en", "de", "fr", "es", "it", "pt", "ru", "uk", "hr", "sl", "lv", "lt", "et",
                        "fi", "sv", "da", "nl", "pl", "cs", "sk", "hu", "ro", "bg", "el", "mt"],
            minimumOS: OperatingSystemVersion(majorVersion: 14, minorVersion: 4, patchVersion: 0),
            guardFloor: 0.78
        ),
        Entry(
            id: "parakeet-ja",
            repo: "FluidInference/parakeet-0.6b-ja-coreml",
            repoFolder: "parakeet-ja",
            revision: "2952296ff1da4a6d6a7aec545e226367db80c612",
            files: [
                .init(path: "Decoderv2.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "86795f3f612cf5bceb5d3ccb62353e7b249ec0d947de2d92f3a493b41c61cfc3"),
                .init(path: "Decoderv2.mlmodelc/coremldata.bin", size: 493, sha256: "aba05a4a882fb8149c0229b0eb36e24269fb9f008e65f302eef37b1f6c982ed3"),
                .init(path: "Decoderv2.mlmodelc/metadata.json", size: 3316, sha256: "345b75575b055563b6adc5a6adb39d3bdd8b5bf06b171fcc8a07229113dfc8c5"),
                .init(path: "Decoderv2.mlmodelc/model.mil", size: 13106, sha256: "dd9367a6dac8128d6cbb22a2bf8c7da48fa15494f04b6a4ef7be091f55bedf73"),
                .init(path: "Decoderv2.mlmodelc/weights/weight.bin", size: 17051392, sha256: "a56d792edf3b88e30466c0b992bb7e316fa743c90f8809c2be9d2ecb8ffbd48e"),
                .init(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "64d086974fa873a29bac8face69e71df44f678e8591dc848650fdfbd4110730d"),
                .init(path: "Encoder.mlmodelc/coremldata.bin", size: 507, sha256: "6e24d36005b89f97ab672596f94215883b19008f556ac1874500385994bd885f"),
                .init(path: "Encoder.mlmodelc/metadata.json", size: 2930, sha256: "d06e8b6e3e305b9d15fad119e9b31d05229c00b532655d120c317e990d633511"),
                .init(path: "Encoder.mlmodelc/model.mil", size: 1086104, sha256: "151eca4da087e17fa187834f2e15ae84e91a866299f2eecd5f184ff3ee738a3a"),
                .init(path: "Encoder.mlmodelc/weights/weight.bin", size: 593943616, sha256: "257685d3fdb578c5d6d7f0a5460c778f6104bcf2f264e4ae704b885c69ad6dda"),
                .init(path: "Jointerv2.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "7dcee73505a75e1264f5d2c40f3767fe528768c00ed73b3937b354d10b41e779"),
                .init(path: "Jointerv2.mlmodelc/coremldata.bin", size: 521, sha256: "98c853843c56998e061a2749365c0b1e0bfd5b03f2f54465e843f3de83e8c148"),
                .init(path: "Jointerv2.mlmodelc/metadata.json", size: 3464, sha256: "192a4656ca8744e9e27317a9008ebde4b664dbaf46011aec85ae27b9715b9697"),
                .init(path: "Jointerv2.mlmodelc/model.mil", size: 11774, sha256: "0e4fb7f1307d2e8fc15542118856cd34ed589134cbb84f0bcd60387aba6ef17d"),
                .init(path: "Jointerv2.mlmodelc/weights/weight.bin", size: 6078924, sha256: "d6f24519c7c6959e8ec6fb078e8c05d912d292fcb57720c63fdc9291b1db122d"),
                .init(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "315309121ac09c8fb7ed9f8dab20a30e440530b527401af5abcf6d0cf959e495"),
                .init(path: "Preprocessor.mlmodelc/coremldata.bin", size: 512, sha256: "de3624dd8335b3b0391be95da73b59577916f3ac7d1c6d30a66fd16369af7cb8"),
                .init(path: "Preprocessor.mlmodelc/metadata.json", size: 2837, sha256: "6c12ff477a63450f41ca2b52451d767a9bfc91d70311788c04265786bab43d3e"),
                .init(path: "Preprocessor.mlmodelc/model.mil", size: 27152, sha256: "cd35cb142ca4db597e99b0cb8d3d68f087e7a9d3e330ce46c8c20d55ab0b1c59"),
                .init(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 807968, sha256: "6512ba5d1acc3ffe6f322089c0ece5466f93c7ac77c267dd851a1fb517c637f9"),
                .init(path: "vocab.json", size: 29658, sha256: "9db0aa7ab1f5d2714c20a7880cb452d753da91cb10de88cb289cda4fd473d50a"),
            ],
            languages: ["ja"],
            minimumOS: OperatingSystemVersion(majorVersion: 14, minorVersion: 4, patchVersion: 0),
            guardFloor: 0,
            egressForbiddenOnly: true
        ),
    ])
}
