import Foundation

/// A parsed `minutia://` deep link. The scheme and query shapes are a wire contract with the
/// web app's `companion-links` module; keep the two in sync. Meeting ids are lowercased because
/// the storage RLS paths are lowercase and case-sensitive.
enum DeepLink: Equatable {
    /// `minutia://auth-callback?token_hash=...` (browser magic link) or the Google PKCE
    /// callback (host `auth-callback`, carrying `code` instead). `tokenHash` is nil for PKCE.
    case authCallback(tokenHash: String?)
    /// `minutia://record?meeting_id=<uuid>`. The id is uuid-validated and lowercased.
    case record(meetingId: String)
    case invalid

    static func parse(_ url: URL) -> DeepLink {
        guard url.scheme == "minutia",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return .invalid }

        func query(_ name: String) -> String? {
            components.queryItems?.first(where: { $0.name == name })?.value
        }

        switch url.host {
        case "auth-callback":
            return .authCallback(tokenHash: query("token_hash"))
        case "record":
            guard let raw = query("meeting_id"), let uuid = UUID(uuidString: raw) else {
                return .invalid
            }
            return .record(meetingId: uuid.uuidString.lowercased())
        default:
            return .invalid
        }
    }
}
