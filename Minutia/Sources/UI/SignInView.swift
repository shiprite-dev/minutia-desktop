import AppKit
import SwiftUI

/// Native macOS sign-in. The companion auto-connects to the managed cloud instance (or the
/// stored self-host instance) on appear, so the user never sees instance plumbing: they land
/// straight on browser sign-in (primary) with email/password and Google as a collapsed
/// fallback. Instance changes live in Settings, for self-hosters only.
struct SignInView: View {
    @ObservedObject var authManager: AuthManager
    @Environment(\.openSettings) private var openSettings

    @State private var email = ""
    @State private var password = ""
    @State private var connecting = true
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                Text("Minutia").font(.headline)
            }
            .padding(12)

            form
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var form: some View {
        Form {
            if authManager.isConnected {
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
            } else if connecting {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Connecting to Minutia")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let message = errorMessage ?? authManager.callbackError {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message)
                            .foregroundStyle(.red)
                            .font(.callout)
                        if !authManager.isConnected {
                            Button("Change instance in Settings") {
                                NSApp.activate(ignoringOtherApps: true)
                                openSettings()
                            }
                            .buttonStyle(.link)
                            .font(.callout)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await autoConnect() }
    }

    /// Connect to the resolved instance the moment the sign-in screen appears. Idempotent with
    /// restoreSession(): a client already built by session restore short-circuits here.
    private func autoConnect() async {
        guard authManager.supabase == nil else { connecting = false; return }
        connecting = true
        errorMessage = nil
        do {
            try await authManager.ensureConnected()
        } catch {
            errorMessage = "Could not connect to Minutia. \(error.localizedDescription)"
        }
        connecting = false
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
