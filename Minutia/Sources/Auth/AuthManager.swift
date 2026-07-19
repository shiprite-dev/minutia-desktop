import Foundation
import OSLog
import Supabase

/// Owns the Supabase session: instance discovery, sign-in (password, Google PKCE, and the
/// browser magic-link handoff), and the OAuth callback. supabase-swift persists the session
/// in the Keychain by default, so nothing here writes the secret to disk.
@MainActor
final class AuthManager: ObservableObject {
    @Published private(set) var userEmail: String?
    /// The connected instance paired with its signed-in email. A first-class signal so an
    /// instance switch that keeps the same email still reads as a new session (reload series,
    /// rebind the detector) rather than a no-op deduped away by email alone.
    @Published private(set) var sessionIdentity = SessionIdentity(instance: nil, email: nil)
    /// Set when the browser sign-in callback fails so SignInView can show it inline.
    @Published var callbackError: String?
    /// Connection truth: true once a Supabase client is built for an instance. Cleared when a
    /// (re)connect fails so the status never reports a stale previous connection.
    @Published private(set) var isConnected = false

    private(set) var supabase: SupabaseClient?
    private(set) var instance: URL?
    private var lastHandledTokenHash: String?
    private var connectTask: Task<Void, Error>?
    /// Observes the client's auth events so a server-side session expiry drops the app to
    /// sign-in instead of leaving a phantom signed-in state. Cancelled and replaced on each
    /// connect and on deinit.
    private var authStateTask: Task<Void, Never>?

    /// The instance a session belongs to, paired with its email. Equatable so the AppController
    /// sink fires on any real change, including an instance switch under the same email.
    struct SessionIdentity: Equatable {
        let instance: URL?
        let email: String?
    }

    deinit {
        authStateTask?.cancel()
    }

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

    /// The signed-in email after a (re)connect is exactly the newly connected instance's Keychain
    /// session; `priorEmail` (the previous instance's) is deliberately ignored so a nil session
    /// clears any phantom signed-in state and the user lands on sign-in.
    nonisolated static func resolvedEmail(priorEmail: String?, sessionEmail: String?) -> String? {
        sessionEmail
    }

    /// Namespace the Keychain session per instance so two instances never share (or clobber) a
    /// session. Derived from the full instance host; a hostless URL falls back to a stable key.
    nonisolated static func sessionStorageKey(for instance: URL) -> String {
        "sb-minutia-\(instance.host ?? "default")"
    }

    /// User-facing copy for a failed connect, differentiated by cause. A trust failure must not
    /// suggest retrying or checking the internet (it would loop); only a transport failure does.
    nonisolated static func connectFailureMessage(for error: Error) -> String {
        switch error {
        case AuthError.notAMinutiaInstance:
            return "This URL doesn't look like a Minutia instance. Check the address."
        case AuthError.untrustedInstance:
            return "This server's configuration isn't trusted. Contact your administrator."
        default:
            return "Couldn't reach the server. Check your internet connection and try again."
        }
    }

    /// Whether retrying the same connect can ever succeed. A trust or not-an-instance failure is
    /// deterministic (same URL, same verdict), so the retry affordance would just loop; only
    /// transport failures deserve one.
    nonisolated static func isRetryableConnectFailure(_ error: Error) -> Bool {
        switch error {
        case AuthError.notAMinutiaInstance, AuthError.untrustedInstance:
            return false
        default:
            return true
        }
    }

    /// Whether an inbound token hash is a fresh sign-in or a duplicate delivery (the URL arrives
    /// through both onOpenURL and kAEGetURL, and the hash is single-use).
    enum TokenHashAction: Equatable {
        case process
        case skipDuplicate
    }

    nonisolated static func tokenHashAction(incoming: String, lastHandled: String?) -> TokenHashAction {
        incoming == lastHandled ? .skipDuplicate : .process
    }

    /// A token hash is recorded as handled only after the exchange succeeds. Recording it before
    /// verifyOTP would make a failed first click turn the retry of the same link into a permanent
    /// silent no-op.
    nonisolated static func shouldRecordTokenHash(verifySucceeded: Bool) -> Bool {
        verifySucceeded
    }

    /// User-facing copy for a rejected callback, or nil when the rejection is silent by design.
    /// A stale/reused link (no pending flow, or a state mismatch) tells the user to request a new
    /// one; an already-signed-in rejection stays silent (the session is fine).
    nonisolated static func rejectionMessage(for decision: AuthCallbackDecision) -> String? {
        switch decision {
        case .rejectNoPendingFlow, .rejectStateMismatch:
            return "That sign-in link is stale or was already used. Request a new one from the app."
        case .rejectAlreadySignedIn, .accept:
            return nil
        }
    }

