import SwiftUI

struct RecordingModel {
    var seriesName: String?
    var elapsed: TimeInterval
    var level: Float
    var progress: String
    var reconnecting = false
    var systemAudioDegraded = false
    var micUnavailable = false
}

struct RecordingView: View {
    @ObservedObject var session: CaptureSession
    var seriesName: String?
    let onNotes: () -> Void
    let onStop: () -> Void

    static let barCount = 8

    /// mm:ss for the elapsed clock; hours fold into minutes (90 min shows 90:00).
    static func timestamp(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// How many meter bars light up for a 0...1 level. Any signal lights at least one bar
    /// so a quiet room still reads as "live".
    static func litBars(level: Float, total: Int) -> Int {
        guard level > 0 else { return 0 }
        return min(total, max(1, Int((level * Float(total)).rounded(.up))))
    }

    static func clock(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed))
        guard total >= 3600 else { return timestamp(elapsed) }
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func spokenDuration(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed))
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        let hours = total / 3600, minutes = (total % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(unit(hours, "hour")) \(unit(minutes, "minute"))" : unit(hours, "hour") }
        return minutes > 0 ? unit(minutes, "minute") : unit(total, "second")
    }

    static func progressLine(uploaded: Int, total: Int, audioMayLeaveMac: Bool, deviceOnly: Bool) -> String {
        if audioMayLeaveMac { return "\(uploaded) of \(total) segments uploaded" }
        return deviceOnly ? "Transcribing as you record. Audio stays on this Mac." : "Transcribing on this Mac as you record"
    }

    var body: some View {
        RecordingContent(
            model: RecordingModel(
                seriesName: seriesName,
                elapsed: session.elapsed,
                level: session.level,
                progress: Self.progressLine(uploaded: session.segmentsUploaded, total: session.segmentsTotal, audioMayLeaveMac: session.audioMayLeaveMac, deviceOnly: session.deviceOnly),
                reconnecting: session.reconnecting,
                systemAudioDegraded: session.systemAudioDegraded,
                micUnavailable: session.micUnavailable),
            onNotes: onNotes,
            onStop: onStop)
    }
}

struct RecordingContent: View {
    let model: RecordingModel
    var onNotes: () -> Void = {}
    var onStop: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            Eyebrow(text: "Recording", live: true)

            HStack(alignment: .firstTextBaseline, spacing: Space.x2) {
                Text(model.seriesName ?? "Recording")
                    .font(Typo.title)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(model.seriesName ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(RecordingView.clock(model.elapsed))
                    .font(Typo.timer)
                    .contentTransition(.numericText(value: model.elapsed))
                    .animation(reduceMotion ? nil : Motion.snap, value: Int(model.elapsed))
                    .fixedSize()
                    .accessibilityLabel("Elapsed time")
                    .accessibilityValue(RecordingView.spokenDuration(model.elapsed))
                    .accessibilityAddTraits(.updatesFrequently)
            }

            LevelBars(level: model.level)

            Text(model.progress)
                .font(Typo.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.reconnecting {
                Text("Reconnecting…")
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
            }

            if model.systemAudioDegraded {
                NoticeRow(kind: .warn) {
                    Image(systemName: "speaker.slash").foregroundStyle(Brand.warn)
                } content: {
                    Text("System audio isn't being captured. Recording your microphone only.")
                }
            }

            if model.micUnavailable {
                NoticeRow(kind: .warn) {
                    Image(systemName: "mic.slash").foregroundStyle(Brand.warn)
                } content: {
                    Text(CaptureSession.micUnavailableNotice)
                }
            }

            Button(action: onNotes) {
                Label("Notes", systemImage: "note.text")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(QuietButtonStyle())
            .accessibilityLabel("Show meeting notes")
            .accessibilityHint("Option Command N")

            Button(action: onStop) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Stop recording")
        }
        .padding(Space.x4)
        .frame(width: Space.panelWidth)
        .onAppear { AccessibilityNotification.Announcement("Recording started").post() }
    }
}
