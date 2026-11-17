import SwiftUI

private func openMicrophoneSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
        NSWorkspace.shared.open(url)
    }
}

enum Celebration {
    static let hold: TimeInterval = 1.6

    static func shouldPlay(from old: AppPhase, to new: AppPhase, feedback: String?) -> Bool {
        old == .finalizing && new == .idle && feedback == nil
    }

    static func visible(celebrating: Bool, phase: AppPhase) -> Bool {
        celebrating && phase == .idle
    }
}

enum FinishingProgress {
    static func fraction(_ step: CaptureSession.FinishingStep?) -> Double? {
        guard case .transcribing(let completed, let total) = step, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

enum ErrorActions {
    enum Action { case retry, dismiss, openSettings }

    static func resolve(isMicError: Bool) -> (primary: Action, secondary: Action) {
        isMicError ? (.openSettings, .retry) : (.retry, .dismiss)
    }
}

/// The menu bar panel: one screen per AppPhase, plus a persistent Settings/Quit footer.
/// Purely declarative; every decision is the controller's (and the reducer's).
struct MenuContent: View {
    @ObservedObject var controller: AppController
    @ObservedObject var updater: UpdaterController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var celebrating = false
    @State private var celebrationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.pendingRecordConsent != nil {
                ConsentNotice(
                    hasClaim: controller.pendingRecordConsent?.claim != nil,
                    onAlways: { controller.answerWebStart(.always) },
                    onOnce: { controller.answerWebStart(.once) },
                    onIgnoreClaim: { controller.answerWebStart(.ignore) },
                    onStart: { controller.confirmPendingRecord() },
                    onIgnore: { controller.dismissPendingRecord() })
                    .padding(.horizontal, Space.x4)
                    .padding(.top, Space.x4)
            }

            if let feedback = controller.recordFeedback {
                FeedbackNotice(message: feedback)
                    .padding(.horizontal, Space.x4)
                    .padding(.top, Space.x4)
            }

            Group {
                switch controller.phase {
                case .signedOut:
                    SignInView(authManager: controller.authManager, showsMenuBarHint: controller.showsMenuBarHint)
                case .idle where Celebration.visible(celebrating: celebrating, phase: controller.phase):
                    DoneContent()
                case .idle:
                    IdleHost(controller: controller, detectedVia: nil)
                case .detected(let app):
                    IdleHost(controller: controller, detectedVia: app ?? "Calendar")
                case .recording:
                    RecordingView(
                        session: controller.captureSession,
                        seriesName: controller.series.first { $0.id == controller.selectedSeriesId }?.name,
                        onNotes: { controller.notepad.showAndFocus() },
                        onStop: { controller.stopRecording() })
                case .finalizing:
                    FinalizingView(session: controller.captureSession)
                case .error(let message):
                    ErrorScreen(
                        message: message,
                        isMicError: AppController.isMicPermissionError(message: message),
                        onRetry: { controller.retry() },
                        onDismiss: { controller.dismissError() },
                        onOpenSettings: openMicrophoneSettings)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)

            ModelStatusRow(store: controller.modelStore)
            HairlineRule()
            Footer(updater: updater)
        }
        .frame(width: Space.panelWidth)
        .animation(Motion.resolved(Motion.settle, reduce: reduceMotion), value: controller.phase)
        .animation(Motion.resolved(Motion.settle, reduce: reduceMotion), value: celebrating)
        .sensoryFeedback(.levelChange, trigger: controller.phase == .recording)
        .onChange(of: controller.phase) { old, new in
            celebrationTask?.cancel()
            guard Celebration.shouldPlay(from: old, to: new, feedback: controller.recordFeedback) else {
                celebrating = false
                return
            }
            celebrating = true
            celebrationTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(Celebration.hold * 1_000_000_000))
                if !Task.isCancelled { celebrating = false }
            }
        }
    }
}

struct MenuLink: Equatable {
    let title: String
    let url: URL