    /// The visible result of handling a `minutia://auth-callback`, so a cold launch can surface it
    /// (a notification) rather than swallowing it.
    enum CallbackOutcome: Equatable {
        case signedIn(String?)
        case failed(String)
        case rejected
        case ignored
    }

    /// The callback outcome decided before any token exchange: no client yet is `.ignored`; a
    /// rejected decision is `.rejected`; an accepted decision proceeds (nil = continue to exchange).
    nonisolated static func preExchangeOutcome(hasClient: Bool, decision: AuthCallbackDecision) -> CallbackOutcome? {
        guard hasClient else { return .ignored }
        return decision == .accept ? nil : .rejected
    }

    /// A session-clearing auth event: a server-side sign-out or a failed token refresh both surface
    /// as `.signedOut`, and must drop the app to sign-in.
    nonisolated static func authStateSignalsSignedOut(_ event: AuthChangeEvent) -> Bool {
        event == .signedOut
    }

    /// The single seam through which the signed-in identity changes: keeps `userEmail` and
    /// `sessionIdentity` atomic so the AppController sink never sees a half-updated pair.
    private func setSession(email: String?) {
        userEmail = email
        sessionIdentity = SessionIdentity(instance: instance, email: email)
    }

    /// Watch the client's auth events; a `.signedOut` (server sign-out or failed refresh) clears
    /// the local session so an expired session cannot leave a phantom signed-in state. Idempotent
    /// with our own signOut(), which also lands on a nil session, so the feedback is harmless.
    private func observeAuthState(_ client: SupabaseClient) {
        authStateTask?.cancel()
        authStateTask = Task { [weak self] in
            for await (event, _) in client.auth.authStateChanges {
                guard let self else { return }
                if Self.authStateSignalsSignedOut(event) { self.setSession(email: nil) }
            }
        }
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
            let (data, response) = try await URLSession.shared.data(for: InstanceConfig.metaRequest(instance: instance))
            // A non-2xx status or a body that is not InstanceMeta means this URL is reachable but is
            // not a Minutia instance; distinguish it from a transport failure so the copy can guide
            // the user to fix the address rather than blame their network.
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AuthError.notAMinutiaInstance
            }
            let meta: InstanceMeta
            do {
                meta = try JSONDecoder().decode(InstanceMeta.self, from: data)
            } catch {
                throw AuthError.notAMinutiaInstance
            }

            guard InstanceConfig.isValidSupabaseURL(meta.supabaseUrl, instance: instance) else {
                throw AuthError.untrustedInstance
            }

            let client = SupabaseClient(
                supabaseURL: meta.supabaseUrl,
                supabaseKey: meta.supabaseAnonKey,
                options: .init(auth: .init(storageKey: Self.sessionStorageKey(for: instance))))
            self.supabase = client
            self.instance = instance
            self.isConnected = true
            InstanceConfig.stored = (instance: instance, meta: meta)
            observeAuthState(client)

