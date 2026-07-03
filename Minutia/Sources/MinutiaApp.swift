import SwiftUI

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
        }
        .padding()
        .frame(width: 240)
    }
}
