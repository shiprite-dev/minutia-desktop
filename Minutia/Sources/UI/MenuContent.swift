import SwiftUI

/// The menu bar panel: one screen per AppPhase, plus a persistent Settings/Quit footer.
/// Purely declarative; every decision is the controller's (and the reducer's).
struct MenuContent: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            if let detectedVia {
                DetectionBanner(via: detectedVia, controller: controller)
            }

            if controller.series.isEmpty {
                Text("No series yet. Create one in Minutia on the web.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
