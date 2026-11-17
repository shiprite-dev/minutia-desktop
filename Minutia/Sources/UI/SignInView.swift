import AppKit
import SwiftUI

/// Native macOS sign-in. The companion auto-connects to the managed cloud instance (or the
/// stored self-host instance) on appear, so the user never sees instance plumbing: they land
/// straight on browser sign-in (primary) with email/password and Google as a collapsed
/// fallback. Instance changes live in Settings, for self-hosters only.
struct SignInView: View {
    @ObservedObject var authManager: AuthManager
    var showsMenuBarHint = false
    @Environment(\.openSettings) private var openSettings

    @State private var email = ""
    @State private var password = ""
    @State private var connecting = true
    @State private var busy = false
    @State private var showEmailForm = false
    @State private var errorMessage: String?
    /// The in-flight connect, held so Cancel can stop a dead spinner and drop to the failure UI.
    @State private var connectTask: Task<Void, Never>?
    /// False when the last connect failure was deterministic (untrusted or not a Minutia
    /// instance), hiding the "Try again" affordance that could only loop the same verdict.
    @State private var retryable = true

    /// Pure gate for the sign-in button: a plausible email and a non-empty password.
    static func canSubmit(email: String, password: String) -> Bool {
        guard !password.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        guard let at = trimmedEmail.firstIndex(of: "@"), at != trimmedEmail.startIndex else { return false }
        let domain = trimmedEmail[trimmedEmail.index(after: at)...]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    var body: some View {
        SignInScreen(
            stage: SignInStage.resolve(
                isConnected: authManager.isConnected,
                awaitingBrowser: authManager.awaitingBrowserSignIn,
                connecting: connecting,
                errorMessage: errorMessage,
                retryable: retryable),
            showsMenuBarHint: showsMenuBarHint,
            signInError: authManager.isConnected ? (errorMessage ?? authManager.callbackError) : nil,
            email: $email,
            password: $password,
            showEmailForm: $showEmailForm,
            busy: busy,
            actions: SignInActions(
                signInWithBrowser: signInWithBrowser,
                cancelConnect: cancelConnect,
                cancelBrowserSignIn: cancelBrowserSignIn,
                retry: startConnect,
                openSelfHost: {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                },
                signIn: signIn,
                signInWithGoogle: signInWithGoogle))
            .task { await autoConnect() }
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
        retryable = true
        let host = InstanceConfig.resolvedInstance.host
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
                // A deterministic verdict (untrusted, not a Minutia instance) cannot change on
                // retry: stop the backoff loop immediately and drop the retry affordance.
                if !AuthManager.isRetryableConnectFailure(error) {
                    errorMessage = AuthManager.connectFailureMessage(for: error, host: host)
                    retryable = false
                    break
                }
                if index == backoffs.count - 1 {
                    errorMessage = AuthManager.connectFailureMessage(for: error, host: host)
                }
            }
        }
        if !Task.isCancelled { connecting = false }
    }

    private func signInWithBrowser() {
        errorMessage = nil
        authManager.callbackError = nil
        let device = Host.current().localizedName ?? "Mac"
        NSWorkspace.shared.open(authManager.beginBrowserSignIn(device: device))
    }

    /// Abandon the browser sign-in the user started: clear the waiting state and drop the pending
    /// flow so a late callback for this attempt no longer binds.
    private func cancelBrowserSignIn() {
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

enum SignInStage: Equatable {
    case connecting
    case ready
    case browserPending
    case failed(message: String, retryable: Bool)

    static func resolve(isConnected: Bool, awaitingBrowser: Bool, connecting: Bool, errorMessage: String?, retryable: Bool) -> SignInStage {
        if isConnected { return awaitingBrowser ? .browserPending : .ready }
        if connecting { return .connecting }
        if let errorMessage { return .failed(message: errorMessage, retryable: retryable) }
        return .connecting
    }
}

struct SignInActions {
    var signInWithBrowser: () -> Void = {}
    var cancelConnect: () -> Void = {}
    var cancelBrowserSignIn: () -> Void = {}
    var retry: () -> Void = {}
    var openSelfHost: () -> Void = {}
    var signIn: () -> Void = {}
    var signInWithGoogle: () -> Void = {}
}

struct SignInScreen: View {
    let stage: SignInStage
    let showsMenuBarHint: Bool
    let signInError: String?
    @Binding var email: String
    @Binding var password: String
    @Binding var showEmailForm: Bool
    let busy: Bool
    var actions = SignInActions()

    private var markBreathes: Bool { stage == .connecting || stage == .browserPending }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack(spacing: Space.x3) {
                MarkView(barHeight: 22, breathing: markBreathes, rises: true)
                Text("Minutia").font(Typo.masthead)
            }

            switch stage {
            case .ready: ready
            case .browserPending: browserPending
            case .connecting: connecting
            case .failed(let message, let retryable): failed(message: message, retryable: retryable)
            }

            if showsMenuBarHint {
                QuietRow(systemImage: "arrow.up.right", text: FirstRun.menuBarHint)
            }
        }
        .padding(Space.x4)
        .frame(width: Space.panelWidth, alignment: .leading)
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            Text("Record a meeting. Get the issues log.")
                .font(Typo.body)
                .foregroundStyle(Brand.ink2)
            if let signInError {
                NoticeRow(kind: .warn) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.warn)
                } content: {
                    Text(signInError)
                }
            }
            Button("Sign in with browser", action: actions.signInWithBrowser)
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
            Button {
                withAnimation(Motion.settle) { showEmailForm.toggle() }
            } label: {
                HStack(spacing: Space.x2) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(showEmailForm ? .degrees(90) : .zero)
                    Text("Use email instead")
                }
            }
            .buttonStyle(QuietButtonStyle())
            .accessibilityValue(showEmailForm ? "Expanded" : "Collapsed")
            if showEmailForm {
                VStack(spacing: Space.x2) {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    Button("Sign in", action: actions.signIn)
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(busy || !SignInView.canSubmit(email: email, password: password))
                    Button("Sign in with Google", action: actions.signInWithGoogle)
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(busy)
                }
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var browserPending: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            Text("Check your browser to finish signing in.")
                .font(Typo.body)
                .foregroundStyle(Brand.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Start over", action: actions.cancelBrowserSignIn)
                .buttonStyle(QuietButtonStyle())
        }
    }

    private var connecting: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            Text("Connecting to Minutia")
                .font(Typo.body)
                .foregroundStyle(Brand.ink2)
            Button("Cancel", action: actions.cancelConnect)
                .buttonStyle(QuietButtonStyle())
        }
    }

    private func failed(message: String, retryable: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            NoticeRow(kind: .warn) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(Brand.warn)
            } content: {
                Text(message)
            }
            if retryable {
                Button("Try again", action: actions.retry)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            Button("Using a self-hosted server?", action: actions.openSelfHost)
                .buttonStyle(QuietButtonStyle())
                .font(Typo.caption)
        }
    }
}
