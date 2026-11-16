import Foundation

/// Where a meeting's audio is transcribed. Persisted in `CaptureManifest`.
enum TranscriptionMode: String, Codable {
    case device
    case cloud
    case blocked
}

/// The Settings picker. Stored in UserDefaults under `defaultsKey`.
enum TranscriptionSetting: String, CaseIterable {
    case automatic
    case onDeviceOnly
    case cloud

    static let defaultsKey = "app.minutia.transcriptionSetting"

    static func load(from defaults: UserDefaults) -> TranscriptionSetting {
        defaults.string(forKey: defaultsKey).flatMap(TranscriptionSetting.init(rawValue:)) ?? .automatic
    }

    /// A stored non-Automatic choice keeps the picker visible even with device routing off, so a
    /// user on "On this Mac only" can always leave it.
    func pickerVisible(deviceRoutingEnabled: Bool) -> Bool { deviceRoutingEnabled || self != .automatic }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .onDeviceOnly: "On this Mac only"
        case .cloud: "Cloud"
        }
    }
}

enum TranscriptionReason: String, CaseIterable {
    case intelMac
    case unsupportedOS
    case modelNotReady
    case unsupportedLanguage
    case unknownLanguage
    case thermalCritical
    case userChoseCloud
    case deviceRoutingOff

    /// Plain-language line shown in Settings under the picker.
    var settingsText: String {
        switch self {
        case .intelMac: "This Mac can't run the on-device model."
        case .unsupportedOS: "This version of macOS is too old for the on-device model."
        case .modelNotReady: "The on-device model is still being set up."
        case .unsupportedLanguage: "The on-device model doesn't cover this language."
        case .unknownLanguage: "The meeting language couldn't be determined."
        case .thermalCritical: "This Mac is too hot to transcribe right now."
        case .userChoseCloud: "You chose cloud transcription."
        case .deviceRoutingOff: "On-device transcription isn't available yet."
        }
    }
}

enum TranscriptionDecision: Equatable {
    case device
    case cloud(TranscriptionReason)
    case blocked(TranscriptionReason)

    var mode: TranscriptionMode {
        switch self {
        case .device: .device
        case .cloud: .cloud
        case .blocked: .blocked
        }
    }

    /// Settings line: the current mode, plus the reason when it is not on this Mac.
    var summary: String {
        switch self {
        case .device: "Meetings are transcribed on this Mac."
        case .cloud(let reason): "Meetings are transcribed in the cloud. " + reason.settingsText
        case .blocked(let reason): "Meetings can't be transcribed right now. " + reason.settingsText
        }
    }
}

enum TranscriptionRouter {
    struct Input {
        var isAppleSilicon: Bool
        var osVersion: OperatingSystemVersion
        /// nil when the locale could not be read.
        var language: String?
        var manifest: ModelManifest
        var healthyRevisions: Set<String>
        var thermalState: ProcessInfo.ThermalState
        var setting: TranscriptionSetting
        var deviceRoutingEnabled: Bool
    }

    static let meetingLanguageKey = "app.minutia.meetingLanguage"
    static let deviceRoutingKey = "app.minutia.deviceTranscriptionEnabled"
    static let deviceRoutingEnabledByDefault = false

    static func isDeviceRoutingEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: deviceRoutingKey) as? Bool ?? deviceRoutingEnabledByDefault
    }

    static func resolveLanguage(meetingLanguage: String?, preferredLanguages: [String]) -> String? {
        let raw = meetingLanguage.flatMap { $0.isEmpty ? nil : $0 } ?? preferredLanguages.first
        guard let raw, let code = Locale.Language(identifier: raw).languageCode, code.isISOLanguage else { return nil }
        // ISO 639 special codes, not languages
        return ["und", "mul", "zxx", "mis"].contains(code.identifier) ? nil : code.identifier
    }

    static func decide(_ input: Input) -> TranscriptionDecision {
        if input.setting == .cloud { return .cloud(.userChoseCloud) }
        guard let reason = failure(input) else { return .device }
        return input.setting == .automatic ? .cloud(reason) : .blocked(reason)
    }

    private static func failure(_ input: Input) -> TranscriptionReason? {
        guard input.deviceRoutingEnabled else { return .deviceRoutingOff }
        guard input.isAppleSilicon else { return .intelMac }
        guard let language = input.language else { return .unknownLanguage }
        guard let entry = input.manifest.entries.first(where: {
            !$0.egressForbiddenOnly && $0.languages.contains(language)
        }) else { return .unsupportedLanguage }
        guard input.osVersion.isAtLeast(entry.minimumOS) else { return .unsupportedOS }
        guard input.healthyRevisions.contains(entry.revision) else { return .modelNotReady }
        return input.thermalState == .critical ? .thermalCritical : nil
    }
}
