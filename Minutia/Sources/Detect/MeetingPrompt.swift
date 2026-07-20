import Foundation

/// The proactive "start taking notes?" floating panel is a consent surface shown when a meeting is
/// detected. Its show / expiry / suppression decisions and its copy are pure so the whole matrix is
/// tested without an NSPanel; the panel shell only renders what these decide.
enum MeetingPrompt {
    /// How long the panel stays up before it auto-dismisses.
    static let lifetime: TimeInterval = 25

    /// Only a resting, signed-in phase can host the prompt. Recording/finalizing already handle the
    /// meeting, an error screen is not the place for it, and signed out has no session to record
    /// into; leaving any of those dismisses a shown panel.
    static func canPrompt(phase: AppPhase) -> Bool {
        switch phase {
        case .idle, .detected: return true
        default: return false
        }
    }

    /// Show the panel only on a rising `.high` edge, in a promptable phase, and not already shown or
    /// dismissed for this mic session. `suppressedForSession` is set the moment the panel shows or is
    /// dismissed and cleared only when the mic goes inactive, giving exactly one prompt per continuous
    /// mic session (a `.high -> .soft -> .high` dip never re-shows).
    static func shouldShow(isHigh: Bool, phase: AppPhase, suppressedForSession: Bool) -> Bool {
        isHigh && canPrompt(phase: phase) && !suppressedForSession
    }

    /// Panel headline: name the client for a native app, stay generic otherwise (a browser meeting
    /// or a calendar-only signal cannot be attributed to a specific app).
    static func title(for app: MeetingApp?) -> String {
        switch app {
        case .zoom: return "Looks like you're in a Zoom meeting"
        case .teams: return "Looks like you're in a Teams meeting"
        case .browser, nil: return "Looks like you're in a meeting"
        }
    }

    static func content(for app: MeetingApp?) -> MeetingPromptContent {
        MeetingPromptContent(title: title(for: app), symbol: "waveform")
    }
}

/// What the floating panel renders: a headline and a leading glyph.
struct MeetingPromptContent: Equatable {
    let title: String
    let symbol: String
}
