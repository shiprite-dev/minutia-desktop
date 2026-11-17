import Foundation
import Supabase

/// The default session storage is the login Keychain; an ad-hoc test build has a new code signature on
/// every run, so each read pops a Keychain access prompt (and hangs the headless runner).
final class InMemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

func testSupabase(_ url: URL) -> SupabaseClient {
    SupabaseClient(supabaseURL: url, supabaseKey: "anon-key", options: .init(auth: .init(storage: InMemoryAuthStorage())))
}
