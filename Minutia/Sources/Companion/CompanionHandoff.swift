import CoreGraphics
import Foundation

enum CheckinPolicy {
    static func interval(for phase: AppPhase) -> TimeInterval? {
        switch phase {
        case .signedOut: return nil
        case .recording, .finalizing: return 30
        default: return 5
        }
    }

    static let maxIdleSeconds: TimeInterval = 300

    static func canClaim(phase: AppPhase, screenLocked: Bool, idleSeconds: TimeInterval) -> Bool {
        AppController.canStartRecording(from: phase) && !screenLocked && idleSeconds < maxIdleSeconds
    }
}

enum ClaimAction: Equatable {
    case askFirst
    case startNow
}

enum WebStartPolicy: String {
    case ask
    case always

    static let defaultsKey = "app.minutia.webStartPolicy"

    static func load(from defaults: UserDefaults) -> WebStartPolicy {
        defaults.string(forKey: defaultsKey).flatMap(WebStartPolicy.init(rawValue:)) ?? .ask
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    var onClaim: ClaimAction {
        switch self {
        case .ask: return .askFirst
        case .always: return .startNow
        }
    }
}

enum DeviceIdentity {
    static let defaultsKey = "app.minutia.deviceId"

    static func id(in defaults: UserDefaults) -> String {
        if let stored = defaults.string(forKey: defaultsKey), UUID(uuidString: stored) != nil {
            return stored.lowercased()
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: defaultsKey)
        return fresh
    }

    static var name: String { Host.current().localizedName ?? "Mac" }
}

enum UserActivity {
    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