    /// An account with no series yet: connect a calendar (its meetings become series), or make one.
    static func emptySeries(instance: URL) -> (primary: MenuLink, secondary: MenuLink) {
        (MenuLink(title: "Connect Google Calendar", url: instance.appendingPathComponent("api/auth/google")),
         MenuLink(title: "Create a series", url: instance.appendingPathComponent("series")))
    }
}

private struct ModelStatusRow: View {
    @ObservedObject var store: ModelStore

    var body: some View {
        if let label = store.status.menuLabel, case .downloading(let received, let total) = store.status {
            ModelDownloadRow(label: label, fraction: Double(received) / Double(max(total, 1)))
        }
    }
}

struct ModelDownloadRow: View {
    let label: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text(label)
                .font(Typo.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            ProgressHairline(fraction: fraction)
        }
        .padding(.horizontal, Space.x4)
        .padding(.bottom, Space.x2)
        .frame(width: Space.panelWidth, alignment: .leading)
    }
}

struct IdleModel {
    var series: [Series]
    var selected: UUID?
    var detectedVia: String?
    var softHint: Bool
    var micBanner: Bool
    var recovering: Bool
    var instance: URL
}

private struct IdleHost: View {
    @ObservedObject var controller: AppController
    let detectedVia: String?

    var body: some View {
        IdleScreen(
            model: IdleModel(
                series: controller.series,
                selected: controller.selectedSeriesId,
                detectedVia: detectedVia,
                softHint: controller.softHint,
                micBanner: controller.micBannerVisible,
                recovering: controller.recoveryActive,
                instance: controller.authManager.instance ?? InstanceConfig.resolvedInstance),
            onSelect: controller.pickSeries,
            onRecord: { controller.startRecording() },
            onDismissDetection: { controller.dismissDetection() },
            onOpenURL: { NSWorkspace.shared.open($0) },
            onOpenMicSettings: openMicrophoneSettings)
            .onAppear {
                controller.refreshPermissionState()
                controller.reloadSeries()
            }
    }
}

/// Idle and detected phases share one layout; detection adds the highlighted notice.
struct IdleScreen: View {
    let model: IdleModel
    var onSelect: (UUID?) -> Void = { _ in }
    var onRecord: () -> Void = {}
    var onDismissDetection: () -> Void = {}
    var onOpenURL: (URL) -> Void = { _ in }
    var onOpenMicSettings: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedName: String? { model.series.first { $0.id == model.selected }?.name }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            if model.micBanner {
                MicPermissionNotice(onOpenSettings: onOpenMicSettings)
            }

            if let via = model.detectedVia {
                DetectionNotice(via: via, onDismiss: onDismissDetection)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            } else if model.softHint {
                QuietRow(systemImage: "mic", text: "In a meeting? Record picks it up from here.")
            }

