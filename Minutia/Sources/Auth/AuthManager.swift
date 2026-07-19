import Foundation
import OSLog
import Supabase

/// Owns the Supabase session: instance discovery, sign-in (password, Google PKCE, and the
/// browser magic-link handoff), and the OAuth callback. supabase-swift persists the session
/// in the Keychain by default, so nothing here writes the secret to disk.
@MainActor
final class AuthManager: ObservableObject {
    @Published private(set) var userEmail: String?
    /// Set when the browser sign-in callback fails so SignInView can show it inline.
    @Published var callbackError: String?
    /// Connection truth: true once a Supabase client is built for an instance. Cleared when a
    /// (re)connect fails so the status never reports a stale previous connection.
    @Published private(set) var isConnected = false

    private(set) var supabase: SupabaseClient?
    private(set) var instance: URL?
    private var lastHandledTokenHash: String?
    private var connectTask: Task<Void, Error>?

    static let redirectURL = URL(string: "minutia://auth-callback")!
    private static let pendingAuthKey = "app.minutia.pendingAuth"

    private static let logger = Logger(subsystem: "app.minutia.desktop", category: "AuthManager")

    /// Marks a locally-initiated sign-in so an inbound auth callback can be bound to it. Persisted
    /// in UserDefaults because the magic link round-trips through email and the app may be cold
    /// launched by the callback, so the marker must survive relaunch.
    struct PendingAuth: Codable, Equatable {
        let nonce: String
        let startedAt: Date
    }

    /// Whether an inbound `minutia://auth-callback` should be honored. Pure so the gate matrix
    /// (already signed in, no pending flow, expired, state mismatch, valid) is tested in isolation.
    enum AuthCallbackDecision: Equatable {
        case accept
        case rejectAlreadySignedIn
        case rejectNoPendingFlow
        case rejectStateMismatch
    }

    /// A signed-in app must never process a new sign-in token (session fixation). An unsolicited
    /// or expired callback (no pending flow) is rejected. When the server echoes `state`, it must
    /// match the pending nonce; a nil state with a valid pending flow still accepts, because the
    /// pending-flow plus not-already-signed-in gates are the client-side protection and the state
    /// match only tightens it once the server echoes it.
    nonisolated static func authCallbackDecision(
        alreadySignedIn: Bool,
        pending: PendingAuth?,
        callbackState: String?,
        now: Date,
        ttl: TimeInterval = 900
    ) -> AuthCallbackDecision {
        if alreadySignedIn { return .rejectAlreadySignedIn }
        guard let pending else { return .rejectNoPendingFlow }
        let elapsed = now.timeIntervalSince(pending.startedAt)
        guard elapsed >= 0, elapsed <= ttl else { return .rejectNoPendingFlow }
        if let callbackState, callbackState != pending.nonce { return .rejectStateMismatch }
        return .accept
    }

