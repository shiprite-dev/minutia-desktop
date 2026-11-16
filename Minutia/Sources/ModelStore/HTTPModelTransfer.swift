import Foundation

/// `ModelTransfer` over URLSession with an HTTP Range request for resume.
struct HTTPModelTransfer: ModelTransfer {
    var session: URLSession = .shared
    var chunkSize = 1 << 20

    func fetch(_ url: URL, appendingTo partial: URL, from offset: Int64,
               progress: @escaping @Sendable (Int64) -> Void) async throws {
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 else {
            throw URLError(.badServerResponse)
        }
        let appending = http.statusCode == 206 && offset > 0
        let fm = FileManager.default
        try fm.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !appending || !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        var size = appending ? Int64(try handle.seekToEnd()) : 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        func flush() throws {
            try handle.write(contentsOf: buffer)
            size += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            progress(size)
        }
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 20 { try flush() }
            }
        } catch {
            try? flush()
            throw error
        }
        try flush()
    }
}
