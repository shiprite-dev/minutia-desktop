import SwiftUI
#if DEBUG
import AppKit
#endif

@main
struct MinutiaApp: App {
    @StateObject private var authManager = AuthManager()

    var body: some Scene {
        MenuBarExtra("Minutia", systemImage: "waveform") {
            Group {
                if authManager.userEmail == nil {
                    SignInView(authManager: authManager)
                } else {
                    SignedInView(authManager: authManager)
                }
            }
            .onOpenURL { url in
                Task { await authManager.handleCallback(url) }
            }
            .task { await restoreSession() }
        }
        .menuBarExtraStyle(.window)
    }

    /// Rehydrate the Supabase client from the persisted instance so a Keychain
    /// session lands the app signed in without another Connect step.
    private func restoreSession() async {
        guard authManager.supabase == nil, let stored = InstanceConfig.stored else { return }
        try? await authManager.connect(instance: stored.instance)
    }
}

private struct SignedInView: View {
    @ObservedObject var authManager: AuthManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(authManager.userEmail ?? "")
                .font(.headline)
            Button("Sign out") {
                Task { await authManager.signOut() }
            }
            #if DEBUG
            Divider()
            Button("Debug: 10s capture smoke") {
                Task { await runCaptureSmoke() }
            }
            #endif
        }
        .padding()
        .frame(width: 240)
    }
}

#if DEBUG
/// Runs the tap + mic + segment writer for 10 seconds into ~/Downloads/minutia-smoke with no
/// upload, then reveals the output in Finder. Exercises the capture graph end to end for a manual
/// TCC/audio smoke check; excluded from release builds.
private func runCaptureSmoke() async {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads/minutia-smoke", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let writer = try? SegmentWriter(directory: dir) else { return }

    let micBuffer = RingBuffer(capacityFrames: Int(MixPlan.sampleRate) * 12)
    let sysBuffer = RingBuffer(capacityFrames: Int(MixPlan.sampleRate) * 12)
    let tap = SystemAudioTap(into: sysBuffer)
    let mic = MicCapture(into: micBuffer)
    try? tap.start()
    try? await mic.start()

    var micScratch = [Float](repeating: 0, count: MixPlan.tickFrames)
    var sysScratch = [Float](repeating: 0, count: MixPlan.tickFrames)
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        try? await Task.sleep(nanoseconds: 250_000_000)
        let plan = MixPlan.plan(micAvailable: micBuffer.availableFrames, sysAvailable: sysBuffer.availableFrames)
        let micGot = micBuffer.pop(into: &micScratch, count: plan.micFrames)
        let sysGot = sysBuffer.pop(into: &sysScratch, count: plan.sysFrames)
        let count = max(micGot, sysGot)
        guard count > 0 else { continue }
        let mixed = MixPlan.mix(mic: Array(micScratch[0..<micGot]), sys: Array(sysScratch[0..<sysGot]), count: count)
        _ = try? writer.append(mixed)
    }

    tap.stop()
    mic.stop()
    _ = try? writer.finish()
    NSWorkspace.shared.activateFileViewerSelecting([dir])
}
#endif