    private var pendingAuth: PendingAuth? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.pendingAuthKey),
                  let decoded = try? JSONDecoder().decode(PendingAuth.self, from: data) else { return nil }
            return decoded
        }
        set {
            guard let value = newValue, let data = try? JSONEncoder().encode(value) else {
                UserDefaults.standard.removeObject(forKey: Self.pendingAuthKey)
                return
            }
            UserDefaults.standard.set(data, forKey: Self.pendingAuthKey)
        }
    }

    /// Extracts the magic-link token hash from a `minutia://auth-callback?token_hash=...` URL.
    /// Returns nil for any other URL (notably the Google PKCE callback, which carries `code`).
    static func tokenHash(from url: URL) -> String? {
        guard url.scheme == "minutia", url.host == "auth-callback",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first(where: { $0.name == "token_hash" })?.value
    }

    /// Extracts the `state` nonce echoed back on a `minutia://auth-callback` URL, mirroring
    /// `tokenHash(from:)`. Returns nil for any other URL or when the server did not echo it.
    static func state(from url: URL) -> String? {
        guard url.scheme == "minutia", url.host == "auth-callback",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first(where: { $0.name == "state" })?.value
    }

    /// Begin a browser magic-link sign-in: persist a fresh pending marker (nonce + timestamp) and
    /// return the authorize URL carrying that nonce as `state`, so the resulting callback can be
    /// bound to this attempt.
    func beginBrowserSignIn(device: String) -> URL {
        let nonce = UUID().uuidString
        pendingAuth = PendingAuth(nonce: nonce, startedAt: Date())
        let instance = self.instance ?? InstanceConfig.resolvedInstance
        return MinutiaClient.companionAuthorizeURL(instance: instance, device: device, state: nonce)
    }

    /// Auto-connect for first run and relaunch: use the stored (self-host) instance when
    /// present, else the managed cloud default. Single-flight, so restoreSession() and
    /// SignInView's on-appear can fire concurrently without opening two connects; the second
    /// caller awaits the first's in-flight attempt, and a built client short-circuits both.
    func ensureConnected() async throws {
        guard supabase == nil else { return }
        if let connectTask { return try await connectTask.value }
        let task = Task { try await connect(instance: InstanceConfig.resolvedInstance) }
        connectTask = task
        defer { connectTask = nil }
        try await task.value
    }

    /// Fetch the instance's public connection details and build the Supabase client.
    /// Rehydrates `userEmail` from any Keychain-persisted session.
    func connect(instance: URL) async throws {
        do {
            let (data, _) = try await URLSession.shared.data(for: InstanceConfig.metaRequest(instance: instance))
            let meta = try JSONDecoder().decode(InstanceMeta.self, from: data)

            guard InstanceConfig.isValidSupabaseURL(meta.supabaseUrl, instance: instance) else {
                throw AuthError.untrustedInstance
            }

            let client = SupabaseClient(supabaseURL: meta.supabaseUrl, supabaseKey: meta.supabaseAnonKey)
            self.supabase = client
            self.instance = instance
            self.isConnected = true
            InstanceConfig.stored = (instance: instance, meta: meta)

            // A prior session may already be in the Keychain: surface it so a relaunch
            // lands signed in without re-prompting.
            if let session = try? await client.auth.session {
                userEmail = session.user.email
                fireHeartbeat()
            }
        } catch {
            // A failed (re)connect must not leave a stale client reporting connected, nor a
            // signed-in phase with no client behind it. Clearing userEmail drops the app to the
            // sign-in screen, whose auto-connect recovers against the still-stored instance.
            self.supabase = nil
            self.instance = nil
            self.isConnected = false
            self.userEmail = nil
            throw error
        }
    }

    func signIn(email: String, password: String) async throws {
        guard let supabase else { throw AuthError.notConnected }
        let session = try await supabase.auth.signIn(email: email, password: password)
        userEmail = session.user.email
        fireHeartbeat()
    }

    func signInWithGoogle() async throws {
        guard let supabase else { throw AuthError.notConnected }
        pendingAuth = PendingAuth(nonce: UUID().uuidString, startedAt: Date())
        let session = try await supabase.auth.signInWithOAuth(provider: .google, redirectTo: Self.redirectURL)
        userEmail = session.user.email
        pendingAuth = nil
        fireHeartbeat()
    }

    /// Handle the `minutia://auth-callback` deep link. Two flavors coexist: the browser
    /// magic-link handoff carries `token_hash` and is exchanged via verifyOTP; anything
    /// else is treated as the Google PKCE callback and closed via session(from:).
    func handleCallback(_ url: URL) async {
        guard let supabase else { return }

        // Bind the callback to a locally-initiated sign-in before touching any token: an attacker
        // can feed a victim a token_hash for the attacker's account, so an unsolicited callback,
        // one that arrives while already signed in, or one whose echoed state does not match must
        // never reach verifyOTP/session(from:).
        let decision = Self.authCallbackDecision(
            alreadySignedIn: userEmail != nil,
            pending: pendingAuth,
            callbackState: Self.state(from: url),
            now: Date())
        guard decision == .accept else {
            Self.logger.error("Rejected auth callback: \(String(describing: decision), privacy: .public)")
            return
        }

        if let hash = Self.tokenHash(from: url) {
            // The URL can arrive through both onOpenURL and the kAEGetURL Apple event;
            // a token hash is single-use, so the second delivery must not report an error.
            guard hash != lastHandledTokenHash else { return }
            lastHandledTokenHash = hash
            do {
                let session = try await supabase.auth.verifyOTP(tokenHash: hash, type: .magiclink)
                userEmail = session.user.email
                callbackError = nil
                pendingAuth = nil
                fireHeartbeat()
            } catch {
                Self.logger.error("Browser sign-in failed: \(error.localizedDescription, privacy: .public)")
                callbackError = error.localizedDescription
            }
            return
        }
        do {
            let session = try await supabase.auth.session(from: url)
            userEmail = session.user.email
            pendingAuth = nil
            fireHeartbeat()
        } catch {
            Self.logger.error("OAuth callback failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The current access token; supabase-swift refreshes it transparently.
    func accessToken() async throws -> String {
        guard let supabase else { throw AuthError.notConnected }
        return try await supabase.auth.session.accessToken
    }

    /// The API client for the connected instance, available once signed in.
    func client() -> MinutiaClient? {
        guard let supabase, let instance else { return nil }
        return MinutiaClient(instance: instance, supabase: supabase) { [weak self] in
            guard let self else { throw AuthError.notConnected }
            return try await self.accessToken()
        }
    }

    /// Fire-and-forget companion heartbeat; runs after every successful sign-in and on
    /// every signed-in launch. Failures are silent by contract.
    private func fireHeartbeat() {
        guard let client = client() else { return }
        Task { await client.heartbeat() }
    }

    func signOut() async {
        guard let supabase else { return }
        try? await supabase.auth.signOut()
        userEmail = nil
    }

    enum AuthError: Error {
        case notConnected
        case untrustedInstance
    }
}
