import XCTest
@testable import Minutia

/// Local server double: serves `body`, answering a `Range: bytes=N-` request with 206 and the tail,
/// or with 200 and the whole body when `honorsRange` is false. Records the Range header it saw.
private final class RangeServer: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var honorsRange = true
    nonisolated(unsafe) static var lastRange: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range")
        Self.lastRange = range
        var status = 200
        var payload = Self.body
        if Self.honorsRange, let range, range.hasPrefix("bytes="), range.hasSuffix("-"),
           let start = Int(range.dropFirst("bytes=".count).dropLast()) {
            status = 206
            payload = Self.body.subdata(in: start..<Self.body.count)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(payload.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class HTTPModelTransferTests: XCTestCase {
    private var dir: URL!
    private var transfer: HTTPModelTransfer!
    private let url = URL(string: "https://models.example.com/resolve/rev/weight.bin")!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("HTTPModelTransferTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RangeServer.self]
        transfer = HTTPModelTransfer(session: URLSession(configuration: config))
        RangeServer.body = Data((0..<200).map { UInt8($0) })
        RangeServer.honorsRange = true
        RangeServer.lastRange = nil
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func test_resume_sendsARangeHeader_andAppendsTheRestToThePartialFile() async throws {
        let partial = dir.appendingPathComponent("weight.bin.partial")
        try RangeServer.body.prefix(80).write(to: partial)

        try await transfer.fetch(url, appendingTo: partial, from: 80) { _ in }

        XCTAssertEqual(RangeServer.lastRange, "bytes=80-")
        XCTAssertEqual(try Data(contentsOf: partial), RangeServer.body)
    }

    func test_serverIgnoringRange_rewritesThePartialFileFromZero() async throws {
        RangeServer.honorsRange = false
        let partial = dir.appendingPathComponent("weight.bin.partial")
        try RangeServer.body.prefix(80).write(to: partial)

        try await transfer.fetch(url, appendingTo: partial, from: 80) { _ in }

        XCTAssertEqual(try Data(contentsOf: partial), RangeServer.body)
    }

    func test_freshFetch_createsThePartialFile_andReportsItsSize() async throws {
        let partial = dir.appendingPathComponent("nested/weight.bin.partial")
        let last = LastValue()

        try await transfer.fetch(url, appendingTo: partial, from: 0) { last.set($0) }

        XCTAssertNil(RangeServer.lastRange, "a fetch from zero sends no Range header")
        XCTAssertEqual(try Data(contentsOf: partial), RangeServer.body)
        XCTAssertEqual(last.value, 200)
    }
}

private final class LastValue: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int64 = -1
    var value: Int64 { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: Int64) { lock.lock(); _value = v; lock.unlock() }
}