            // A prior session may already be in the Keychain: surface it so a relaunch lands signed
            // in without re-prompting. A nil session must clear any previous instance's email so the
            // user lands on sign-in rather than a phantom signed-in state.
            let sessionEmail = (try? await client.auth.session)?.user.email
            setSession(email: Self.resolvedEmail(priorEmail: userEmail, sessionEmail: sessionEmail))
            if sessionEmail != nil { fireHeartbeat() }
        } catch {
            // A failed (re)connect must not leave a stale client reporting connected, nor a
            // signed-in phase with no client behind it. Clearing the session drops the app to the
            // sign-in screen, whose auto-connect recovers against the still-stored instance.
            self.supabase = nil
            self.instance = nil
            self.isConnected = false
            self.authStateTask?.cancel()
            self.authStateTask = nil
            setSession(email: nil)
            throw error
        }
    }

    /// Re-run the instance-meta fetch (short timeout) and update `isConnected` so the Settings dot
    /// reflects reality when the user is actually looking at it, without any background polling.
    func verifyConnection() async {
        guard let instance else { isConnected = false; return }
        var request = InstanceConfig.metaRequest(instance: instance)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                isConnected = false
                return
            }
            _ = try JSONDecoder().decode(InstanceMeta.self, from: data)
            isConnected = true
        } catch {
            isConnected = false
        }
        // Also touch the session: a server-revoked session only surfaces once a token refresh is
        // attempted, and a menu-bar app may go hours without one. Failing here emits .signedOut
        // through observeAuthState, dropping the app to sign-in while the user is looking.
        if let supabase { _ = try? await supabase.auth.session }
    }

    func signIn(email: String, password: String) async throws {
        guard let supabase else { throw AuthError.notConnected }
        let session = try await supabase.auth.signIn(email: email, password: password)
        setSession(email: session.user.email)
        fireHeartbeat()
    }

    func signInWithGoogle() async throws {
        guard let supabase else { throw AuthError.notConnected }
        pendingAuth = PendingAuth(nonce: UUID().uuidString, startedAt: Date())
        let session = try await supabase.auth.signInWithOAuth(provider: .google, redirectTo: Self.redirectURL)
        setSession(email: session.user.email)
        pendingAuth = nil
        fireHeartbeat()
    }

    /// Abandon an in-flight browser magic-link sign-in so the "waiting on your browser" state can
    /// be cleared: drop the pending marker so a late callback for this attempt no longer binds.
    func cancelBrowserSignIn() {
        pendingAuth = nil
    }

    /// Handle the `minutia://auth-callback` deep link. Two flavors coexist: the browser
    /// magic-link handoff carries `token_hash` and is exchanged via verifyOTP; anything
    /// else is treated as the Google PKCE callback and closed via session(from:).
    @discardableResult
    func handleCallback(_ url: URL) async -> CallbackOutcome {
        guard let supabase else { return .ignored }

        // Bind the callback to a locally-initiated sign-in before touching any token: an attacker
        // can feed a victim a token_hash for the attacker's account, so an unsolicited callback,
        // one that arrives while already signed in, or one whose echoed state does not match must
        // never reach verifyOTP/session(from:).
        let decision = Self.authCallbackDecision(
            alreadySignedIn: userEmail != nil,
            pending: pendingAuth,
            callbackState: Self.state(from: url),
            now: Date())
        if let outcome = Self.preExchangeOutcome(hasClient: true, decision: decision) {
            Self.logger.error("Rejected auth callback: \(String(describing: decision), privacy: .public)")
            // Surface a stale/reused link so the user knows to request a fresh one; an
            // already-signed-in rejection stays silent (the session is fine).
            if let message = Self.rejectionMessage(for: decision) { callbackError = message }
            return outcome
        }

        if let hash = Self.tokenHash(from: url) {
            // The URL can arrive through both onOpenURL and the kAEGetURL Apple event; a token hash
            // is single-use, so the second delivery must not report an error.
            guard Self.tokenHashAction(incoming: hash, lastHandled: lastHandledTokenHash) == .process else {
                return .ignored
            }
            // Reserve the hash synchronously (before the await) so a concurrent double-delivery is
            // deduped to .ignored while the first exchange is still in flight; a failed exchange
            // releases the reservation below so the same link stays retryable.
            lastHandledTokenHash = hash
            do {
                let session = try await supabase.auth.verifyOTP(tokenHash: hash, type: .magiclink)
                setSession(email: session.user.email)
                callbackError = nil
                pendingAuth = nil
                fireHeartbeat()
                return .signedIn(session.user.email)
            } catch {
                // A failed first click must leave the same link retryable, not deduped into a
                // permanent silent no-op: release the reservation (only if it is still ours).
                if !Self.shouldRecordTokenHash(verifySucceeded: false), lastHandledTokenHash == hash {
                    lastHandledTokenHash = nil
                }
                Self.logger.error("Browser sign-in failed: \(error.localizedDescription, privacy: .public)")
                callbackError = error.localizedDescription
                return .failed(error.localizedDescription)
            }
        }
        do {
            let session = try await supabase.auth.session(from: url)
            setSession(email: session.user.email)
            callbackError = nil
            pendingAuth = nil
            fireHeartbeat()
            return .signedIn(session.user.email)
        } catch {
            Self.logger.error("OAuth callback failed: \(error.localizedDescription, privacy: .public)")
            callbackError = error.localizedDescription
            return .failed(error.localizedDescription)
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
        setSession(email: nil)
        // A single-use token hash is scoped to the prior session; clearing it lets a fresh
        // sign-in reuse a hash value without being deduped as a stale delivery.
        lastHandledTokenHash = nil
    }

    enum AuthError: Error {
        case notConnected
        case untrustedInstance
        case notAMinutiaInstance
    }
}
