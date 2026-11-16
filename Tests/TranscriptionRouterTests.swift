import XCTest
@testable import Minutia

private let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 4, patchVersion: 0)
private let olderMac = OperatingSystemVersion(majorVersion: 14, minorVersion: 3, patchVersion: 1)

private func entry(_ id: String, revision: String, languages: Set<String>,
                   egressForbiddenOnly: Bool = false) -> ModelManifest.Entry {
    ModelManifest.Entry(
        id: id, repo: "Test/\(id)", repoFolder: id, revision: revision, files: [],
        languages: languages, minimumOS: sonoma, guardFloor: 0.5, egressForbiddenOnly: egressForbiddenOnly)
}

/// "xx" is deliberately a made-up code: the router must read it from the manifest, not a list of its own.
private let manifest = ModelManifest(entries: [
    entry("multi", revision: "multi-rev", languages: ["en", "de", "pt", "xx"]),
    entry("ja-only", revision: "ja-rev", languages: ["ja"], egressForbiddenOnly: true),
])

private func input(appleSilicon: Bool = true, os: OperatingSystemVersion = sonoma, language: String? = "en",
                   healthy: Set<String> = ["multi-rev", "ja-rev"], thermal: ProcessInfo.ThermalState = .nominal,
                   setting: TranscriptionSetting = .automatic, gate: Bool = true,
                   manifest: ModelManifest = manifest) -> TranscriptionRouter.Input {
    TranscriptionRouter.Input(
        isAppleSilicon: appleSilicon, osVersion: os, language: language, manifest: manifest,
        healthyRevisions: healthy, thermalState: thermal, setting: setting, deviceRoutingEnabled: gate)
}

final class TranscriptionRouterTests: XCTestCase {
    // MARK: decide

