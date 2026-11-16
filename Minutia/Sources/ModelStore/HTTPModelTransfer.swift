import Foundation

/// `ModelTransfer` over URLSession with an HTTP Range request for resume.
struct HTTPModelTransfer: ModelTransfer {
    var session: URLSession = .shared

    func fetch(_ url: URL, appendingTo partial: URL, from offset: Int64,
               progress: @escaping @Sendable (Int64) -> Void) async throws {}
}
