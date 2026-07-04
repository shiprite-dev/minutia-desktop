import Foundation

enum AppPhase: Equatable {
    case signedOut
    case idle
    case detected(app: String?)
    case recording
    case finalizing
    case error(String)
}

enum AppEvent {
    case signedIn
    case signedOut
    case meetingDetected(String?)
    case recordStarted
    case recordStopped
    case finalized
    case failed(String)
    case dismissedDetection
}

extension AppPhase {
    func next(_ event: AppEvent) -> AppPhase {
        if case .signedOut = event { return .signedOut }
        if case .failed(let message) = event { return .error(message) }

        switch (self, event) {
        case (.signedOut, .signedIn):
            return .idle
        case (.idle, .meetingDetected(let app)):
            return .detected(app: app)
        case (.idle, .recordStarted), (.detected, .recordStarted), (.error, .recordStarted):
            return .recording
        case (.detected, .dismissedDetection), (.error, .dismissedDetection):
            return .idle
        case (.recording, .recordStopped):
            return .finalizing
        case (.finalizing, .finalized):
            return .idle
        default:
            return self
        }
    }
}
