import Foundation

/// Public connection details discovered from a Minutia instance via GET /api/instance-meta.
struct InstanceMeta: Codable, Equatable {
    let name: String
    let supabaseUrl: URL
    let supabaseAnonKey: String
}

/// Instance selection: URL normalization, discovery request, and persistence.
/// Only public data lives here; the session secret stays in the Keychain via supabase-swift.
enum InstanceConfig {
    static var defaults: UserDefaults = .standard
    private static let storageKey = "app.minutia.instance"

    /// The managed cloud instance the companion connects to by default. Self-hosters
    /// change this to their own instance in Settings, which persists and thereafter wins.
    static let defaultInstance = URL(string: "https://app.getminutia.com")!

    /// The instance to auto-connect to: a stored (self-host) choice always wins; the
    /// managed cloud default is only a fallback when nothing has been stored. Reading this
    /// never writes, so it cannot overwrite a stored self-host URL.
    static var resolvedInstance: URL {
        stored?.instance ?? defaultInstance
    }

    static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty else { return nil }
        let isLoopback = host == "localhost" || host == "127.0.0.1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else { return nil }
        components.scheme = scheme
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func metaRequest(instance: URL) -> URLRequest {
        var request = URLRequest(url: instance.appendingPathComponent("api/instance-meta"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private struct Stored: Codable {
        let instance: URL
        let meta: InstanceMeta
    }

    static var stored: (instance: URL, meta: InstanceMeta)? {
        get {
            guard let data = defaults.data(forKey: storageKey),
                  let decoded = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
            return (decoded.instance, decoded.meta)
        }
        set {
            guard let value = newValue,
                  let data = try? JSONEncoder().encode(Stored(instance: value.instance, meta: value.meta)) else {
                defaults.removeObject(forKey: storageKey)
                return
            }
            defaults.set(data, forKey: storageKey)
        }
    }
}
