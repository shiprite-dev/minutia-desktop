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
    /// The in-flight connect, held so Cancel can stop a dead spinner and drop to the failure UI.
    @State private var connectTask: Task<Void, Never>?
    /// True after the browser is opened for magic-link sign-in: shows a waiting state with a
    /// "Start over" escape hatch, cleared when sign-in completes or a callback error arrives.
    @State private var browserPending = false

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
                if browserPending {
                    // The browser was opened for magic-link sign-in: wait for the callback, but
                    // never trap the user here. "Start over" clears this and the pending flow.
                    Section("Signing in") {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Check your browser to finish signing in.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Button("Start over") { cancelBrowserSignIn() }
                            .buttonStyle(.link)
                    }
                } else {
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
            } else if connecting {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Connecting to Minutia")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    // Never a dead, uncancellable spinner: Cancel stops the connect and drops to
                    // the failure/self-host UI immediately.
                    Button("Cancel") { cancelConnect() }
                        .buttonStyle(.link)
                }
            }

            if !authManager.isConnected, !connecting, let message = errorMessage {
                // Connection failure (not a sign-in failure): a first-run user most often hits this
                // because the network was not ready at launch, so lead with a warm retry rather than
                // a raw transport error, and keep the self-host option as a quiet secondary link.
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try again") { startConnect() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                        Button("Using a self-hosted server?") {
                            NSApp.activate(ignoringOtherApps: true)
                            openSettings()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            } else if authManager.isConnected, let message = errorMessage ?? authManager.callbackError {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .task { await autoConnect() }
        .onChange(of: authManager.userEmail) { _, email in
            if email != nil { browserPending = false }
        }
        .onChange(of: authManager.callbackError) { _, error in
            if error != nil { browserPending = false }
        }
    }

    /// Connect to the resolved instance the moment the sign-in screen appears. Idempotent with
    /// restoreSession(): a client already built by session restore short-circuits here.
    private func autoConnect() async {
        guard authManager.supabase == nil else { connecting = false; return }
        startConnect()
        await connectTask?.value
    }

    /// Kick off (or restart) the connect as a cancellable task so Cancel/Try again can drive it.
    private func startConnect() {
        connectTask?.cancel()
        connectTask = Task { await attemptConnect() }
    }

    /// Cancel an in-flight connect and drop to the failure/self-host UI, so the spinner is never a
    /// dead end the user cannot escape.
    private func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        connecting = false
        if errorMessage == nil {
            errorMessage = "Connecting was cancelled. Try again when you're ready."
        }
    }

    /// Connect with a short backoff so a transient failure at launch (network not ready yet)
    /// self-heals within a few seconds before the manual "Try again" affordance is shown.
    private func attemptConnect() async {
        connecting = true
        errorMessage = nil
        let backoffs: [Double] = [0, 1, 2, 4]
        for (index, delay) in backoffs.enumerated() {
            if Task.isCancelled { return }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            if Task.isCancelled { return }
            if authManager.supabase != nil { break }
            do {
                try await authManager.ensureConnected()
                errorMessage = nil
                break
            } catch {
                if index == backoffs.count - 1 {
                    errorMessage = AuthManager.connectFailureMessage(for: error)
                }
            }
        }
        if !Task.isCancelled { connecting = false }
    }

    private func signInWithBrowser() {
        errorMessage = nil
        authManager.callbackError = nil
        browserPending = true
        let device = Host.current().localizedName ?? "Mac"
        NSWorkspace.shared.open(authManager.beginBrowserSignIn(device: device))
    }

    /// Abandon the browser sign-in the user started: clear the waiting state and drop the pending
    /// flow so a late callback for this attempt no longer binds.
    private func cancelBrowserSignIn() {
        browserPending = false
        authManager.cancelBrowserSignIn()
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