    func test_automatic_routesToDevice_onAppleSiliconWithAHealthyModelCoveringTheLanguage() {
        let rows: [(String, TranscriptionRouter.Input)] = [
            ("english", input()),
            ("german from the same entry", input(language: "de")),
            ("a language only the manifest knows", input(language: "xx")),
            ("newer macOS", input(os: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))),
            ("fair thermal", input(thermal: .fair)),
            ("serious thermal", input(thermal: .serious)),
            ("healthy but not warm: warmth is not an input", input(healthy: ["multi-rev"])),
        ]
        for (name, row) in rows {
            XCTAssertEqual(TranscriptionRouter.decide(row), .device, name)
        }
    }

    func test_automatic_eachSingleFailingCondition_routesToCloudWithItsOwnReason() {
        let rows: [(TranscriptionRouter.Input, TranscriptionReason)] = [
            (input(appleSilicon: false), .intelMac),
            (input(os: olderMac), .unsupportedOS),
            (input(healthy: []), .modelNotReady),
            (input(healthy: ["ja-rev"]), .modelNotReady),
            (input(language: "zh"), .unsupportedLanguage),
            (input(language: nil), .unknownLanguage),
            (input(thermal: .critical), .thermalCritical),
            (input(setting: .cloud), .userChoseCloud),
            (input(gate: false), .deviceRoutingOff),
        ]
        for (row, reason) in rows {
            XCTAssertEqual(TranscriptionRouter.decide(row), .cloud(reason), "\(reason)")
        }
        XCTAssertEqual(Set(rows.map(\.1)).count, TranscriptionReason.allCases.count,
                       "every reason is reachable and distinct")
    }

    func test_automatic_neverSelectsTheEgressForbiddenJapaneseModel_evenWhenHealthy() {
        XCTAssertEqual(TranscriptionRouter.decide(input(language: "ja")), .cloud(.unsupportedLanguage))
    }

    func test_automatic_onThePinnedManifest_routesEnglishToDeviceAndJapaneseToCloud() {
        let pinned = ModelManifest.pinned
        let healthy = Set(pinned.entries.map(\.revision))
        let rows: [(String, TranscriptionDecision)] = [
            ("en", .device), ("de", .device), ("pt", .device),
            ("ja", .cloud(.unsupportedLanguage)), ("zh", .cloud(.unsupportedLanguage)),
        ]
        for (language, expected) in rows {
            XCTAssertEqual(TranscriptionRouter.decide(input(language: language, healthy: healthy, manifest: pinned)),
                           expected, language)
        }
    }

    func test_onDeviceOnly_neverReturnsCloud_unsupportedCasesAreBlockedWithTheirReason() {
        let rows: [(TranscriptionRouter.Input, TranscriptionDecision)] = [
            (input(setting: .onDeviceOnly), .device),
            (input(healthy: ["multi-rev"], setting: .onDeviceOnly), .device),
            (input(appleSilicon: false, setting: .onDeviceOnly), .blocked(.intelMac)),
            (input(os: olderMac, setting: .onDeviceOnly), .blocked(.unsupportedOS)),
            (input(healthy: [], setting: .onDeviceOnly), .blocked(.modelNotReady)),
            (input(language: "zh", setting: .onDeviceOnly), .blocked(.unsupportedLanguage)),
            (input(language: "ja", setting: .onDeviceOnly), .blocked(.unsupportedLanguage)),
            (input(language: nil, setting: .onDeviceOnly), .blocked(.unknownLanguage)),
            (input(thermal: .critical, setting: .onDeviceOnly), .blocked(.thermalCritical)),
            (input(setting: .onDeviceOnly, gate: false), .blocked(.deviceRoutingOff)),
        ]
        for (index, (row, expected)) in rows.enumerated() {
            let decision = TranscriptionRouter.decide(row)
            XCTAssertEqual(decision, expected, "row \(index)")
            XCTAssertNotEqual(decision.mode, .cloud, "row \(index)")
        }
    }

    func test_cloudSetting_alwaysRoutesToCloud_evenWhenTheDeviceCouldTranscribe() {
        for gate in [true, false] {
            XCTAssertEqual(TranscriptionRouter.decide(input(setting: .cloud, gate: gate)), .cloud(.userChoseCloud))
        }
    }

    func test_decisionMode_mapsEachCase() {
        XCTAssertEqual(TranscriptionDecision.device.mode, .device)
        XCTAssertEqual(TranscriptionDecision.cloud(.intelMac).mode, .cloud)
        XCTAssertEqual(TranscriptionDecision.blocked(.intelMac).mode, .blocked)
    }

    // MARK: Language

    func test_resolveLanguage_takesTheMeetingLanguageElseTheFirstPreferredLanguage() {
        let rows: [(String?, [String], String?)] = [
            (nil, ["ja-JP"], "ja"),
            (nil, ["en-US"], "en"),
            (nil, ["pt-BR", "en-US"], "pt"),
            (nil, ["zh-Hans-CN"], "zh"),
            (nil, ["EN"], "en"),
            (nil, [], nil),
            (nil, [""], nil),
            (nil, ["xx-YY"], nil),
            (nil, ["not a locale!!"], nil),
            (nil, ["xx-YY", "en-US"], nil),
            ("ja", ["en-US"], "ja"),
            ("de-DE", ["en-US"], "de"),
            ("", ["en-US"], "en"),
            ("xx-YY", ["en-US"], nil),
            (nil, ["und"], nil),
            (nil, ["mul"], nil),
            (nil, ["zxx"], nil),
            (nil, ["mis"], nil),
            (nil, ["und-US"], nil),
            ("und", ["en-US"], nil),
            ("mul", ["en-US"], nil),
            ("zxx", ["en-US"], nil),
            ("mis", ["en-US"], nil),
        ]
        for (meeting, preferred, expected) in rows {
            XCTAssertEqual(
                TranscriptionRouter.resolveLanguage(meetingLanguage: meeting, preferredLanguages: preferred),
                expected, "meeting \(meeting ?? "nil"), preferred \(preferred)")
        }
    }

    func test_specialISOCodes_resolveToNoLanguage_andRouteAsUnknown() {
        for code in ["und", "mul", "zxx", "mis"] {
            let fromMeeting = TranscriptionRouter.resolveLanguage(meetingLanguage: code, preferredLanguages: ["en-US"])
            let fromMac = TranscriptionRouter.resolveLanguage(meetingLanguage: nil, preferredLanguages: [code])
            XCTAssertEqual(TranscriptionRouter.decide(input(language: fromMeeting)), .cloud(.unknownLanguage), code)
            XCTAssertEqual(TranscriptionRouter.decide(input(language: fromMac, setting: .onDeviceOnly)),
                           .blocked(.unknownLanguage), code)
        }
    }

    // MARK: Setting and gate

    func test_freshInstall_defaultsToAutomatic_andReachesDeviceOnceTheModelIsHealthy() throws {
        let suite = "TranscriptionRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let setting = TranscriptionSetting.load(from: defaults)

        XCTAssertEqual(setting, .automatic)
        XCTAssertEqual(TranscriptionRouter.decide(input(healthy: [], setting: setting)), .cloud(.modelNotReady))
        XCTAssertEqual(TranscriptionRouter.decide(input(setting: setting)), .device)
    }

    func test_setting_loadsTheStoredChoice_andFallsBackToAutomaticOnGarbage() throws {
        let suite = "TranscriptionRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        for setting in TranscriptionSetting.allCases {
            defaults.set(setting.rawValue, forKey: TranscriptionSetting.defaultsKey)
            XCTAssertEqual(TranscriptionSetting.load(from: defaults), setting)
        }
        defaults.set("hybrid", forKey: TranscriptionSetting.defaultsKey)
        XCTAssertEqual(TranscriptionSetting.load(from: defaults), .automatic)
    }

    func test_setting_pickerTitles() {
        XCTAssertEqual(TranscriptionSetting.allCases.map(\.title), ["Automatic", "On this Mac only", "Cloud"])
    }

    func test_deviceRoutingGate_holdsCloudUntilFlipped_andAHiddenDefaultOverridesIt() throws {
        let suite = "TranscriptionRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(TranscriptionRouter.deviceRoutingEnabledByDefault, "device routing ships turned off by default")
        XCTAssertEqual(TranscriptionRouter.isDeviceRoutingEnabled(defaults), TranscriptionRouter.deviceRoutingEnabledByDefault)
        defaults.set(true, forKey: TranscriptionRouter.deviceRoutingKey)
        XCTAssertTrue(TranscriptionRouter.isDeviceRoutingEnabled(defaults))
        defaults.set(false, forKey: TranscriptionRouter.deviceRoutingKey)
        XCTAssertFalse(TranscriptionRouter.isDeviceRoutingEnabled(defaults))
    }

    // MARK: Settings copy

    func test_everyReason_hasItsOwnPlainSettingsLine() {
        let texts = TranscriptionReason.allCases.map(\.settingsText)
        XCTAssertFalse(texts.contains { $0.isEmpty })
        XCTAssertEqual(Set(texts).count, texts.count)
        XCTAssertFalse(texts.contains { $0.localizedCaseInsensitiveContains("groq") }, "no provider plumbing in Settings")
    }

    func test_summary_namesTheMode_andCarriesTheReasonOnlyWhenNotOnThisMac() {
        let device = TranscriptionDecision.device.summary
        XCTAssertFalse(device.isEmpty)
        for reason in TranscriptionReason.allCases {
            XCTAssertFalse(device.contains(reason.settingsText))
            let cloud = TranscriptionDecision.cloud(reason).summary
            let blocked = TranscriptionDecision.blocked(reason).summary
            XCTAssertTrue(cloud.contains(reason.settingsText), "\(reason)")
            XCTAssertTrue(blocked.contains(reason.settingsText), "\(reason)")
            XCTAssertNotEqual(cloud, blocked, "\(reason)")
            XCTAssertNotEqual(cloud, device)
        }
    }
}
