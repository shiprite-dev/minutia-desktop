import AppKit
import AVFoundation
import Combine
import OSLog
import Sparkle
import SwiftUI
import UserNotifications

@main
struct MinutiaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AppController.shared
    @StateObject private var updater = UpdaterController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller, updater: updater)
                .task { await controller.restoreSession() }
        } label: {
            MenuBarIcon(
                phase: controller.phase,
                softHint: controller.softHint,
                pendingConsent: controller.pendingRecordConsent != nil)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(controller: controller, updater: updater)
        }
    }
}

/// Owns Sparkle's updater for the app's lifetime. Held as a scene `@StateObject` (not on
/// AppController) so the updater is created only when the real app scene runs, never during the
/// headless unit-test host, which has no bundle feed to check. `canCheckForUpdates` mirrors the
/// updater's KVO state so the menu control can disable itself while a check is already running.
///
/// This is also Sparkle's `SPUStandardUserDriverDelegate` so scheduled update reminders are gentle:
/// in an LSUIElement app the standard scheduled-update alert opens behind other windows and is
/// effectively invisible, so a background-found update instead sets `updateAvailable`, which the menu
/// footer and Settings surface. Acting on it calls `checkForUpdates()` to hand the update back to
/// Sparkle's standard UI in focus.
@MainActor
final class UpdaterController: NSObject, ObservableObject {
    private var controller: SPUStandardUpdaterController!
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var updateAvailable = false

    override init() {
        super.init()
        // Start the updater only for the real app with a real Sparkle key. Under XCTest the app is
        // the test host, so its scene (and this holder) is constructed inside the runner; a started
        // updater with the placeholder SUPublicEDKey throws and pops a modal error alert that hangs
        // the headless runner. Skipping the start keeps the suite green and avoids that alert on
        // local runs until the public key is swapped in for the first release.
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let hasRealKey = key?.isEmpty == false && key != "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        controller = SPUStandardUpdaterController(
            startingUpdater: hasRealKey && !underTest, updaterDelegate: nil, userDriverDelegate: self)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

extension UpdaterController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// No side effects here (Sparkle calls this purely to decide who presents). Let the standard
    /// driver present only when it already has immediate focus; a background scheduled reminder is
    /// surfaced through `updateAvailable` instead so it is never buried behind other windows.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    /// Raise the in-app badge for any update the user did not initiate, whether or not the standard
    /// driver also shows its window; the badge is the reliable signal in a menu-bar app.
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated {
            if !state.userInitiated { self.updateAvailable = true }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { self.updateAvailable = false }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { self.updateAvailable = false }
    }
}

