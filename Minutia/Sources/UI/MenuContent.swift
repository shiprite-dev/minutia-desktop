import SwiftUI

private func openMicrophoneSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
        NSWorkspace.shared.open(url)
    }
}

enum PanelHaptic {
    static func feedback(from old: AppPhase, to new: AppPhase) -> SensoryFeedback? {
        switch (old, new) {
        case (.idle, .recording), (.detected, .recording), (.error, .recording), (.recording, .finalizing): .levelChange
        default: nil
        }
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
    @Environment(\.motionReduced) private var reduceMotion

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
            }

            if let feedback = controller.recordFeedback {
                FeedbackNotice(message: feedback)
            }

            Group {
                switch controller.phase {
                case .signedOut:
                    SignInView(authManager: controller.authManager, showsMenuBarHint: controller.showsMenuBarHint)
                case .idle where controller.review.model != nil:
                    ReviewView(review: controller.review, onOpenRecap: controller.openRecap)
                case .idle:
                    IdleHost(controller: controller, detectedVia: nil)
                case .detected(let app):
                    IdleHost(controller: controller, detectedVia: app ?? "Calendar")
                case .recording:
                    RecordingView(
                        session: controller.captureSession,
                        seriesName: controller.recordingSeriesName,
                        onNotes: { controller.notepad.showAndFocus() },
                        onStop: { controller.stopRecording() })
                    if let waiting = controller.review.queueRows.first {
                        ReviewQueueLine(row: waiting).padding(.horizontal, Space.x2).padding(.bottom, Space.x2)
                    }
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
            .padding(.top, controller.pendingRecordConsent != nil || controller.recordFeedback != nil ? -Space.x1 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)

            ModelStatusRow(store: controller.modelStore)
            HairlineRule()
            Footer(updater: updater)
        }
        .frame(width: Space.panelWidth)
        .environment(\.panelVisible, controller.panelOpen)
        .environment(\.consentPending, controller.pendingRecordConsent != nil)
        .animation(Motion.resolved(Motion.settle, reduce: reduceMotion), value: controller.phase)
        .animation(Motion.resolved(Motion.settle, reduce: reduceMotion), value: controller.review.model?.meetingId)
        .sensoryFeedback(trigger: controller.phase) { old, new in PanelHaptic.feedback(from: old, to: new) }
        .onAppear { controller.panelOpened() }
        .onDisappear { controller.panelClosed() }
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
                .foregroundStyle(Brand.ink2)
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
    var queue: [ReviewQueueRow] = []
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
                instance: controller.authManager.instance ?? InstanceConfig.resolvedInstance,
                queue: controller.review.queueRows),
            onSelect: controller.pickSeries,
            onRecord: { controller.startRecording() },
            onDismissDetection: { controller.dismissDetection() },
            onOpenURL: { NSWorkspace.shared.open($0) },
            onOpenMicSettings: openMicrophoneSettings,
            onOpenReview: { controller.review.start(meetingId: $0) })
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
    var onOpenReview: (UUID) -> Void = { _ in }
    @Environment(\.motionReduced) private var reduceMotion
    @Environment(\.consentPending) private var consentPending

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
                    MarkView(barHeight: 12, breathing: true)
                    Text(AppController.recoveryRowLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Typo.body)
                .foregroundStyle(Brand.ink3)
            }

            if !model.queue.isEmpty {
                Eyebrow(text: "To review")
                VStack(spacing: 0) {
                    ForEach(model.queue) { row in ReviewQueueLine(row: row) { onOpenReview(row.id) } }
                }
                .padding(.horizontal, -Space.x2)
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

                RecordButton(consentPending: consentPending, action: onRecord)
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
                .foregroundStyle(Brand.ink2)
                .fixedSize(horizontal: false, vertical: true)
            ConnectButton(title: links.primary.title, consentPending: consentPending) { onOpenURL(links.primary.url) }
            Button(links.secondary.title) { onOpenURL(links.secondary.url) }
                .buttonStyle(QuietButtonStyle())
        }
    }
}

private struct ConnectButton: View {
    let title: String
    let consentPending: Bool
    let action: () -> Void

    var body: some View {
        if consentPending {
            Button(action: action) { Label(title, systemImage: "calendar") }.buttonStyle(SecondaryButtonStyle())
        } else {
            Button(action: action) { Label(title, systemImage: "calendar") }.buttonStyle(PrimaryButtonStyle())
        }
    }
}

private struct RecordButton: View {
    let consentPending: Bool
    let action: () -> Void

    var body: some View {
        if consentPending {
            Button(action: action) { Label("Record", systemImage: "record.circle") }
                .buttonStyle(SecondaryButtonStyle())
        } else {
            Button(action: action) { Label("Record", systemImage: "record.circle") }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
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
                    .foregroundStyle(Brand.ink2)
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
            Image(systemName: "exclamationmark.circle").foregroundStyle(Brand.ink2)
        } content: {
            Text(message).foregroundStyle(Brand.ink2)
        }
        .padding(.horizontal, Space.x4)
        .padding(.top, Space.x4)
        .frame(width: Space.panelWidth)
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
        .padding(.horizontal, Space.x4)
        .padding(.top, Space.x4)
        .frame(width: Space.panelWidth)
    }
}

private struct DetectionNotice: View {
    let via: String
    let onDismiss: () -> Void

    var body: some View {
        NoticeRow(kind: .accent) {
            MarkView(barHeight: 14, rises: true)
        } content: {
            HStack(alignment: .top, spacing: Space.x2) {
                Text(AppController.detectionBannerText(via: via))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .padding(-4)
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
                MarkView(barHeight: 20, breathing: true)
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
                        .foregroundStyle(Brand.ink2)
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

struct ErrorScreen: View {
    let message: String
    let isMicError: Bool
    var onRetry: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    @Environment(\.consentPending) private var consentPending

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
        case .retry: leading("Retry", action: onRetry, primary: primary)
        case .openSettings: leading("Open System Settings", action: onOpenSettings, primary: primary)
        case .dismiss:
            Button("Dismiss", action: onDismiss).buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func leading(_ title: String, action: @escaping () -> Void, primary: Bool) -> some View {
        if primary && !consentPending {
            Button(title, action: action).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
        } else {
            Button(title, action: action).buttonStyle(SecondaryButtonStyle())
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
        HStack(spacing: 0) {
            Button(action: onSettings) {
                Image(systemName: "gearshape").frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle())
            .accessibilityLabel("Settings")
            Spacer()
            Button(action: onQuit) {
                Text("Quit").frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle())
            .keyboardShortcut("q")
        }
        .overlay {
            if updateAvailable {
                Button(action: onUpdate) {
                    HStack(spacing: Space.x2 - 2) {
                        Circle().fill(Brand.vermilion).frame(width: 6, height: 6)
                        Text("Update available")
                    }
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(QuietButtonStyle())
                .opacity(chipShown ? 1 : 0)
                .onAppear { withAnimation(Motion.fade) { chipShown = true } }
            }
        }
        .padding(.horizontal, Space.x4)
        .frame(width: Space.panelWidth, height: 28)
    }
}
