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
        .cloud
    }

    var title: String { "" }
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
    var settingsText: String { "" }
}

enum TranscriptionDecision: Equatable {
    case device
    case cloud(TranscriptionReason)
    case blocked(TranscriptionReason)

    var mode: TranscriptionMode { .blocked }

    /// Settings line: the current mode, plus the reason when it is not on this Mac.
    var summary: String { "" }
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
        false
    }

    static func resolveLanguage(meetingLanguage: String?, preferredLanguages: [String]) -> String? {
        nil
    }

    static func decide(_ input: Input) -> TranscriptionDecision {
        .blocked(.thermalCritical)
    }
}
