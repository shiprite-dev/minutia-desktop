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

    private(set) var supabase: SupabaseClient?
    private(set) var instance: URL?
    private var lastHandledTokenHash: String?

    static let redirectURL = URL(string: "minutia://auth-callback")!

    private static let logger = Logger(subsystem: "app.minutia.desktop", category: "AuthManager")

    /// Extracts the magic-link token hash from a `minutia://auth-callback?token_hash=...` URL.
    /// Returns nil for any other URL (notably the Google PKCE callback, which carries `code`).
    static func tokenHash(from url: URL) -> String? {
        guard url.scheme == "minutia", url.host == "auth-callback",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first(where: { $0.name == "token_hash" })?.value
    }

    /// Fetch the instance's public connection details and build the Supabase client.
    /// Rehydrates `userEmail` from any Keychain-persisted session.
    func connect(instance: URL) async throws {
        let (data, _) = try await URLSession.shared.data(for: InstanceConfig.metaRequest(instance: instance))
        let meta = try JSONDecoder().decode(InstanceMeta.self, from: data)

        let client = SupabaseClient(supabaseURL: meta.supabaseUrl, supabaseKey: meta.supabaseAnonKey)
        self.supabase = client
        self.instance = instance
        InstanceConfig.stored = (instance: instance, meta: meta)

        // A prior session may already be in the Keychain: surface it so a relaunch
        // lands signed in without re-prompting.
        if let session = try? await client.auth.session {
            userEmail = session.user.email
            fireHeartbeat()
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
        let session = try await supabase.auth.signInWithOAuth(provider: .google, redirectTo: Self.redirectURL)
        userEmail = session.user.email
        fireHeartbeat()
    }

    /// Handle the `minutia://auth-callback` deep link. Two flavors coexist: the browser
    /// magic-link handoff carries `token_hash` and is exchanged via verifyOTP; anything
    /// else is treated as the Google PKCE callback and closed via session(from:).
    func handleCallback(_ url: URL) async {
        guard let supabase else { return }
        if let hash = Self.tokenHash(from: url) {
            // The URL can arrive through both onOpenURL and the kAEGetURL Apple event;
            // a token hash is single-use, so the second delivery must not report an error.
            guard hash != lastHandledTokenHash else { return }
            lastHandledTokenHash = hash
            do {
                let session = try await supabase.auth.verifyOTP(tokenHash: hash, type: .magiclink)
                userEmail = session.user.email
                callbackError = nil
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
    }
}
