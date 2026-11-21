import Foundation
import Network

/// A real HTTP/1.1 server on 127.0.0.1 so a WKWebView (which runs its networking out of process and
/// never sees URLProtocol stubs) talks to it over a socket. Every request is recorded with its raw
/// header lines, exactly as they arrived.
final class LocalWebServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let query: String?
        let headerLines: [String]
        let body: Data

        func header(_ name: String) -> String? {
            headerLines.first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
                .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
        }

        var form: [String: String] {
            var fields: [String: String] = [:]
            for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if parts.count == 2 { fields[parts[0]] = parts[1] }
            }
            return fields
        }
    }

    indirect enum Reply {
        case respond(status: Int, headers: [String: String], body: String)
        /// Hold the connection open with no answer.
        case hang
        /// Close the connection without answering, as a dropped network does.
        case drop
        /// Answer after a delay, as a slow server does.
        case delayed(TimeInterval, Reply)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalWebServer")
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var held: [NWConnection] = []
    private var route: (Request) -> Reply = { _ in .respond(status: 404, headers: [:], body: "") }
    private(set) var base: URL!

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [listener] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        base = URL(string: "http://127.0.0.1:\(port)")!
        return base
    }

    func stop() {
        listener.cancel()
        lock.withLock { held }.forEach { $0.cancel() }
    }

    func handle(_ route: @escaping (Request) -> Reply) { lock.withLock { self.route = route } }

    var requests: [Request] { lock.withLock { recorded } }

    func requests(_ path: String) -> [Request] { requests.filter { $0.path == path } }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.answer(request, on: connection)
            } else if done || error != nil {
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    private static func parse(_ buffer: Data) -> Request? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let lines = Array(head.dropFirst())
        let length = lines.first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        let start = head[0].split(separator: " ")
        let target = start.count > 1 ? String(start[1]) : "/"
        let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
        return Request(method: String(start.first ?? ""), path: parts[0], query: parts.count > 1 ? parts[1] : nil,
                       headerLines: lines, body: Data(body.prefix(length)))
    }

    private func answer(_ request: Request, on connection: NWConnection) {
        let reply = lock.withLock { () -> Reply in
            recorded.append(request)
            return route(request)
        }
        send(reply, on: connection)
    }

    private func send(_ reply: Reply, on connection: NWConnection) {
        switch reply {
        case .hang:
            lock.withLock { held.append(connection) }
        case .drop:
            connection.cancel()
        case .delayed(let seconds, let later):
            queue.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.send(later, on: connection) }
        case .respond(let status, let headers, let body):
            var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n"
            for (name, value) in headers { head += "\(name): \(value)\r\n" }
            if headers["Content-Type"] == nil { head += "Content-Type: text/html; charset=utf-8\r\n" }
            connection.send(content: Data((head + "\r\n" + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func reason(_ status: Int) -> String {
        [200: "OK", 302: "Found", 303: "See Other", 401: "Unauthorized", 404: "Not Found", 429: "Too Many Requests"][status] ?? "Status"
    }
}