/// AppKit URL-scheme delivery. Two paths cover the two ways macOS delivers a `minutia://`
/// URL, and both funnel into `AppController.handleURL`:
///  - `application(_:open:)` fires on a COLD launch (the URL starts the app). It is reliable
///    for that case and untouched by SwiftUI's scene machinery.
///  - a manual `kAEGetURL` Apple Event handler covers the WARM case (app already running). In
///    a pure SwiftUI `MenuBarExtra`/`LSUIElement` app, macOS delivers a warm URL as a
///    `kAEGetURL` Apple Event that SwiftUI never forwards to `application(_:open:)`, so without
///    this handler the sign-in callback is silently dropped for every already-running user.
/// The handler is registered in `applicationDidFinishLaunching`, which runs AFTER SwiftUI
/// installs its own event handlers; registering earlier (e.g. in AppController.init) is
/// clobbered by SwiftUI. Double-delivery is safe: `AuthManager.handleCallback` dedupes the
/// single-use token hash.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))

        // Restore the Keychain session at launch so meeting detection starts without the menu ever
        // being opened; MenuBarExtra builds its content (and its .task) lazily on first open, so
        // relying on that alone leaves a freshly launched app unconnected until the user clicks it.
        // AuthManager.ensureConnected is single-flight and idempotent, so this racing MenuContent's
        // own restoreSession() is safe.
        Task { @MainActor in await AppController.shared.restoreSession() }
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else { return }
        Task { @MainActor in await AppController.shared.handleURL(url) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            Task { @MainActor in await AppController.shared.handleURL(url) }
        }
    }

    /// Guard against quitting with unfinished durable work: a live/finalizing recording, or a startup
    /// recovery sweep still rescuing a prior recording. "Finish & Quit" defers termination until the
    /// stop+finalize (and any in-flight recovery) completes. Even if the user quits anyway (or
    /// finalize fails), the durable capture directory means next-launch recovery finishes the job, so
    /// no path loses the recording.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppController.shouldConfirmQuit(
            phase: AppController.shared.phase,
            recoveryActive: AppController.shared.recoveryActive) else {
            return .terminateNow
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Finishing upload"
        alert.informativeText = "Minutia is still finishing a recording upload. Finish and quit, or keep it running?"
        alert.addButton(withTitle: "Finish & Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }
        Task { @MainActor in
            await AppController.shared.finishForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Status item glyph per phase: distinct attention glyphs for the states that otherwise render the
/// same plain waveform as idle (detected, a pending web-record consent, and signed-out), plus a
/// recording glyph that blinks between filled and hollow on a 1s timer while recording. Status items
/// ignore `withAnimation`, so a real timer drives the affordance; it is invalidated the moment the
/// icon leaves the recording phase, and stays a static filled glyph under Reduce Motion. The
/// per-state glyph is a pure decision (`symbolName`) so the full matrix is tested.
struct MenuBarIcon: View {
    let phase: AppPhase
    let softHint: Bool
    let pendingConsent: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hollow = false
    @State private var timer: Timer?

    var body: some View {
        Image(systemName: currentSymbol)
            .accessibilityLabel(Self.accessibilityLabel(phase: phase, pendingConsent: pendingConsent))
            .onAppear { syncPulse() }
            .onChange(of: phase) { _, _ in syncPulse() }
            .onDisappear { stopPulse() }
    }

    /// The pure per-state glyph, overlaid only by the recording blink (a timer-driven view concern).
    private var currentSymbol: String {
        if case .recording = phase, hollow, !reduceMotion { return "record.circle" }
        return Self.symbolName(phase: phase, softHint: softHint, pendingConsent: pendingConsent)
    }

    /// The status-item SF Symbol for a given state. Recording/finalizing/error take precedence over a
    /// pending consent; in idle or detected a pending consent shows its own glyph over the soft hint.
    /// All names are verified available on macOS 14.
    static func symbolName(phase: AppPhase, softHint: Bool, pendingConsent: Bool) -> String {
        switch phase {
        case .recording: return "record.circle.fill"
        case .finalizing: return "record.circle"
        case .error: return "waveform.badge.exclamationmark"
        case .detected: return pendingConsent ? "questionmark.circle.fill" : "waveform.badge.mic"
        case .signedOut: return "waveform.slash"
        case .idle:
            if pendingConsent { return "questionmark.circle.fill" }
            return softHint ? "waveform.badge.mic" : "waveform"
        }
    }

    /// VoiceOver text for the status item, since the glyph alone conveys the phase. Mirrors the glyph
    /// precedence: recording/finalizing/error win over a pending consent.
    static func accessibilityLabel(phase: AppPhase, pendingConsent: Bool) -> String {
        switch phase {
        case .recording: return "Minutia, recording"
        case .finalizing: return "Minutia, finishing recording"
        case .error: return "Minutia, error"
        case .detected: return pendingConsent ? "Minutia, record request pending" : "Minutia, meeting detected"
        case .signedOut: return "Minutia, signed out"
        case .idle: return pendingConsent ? "Minutia, record request pending" : "Minutia, idle"
        }
    }

    private func syncPulse() {
        stopPulse()
        guard phase == .recording, !reduceMotion else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            hollow.toggle()
        }
    }

    private func stopPulse() {
        timer?.invalidate()
        timer = nil
        hollow = false
    }
}

/// An outstanding request to record, triggered by the browser via `minutia://record`. Capture
/// never starts from the deep link itself: this pending consent gates it behind an explicit user
/// confirm (notification action or in-menu banner).
struct PendingRecordConsent: Equatable {
    let meetingId: String
    let requestedAt: Date
}

/// Orchestrates the menu bar app: folds auth, detection, and capture signals through the
/// AppPhase reducer, and owns the record/stop flows. Views stay logic-free; every state
/// decision lives in `AppPhase.next` under tests.
@MainActor
final class AppController: NSObject, ObservableObject {
    /// One graph shared by the SwiftUI scene (`@StateObject`) and the AppKit URL handler
    /// (`AppDelegate.application(_:open:)`), so a deep link reaches the live AuthManager
    /// rather than a second, disconnected instance.
    static let shared = AppController()

    @Published private(set) var phase: AppPhase = .signedOut
    @Published private(set) var series: [Series] = []
    /// Set when the browser fires `minutia://record`: capture is held here until the user confirms,
    /// so a web page can never start a covert recording. Surfaced as a notification and an in-menu
    /// banner (the fallback when notifications are denied).
    @Published private(set) var pendingRecordConsent: PendingRecordConsent?
    /// Soft detection: mic active with no corroborating app/calendar signal. Surfaced quietly
    /// (menu bar glyph + one secondary row), never a notification. See `shouldShowSoftHint`.
    @Published private(set) var softHint: Bool = false
    /// True when the app has microphone access; drives the in-menu "grant access" banner. System
    /// audio TCC has no queryable status, so only the mic is reflected here.
    @Published private(set) var micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    /// True when notification permission is denied; drives the Settings row nudging the user to
    /// enable it, since detection and consent prompts otherwise have no way to reach them.
    @Published private(set) var notificationsDenied = false
    /// Transient in-menu feedback (e.g. a rejected web-record) so the message exists even when
    /// notifications are off. Cleared on the next phase change.
    @Published private(set) var recordFeedback: String?
    /// True while the startup recovery sweep is finalizing a prior recording's orphaned upload.
    /// Drives a quiet in-menu row and folds recovery into the quit guard.
    @Published private(set) var recoveryActive: Bool = false
    @Published var selectedSeriesId: UUID? {
        didSet {
            UserDefaults.standard.set(selectedSeriesId?.uuidString, forKey: Self.lastSeriesKey)
        }
    }

    let authManager = AuthManager()
    let captureSession = CaptureSession()
    let detector = MeetingDetector()

    static let lastSeriesKey = "app.minutia.lastSeries"

    private static let logger = Logger(subsystem: "app.minutia.desktop", category: "Recovery")

    static let webRecordCategoryId = "app.minutia.webRecord"
    static let confirmWebRecordActionId = "app.minutia.webRecord.confirm"
    static let dismissWebRecordActionId = "app.minutia.webRecord.dismiss"
    /// userInfo key carrying a recovered recording's recap URL, opened when the notification is tapped.
    static let recapURLUserInfoKey = "app.minutia.recapURL"

    /// Record can begin only from a resting or recoverable phase. Guards a stale detection
    /// notification clicked mid-recording from starting a second server meeting and
    /// overwriting the recording meeting id (which would open the wrong recap).
    nonisolated static func canStartRecording(from phase: AppPhase) -> Bool {
        switch phase {
        case .idle, .detected, .error: return true
        default: return false
        }
    }

    /// A web-triggered record consent is honored only within [0, ttl] of when it was requested.
    /// The lower bound rejects clock skew; the upper bound expires a stale confirm the user left
    /// sitting in a notification or the menu.
    nonisolated static func isRecordConsentValid(requestedAt: Date, now: Date, ttl: TimeInterval = 120) -> Bool {
        let elapsed = now.timeIntervalSince(requestedAt)
        return elapsed >= 0 && elapsed <= ttl
    }

    /// What a `minutia://record?meeting_id=` command from the browser should do.
    enum RecordCommandDecision: Equatable {
        case start
        case ignoreSameMeeting
        case rejectOtherMeeting
        case signInRequired
    }

    /// Decide how to handle a web-triggered record command. Pure so the branch matrix (signed
    /// out, already recording this meeting, recording a different one, free to start) is tested
    /// without a live client or capture pipeline. Phase is the source of truth for "actively
    /// recording"; `recordingMeetingId` (lowercased) only distinguishes same vs different.
    nonisolated static func recordCommandDecision(
        requestedMeetingId: String,
        phase: AppPhase,
        signedIn: Bool,
        recordingMeetingId: String?
    ) -> RecordCommandDecision {
        guard signedIn else { return .signInRequired }
        switch phase {
        case .recording, .finalizing:
            return recordingMeetingId == requestedMeetingId ? .ignoreSameMeeting : .rejectOtherMeeting
        default:
            return .start
        }
    }

    /// Which start path last failed and is sitting in `.error`, so Retry re-runs the right one:
    /// a web-triggered record needs its meeting id, a finalize failure needs to finish the preserved
    /// audio (not start fresh), and everything else falls back to the selected series.
    enum FailedStart: Equatable {
        case series
        case meeting(String)
        case finalize(meetingId: String)
    }

    /// Route a Retry from the error phase. A remembered `.meeting`/`.finalize` failure retries that
    /// meeting; a `.series` failure or nothing remembered falls back to the series start path.
    nonisolated static func retryTarget(lastFailedStart: FailedStart?) -> FailedStart {
        lastFailedStart ?? .series
    }

    /// Route a mid-capture fatal to the Retry path that finishes the right work. Preserved audio
    /// (disk-full, stall) means Retry must finalize the durable directory, not start over. A
    /// non-preserved fatal (mic denied with nothing written) retries the original start: the web
    /// meeting id when there is no series, else the selected series.
    nonisolated static func fatalRetryTarget(
        preservedForRecovery: Bool, recordingMeetingId: String?, hasSeries: Bool
    ) -> FailedStart {
        guard let id = recordingMeetingId else { return .series }
        if preservedForRecovery { return .finalize(meetingId: id) }
        return hasSeries ? .series : .meeting(id)
    }

    /// What `finishForQuit` should do from the current phase: stop a live recording, or wait out an
    /// already-running finalize (calling `stop()` again would throw `notRunning` and flip the UI to
    /// error mid-quit). Anything else needs no finish work.
    enum QuitFinishAction: Equatable {
        case stop
        case awaitFinalizing
        case none
    }

    nonisolated static func quitFinishAction(phase: AppPhase) -> QuitFinishAction {
        switch phase {
        case .recording: return .stop
        case .finalizing: return .awaitFinalizing
        default: return .none
        }
    }

    /// Whether a Record press must be refused before any server call because the mic is already
    /// denied/restricted; starting the RPC first would orphan an empty server meeting. A
    /// `.notDetermined` status flows through unchanged so the deliberate prompt-during-capture design
    /// (which preserves system audio recorded while the dialog is up) is untouched.
    nonisolated static func micPreCheckFails(status: AVAuthorizationStatus) -> Bool {
        status == .denied || status == .restricted
    }

    /// The pre-flight branch for a series Record press: refuse before any server call when the mic is
    /// denied, guide the user (never silently return) when no series is selected, else proceed. Pure
    /// so the guard matrix is tested without a live client.
    enum RecordPreflight: Equatable {
        case micDenied
        case noSeries
        case proceed
    }

    nonisolated static func recordPreflight(micStatus: AVAuthorizationStatus, hasSeries: Bool) -> RecordPreflight {
        if micPreCheckFails(status: micStatus) { return .micDenied }
        if !hasSeries { return .noSeries }
        return .proceed
    }

    /// User-facing copy for a failed finalize. featureUnavailable names the host and reassures the
    /// audio is saved (the entitlement is an account setting, not a recording fault); a timeout is
    /// honest that the audio is safe locally and recoverable via Retry, since the durable directory
    /// outlives the timed-out network step.
    nonisolated static func finalizeFailureMessage(for error: Error, host: String?) -> String {
        if case MinutiaClientError.featureUnavailable = error {
            return "Transcription is not enabled for this account on \(host ?? "the server"). Your audio is saved. Ask your workspace admin to enable AI features."
        }
        if error is TimeoutError {
            return "Finishing the recording timed out. Your audio is saved locally; Retry to finish uploading."
        }
        return "Could not finish recording: \(error.localizedDescription)"
    }

    /// Signing out mid-capture must tear the pipeline down first; mic and system audio would
    /// otherwise keep recording invisibly with uploads failing auth.
    nonisolated static func shouldStopCaptureOnSignOut(phase: AppPhase) -> Bool {
        switch phase {
        case .recording, .finalizing: return true
        default: return false
        }
    }

    /// Quitting must prompt when there is unfinished durable work: a recording in flight (or
    /// finalizing its upload), or a startup recovery sweep still rescuing a prior recording. Leaving
    /// without finishing would defer the upload to the next-launch recovery at best.
    nonisolated static func shouldConfirmQuit(phase: AppPhase, recoveryActive: Bool) -> Bool {
        if recoveryActive { return true }
        switch phase {
        case .recording, .finalizing: return true
        default: return false
        }
    }

    /// Whether an error message is the mic-permission failure, so the ErrorView can offer the same
    /// System Settings deep link the idle banner does. Matches the exact constant produced by
    /// `CaptureSession.failureMessage`, the single source of that copy.
    nonisolated static func isMicPermissionError(message: String) -> Bool {
        message == CaptureSession.failureMessage(for: MicCapture.CaptureError.permissionDenied)
    }

    /// The soft hint shows only when mic-only detection meets a resting idle app: quiet by
    /// design (no notification). Any capture, finalize, error, or the .high banner suppresses
    /// it so it never competes for attention or lingers over a live recording.
    nonisolated static func shouldShowSoftHint(confidence: DetectionConfidence, phase: AppPhase) -> Bool {
        guard case .soft = confidence, case .idle = phase else { return false }
        return true
    }

    // MARK: - Following the meeting's end

    /// What one web-app status poll should do. The web app ends a meeting by setting its status to
    /// "completed"; anything else (live, upcoming, an unknown value, or nil from a read that could not
    /// resolve the row) means the meeting is still going, so keep polling. Pure so the branch matrix
    /// is tested without a live client.
    enum MeetingEndPollDecision: Equatable {
        case stop
        case keepPolling
    }

    nonisolated static func meetingEndPollDecision(status: String?) -> MeetingEndPollDecision {
        status == "completed" ? .stop : .keepPolling
    }

    /// The web-end status poll runs only while a recording is live: it watches for the meeting being
    /// ended from the web app. Started on entering `.recording`, cancelled on every exit.
    nonisolated static func shouldPollMeetingEnd(phase: AppPhase) -> Bool {
        if case .recording = phase { return true }
        return false
    }

    /// Why a recording stopped, which decides whether the recap opens. A manual stop and a
    /// locally-detected end both land the user on the fresh notes; a web-end stop suppresses the recap
    /// because the user is already on the web app and auto-opening a tab is noise.
    enum StopReason: Equatable {
        case manual
        case webEnded
        case localEnded
    }

    nonisolated static func opensRecap(for reason: StopReason) -> Bool {
        switch reason {
        case .manual, .localEnded: return true
        case .webEnded: return false
        }
    }

    /// How a recording was detected when it started, so local end-detection knows which raw signal
    /// marks the meeting as over. Captured from the `DetectionConfidence` at start time; a menu or
    /// deep-link start with no active detection is `.none`.
    enum DetectionOrigin: Equatable {
        case zoom
        case teams
        case browser
        case calendar
        case none
    }

    nonisolated static func detectionOrigin(for confidence: DetectionConfidence) -> DetectionOrigin {
        switch confidence {
        case .high(.zoom): return .zoom
        case .high(.teams): return .teams
        case .high(.browser): return .browser
        case .high(nil): return .calendar
        case .soft, .none: return .none
        }
    }

    /// Whether this poll's raw signals show the origin's meeting signal as absent: a native origin
    /// (Zoom/Teams) watches the native-app signal, a browser origin watches the browser-input signal.
    /// A calendar/none origin has no signal to lose, so it is never absent and never auto-ends.
    nonisolated static func endSignalAbsent(origin: DetectionOrigin, signals: MeetingDetector.RawSignals) -> Bool {
        switch origin {
        case .zoom, .teams: return !signals.nativeAppPresent
        case .browser: return !signals.browserInputPresent
        case .calendar, .none: return false
        }
    }

    /// Consecutive absent polls before a meeting is treated as ended, so a single blip never wraps up
    /// a live recording (mirrors the two-poll browser-signal confirmation on the detection side).
    static let endAbsentThreshold = 2

    /// Whether the meeting has ended for a native/browser origin: its signal has been absent for two
    /// consecutive polls. A calendar/none origin never auto-ends. Pure over the origin and the
    /// controller's running consecutive-absent count.
    nonisolated static func meetingEndDetected(origin: DetectionOrigin, consecutiveAbsent: Int) -> Bool {
        switch origin {
        case .zoom, .teams, .browser: return consecutiveAbsent >= endAbsentThreshold
        case .calendar, .none: return false
        }
    }

    /// Whether the end-prompt countdown, when it fires, should actually stop the recording: only while
    /// still recording and the user has not chosen "Keep recording". Guards the one-shot timer so a
    /// manual/web-end stop that already left `.recording`, or a waved-off auto-end, is a no-op.
    nonisolated static func shouldAutoStopOnEndTimeout(phase: AppPhase, autoEndDisabled: Bool) -> Bool {
        guard case .recording = phase else { return false }
        return !autoEndDisabled
    }

    /// A recovered origin signal while the end prompt is up cancels the pending wrap-up: the signal
    /// returning is stronger evidence the meeting is live than the countdown honors, mirroring the
    /// consecutive-absent threshold that guards arming it. The wave-off flag is left untouched, so a
    /// later real end re-prompts.
    nonisolated static func shouldDismissEndPromptOnRecovery(
        signalAbsent: Bool, endPromptShowing: Bool
    ) -> Bool {
        !signalAbsent && endPromptShowing
    }

    /// The proactive "start taking notes?" floating panel and its per-mic-session state. Suppression
    /// is set the moment the panel shows or is dismissed and cleared only when the mic goes inactive
    /// (confidence returns to `.none`), giving one prompt per continuous mic session. The panel wrapper
    /// creates no AppKit window until `show`, so holding it costs nothing under the headless test host.
    private let meetingPromptPanel = MeetingPromptPanel()
    private var promptSuppressedForSession = false
    private var promptExpiryTimer: Timer?

    /// Local end-detection state for the live recording. `recordingOrigin` (captured from the
    /// detection confidence at start) selects which raw signal marks the meeting as over;
    /// `endAbsentCount` is the running consecutive-absent count; `autoEndDisabled` is set by
    /// "Keep recording" to suppress auto-end for the rest of the recording; `endPromptShowing` gates
    /// re-showing the panel; the timer is the 10s wrap-up countdown.
    private var recordingOrigin: DetectionOrigin = .none
    private var endAbsentCount = 0
    private var autoEndDisabled = false
    private var endPromptShowing = false
    private var endCountdownTimer: Timer?
    /// Single-flight 5s poll of the recording meeting's server status, so ending the meeting from the
    /// web app stops the desktop recording. Started on recording start, cancelled on stop/sign-out/error.
    private var webEndPollTask: Task<Void, Never>?

    private var cancellables: Set<AnyCancellable> = []
    private var lastConfidence: DetectionConfidence = .none
    private var recordingMeetingId: UUID?
    private var recordingSeriesId: UUID?
    /// The instance capture started against, captured at start so the recap URL survives an instance
    /// switch made while the meeting was recording.
    private var recordingInstance: URL?
    private var lastFailedStart: FailedStart?
    /// The instance the detector's agenda provider is currently bound to. When it changes (an
    /// instance switch), the detector must be torn down and restarted so it stops polling the old
    /// instance's client; within one instance, repeated syncs keep the running session (and its
    /// notify debounce) intact.
    private var detectorBoundInstance: URL?
    /// Single-flight guard for the startup recovery sweep.
    private var recoveryTask: Task<Void, Never>?

    private override init() {
        super.init()
        Self.registerNotificationCategories()
        UNUserNotificationCenter.current().delegate = self

        // A mid-capture fatal (denied mic, disk-full, stall) flips the UI to .error with a message.
        // Route Retry to the right recovery: preserved audio must be finalized, not re-recorded, so
        // remember the failed-start target BEFORE apply(.failed) (which keeps it only on the way into
        // .error).
        captureSession.onFailure = { [weak self] message, preserved in
            guard let self else { return }
            self.lastFailedStart = Self.fatalRetryTarget(
                preservedForRecovery: preserved,
                recordingMeetingId: self.recordingMeetingId?.uuidString,
                hasSeries: self.recordingSeriesId != nil)
            self.apply(.failed(message))
        }

        // A fast-lane segment register hit the account-lacks-AI terminal 403 mid-recording. Recording
        // and uploads keep going; surface it once through the existing in-menu feedback banner, which
        // persists through the .recording phase and clears on the next transition.
        captureSession.onTranscriptionUnavailable = { [weak self] in
            self?.recordFeedback = "Transcription is not enabled for this account. Audio keeps recording and will be saved."
        }

        authManager.$sessionIdentity
            .removeDuplicates()
            .sink { [weak self] identity in self?.handleAuthChange(signedIn: identity.email != nil) }
            .store(in: &cancellables)

        detector.$confidence
            .removeDuplicates()
            .sink { [weak self] confidence in self?.handleDetection(confidence) }
            .store(in: &cancellables)

        // Raw per-poll signals drive local end-detection while a recording keeps the mic active.
        detector.onRawSignals = { [weak self] signals in self?.handleRawSignals(signals) }
    }

    /// Rehydrate the Supabase client from the stored instance (or the managed cloud
    /// default on first run) so a Keychain session lands the app signed in with no
    /// Connect step. Idempotent with SignInView's on-appear auto-connect.
    func restoreSession() async {
        try? await authManager.ensureConnected()
        // Recover orphaned captures on every launch, not only on a sign-in transition: a warm launch
        // restoring a Keychain session emits no signedIn transition, so a recording orphaned by a
        // prior crash would otherwise sit unrescued across relaunches. Single-flight and self-guarded
        // (no client, or a sweep already running, makes this a no-op).
        runRecovery()
    }

    // MARK: - Phase transitions

    private func apply(_ event: AppEvent) {
        let next = phase.next(event)
        guard next != phase else { return }
        phase = next
        // A pending web-record consent is only actionable from a resting/recoverable phase.
        // Drop it the moment we leave one (recording started by any path, finalizing, or sign-out)
        // so a stale banner cannot linger past the meeting or a sign-out.
        if !Self.canStartRecording(from: next) { pendingRecordConsent = nil }
        // The floating prompt only belongs over a promptable phase; leaving one (recording started
        // from the menu or a deep link, finalizing, error, or sign-out) dismisses it.
        if !MeetingPrompt.canPrompt(phase: next) { dismissMeetingPrompt() }
        // The end prompt belongs only over a live recording; leaving it (a manual stop, a web-end
        // stop, an error, or sign-out) dismisses it and cancels its wrap-up countdown, so the two
        // end paths never fight.
        if !MeetingPrompt.canPromptEnd(phase: next) { dismissEndPrompt() }
        // The web-end status poll runs only while recording; start on entry, cancel on every exit.
        if Self.shouldPollMeetingEnd(phase: next) { startWebEndPoll() } else { stopWebEndPoll() }
        // Transient feedback lives for exactly one phase; any transition clears it.
        recordFeedback = nil
        // The remembered failed-start route is only meaningful while parked in .error. Any
        // transition to a non-error phase (recording actually started, or the error dismissed)
        // retires it; a transition into .error keeps the route set by the catch that triggered it.
        if case .error = next {} else { lastFailedStart = nil }
        if case .idle = next { refreshPermissionState() }
        refreshSoftHint()
        syncDetector()
    }

    /// Refresh the mic-authorization and notification-permission flags that drive the in-menu and
    /// Settings guidance. Called on idle entry and when the menu/Settings appear.
    func refreshPermissionState() {
        micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                self.notificationsDenied = settings.authorizationStatus == .denied
            }
        }
    }

    /// Derive the published hint from the latest confidence and phase together, so leaving
    /// idle (record, error, sign-out) clears it and re-entering idle under soft restores it.
    private func refreshSoftHint() {
        softHint = Self.shouldShowSoftHint(confidence: lastConfidence, phase: phase)
    }

    /// The detector runs while signed in and resting (idle/detected) and continues through
    /// `.recording` so it can watch the meeting's own signal for the meeting ending. During recording
    /// the phase guards keep it inert on the detection side (no start prompt, no phase change); only
    /// its raw per-poll signals are consumed, for local end-detection. Finalizing/error/signed-out
    /// stop it.
    private func syncDetector() {
        switch phase {
        case .idle, .detected, .recording:
            guard let client = authManager.client() else {
                detector.stop()
                detectorBoundInstance = nil
                return
            }
            // On an instance switch, tear the detector down first so start() binds the NEW agenda
            // provider (start() keeps the old provider while running); on the same instance this is
            // a cheap no-op that preserves the running session's notify debounce.
            let instance = authManager.instance
            if detectorBoundInstance != instance {
                detector.stop()
                detectorBoundInstance = instance
            }
            detector.start(agendaProvider: { (try? await client.agenda()) ?? [] })
        default:
            detector.stop()
            detectorBoundInstance = nil
        }
    }

    private func handleAuthChange(signedIn: Bool) {
        if signedIn {
            apply(.signedIn)
            // apply() no-ops when an instance switch under the same email keeps the phase at .idle,
            // so rebind the detector explicitly: syncDetector re-points its agenda provider at the
            // new instance's client. loadSeries and runRecovery likewise re-run for the new instance.
            syncDetector()
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            Task { await loadSeries() }
            runRecovery()
        } else {
            if Self.shouldStopCaptureOnSignOut(phase: phase) {
                // Keep the recording ids set until the finalize completes: a fast re-sign-in would
                // otherwise let runRecovery see no active meeting and touch the still-finalizing
                // capture dir concurrently with this stop. Clear them only once stop() returns.
                Task {
                    _ = try? await captureSession.stop()
                    recordingMeetingId = nil
                    recordingSeriesId = nil
                    recordingInstance = nil
                }
            } else {
                recordingMeetingId = nil
                recordingSeriesId = nil
                recordingInstance = nil
            }
            lastFailedStart = nil
            pendingRecordConsent = nil
            apply(.signedOut)
            series = []
        }
    }

    private func handleDetection(_ confidence: DetectionConfidence) {
        lastConfidence = confidence
        switch confidence {
        case .high(let app):
            apply(.meetingDetected(Self.detectionLabel(app)))
            showMeetingPromptIfNeeded(app: app)
        case .none:
            // The corroborating signal is gone (mic released): retire a stale banner and reset the
            // prompt session so the next meeting can prompt again.
            if case .detected = phase { apply(.dismissedDetection) }
            resetMeetingPromptSession()
        case .soft:
            // Quiet by design: no phase change, no prompt, just the menu bar hint.
            break
        }
        refreshSoftHint()
    }

    // MARK: - Proactive meeting prompt

    /// Present the floating prompt on the rising `.high` edge, once per mic session. `apply` has
    /// already moved the phase to `.detected` by the time this runs, so the phase check reflects the
    /// promptable state. Confirming starts capture via the same `startRecording` path the in-menu
    /// banner uses (mic preflight included); dismissing suppresses re-prompt for the rest of the
    /// session.
    private func showMeetingPromptIfNeeded(app: MeetingApp?) {
        guard MeetingPrompt.shouldShow(
            isHigh: true, phase: phase, suppressedForSession: promptSuppressedForSession) else { return }
        promptSuppressedForSession = true
        meetingPromptPanel.show(
            content: MeetingPrompt.content(for: app),
            onStart: { [weak self] in
                self?.dismissMeetingPrompt()
                self?.startRecording()
            },
            onDismiss: { [weak self] in self?.dismissMeetingPrompt() })
        promptExpiryTimer?.invalidate()
        promptExpiryTimer = Timer.scheduledTimer(
            withTimeInterval: MeetingPrompt.lifetime, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismissMeetingPrompt() }
        }
    }

    /// Hide the panel and cancel its expiry. Does not clear the session suppression: a dismissed or
    /// expired prompt must not re-show until the mic session resets.
    private func dismissMeetingPrompt() {
        promptExpiryTimer?.invalidate()
        promptExpiryTimer = nil
        meetingPromptPanel.dismiss()
    }

    /// A new mic session (mic went inactive, then a fresh meeting): hide any stale panel and clear
    /// suppression so the next detection can prompt again.
    private func resetMeetingPromptSession() {
        promptSuppressedForSession = false
        dismissMeetingPrompt()
    }

    // MARK: - Following the meeting's end

    /// Reset the local end-detection state for a new recording: capture its origin (which signal
    /// marks the meeting as over) and clear the absent count, the wave-off, and the panel gate.
    private func resetEndDetectionState(origin: DetectionOrigin) {
        recordingOrigin = origin
        endAbsentCount = 0
        autoEndDisabled = false
        endPromptShowing = false
    }

    /// Each active-mic poll while recording: fold the origin's raw signal into the consecutive-absent
    /// count (a recovered signal resets it and cancels a pending wrap-up), and offer to wrap up once
    /// the meeting looks over.
    private func handleRawSignals(_ signals: MeetingDetector.RawSignals) {
        guard case .recording = phase else { return }
        let absent = Self.endSignalAbsent(origin: recordingOrigin, signals: signals)
        endAbsentCount = absent ? endAbsentCount + 1 : 0
        if Self.shouldDismissEndPromptOnRecovery(signalAbsent: absent, endPromptShowing: endPromptShowing) {
            dismissEndPrompt()
        }
        guard Self.meetingEndDetected(origin: recordingOrigin, consecutiveAbsent: endAbsentCount) else { return }
        showEndPromptIfNeeded()
    }

    /// Present the end-variant panel: "Wrap up my notes" stops now (recap opens as usual), "Keep
    /// recording" waves off auto-end for the rest of the recording. If the user does nothing, the 10s
    /// countdown auto-stops through the same normal path so the notes appear untouched.
    private func showEndPromptIfNeeded() {
        guard MeetingPrompt.shouldShowEnd(
            phase: phase, autoEndDisabled: autoEndDisabled, alreadyShowing: endPromptShowing) else { return }
        endPromptShowing = true
        meetingPromptPanel.show(
            content: MeetingPrompt.endContent(),
            onStart: { [weak self] in self?.stopRecording(reason: .localEnded) },
            onDismiss: { [weak self] in self?.keepRecording() })
        endCountdownTimer?.invalidate()
        endCountdownTimer = Timer.scheduledTimer(
            withTimeInterval: MeetingPrompt.endCountdown, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.autoStopFromEndPrompt() }
        }
    }

    /// "Keep recording": disable auto-end for the rest of this recording and hide the panel.
    private func keepRecording() {
        autoEndDisabled = true
        dismissEndPrompt()
    }

    /// The wrap-up countdown fired. Stop through the normal path (recap opens) only if still recording
    /// and not waved off, so it triggers at most once and never after a manual/web-end stop.
    private func autoStopFromEndPrompt() {
        guard Self.shouldAutoStopOnEndTimeout(phase: phase, autoEndDisabled: autoEndDisabled) else { return }
        stopRecording(reason: .localEnded)
    }

    /// Hide the end panel and cancel its wrap-up countdown. Driven from `apply` whenever the phase
    /// leaves `.recording`, so a manual stop, a web-end stop, an error, or sign-out all cancel it.
    private func dismissEndPrompt() {
        endCountdownTimer?.invalidate()
        endCountdownTimer = nil
        endPromptShowing = false
        meetingPromptPanel.dismiss()
    }

    /// Poll the recording meeting's server status every 5s so ending the meeting from the web app
    /// stops the desktop recording. Single-flight, and self-guarded on a live client and meeting id.
    /// Poll errors are logged and swallowed: a network blip must never stop capture, the poll simply
    /// tries again on the next tick.
    private func startWebEndPoll() {
        guard webEndPollTask == nil,
              let client = authManager.client(),
              let meetingId = recordingMeetingId?.uuidString else { return }
        webEndPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                let status: String?
                do {
                    status = try await client.meetingStatus(meetingId: meetingId)
                } catch {
                    Self.logger.debug("meeting-end poll error: \(error.localizedDescription, privacy: .public)")
                    continue
                }
                guard let self, !Task.isCancelled else { return }
                if case .stop = Self.meetingEndPollDecision(status: status) {
                    self.handleWebMeetingEnded()
                    return
                }
            }
        }
    }

    private func stopWebEndPoll() {
        webEndPollTask?.cancel()
        webEndPollTask = nil
    }

    /// The meeting was ended from the web app: stop the recording through the normal path but suppress
    /// the recap (the user is already on the web), leaving a calm note that the recording is finishing.
    /// The stop leaves `.recording`, which cancels any pending local end prompt via `apply`.
    private func handleWebMeetingEnded() {
        stopRecording(reason: .webEnded)
        recordFeedback = "Meeting ended from the web. Finishing your notes."
    }

    /// Detection label carried in `.detected(app:)`: "Zoom" / "Teams" / "browser meeting" / "Calendar".
    static func detectionLabel(_ app: MeetingApp?) -> String {
        switch app {
        case .zoom: return "Zoom"
        case .teams: return "Teams"
        case .browser: return "browser meeting"
        case nil: return "Calendar"
        }
    }

    /// The in-menu detection banner headline. A browser meeting cannot be attributed to a named app,
    /// so it drops the "via X" phrasing for a generic prompt; a named app or calendar keeps it.
    static func detectionBannerText(via: String) -> String {
        if via == detectionLabel(.browser) { return "In a meeting? Record?" }
        return "Meeting detected via \(via): Record?"
    }

    // MARK: - Series

    private func loadSeries() async {
        guard let client = authManager.client() else { return }
        guard let owned = try? await client.ownedSeries() else { return }
        series = owned
        let last = UserDefaults.standard.string(forKey: Self.lastSeriesKey).flatMap(UUID.init(uuidString:))
        if let last, owned.contains(where: { $0.id == last }) {
            selectedSeriesId = last
        } else if selectedSeriesId == nil || !owned.contains(where: { $0.id == selectedSeriesId }) {
            selectedSeriesId = owned.first?.id
        }
    }

    /// Re-fetch the owned series so a series created on the web while the app was already open is
    /// picked up. Called when the idle menu appears, the cheapest correct refresh point.
    func reloadSeries() {
        Task { await loadSeries() }
    }

    // MARK: - Record / stop

    /// Single start path shared by the Record button, the detection banner, and the
    /// notification action.
    func startRecording() {
        guard Self.canStartRecording(from: phase) else { return }
        guard let client = authManager.client() else { return }
        switch Self.recordPreflight(
            micStatus: AVCaptureDevice.authorizationStatus(for: .audio),
            hasSeries: selectedSeriesId != nil) {
        case .micDenied:
            // Refuse before any server call: starting the RPC first would orphan an empty meeting.
            apply(.failed(CaptureSession.failureMessage(for: MicCapture.CaptureError.permissionDenied)))
            return
        case .noSeries:
            // Guide the user rather than returning silently, and post a notification too so the
            // notification-action Record path is never a dead click.
            let message = "Create a series in Minutia on the web, then record."
            recordFeedback = message
            Self.postNotification(title: "Can't record yet", body: message)
            return
        case .proceed:
            break
        }
        guard let seriesId = selectedSeriesId else { return }
        let instance = client.instance
        Task {
            do {
                let meeting = try await client.startOrJoinMeeting(seriesId: seriesId)
                let userId = try? await client.supabase.auth.session.user.id.uuidString.lowercased()
                try captureSession.start(meetingId: meeting.id.uuidString, seriesId: seriesId, userId: userId, client: client)
                recordingMeetingId = meeting.id
                recordingSeriesId = seriesId
                recordingInstance = instance
                resetEndDetectionState(origin: Self.detectionOrigin(for: lastConfidence))
                apply(.recordStarted)
            } catch {
                lastFailedStart = .series
                apply(.failed("Could not start recording: \(error.localizedDescription)"))
            }
        }
    }

    /// Record against a meeting id handed in from the browser (which already started/resolved
    /// the meeting), so skip the start-or-join RPC and attach capture straight to the given id.
    /// No series is known, so the stop-time recap is left to the browser tab the user came from.
    func startRecording(meetingId: String) {
        guard Self.canStartRecording(from: phase), let client = authManager.client() else { return }
        if Self.micPreCheckFails(status: AVCaptureDevice.authorizationStatus(for: .audio)) {
            apply(.failed(CaptureSession.failureMessage(for: MicCapture.CaptureError.permissionDenied)))
            return
        }
        let instance = client.instance
        Task {
            do {
                let userId = try? await client.supabase.auth.session.user.id.uuidString.lowercased()
                try captureSession.start(meetingId: meetingId, seriesId: nil, userId: userId, client: client)
                recordingMeetingId = UUID(uuidString: meetingId)
                recordingSeriesId = nil
                recordingInstance = instance
                resetEndDetectionState(origin: Self.detectionOrigin(for: lastConfidence))
                apply(.recordStarted)
            } catch {
                lastFailedStart = .meeting(meetingId)
                apply(.failed("Could not start recording: \(error.localizedDescription)"))
            }
        }
    }

    /// Route a web-triggered `minutia://record` command through the pure decision, then act:
    /// prompt sign-in when unauthed, no-op when already recording this same meeting, warn when
    /// a different meeting is live, else start capture against the given id.
    func handleRecordCommand(meetingId: String) {
        let decision = Self.recordCommandDecision(
            requestedMeetingId: meetingId,
            phase: phase,
            signedIn: authManager.userEmail != nil,
            recordingMeetingId: recordingMeetingId?.uuidString.lowercased())
        switch decision {
        case .signInRequired:
            NSApp.activate(ignoringOtherApps: true)
            Self.postNotification(
                title: "Sign in to record",
                body: "Open Minutia and sign in, then start the recording again.")
        case .ignoreSameMeeting:
            return
        case .rejectOtherMeeting:
            recordFeedback = "Already recording another meeting. Stop it first to record this one."
            Self.postNotification(
                title: "Already recording another meeting",
                body: "Stop the current recording before starting a new one.")
        case .start:
            promptRecordConsent(meetingId: meetingId)
        }
    }

    /// Hold a web-triggered record behind an explicit confirm: capture must never start silently
    /// from a deep link. Stores the pending consent, brings the app forward, and posts a two-action
    /// notification. A duplicate request for the same meeting does not stack a second prompt.
    func promptRecordConsent(meetingId: String) {
        if let pending = pendingRecordConsent, pending.meetingId == meetingId { return }
        pendingRecordConsent = PendingRecordConsent(meetingId: meetingId, requestedAt: Date())
        NSApp.activate(ignoringOtherApps: true)
        let content = UNMutableNotificationContent()
        content.title = "Record this meeting from your browser?"
        content.body = "Minutia will start recording only after you confirm."
        content.categoryIdentifier = Self.webRecordCategoryId
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Confirm a pending web-triggered record: start capture only if the consent is still valid and
    /// the phase can start recording. Clears the pending consent either way so a stale confirm can
    /// never start capture later.
    func confirmPendingRecord() {
        guard let pending = pendingRecordConsent else { return }
        pendingRecordConsent = nil
        guard Self.isRecordConsentValid(requestedAt: pending.requestedAt, now: Date()),
              Self.canStartRecording(from: phase) else { return }
        startRecording(meetingId: pending.meetingId)
    }

    func dismissPendingRecord() {
        pendingRecordConsent = nil
    }

    /// Registers the web-record consent notification category. (Local meeting detection now surfaces
    /// through the floating prompt and the in-menu banner, not a notification.)
    private static func registerNotificationCategories() {
        let confirm = UNNotificationAction(
            identifier: confirmWebRecordActionId, title: "Start recording", options: [.foreground])
        let dismiss = UNNotificationAction(
            identifier: dismissWebRecordActionId, title: "Ignore", options: [])
        let webRecord = UNNotificationCategory(
            identifier: webRecordCategoryId, actions: [confirm, dismiss],
            intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([webRecord])
    }

    private static func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func stopRecording() { stopRecording(reason: .manual) }

    /// Stop and finalize the recording. `reason` decides whether the recap opens: a manual or
    /// locally-detected end lands the user on the fresh notes; a web-end stop suppresses the recap
    /// (the user is already on the web app).
    private func stopRecording(reason: StopReason) {
        // Re-entrancy guard: a second Stop press while already finalizing must not call
        // captureSession.stop() again (it would throw notRunning and flip the UI to error).
        guard case .recording = phase else { return }
        apply(.recordStopped)
        let meetingId = recordingMeetingId
        let seriesId = recordingSeriesId
        let instance = recordingInstance
        Task {
            do {
                _ = try await captureSession.stop()
                recordingMeetingId = nil
                recordingSeriesId = nil
                recordingInstance = nil
                apply(.finalized)
                if let meetingId, let instance, Self.opensRecap(for: reason) {
                    await openRecap(meetingId: meetingId, seriesId: seriesId, instance: instance)
                }
            } catch {
                // The durable directory survives a timed-out finalize, so Retry finishes the upload
                // rather than starting a new recording.
                lastFailedStart = meetingId.map { .finalize(meetingId: $0.uuidString) } ?? .series
                apply(.failed(Self.finalizeFailureMessage(for: error, host: instance?.host)))
            }
        }
    }

    /// Awaited stop+finalize for app termination. Runs the same sequence as `stopRecording` but the
    /// caller (applicationShouldTerminate) can await it before the process exits. Errors are
    /// tolerated: even on throw/timeout the durable capture directory remains, so next-launch
    /// recovery finalizes it. No recap is opened; the app is quitting.
    func finishForQuit() async {
        switch Self.quitFinishAction(phase: phase) {
        case .stop:
            apply(.recordStopped)
            do {
                _ = try await captureSession.stop()
                recordingMeetingId = nil
                recordingSeriesId = nil
                recordingInstance = nil
                apply(.finalized)
            } catch {
                // stop() threw, so recordingInstance was not cleared: it still names the host.
                apply(.failed(Self.finalizeFailureMessage(for: error, host: recordingInstance?.host)))
            }
        case .awaitFinalizing:
            // A stop is already in flight (the user pressed Stop, then quit). Calling stop() again
            // would throw notRunning; instead wait for the running finalize to settle, bounded so a
            // wedged upload cannot block termination forever.
            await waitWhileFinalizing()
        case .none:
            break
        }
        // Drain an in-flight startup recovery sweep too, so Finish & Quit does not abandon a prior
        // recording's rescue. No-op when nothing is recovering (the task is already nil).
        await recoveryTask?.value
    }

    private func waitWhileFinalizing() async {
        let deadline = Date().addingTimeInterval(CaptureSession.finalizeTimeout + 5)
        while case .finalizing = phase, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Startup recovery

    /// After sign-in, sweep any capture directories orphaned by a prior quit/crash/fatal and
    /// finalize each. Single-flight and best-effort: a failure leaves the directory for a later
    /// launch. The live recording's directory (if any) is never swept.
    private func runRecovery() {
        guard recoveryTask == nil, let client = authManager.client(), let instance = authManager.instance else { return }
        let activeId = recordingMeetingId?.uuidString
        recoveryActive = true
        recoveryTask = Task { [weak self] in
            let userId = try? await client.supabase.auth.session.user.id.uuidString.lowercased()
            let result = await Self.recoverAll(
                client: client, instance: instance, connectedUserId: userId, excluding: activeId)
            // Recovery is otherwise silent; tell the user each rescued meeting is being finished, and
            // make tapping the notification open its recap.
            for manifest in result.recovered {
                await self?.postRecoveryNotification(manifest: manifest, client: client)
            }
            // A recovered recording whose account lacks the AI entitlement keeps its audio but cannot
            // be transcribed; tell the user once (per directory) rather than swallowing it silently.
            if !result.transcriptionUnavailable.isEmpty {
                Self.postNotification(
                    title: "Transcription unavailable",
                    body: "Transcription is not enabled for this account on \(instance.host ?? "the server"). The recording is saved.")
            }
            // A recording that has failed to finalize past the attempt ceiling is treated as
            // deterministically dead: tell the user once, keep the audio, stop retrying it.
            if !result.exhausted.isEmpty {
                Self.postNotification(
                    title: "Recording could not be finished",
                    body: "A saved recording could not be finished after several attempts. The audio is kept in Application Support.")
            }
            self?.recoveryActive = false
            self?.recoveryTask = nil
        }
    }

    /// How the startup recovery sweep should treat a per-directory finalize result. A
    /// featureUnavailable is terminal-but-not-lost (keep the audio, tell the user); any other error is
    /// retried on the next launch. Pure so the branch matrix is tested without a live client.
    enum RecoveryOutcome: Equatable {
        case recovered
        case transcriptionUnavailable
        case retryLater
    }

    nonisolated static func recoveryOutcome(for error: Error?) -> RecoveryOutcome {
        guard let error else { return .recovered }
        if case MinutiaClientError.featureUnavailable = error { return .transcriptionUnavailable }
        return .retryLater
    }

    /// After this many consecutive failed finalizes a capture is treated as deterministically dead:
    /// the sweep stops attempting it (the audio is kept) so a launch loop never retries it forever.
    static let maxRecoveryAttempts = 5

    /// The sweep's decision for one orphaned directory, given how many times its recovery has already
    /// failed (the manifest's persisted count before this launch). Pure so the bound is tested without
    /// a live client.
    struct RecoverySweep: Equatable {
        /// Skip the directory entirely: the attempt ceiling is reached, so leave it alone (audio kept,
        /// no work, no repeat notification).
        let skip: Bool
        /// The count to persist if this launch's recovery also fails (prior + 1, held at the ceiling).
        let nextAttempts: Int
        /// Post the one-time "could not be finished" notification: true only on the attempt that
        /// reaches the ceiling, so it fires exactly once across all launches.
        let notifyOnExhaustion: Bool
    }

    nonisolated static func recoverySweep(priorAttempts: Int) -> RecoverySweep {
        if priorAttempts >= maxRecoveryAttempts {
            return RecoverySweep(skip: true, nextAttempts: priorAttempts, notifyOnExhaustion: false)
        }
        let next = priorAttempts + 1
        return RecoverySweep(skip: false, nextAttempts: next, notifyOnExhaustion: next >= maxRecoveryAttempts)
    }

    /// Sweeps orphaned capture directories, finalizing each recoverable one, and returns the
    /// manifests it successfully recovered (and deleted) so the caller can notify. Nonisolated and
    /// static so it stays testable and off the main actor.
    nonisolated static func recoverAll(
        client: MinutiaClient, instance: URL, connectedUserId: String?, excluding activeMeetingId: String?
    ) async -> (recovered: [CaptureManifest], transcriptionUnavailable: [CaptureManifest], exhausted: [CaptureManifest]) {
        var recovered: [CaptureManifest] = []
        var transcriptionUnavailable: [CaptureManifest] = []
        var exhausted: [CaptureManifest] = []
        guard let root = try? CaptureStore.capturesRoot() else { return (recovered, transcriptionUnavailable, exhausted) }
        for dir in CaptureRecovery.recoverableDirectories(in: root, excluding: activeMeetingId) {
            guard let manifest = CaptureRecovery.loadManifest(from: dir) else {
                logger.error("Recovery: unreadable manifest at \(dir.lastPathComponent, privacy: .public)")
                continue
            }
            // Skip dirs captured against a different instance or a different user: the current client
            // cannot finalize a meeting that does not exist for this session, and retrying orphans it
            // forever.
            guard CaptureRecovery.shouldRecover(
                manifest: manifest, connectedInstance: instance, connectedUserId: connectedUserId) else { continue }
            // A capture that has failed too many times is deterministically dead: leave it (audio kept)
            // rather than retrying it on every launch. The exhaustion notification already fired once.
            let sweep = recoverySweep(priorAttempts: manifest.recoveryAttempts)
            if sweep.skip { continue }
            var caught: Error?
            do {
                try await CaptureRecovery.recover(directory: dir, manifest: manifest, client: client)
            } catch {
                caught = error
            }
            switch recoveryOutcome(for: caught) {
            case .recovered:
                try? FileManager.default.removeItem(at: dir)
                recovered.append(manifest)
            case .transcriptionUnavailable:
                // Keep the directory: the audio is safe (uploaded + finalized) and the entitlement may
                // be granted later. Never delete on featureUnavailable. Logged every sweep, but the
                // user-facing notification fires once per directory (persisted `notified` flag).
                logger.error("Recovery: transcription not enabled for meeting \(manifest.meetingId, privacy: .public)")
                if !manifest.notified {
                    var updated = manifest
                    updated.notified = true
                    CaptureRecovery.saveManifest(updated, to: dir)
                    transcriptionUnavailable.append(manifest)
                }
            case .retryLater:
                // Persist the incremented attempt count so the bound survives relaunches. Keep the
                // audio; when the count reaches the ceiling, notify the user exactly once.
                var updated = manifest
                updated.recoveryAttempts = sweep.nextAttempts
                CaptureRecovery.saveManifest(updated, to: dir)
                logger.error("Recovery deferred for meeting \(manifest.meetingId, privacy: .public) attempt \(sweep.nextAttempts, privacy: .public): \(String(describing: caught), privacy: .public)")
                if sweep.notifyOnExhaustion { exhausted.append(manifest) }
            }
        }
        return (recovered, transcriptionUnavailable, exhausted)
    }

    /// Posts the "Recovered your recording" notification, carrying the recap URL in userInfo so the
    /// default tap action opens it. Resolves the series id (nil in the manifest for web-triggered
    /// records) before building the URL from the manifest's own instance.
    private func postRecoveryNotification(manifest: CaptureManifest, client: MinutiaClient) async {
        var seriesId = manifest.seriesId.flatMap { UUID(uuidString: $0) }
        if seriesId == nil {
            seriesId = try? await client.meetingSeriesId(meetingId: manifest.meetingId)
        }
        let content = UNMutableNotificationContent()
        content.title = "Recovered your recording"
        content.body = "A meeting that didn't finish uploading has been recovered. The recap is being prepared."
        if let seriesId, let meetingId = UUID(uuidString: manifest.meetingId) {
            let url = MinutiaClient.recapURL(
                instance: manifest.instanceURL, seriesId: seriesId, meetingId: meetingId)
            content.userInfo = [Self.recapURLUserInfoKey: url.absoluteString]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func dismissDetection() {
        apply(.dismissedDetection)
    }

    /// Error-phase actions: Retry re-runs the failed start path (series or the web meeting id),
    /// Dismiss returns to idle.
    func retry() {
        switch Self.retryTarget(lastFailedStart: lastFailedStart) {
        case .meeting(let id): startRecording(meetingId: id)
        case .series: startRecording()
        case .finalize(let id): refinalize(meetingId: id)
        }
    }

    /// Retry a failed finalize by re-running the durable-directory recovery for that meeting, exactly
    /// as startup recovery does, instead of starting a fresh recording. On success the recap opens;
    /// on failure the app parks back in `.error` with the finalize target still remembered.
    private func refinalize(meetingId: String) {
        guard case .error = phase, let client = authManager.client() else { return }
        apply(.refinalizeStarted)
        Task {
            do {
                let dir = try CaptureStore.capturesRoot()
                    .appendingPathComponent(meetingId.lowercased(), isDirectory: true)
                guard let manifest = CaptureRecovery.loadManifest(from: dir) else {
                    throw CaptureSession.CaptureError.notRunning
                }
                try await CaptureRecovery.recover(directory: dir, manifest: manifest, client: client)
                try? FileManager.default.removeItem(at: dir)
                apply(.finalized)
                if let meetingUUID = UUID(uuidString: manifest.meetingId) {
                    await openRecap(
                        meetingId: meetingUUID,
                        seriesId: manifest.seriesId.flatMap { UUID(uuidString: $0) },
                        instance: manifest.instanceURL)
                }
            } catch {
                // Re-arm the finalize target: apply(.refinalizeStarted) moved through .finalizing,
                // which retires lastFailedStart, so set it again before parking back in .error.
                lastFailedStart = .finalize(meetingId: meetingId)
                apply(.failed(Self.finalizeFailureMessage(for: error, host: authManager.instance?.host)))
            }
        }
    }

    func dismissError() {
        apply(.dismissedDetection)
    }

    /// Land the flowing recap in front of the user the moment finalize completes. Resolves the series
    /// id when unknown (a web-triggered record carries none) via the meetings table; if it still
    /// cannot be resolved, falls back to a notification rather than doing nothing. The URL is built
    /// from the instance capture started against, not the currently-connected one.
    private func openRecap(meetingId: UUID, seriesId: UUID?, instance: URL) async {
        var resolvedSeries = seriesId
        if resolvedSeries == nil, let client = authManager.client() {
            resolvedSeries = try? await client.meetingSeriesId(meetingId: meetingId.uuidString)
        }
        guard let resolvedSeries else {
            Self.postNotification(
                title: "Recording saved",
                body: "Open Minutia on the web to see the recap.")
            return
        }
        NSWorkspace.shared.open(
            MinutiaClient.recapURL(instance: instance, seriesId: resolvedSeries, meetingId: meetingId))
    }

    // MARK: - URL callback

    /// Deliver a `minutia://` deep link from the AppKit URL handler. Ensures the Supabase
    /// client is built first: a cold start launches the app via the URL before
    /// `restoreSession()` runs, and `verifyOTP` needs the client. Idempotent with
    /// `restoreSession`'s single-flight connect; AuthManager dedupes the single-use token
    /// hash across repeat deliveries. Routes both the browser magic-link (token_hash) and
    /// the Google PKCE (code) callbacks.
    func handleURL(_ url: URL) async {
        // Rehydrate first for both paths: a cold start launches the app via the URL before
        // restoreSession() runs, so without this a record command sees no session/client (and
        // verifyOTP has no client). Single-flight and idempotent, so always running it is safe.
        try? await authManager.ensureConnected()
        if case .record(let meetingId) = DeepLink.parse(url) {
            handleRecordCommand(meetingId: meetingId)
            return
        }
        // Surface the cold-launch result: a URL can launch the app with no window in front, so a
        // silent sign-in or failure would leave the user with no signal it happened.
        switch await authManager.handleCallback(url) {
        case .signedIn:
            Self.postNotification(title: "Signed in to Minutia", body: "You're ready to record meetings.")
        case .failed(let message):
            Self.postNotification(title: "Sign-in failed", body: message)
        case .rejected, .ignored:
            break
        }
    }
}

extension AppController: UNUserNotificationCenterDelegate {
    /// Show detection/consent notifications even while the app is foreground (e.g. the Settings
    /// window makes it `.regular`); otherwise macOS suppresses the banner and the prompt is lost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionId = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            switch actionId {
            case Self.confirmWebRecordActionId:
                self.confirmPendingRecord()
            case Self.dismissWebRecordActionId:
                self.dismissPendingRecord()
            case UNNotificationDefaultActionIdentifier:
                // Tapping the recovered-recording notification opens its recap. The URL round-trips
                // through userInfo, so re-check the scheme: a corrupt manifest must never make a
                // notification tap open an arbitrary non-web scheme.
                if let urlString = userInfo[Self.recapURLUserInfoKey] as? String,
                   let url = URL(string: urlString),
                   url.scheme == "https" || url.scheme == "http" {
                    NSWorkspace.shared.open(url)
                }
            default:
                break
            }
            completionHandler()
        }
    }
}