            if model.recovering {
                HStack(spacing: Space.x2) {
                    MarkView(side: 14, breathing: true)
                    Text(AppController.recoveryRowLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Typo.body)
                .foregroundStyle(Brand.ink3)
            }

            if model.series.isEmpty {
                emptyState
            } else {
                Eyebrow(text: "Series")
                Picker("Series", selection: Binding(get: { model.selected }, set: onSelect)) {
                    ForEach(model.series) { series in
                        Text(series.name).lineLimit(1).truncationMode(.tail).tag(Optional(series.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
                .help(selectedName ?? "")
                .accessibilityLabel("Series")

                Button(action: onRecord) {
                    Label("Record", systemImage: "record.circle")
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(model.selected == nil)
                .accessibilityLabel(selectedName.map { "Record \($0)" } ?? "Record")
            }
        }
        .padding(Space.x4)
        .frame(width: Space.panelWidth, alignment: .leading)
        .animation(Motion.resolved(Motion.settle, reduce: reduceMotion), value: model.detectedVia)
    }

    private var emptyState: some View {
        let links = MenuLink.emptySeries(instance: model.instance)
        return VStack(alignment: .leading, spacing: Space.x3) {
            Text("No series yet").font(Typo.title)
            Text("Connect a calendar or create a series in Minutia on the web, then record here.")
                .font(Typo.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { onOpenURL(links.primary.url) } label: {
                Label(links.primary.title, systemImage: "calendar")
            }
            .buttonStyle(PrimaryButtonStyle())
            Button(links.secondary.title) { onOpenURL(links.secondary.url) }
                .buttonStyle(QuietButtonStyle())
        }
    }
}

struct QuietRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: Space.x2) {
            Image(systemName: systemImage)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(Typo.body)
        .foregroundStyle(Brand.ink3)
    }
}

private struct MicPermissionNotice: View {
    let onOpenSettings: () -> Void

    var body: some View {
        NoticeRow(kind: .warn) {
            Image(systemName: "mic.slash").foregroundStyle(Brand.warn)
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Microphone access needed to record").font(Typo.bodyStrong)
                Text("System audio is requested the first time you record.")
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                Button("Open System Settings", action: onOpenSettings)
                    .buttonStyle(SecondaryButtonStyle())
                    .fixedSize()
            }
        }
    }
}

struct FeedbackNotice: View {
    let message: String

    var body: some View {
        NoticeRow(kind: .neutral) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
        } content: {
            Text(message).foregroundStyle(.secondary)
        }
    }
}

/// Consent gate for a browser-triggered `minutia://record`: capture starts only when the user
/// answers here (or in the notification), so a web page can never start a covert recording.
struct ConsentNotice: View {
    let hasClaim: Bool
    var onAlways: () -> Void = {}
    var onOnce: () -> Void = {}
    var onIgnoreClaim: () -> Void = {}
    var onStart: () -> Void = {}
    var onIgnore: () -> Void = {}

