import Foundation

/// The proactive "start taking notes?" floating panel is a consent surface shown when a meeting is
/// detected. Its show / expiry / suppression decisions and its copy are pure so the whole matrix is
/// tested without an NSPanel; the panel shell only renders what these decide.
enum MeetingPrompt {
    /// How long the panel stays up before it auto-dismisses.
    static let lifetime: TimeInterval = 25

    /// How long the end-variant panel waits, after the meeting looks over, before it auto-wraps up
    /// the notes so they appear without the user touching the menu bar.
    static let endCountdown: TimeInterval = 10

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

    /// The start variant: offer to begin taking notes on a freshly detected meeting. The compact
    /// xmark dismiss is rendered when `secondaryTitle` is nil.
    static func content(for app: MeetingApp?) -> MeetingPromptContent {
        MeetingPromptContent(
            title: title(for: app), symbol: "waveform",
            primaryTitle: "Start taking notes", secondaryTitle: nil)
    }

    /// The end variant: the meeting looks over, offer to wrap up the notes. A calm, confident prompt
    /// with a prominent wrap-up action and a quiet "Keep recording" escape.
    static func endContent() -> MeetingPromptContent {
        MeetingPromptContent(
            title: "Meeting ended?", symbol: "checkmark.circle",
            primaryTitle: "Wrap up my notes", secondaryTitle: "Keep recording")
    }

    /// Only a live recording can host the end prompt: it offers to finish the notes for the recording
    /// in progress. Leaving `.recording` (a manual stop, a web-end stop, sign-out) dismisses it.
    static func canPromptEnd(phase: AppPhase) -> Bool {
        if case .recording = phase { return true }
        return false
    }

    /// Show the end prompt only while recording, when auto-end has not been waved off for this
    /// recording ("Keep recording"), and it is not already on screen.
    static func shouldShowEnd(phase: AppPhase, autoEndDisabled: Bool, alreadyShowing: Bool) -> Bool {
        canPromptEnd(phase: phase) && !autoEndDisabled && !alreadyShowing
    }
}

/// What the floating panel renders: a headline, a leading glyph, a prominent primary action, and a
/// secondary action. A nil `secondaryTitle` renders the compact xmark dismiss (start variant); a
/// string renders a labeled quiet button (end variant's "Keep recording").
struct MeetingPromptContent: Equatable {
    let title: String
    let symbol: String
    let primaryTitle: String
    let secondaryTitle: String?
}
