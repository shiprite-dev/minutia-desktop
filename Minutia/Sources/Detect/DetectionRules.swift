import Foundation

enum MeetingApp: String, Equatable {
    case zoom
    case teams
}

enum DetectionConfidence: Equatable {
    case high(MeetingApp?)
    case soft
    case none
}

/// Pure meeting-detection heuristics: which app is running, how confident we are that a meeting
/// is live, and which agenda item (if any) matches right now. No CoreAudio, no process listing;
/// callers gather the raw signals and pass them in so this stays unit-testable.
enum DetectionRules {
    /// `CptHost` is Zoom's helper process, spawned only while a Zoom meeting is active, so its
    /// presence is a stronger signal than the main Zoom app being open. `com.microsoft.teams2` is
    /// the 2026 Teams bundle id; the classic `com.microsoft.teams` app does not signal a live call.
    /// Zoom wins when both are present because CptHost is the more specific signal.
    static func detectApp(processNames: [String], bundleIds: [String]) -> MeetingApp? {
        if processNames.contains("CptHost") { return .zoom }
        if bundleIds.contains("com.microsoft.teams2") { return .teams }
        return nil
    }

    /// A live meeting requires an active microphone plus a corroborating signal: a detected meeting
    /// app, or a calendar event known to be happening now. Mic alone is a soft signal (someone could
    /// just be talking); no mic is never a meeting regardless of other signals.
    static func assess(micActive: Bool, app: MeetingApp?, calendarLive: Bool) -> DetectionConfidence {
        guard micActive else { return .none }
        if app != nil || calendarLive { return .high(app) }
        return .soft
    }

    /// The earliest agenda item with a meeting URL whose window covers `now`, allowing a 2-minute
    /// grace period before `startAt` so detection can fire slightly ahead of the scheduled start.
    static func liveAgendaItem(_ items: [AgendaItem], now: Date) -> AgendaItem? {
        items
            .filter { $0.meetingUrl != nil }
            .filter { now >= $0.startAt.addingTimeInterval(-120) && now <= $0.endAt }
            .min { $0.startAt < $1.startAt }
    }
}
