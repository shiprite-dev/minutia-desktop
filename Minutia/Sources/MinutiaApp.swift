import AppKit
import Combine
import SwiftUI
import UserNotifications

@main
struct MinutiaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AppController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
                .task { await controller.restoreSession() }
        } label: {
            MenuBarIcon(phase: controller.phase, softHint: controller.softHint)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(controller: controller)
        }
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
            .onAppear { syncPulse() }
            .onChange(of: phase) { _, _ in syncPulse() }
            .onDisappear { stopPulse() }
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
    /// Soft detection: mic active with no corroborating app/calendar signal. Surfaced quietly
    /// (menu bar glyph + one secondary row), never a notification. See `shouldShowSoftHint`.
    @Published private(set) var softHint: Bool = false
    @Published var selectedSeriesId: UUID? {
        didSet {
            UserDefaults.standard.set(selectedSeriesId?.uuidString, forKey: Self.lastSeriesKey)
        }
    }

    let authManager = AuthManager()
    let captureSession = CaptureSession()
    let detector = MeetingDetector()

    static let lastSeriesKey = "app.minutia.lastSeries"

    /// Record can begin only from a resting or recoverable phase. Guards a stale detection
    /// notification clicked mid-recording from starting a second server meeting and
    /// overwriting the recording meeting id (which would open the wrong recap).
    nonisolated static func canStartRecording(from phase: AppPhase) -> Bool {
        switch phase {
        case .idle, .detected, .error: return true
        default: return false
        }
    }

    /// Signing out mid-capture must tear the pipeline down first; mic and system audio would
    /// otherwise keep recording invisibly with uploads failing auth.
    nonisolated static func shouldStopCaptureOnSignOut(phase: AppPhase) -> Bool {
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

    private override init() {
        super.init()
        MeetingDetector.registerNotificationCategory()
        UNUserNotificationCenter.current().delegate = self

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
        refreshSoftHint()
        syncDetector()
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
        } else {
            if Self.shouldStopCaptureOnSignOut(phase: phase) {
                Task { _ = try? await captureSession.stop() }
            }
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
                try captureSession.start(meetingId: meeting.id.uuidString, client: client)
                recordingMeetingId = meeting.id
                recordingSeriesId = seriesId
                apply(.recordStarted)
            } catch {
                apply(.failed("Could not start recording: \(error.localizedDescription)"))
            }
        }
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

    func dismissDetection() {
        apply(.dismissedDetection)
    }

    /// Error-phase actions: Retry re-runs the start path, Dismiss returns to idle.
    func retry() {
        startRecording()
    }

    func dismissError() {
        apply(.dismissedDetection)
    }

    /// Land the flowing recap in front of the user the moment finalize completes.
    private func openRecap() {
        guard let instance = authManager.instance,
              let seriesId = recordingSeriesId, let meetingId = recordingMeetingId else { return }
        recordingMeetingId = nil
        recordingSeriesId = nil
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
        try? await authManager.ensureConnected()
        await authManager.handleCallback(url)
    }
}

extension AppController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionId = response.actionIdentifier
        Task { @MainActor in
            if actionId == MeetingDetector.recordActionId {
                self.startRecording()
            }
            completionHandler()
        }
    }
}
