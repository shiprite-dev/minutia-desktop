import Foundation
import OSLog
import Supabase

/// Owns the Supabase session: instance discovery, sign-in (password + Google PKCE),
/// and the OAuth callback. supabase-swift persists the session in the Keychain by
/// default, so nothing here writes the secret to disk.
@MainActor
final class AuthManager: ObservableObject {
    @Published private(set) var userEmail: String?

    private(set) var supabase: SupabaseClient?
    private(set) var instance: URL?

    static let redirectURL = URL(string: "minutia://auth-callback")!

    private static let logger = Logger(subsystem: "app.minutia.desktop", category: "AuthManager")

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
        }
    }

    func signIn(email: String, password: String) async throws {
        guard let supabase else { throw AuthError.notConnected }
        let session = try await supabase.auth.signIn(email: email, password: password)
        userEmail = session.user.email
    }

    func signInWithGoogle() async throws {
        guard let supabase else { throw AuthError.notConnected }
        let session = try await supabase.auth.signInWithOAuth(provider: .google, redirectTo: Self.redirectURL)
        userEmail = session.user.email
    }

    /// Handle the `minutia://auth-callback` deep link that closes the PKCE loop.
    func handleCallback(_ url: URL) async {
        guard let supabase else { return }
        do {
            let session = try await supabase.auth.session(from: url)
            userEmail = session.user.email
        } catch {
            Self.logger.error("OAuth callback failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The current access token; supabase-swift refreshes it transparently.
    func accessToken() async throws -> String {
        guard let supabase else { throw AuthError.notConnected }
        return try await supabase.auth.session.accessToken
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
