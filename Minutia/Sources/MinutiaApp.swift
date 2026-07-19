import AppKit
import AVFoundation
import Combine
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
            MenuContent(controller: controller)
                .task { await controller.restoreSession() }
        } label: {
            MenuBarIcon(phase: controller.phase, softHint: controller.softHint)
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
@MainActor
final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheckForUpdates = false

    init() {
        // Start the updater only for the real app with a real Sparkle key. Under XCTest the app is
        // the test host, so its scene (and this holder) is constructed inside the runner; a started
        // updater with the placeholder SUPublicEDKey throws and pops a modal error alert that hangs
        // the headless runner. Skipping the start keeps the suite green and avoids that alert on
        // local runs until the public key is swapped in for the first release.
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let hasRealKey = key?.isEmpty == false && key != "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        controller = SPUStandardUpdaterController(
            startingUpdater: hasRealKey && !underTest, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
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

    /// Guard against quitting mid-recording. When capturing, prompt to finish the upload first;
    /// "Finish & Quit" defers termination until stop+finalize completes. Even if the user quits
    /// anyway (or finalize fails), the durable capture directory means next-launch recovery finishes
    /// the job, so no path loses the recording.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppController.shouldConfirmQuit(phase: AppController.shared.phase) else {
            return .terminateNow
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Recording in progress"
        alert.informativeText = "Minutia is still finishing the upload for this recording. Finish and quit, or keep recording?"
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

/// Status item glyph per phase: waveform idle, exclamation on error, and a recording glyph
/// that blinks between filled and hollow on a 1s timer while recording. Status items ignore
/// `withAnimation`, so a real timer drives the affordance; it is invalidated the moment the
/// icon leaves the recording phase, and stays a static filled glyph under Reduce Motion.
/// Soft detection swaps the idle waveform for a static mic-badged waveform (no animation,
/// no notification), reverting to the plain waveform the instant the hint clears.
struct MenuBarIcon: View {
    let phase: AppPhase
    let softHint: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hollow = false
    @State private var timer: Timer?

    var body: some View {
        glyph
            .accessibilityLabel(Self.accessibilityLabel(phase: phase))
            .onAppear { syncPulse() }
            .onChange(of: phase) { _, _ in syncPulse() }
            .onDisappear { stopPulse() }
    }

    /// VoiceOver text for the status item, since the glyph alone conveys the phase.
    static func accessibilityLabel(phase: AppPhase) -> String {
        switch phase {
        case .recording: return "Minutia, recording"
        case .finalizing: return "Minutia, finishing recording"
        case .detected: return "Minutia, meeting detected"
        case .error: return "Minutia, error"
        default: return "Minutia, idle"
        }
    }

    @ViewBuilder private var glyph: some View {
        switch phase {
        case .recording:
            Image(systemName: hollow && !reduceMotion ? "record.circle" : "record.circle.fill")
        case .finalizing:
            Image(systemName: "record.circle")
        case .error:
            Image(systemName: "waveform.badge.exclamationmark")
        default:
            Image(systemName: softHint ? "waveform.badge.mic" : "waveform")
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
    @Published var selectedSeriesId: UUID? {
        didSet {
            UserDefaults.standard.set(selectedSeriesId?.uuidString, forKey: Self.lastSeriesKey)
        }
    }

    let authManager = AuthManager()
    let captureSession = CaptureSession()
    let detector = MeetingDetector()

    static let lastSeriesKey = "app.minutia.lastSeries"

    static let webRecordCategoryId = "app.minutia.webRecord"
    static let confirmWebRecordActionId = "app.minutia.webRecord.confirm"
    static let dismissWebRecordActionId = "app.minutia.webRecord.dismiss"

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
    /// a web-triggered record needs its meeting id, not the selected series.
    enum FailedStart: Equatable {
        case series
        case meeting(String)
    }

    /// Route a Retry from the error phase. A remembered `.meeting` failure retries that meeting id;
    /// a `.series` failure or nothing remembered falls back to the series start path.
    nonisolated static func retryTarget(lastFailedStart: FailedStart?) -> FailedStart {
        lastFailedStart ?? .series
    }

    /// Signing out mid-capture must tear the pipeline down first; mic and system audio would
    /// otherwise keep recording invisibly with uploads failing auth.
    nonisolated static func shouldStopCaptureOnSignOut(phase: AppPhase) -> Bool {
        switch phase {
        case .recording, .finalizing: return true
        default: return false
        }
    }

    /// Quitting mid-capture must prompt: a recording is in flight (or finalizing its upload) and
    /// leaving without finishing would lose the un-uploaded tail until the next-launch recovery.
    nonisolated static func shouldConfirmQuit(phase: AppPhase) -> Bool {
        switch phase {
        case .recording, .finalizing: return true
        default: return false
        }
    }

    /// The soft hint shows only when mic-only detection meets a resting idle app: quiet by
    /// design (no notification). Any capture, finalize, error, or the .high banner suppresses
    /// it so it never competes for attention or lingers over a live recording.
    nonisolated static func shouldShowSoftHint(confidence: DetectionConfidence, phase: AppPhase) -> Bool {
        guard case .soft = confidence, case .idle = phase else { return false }
        return true
    }

    private var cancellables: Set<AnyCancellable> = []
    private var lastConfidence: DetectionConfidence = .none
    private var recordingMeetingId: UUID?
    private var recordingSeriesId: UUID?
    private var lastFailedStart: FailedStart?
    /// Single-flight guard for the startup recovery sweep.
    private var recoveryTask: Task<Void, Never>?

    private override init() {
        super.init()
        Self.registerNotificationCategories()
        UNUserNotificationCenter.current().delegate = self

        // A mid-capture fatal (denied mic, disk-full) flips the UI to .error with a user message.
        captureSession.onFailure = { [weak self] message in self?.apply(.failed(message)) }

        authManager.$userEmail
            .removeDuplicates()
            .sink { [weak self] email in self?.handleAuthChange(signedIn: email != nil) }
            .store(in: &cancellables)

        detector.$confidence
            .removeDuplicates()
            .sink { [weak self] confidence in self?.handleDetection(confidence) }
            .store(in: &cancellables)
    }

    /// Rehydrate the Supabase client from the stored instance (or the managed cloud
    /// default on first run) so a Keychain session lands the app signed in with no
    /// Connect step. Idempotent with SignInView's on-appear auto-connect.
    func restoreSession() async {
        try? await authManager.ensureConnected()
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

    /// The detector runs only while signed in and not capturing; our own mic use during a
    /// recording would otherwise re-trigger detection and post a spurious notification.
    private func syncDetector() {
        switch phase {
        case .idle, .detected:
            guard let client = authManager.client() else { return }
            detector.start(agendaProvider: { (try? await client.agenda()) ?? [] })
        default:
            detector.stop()
        }
    }

    private func handleAuthChange(signedIn: Bool) {
        if signedIn {
            apply(.signedIn)
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            Task { await loadSeries() }
            runRecovery()
        } else {
            if Self.shouldStopCaptureOnSignOut(phase: phase) {
                Task { _ = try? await captureSession.stop() }
            }
            recordingMeetingId = nil
            recordingSeriesId = nil
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
        case .none:
            // The corroborating signal is gone (mic released): retire a stale banner.
            if case .detected = phase { apply(.dismissedDetection) }
        case .soft:
            // Quiet by design: no phase change, no notification, just the menu bar hint.
            break
        }
        refreshSoftHint()
    }

    /// Banner wording source: "Meeting detected via {Zoom/Teams/Calendar}".
    static func detectionLabel(_ app: MeetingApp?) -> String {
        switch app {
        case .zoom: return "Zoom"
        case .teams: return "Teams"
        case nil: return "Calendar"
        }
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

    // MARK: - Record / stop

    /// Single start path shared by the Record button, the detection banner, and the
    /// notification action.
    func startRecording() {
        guard Self.canStartRecording(from: phase) else { return }
        guard let seriesId = selectedSeriesId, let client = authManager.client() else { return }
        Task {
            do {
                let meeting = try await client.startOrJoinMeeting(seriesId: seriesId)
                try captureSession.start(meetingId: meeting.id.uuidString, seriesId: seriesId, client: client)
                recordingMeetingId = meeting.id
                recordingSeriesId = seriesId
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
        do {
            try captureSession.start(meetingId: meetingId, seriesId: nil, client: client)
            recordingMeetingId = UUID(uuidString: meetingId)
            recordingSeriesId = nil
            apply(.recordStarted)
        } catch {
            lastFailedStart = .meeting(meetingId)
            apply(.failed("Could not start recording: \(error.localizedDescription)"))
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

    /// Registers both notification categories (the detector's "Record this meeting?" and the
    /// web-record consent prompt) in a single synchronous `setNotificationCategories` call, so
    /// neither can clobber the other through a read-modify-write race.
    private static func registerNotificationCategories() {
        let confirm = UNNotificationAction(
            identifier: confirmWebRecordActionId, title: "Start recording", options: [.foreground])
        let dismiss = UNNotificationAction(
            identifier: dismissWebRecordActionId, title: "Ignore", options: [])
        let webRecord = UNNotificationCategory(
            identifier: webRecordCategoryId, actions: [confirm, dismiss],
            intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            MeetingDetector.notificationCategory, webRecord,
        ])
    }

    private static func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func stopRecording() {
        apply(.recordStopped)
        Task {
            do {
                _ = try await captureSession.stop()
                apply(.finalized)
                openRecap()
            } catch {
                apply(.failed("Could not finish recording: \(error.localizedDescription)"))
            }
        }
    }

    /// Awaited stop+finalize for app termination. Runs the same sequence as `stopRecording` but the
    /// caller (applicationShouldTerminate) can await it before the process exits. Errors are
    /// tolerated: even on throw/timeout the durable capture directory remains, so next-launch
    /// recovery finalizes it. No recap is opened; the app is quitting.
    func finishForQuit() async {
        apply(.recordStopped)
        do {
            _ = try await captureSession.stop()
            apply(.finalized)
        } catch {
            apply(.failed("Could not finish recording: \(error.localizedDescription)"))
        }
    }

    // MARK: - Startup recovery

    /// After sign-in, sweep any capture directories orphaned by a prior quit/crash/fatal and
    /// finalize each. Single-flight and best-effort: a failure leaves the directory for a later
    /// launch. The live recording's directory (if any) is never swept.
    private func runRecovery() {
        guard recoveryTask == nil, let client = authManager.client(), let instance = authManager.instance else { return }
        let activeId = recordingMeetingId?.uuidString
        recoveryTask = Task { [weak self] in
            await Self.recoverAll(client: client, instance: instance, excluding: activeId)
            self?.recoveryTask = nil
        }
    }

    nonisolated static func recoverAll(client: MinutiaClient, instance: URL, excluding activeMeetingId: String?) async {
        guard let root = try? CaptureStore.capturesRoot() else { return }
        for dir in CaptureRecovery.recoverableDirectories(in: root, excluding: activeMeetingId) {
            guard let manifest = CaptureRecovery.loadManifest(from: dir) else { continue }
            // Skip dirs captured against a different instance: the current client cannot finalize a
            // meeting that does not exist on the connected instance, and retrying orphans it forever.
            guard CaptureRecovery.shouldRecover(manifest: manifest, connectedInstance: instance) else { continue }
            do {
                try await CaptureRecovery.recover(directory: dir, manifest: manifest, client: client)
                try? FileManager.default.removeItem(at: dir)
            } catch {
                // Best-effort: leave the directory for the next launch to retry.
            }
        }
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
        }
    }

    func dismissError() {
        apply(.dismissedDetection)
    }

    /// Land the flowing recap in front of the user the moment finalize completes. Clears the
    /// recording ids unconditionally: a web-triggered record has no series id, so without an
    /// unconditional clear the stale meeting id would make the next record command misfire.
    private func openRecap() {
        let seriesId = recordingSeriesId
        let meetingId = recordingMeetingId
        recordingMeetingId = nil
        recordingSeriesId = nil
        guard let instance = authManager.instance, let seriesId, let meetingId else { return }
        let url = instance.appendingPathComponent(
            "series/\(seriesId.uuidString.lowercased())/meetings/\(meetingId.uuidString.lowercased())")
        NSWorkspace.shared.open(url)
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
        await authManager.handleCallback(url)
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
        Task { @MainActor in
            switch actionId {
            case MeetingDetector.recordActionId:
                self.startRecording()
            case Self.confirmWebRecordActionId:
                self.confirmPendingRecord()
            case Self.dismissWebRecordActionId:
                self.dismissPendingRecord()
            default:
                break
            }
            completionHandler()
        }
    }
}
