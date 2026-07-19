import SwiftUI

/// Live recording panel: elapsed clock, an 8-bar level meter fed by the capture session's
/// peak-hold level, upload progress, and the Stop button.
struct RecordingView: View {
    @ObservedObject var session: CaptureSession
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recording")
                    .font(.headline)
                Spacer()
                Text(Self.timestamp(session.elapsed))
                    .font(.title3.monospacedDigit())
            }

            LevelMeter(level: session.level)

            Text("\(session.segmentsUploaded) of \(session.segmentsTotal) segments uploaded")
                .font(.caption)
                .foregroundStyle(.secondary)

            if session.reconnecting {
                Text("Reconnecting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                onStop()
            } label: {
                Label("Stop", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        let lit = RecordingView.litBars(level: level, total: RecordingView.barCount)
        HStack(spacing: 3) {
            ForEach(0..<RecordingView.barCount, id: \.self) { index in
                Capsule()
                    .fill(index < lit ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(height: 6)
            }
        }
        .animation(.easeOut(duration: 0.15), value: lit)
        .accessibilityElement()
        .accessibilityLabel("Audio level")
        .accessibilityValue("\(lit) of \(RecordingView.barCount)")
    }
}
