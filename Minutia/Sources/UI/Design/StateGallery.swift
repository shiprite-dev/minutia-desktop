#if DEBUG
import SwiftUI

enum StateGallery {
    struct Entry: Identifiable {
        let name: String
        let view: AnyView
        let isPanel: Bool
        var id: String { name }
    }

    static let longName = "Quarterly platform reliability, security and incident review with every engineering lead"
    private static let series = [Series(id: UUID(), name: "Weekly Eng Sync"), Series(id: UUID(), name: longName)]
    private static let instance = URL(string: "https://example.com")!

    private static func idle(_ edit: (inout IdleModel) -> Void = { _ in }) -> IdleScreen {
        var model = IdleModel(series: series, selected: series[0].id, detectedVia: nil, softHint: false, micBanner: false, recovering: false, instance: instance)
        edit(&model)
        return IdleScreen(model: model)
    }

    private static func signIn(_ stage: SignInStage, hint: Bool = false, error: String? = nil) -> SignInScreen {
        SignInScreen(stage: stage, showsMenuBarHint: hint, signInError: error, email: .constant(""), password: .constant(""), showEmailForm: .constant(false), busy: false)
    }

    private static func panel<V: View>(_ name: String, update: Bool = false, _ view: V) -> Entry {
        Entry(name: name, view: AnyView(VStack(spacing: 0) { view; HairlineRule(); FooterBar(updateAvailable: update) }), isPanel: true)
    }

    static let entries: [Entry] = [
        panel("01-signed-out", signIn(.ready, hint: true)),
        panel("02-connecting", signIn(.connecting)),
        panel("03-browser-pending", signIn(.browserPending)),
        panel("04-offline", signIn(.failed(message: "Can't reach app.getminutia.com. Check your connection and try again.", retryable: true))),
        panel("05-zero-series", idle { $0.series = []; $0.selected = nil }),
        panel("06-idle", idle()),
        panel("07-idle-long-name", idle { $0.selected = series[1].id }),
        panel("08-detected", idle { $0.detectedVia = "Zoom" }),
        panel("09-soft-hint", idle { $0.softHint = true }),
        panel("10-mic-permission", idle { $0.micBanner = true }),
        panel("11-recovery", idle { $0.recovering = true }),
        panel("12-consent", VStack(spacing: 0) { ConsentNotice(hasClaim: false); idle().padding(.top, -Space.x1) }.environment(\.consentPending, true)),
        panel("12b-consent-always", VStack(spacing: 0) { ConsentNotice(hasClaim: true); idle().padding(.top, -Space.x1) }.environment(\.consentPending, true)),
        panel("13-recording", RecordingContent(model: RecordingModel(seriesName: "Weekly Eng Sync", elapsed: 754, level: 0.7, progress: "2 of 3 segments uploaded"))),
        panel("14-recording-long-2h", RecordingContent(model: RecordingModel(seriesName: longName, elapsed: 7457, level: 0.3, progress: "Reconnecting upload", reconnecting: true, systemAudioDegraded: true))),
        panel("15-finishing", FinishingContent(label: "Uploading and requesting transcript", progress: nil, preparingSince: nil)),
        panel("16-transcribing", FinishingContent(label: "Transcribing on this Mac, 5 of 12", progress: 5.0 / 12, preparingSince: nil)),
        panel("17-preparing-model", FinishingContent(label: "Preparing the speech model", progress: nil, preparingSince: Date().addingTimeInterval(-14))),
        panel("18-done", DoneContent()),
        panel("19-error", ErrorScreen(message: "Upload failed after several attempts. Your recording is saved on this Mac.", isMicError: false)),
        panel("20-error-mic", ErrorScreen(message: "Microphone access was denied. Allow it in System Settings, then retry.", isMicError: true)),
        panel("21-model-downloading", VStack(spacing: 0) { idle(); ModelDownloadRow(label: "Downloading model 42%", fraction: 0.42) }),
        panel("22-update-available", update: true, idle()),
        Entry(name: "23-prompt-capsule", view: AnyView(MeetingPromptView(content: MeetingPromptContent(title: "Meeting detected", symbol: "waveform", primaryTitle: "Start taking notes", secondaryTitle: nil), onStart: {}, onDismiss: {}).padding(Space.x6)), isPanel: false),
    ]
}

#Preview("States, light") { gallery(.light) }
#Preview("States, dark") { gallery(.dark) }

private func gallery(_ scheme: ColorScheme) -> some View {
    ScrollView {
        LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(StateGallery.entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.caption).foregroundStyle(.secondary)
                    entry.view
                }
            }
        }
        .padding(24)
    }
    .frame(width: 400, height: 900)
    .environment(\.colorScheme, scheme)
}
#endif
