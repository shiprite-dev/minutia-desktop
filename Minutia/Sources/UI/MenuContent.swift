import SwiftUI

/// The menu bar panel: one screen per AppPhase, plus a persistent Settings/Quit footer.
/// Purely declarative; every decision is the controller's (and the reducer's).
struct MenuContent: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Above the phase switch so the consent affordance is reachable in every phase a
            // web-record can be pending (idle, detected, error), not only the idle layout. This
            // is the guaranteed fallback when notification permission is denied.
            if controller.pendingRecordConsent != nil {
                WebRecordConsentBanner(controller: controller)
                    .padding(12)
            }

            // Transient feedback (e.g. a rejected web-record) surfaced in-menu, so it reaches the
            // user even when notification permission is denied. Auto-clears on the next phase change.
            if let feedback = controller.recordFeedback {
                FeedbackBanner(message: feedback)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            }

            Group {
                switch controller.phase {
                case .signedOut:
                    SignInView(authManager: controller.authManager)
                case .idle:
                    IdleView(controller: controller, detectedVia: nil)
                case .detected(let app):
                    IdleView(controller: controller, detectedVia: app ?? "Calendar")
                case .recording:
                    RecordingView(session: controller.captureSession) {
                        controller.stopRecording()
                    }
                case .finalizing:
                    FinalizingView()
                case .error(let message):
                    ErrorView(message: message, controller: controller)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
            Footer()
        }
        .frame(width: 320)
    }
}

/// Idle and detected phases share one layout; detection adds the highlighted banner.
private struct IdleView: View {
    @ObservedObject var controller: AppController
    let detectedVia: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !controller.micAuthorized {
                MicPermissionBanner()
            }

            if let detectedVia {
                DetectionBanner(via: detectedVia, controller: controller)
            } else if controller.softHint {
                SoftHintRow()
            }

            if controller.series.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No series yet. Create one in Minutia on the web.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Minutia") {
                        NSWorkspace.shared.open(controller.authManager.instance ?? InstanceConfig.resolvedInstance)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Picker("Series", selection: $controller.selectedSeriesId) {
                    ForEach(controller.series) { series in
                        Text(series.name).tag(Optional(series.id))
                    }
                }
            }

            Button {
                controller.startRecording()
            } label: {
                Label("Record", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(controller.selectedSeriesId == nil)
        }
        .padding(12)
        .onAppear {
            controller.refreshPermissionState()
            controller.reloadSeries()
        }
    }
}

/// Shown when mic access is not granted: recording is impossible without it, so guide the user
/// straight to the System Settings pane. System audio TCC cannot be queried, so it is only noted.
private struct MicPermissionBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "mic.slash")
                    .foregroundStyle(.yellow)
                Text("Microphone access needed to record")
                    .font(.callout)
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("System audio is requested the first time you record.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Small transient banner for controller feedback that must surface without notifications.
private struct FeedbackBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Quiet soft-detection nudge: mic active but no corroborating meeting signal. Deliberately
/// styled secondary (not the accent banner) so it reads as a whisper, not an alert.
private struct SoftHintRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic")
            Text("In a meeting? Record picks it up from here.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// Consent gate for a browser-triggered `minutia://record`. The guaranteed fallback when
/// notifications are denied, so it must be reachable from the menu: capture starts only when the
/// user taps Start recording here (or in the notification).
private struct WebRecordConsentBanner: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "record.circle")
                    .foregroundStyle(.tint)
                Text("Record this meeting from your browser?")
                    .font(.callout)
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button {
                    controller.confirmPendingRecord()
                } label: {
                    Text("Start recording")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                Button("Ignore") {
                    controller.dismissPendingRecord()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DetectionBanner: View {
    let via: String
    @ObservedObject var controller: AppController

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text("Meeting detected via \(via): Record?")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                controller.dismissDetection()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Dismiss detection")
        }
        .padding(10)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct FinalizingView: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Uploading and requesting transcript")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

private struct ErrorView: View {
    let message: String
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
            HStack {
                Button("Retry") { controller.retry() }
                    .keyboardShortcut(.defaultAction)
                Button("Dismiss") { controller.dismissError() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(12)
    }
}

private struct Footer: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Settings")
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
