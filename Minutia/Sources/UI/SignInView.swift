import AppKit
import SwiftUI

/// Native macOS sign-in: connect to an instance, then browser sign-in (primary) with
/// email/password and Google as a collapsed fallback. No custom chrome; HIG form controls.
struct SignInView: View {
    @ObservedObject var authManager: AuthManager

    @State private var instanceText = ""
    @State private var email = ""
    @State private var password = ""
    @State private var connected = false
    @State private var busy = false
    @State private var showEmailForm = false
    @State private var errorMessage: String?

    /// Pure gate for the sign-in button: a plausible email and a non-empty password.
    static func canSubmit(email: String, password: String) -> Bool {
        guard !password.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        guard let at = trimmedEmail.firstIndex(of: "@"), at != trimmedEmail.startIndex else { return false }
        let domain = trimmedEmail[trimmedEmail.index(after: at)...]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    var body: some View {
        Form {
            Section("Instance") {
                TextField("https://minutia.example.com", text: $instanceText)
                    .textContentType(.URL)
                    .disabled(connected || busy)
                Button(connected ? "Connected" : "Connect", action: connect)
                    .disabled(connected || busy || InstanceConfig.normalize(instanceText) == nil)
            }

            if connected {
                Section("Sign in") {
                    Button("Sign in with browser", action: signInWithBrowser)
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy)
                    DisclosureGroup("Use email instead", isExpanded: $showEmailForm) {
                        TextField("Email", text: $email)
                            .textContentType(.username)
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                        Button("Sign in", action: signIn)
                            .disabled(busy || !Self.canSubmit(email: email, password: password))
                        Button("Sign in with Google", action: signInWithGoogle)
                            .disabled(busy)
                    }
                }
            }

            if let message = errorMessage ?? authManager.callbackError {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task { hydrateStoredInstance() }
    }

    private func hydrateStoredInstance() {
        // A restored session may have already built the Supabase client; reflect that
        // so the sign-in fields show without a redundant Connect step.
        if authManager.supabase != nil { connected = true }
        guard let stored = InstanceConfig.stored else { return }
        if instanceText.isEmpty { instanceText = stored.instance.absoluteString }
    }

    private func connect() {
        guard let url = InstanceConfig.normalize(instanceText) else { return }
        run { try await authManager.connect(instance: url); connected = true }
    }

    private func signInWithBrowser() {
        guard let instance = authManager.instance else { return }
        errorMessage = nil
        authManager.callbackError = nil
        let device = Host.current().localizedName ?? "Mac"
        NSWorkspace.shared.open(MinutiaClient.companionAuthorizeURL(instance: instance, device: device))
    }

    private func signIn() {
        run { try await authManager.signIn(email: email, password: password) }
    }

    private func signInWithGoogle() {
        run { try await authManager.signInWithGoogle() }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        busy = true
        errorMessage = nil
        Task {
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }
}
