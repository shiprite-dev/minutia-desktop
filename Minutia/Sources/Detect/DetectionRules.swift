import Foundation

enum MeetingApp: String, Equatable {
    case zoom
    case teams
    /// A meeting running inside a web browser (Google Meet et al.), detected from a browser having a
    /// live audio-input stream. Unlike Zoom/Teams it cannot be attributed to a specific product, so
    /// its user-facing copy never names an app.
    case browser
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

    /// Bundle ids of the browsers a web meeting can run in. Membership is the whole browser-meeting
    /// signal: any of these holding a live audio-input stream means a call (Meet, Around, etc.) is in
    /// progress, since browsers only capture the mic during a call.
    static let browserBundleIds: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.apple.Safari",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "com.vivaldi.Vivaldi",
    ]

    /// A single bundle id counts as a browser when it equals one of the known browser ids, is a
    /// dot-scoped child of one (`com.google.Chrome.helper`, the process CoreAudio commonly attributes
    /// browser mic input to for every listed browser), or is a WebKit content/GPU helper
    /// (`com.apple.WebKit.WebContent`, `com.apple.WebKit.GPU`). The dot boundary is load-bearing: it
    /// keeps `com.google.ChromeCast` and `com.apple.WebKitFakeNo` out.
    static func isBrowserBundleId(_ id: String) -> Bool {
        if browserBundleIds.contains(where: { id == $0 || id.hasPrefix($0 + ".") }) { return true }
        let webKit = "com.apple.WebKit"
        return id == webKit || id.hasPrefix(webKit + ".")
    }

    /// Whether any process holding a live audio-input stream is a known browser (top-level app or one
    /// of its helper/content processes). The caller supplies the input-bundle-id set (already
    /// excluding our own process), keeping this a pure membership test.
    static func detectBrowserMeeting(inputBundleIds: Set<String>) -> Bool {
        inputBundleIds.contains(where: isBrowserBundleId)
    }

    /// A browser-input signal only counts once it has held across two consecutive polls, so a brief
    /// mic blip (a 2-second dictation, a notification chime) never trips a meeting prompt. Pure over
    /// the previous and current poll's raw browser hit; the caller threads the previous value.
    static func browserSignalConfirmed(previousPollHit: Bool, currentPollHit: Bool) -> Bool {
        previousPollHit && currentPollHit
    }

    /// A live meeting requires an active microphone plus a corroborating signal, in precedence order:
    /// a native meeting app (Zoom/Teams), a calendar event happening now, or a confirmed browser
    /// meeting. Mic alone is a soft signal (someone could just be talking); no mic is never a meeting
    /// regardless of other signals. Native and calendar signals outrank the browser signal because
    /// they are more specific.
    static func assess(
        micActive: Bool, app: MeetingApp?, calendarLive: Bool, browserActive: Bool
    ) -> DetectionConfidence {
        guard micActive else { return .none }
        if app != nil { return .high(app) }
        if calendarLive { return .high(nil) }
        if browserActive { return .high(.browser) }
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