    var body: some View {
        NoticeRow(kind: .accent) {
            Image(systemName: "record.circle").foregroundStyle(Brand.vermilion)
        } content: {
            VStack(alignment: .leading, spacing: Space.x2) {
                Text("Record this meeting from your browser?").font(Typo.bodyStrong)
                if hasClaim {
                    Button("Always start automatically", action: onAlways)
                        .buttonStyle(PrimaryButtonStyle())
                    HStack(spacing: Space.x2) {
                        Button("Just this once", action: onOnce).buttonStyle(SecondaryButtonStyle())
                        Button("Ignore", action: onIgnoreClaim).buttonStyle(SecondaryButtonStyle())
                    }
                } else {
                    HStack(spacing: Space.x2) {
                        Button("Start recording", action: onStart)
                            .buttonStyle(PrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction)
                        Button("Ignore", action: onIgnore).buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
        }
    }
}

private struct DetectionNotice: View {
    let via: String
    let onDismiss: () -> Void

    var body: some View {
        NoticeRow(kind: .accent) {
            MarkView(side: 20, rises: true)
        } content: {
            HStack(alignment: .top, spacing: Space.x2) {
                Text(AppController.detectionBannerText(via: via))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Dismiss detection")
            }
        }
    }
}

private struct FinalizingView: View {
    @ObservedObject var session: CaptureSession
    @State private var preparingSince: Date?

    var body: some View {
        FinishingContent(
            label: CaptureSession.finishingLabel(step: session.finishingStep, audioMayLeaveMac: session.audioMayLeaveMac),
            progress: FinishingProgress.fraction(session.finishingStep),
            preparingSince: preparingSince)
            .onChange(of: session.finishingStep == .preparingModel, initial: true) { _, preparing in
                preparingSince = preparing ? Date() : nil
            }
    }
}

struct FinishingContent: View {
    let label: String
    let progress: Double?
    let preparingSince: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack(alignment: .top, spacing: Space.x3) {
                MarkView(side: 36, breathing: true)
                VStack(alignment: .leading, spacing: Space.x1) {
                    Text(label)
                        .font(Typo.title)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.numericText())
                    if let preparingSince {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("\(Int(context.date.timeIntervalSince(preparingSince)))s")
                                .font(Typo.caption.monospacedDigit())
                                .foregroundStyle(Brand.ink3)
                                .contentTransition(.numericText())
                        }
                    }
                    Text("You can close this. Minutia finishes in the background.")
                        .font(Typo.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let progress {
                ProgressHairline(fraction: progress)
            }
        }
        .padding(Space.x4)
        .frame(width: Space.panelWidth, alignment: .leading)
    }
}

struct DoneContent: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat
    @State private var popped = false

    init() {
        _progress = State(initialValue: CheckReveal.initialProgress(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
    }

    var body: some View {
        HStack(spacing: Space.x3) {
            MarkView(side: 36, checkProgress: progress, popped: popped)
            Text("Recap is ready").font(Typo.title)
        }
        .padding(Space.x4)
        .frame(width: Space.panelWidth, alignment: .leading)
        .sensoryFeedback(.alignment, trigger: progress == 1)
        .task {
            AccessibilityNotification.Announcement("Recap is ready").post()
            guard !reduceMotion else { progress = 1; return }
            try? await Task.sleep(nanoseconds: 180_000_000)
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.42)) { progress = 1 }
            try? await Task.sleep(nanoseconds: 420_000_000)
            popped = true
            try? await Task.sleep(nanoseconds: 120_000_000)
            popped = false
        }
        .accessibilityElement(children: .combine)
    }
}

struct ErrorScreen: View {
    let message: String
    let isMicError: Bool
    var onRetry: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    var body: some View {
        let actions = ErrorActions.resolve(isMicError: isMicError)
        VStack(alignment: .leading, spacing: Space.x3) {
            NoticeRow(kind: .warn) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.warn)
            } content: {
                Text(message)
            }
            button(actions.primary, primary: true)
            button(actions.secondary, primary: false)
            if isMicError {
                button(.dismiss, primary: false)
            }
        }
        .padding(Space.x4)
        .frame(width: Space.panelWidth, alignment: .leading)
    }

    @ViewBuilder
    private func button(_ action: ErrorActions.Action, primary: Bool) -> some View {
        switch action {
        case .retry:
            if primary {
                Button("Retry", action: onRetry).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            } else {
                Button("Retry", action: onRetry).buttonStyle(SecondaryButtonStyle())
            }
        case .openSettings:
            Button("Open System Settings", action: onOpenSettings).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
        case .dismiss:
            Button("Dismiss", action: onDismiss).buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct Footer: View {
    @ObservedObject var updater: UpdaterController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        FooterBar(
            updateAvailable: updater.updateAvailable,
            onSettings: {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            },
            onUpdate: { updater.checkForUpdates() },
            onQuit: { NSApp.terminate(nil) })
    }
}

struct FooterBar: View {
    let updateAvailable: Bool
    var onSettings: () -> Void = {}
    var onUpdate: () -> Void = {}
    var onQuit: () -> Void = {}
    @State private var chipShown = false

    var body: some View {
        HStack {
            Button(action: onSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(QuietButtonStyle())
            .accessibilityLabel("Settings")
            Spacer()
            if updateAvailable {
                Button(action: onUpdate) {
                    HStack(spacing: Space.x2 - 2) {
                        Circle().fill(Brand.vermilion).frame(width: 6, height: 6)
                        Text("Update available")
                    }
                }
                .buttonStyle(QuietButtonStyle())
                .opacity(chipShown ? 1 : 0)
                .onAppear { withAnimation(Motion.fade) { chipShown = true } }
                Spacer()
            }
            Button("Quit", action: onQuit)
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut("q")
        }
        .padding(.horizontal, Space.x4)
        .frame(width: Space.panelWidth, height: 28)
    }
}
