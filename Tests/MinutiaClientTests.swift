import XCTest
@testable import Minutia
import Supabase

/// Minimal URLProtocol stub for exercising MinutiaClient's URLSession.shared calls
/// without hitting the network. Registered/unregistered per test case.
final class URLProtocolStub: URLProtocol {
    static var responseHandler: ((URLRequest) -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = URLProtocolStub.responseHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (data, response) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeStubbedClient() -> MinutiaClient {
    MinutiaClient(
        instance: URL(string: "https://minutia.example.com")!,
        supabase: SupabaseClient(supabaseURL: URL(string: "https://supabase.example.com")!, supabaseKey: "anon-key"),
        tokenProvider: { "test-access-token" }
    )
}

final class InstanceConfigNormalizeTests: XCTestCase {
    func test_normalize_addsHttpsWhenNoScheme() {
        XCTAssertEqual(InstanceConfig.normalize("minutia.example.com"), URL(string: "https://minutia.example.com"))
    }

    func test_normalize_trimsWhitespace() {
        XCTAssertEqual(InstanceConfig.normalize("  minutia.example.com  "), URL(string: "https://minutia.example.com"))
    }

    func test_normalize_stripsTrailingSlash() {
        XCTAssertEqual(InstanceConfig.normalize("https://minutia.example.com/"), URL(string: "https://minutia.example.com"))
    }

    func test_normalize_stripsPath() {
        XCTAssertEqual(InstanceConfig.normalize("https://minutia.example.com/login"), URL(string: "https://minutia.example.com"))
    }

    func test_normalize_rejectsNonHttpScheme() {
        XCTAssertNil(InstanceConfig.normalize("ftp://minutia.example.com"))
    }

    func test_normalize_rejectsHttpForNonLocalHost() {
        XCTAssertNil(InstanceConfig.normalize("http://minutia.example.com"))
    }

    func test_normalize_allowsHttpForLocalhost() {
        XCTAssertEqual(InstanceConfig.normalize("http://localhost:3000"), URL(string: "http://localhost:3000"))
    }

    func test_normalize_allowsHttpForLoopbackIP() {
        XCTAssertEqual(InstanceConfig.normalize("http://127.0.0.1:3000"), URL(string: "http://127.0.0.1:3000"))
    }

    func test_normalize_rejectsEmptyString() {
        XCTAssertNil(InstanceConfig.normalize("   "))
    }
}

final class InstanceConfigMetaRequestTests: XCTestCase {
    func test_metaRequest_buildsGetRequestWithJsonAccept() {
        let instance = URL(string: "https://minutia.example.com")!
        let request = InstanceConfig.metaRequest(instance: instance)

        XCTAssertEqual(request.url, URL(string: "https://minutia.example.com/api/instance-meta"))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }
}

final class InstanceMetaDecodingTests: XCTestCase {
    func test_instanceMeta_decodesFixtureJson() throws {
        let json = """
        {"name":"Minutia","supabaseUrl":"https://supabase.example.com","supabaseAnonKey":"anon-key-value"}
        """.data(using: .utf8)!

        let meta = try JSONDecoder().decode(InstanceMeta.self, from: json)

        XCTAssertEqual(meta, InstanceMeta(
            name: "Minutia",
            supabaseUrl: URL(string: "https://supabase.example.com")!,
            supabaseAnonKey: "anon-key-value"
        ))
    }

    func test_instanceMeta_rejectsHtmlResponse() {
        let html = "<html><body>Not JSON</body></html>".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(InstanceMeta.self, from: html))
    }

    func test_instanceMeta_rejectsSetupIncompleteError() {
        let json = """
        {"error":"Setup incomplete."}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(InstanceMeta.self, from: json))
    }
}

final class MinutiaClientBuilderTests: XCTestCase {
    private let instance = URL(string: "https://minutia.example.com")!
    private let token = "test-access-token"

    private func jsonBody(_ request: URLRequest) -> NSDictionary? {
        guard let body = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) else { return nil }
        return object as? NSDictionary
    }

    func test_segmentPath_buildsMeetingScopedM4aPath() {
        XCTAssertEqual(MinutiaClient.segmentPath(meetingId: "m1", seq: 0), "m1/seg-0.m4a")
        XCTAssertEqual(MinutiaClient.segmentPath(meetingId: "abc", seq: 12), "abc/seg-12.m4a")
    }

    // Storage RLS compares the path's meeting folder to the lowercase canonical id case-sensitively,
    // so a Swift UUID.uuidString (uppercase) must be lowercased before it reaches storage or a route.
    private let upperUUID = "EDA64C8E-901A-4B7C-8F21-0A1B2C3D4E5F"
    private let lowerUUID = "eda64c8e-901a-4b7c-8f21-0a1b2c3d4e5f"

    func test_segmentPath_lowercasesUppercaseMeetingId() {
        XCTAssertEqual(MinutiaClient.segmentPath(meetingId: upperUUID, seq: 3), "\(lowerUUID)/seg-3.m4a")
    }

    func test_recordingPath_lowercasesUppercaseMeetingId() {
        XCTAssertEqual(MinutiaClient.recordingPath(meetingId: upperUUID), "\(lowerUUID)/recording.m4a")
    }

    func test_registerSegmentRequest_lowercasesRouteAndBodyPath() {
        let request = MinutiaClient.registerSegmentRequest(instance: instance, meetingId: upperUUID, seq: 0, token: token)

        XCTAssertEqual(request.url, URL(string: "https://minutia.example.com/api/meetings/\(lowerUUID)/segments/0/transcribe"))
        XCTAssertEqual(jsonBody(request), ["path": "\(lowerUUID)/seg-0.m4a"] as NSDictionary)
    }

    func test_finalTranscribeRequest_lowercasesRoute() {
        let request = MinutiaClient.finalTranscribeRequest(instance: instance, meetingId: upperUUID, expectedSegments: nil, token: token)

        XCTAssertEqual(request.url, URL(string: "https://minutia.example.com/api/meetings/\(lowerUUID)/transcribe"))
    }

    func test_summaryWarmupRequest_lowercasesRoute() {
        let request = MinutiaClient.summaryWarmupRequest(instance: instance, meetingId: upperUUID, token: token)

        XCTAssertEqual(request.url, URL(string: "https://minutia.example.com/api/meetings/\(lowerUUID)/summary/stream"))
    }

    func test_registerSegmentRequest_hasContractPathHeadersAndBody() {
        let request = MinutiaClient.registerSegmentRequest(instance: instance, meetingId: "m1", seq: 0, token: token)

        XCTAssertEqual(request.url, URL(string: "https://minutia.example.com/api/meetings/m1/segments/0/transcribe"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(jsonBody(request), ["path": "m1/seg-0.m4a"] as NSDictionary)
    }

    func test_finalTranscribeRequest_withExpectedSegments_sendsCount() {
        let request = MinutiaClient.finalTranscribeRequest(instance: instance, meetingId: "m1", expectedSegments: 3, token: token)

        XCTAssertEqual(request.url, URL(string: "https://minutia.example.com/api/meetings/m1/transcribe"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(jsonBody(request), ["expected_segments": 3] as NSDictionary)
    }

    func test_finalTranscribeRequest_withNilExpectedSegments_sendsEmptyBody() {
        let request = MinutiaClient.finalTranscribeRequest(instance: instance, meetingId: "m1", expectedSegments: nil, token: token)

        XCTAssertEqual(jsonBody(request), [:] as NSDictionary)
    }

    func test_summaryWarmupRequest_hasContractPathAndHeaders() {
        let request = MinutiaClient.summaryWarmupRequest(instance: instance, meetingId: "m1", token: token)

        XCTAssertEqual(request.url, URL(string: "https://minutia.example.com/api/meetings/m1/summary/stream"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
    }

    func test_agendaRequest_hasContractPathAndHeaders() {
        let request = MinutiaClient.agendaRequest(instance: instance, token: token)

        XCTAssertEqual(request.url, URL(string: "https://minutia.example.com/api/calendar/agenda"))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
    }

    func test_heartbeatRequest_hasContractPathAndHeaders() {
        let request = MinutiaClient.heartbeatRequest(instance: instance, token: token)

        XCTAssertEqual(request.url, URL(string: "https://minutia.example.com/api/companion/heartbeat"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
    }

    func test_companionAuthorizeURL_percentEncodesDeviceName() {
        let url = MinutiaClient.companionAuthorizeURL(instance: instance, device: "Pratik's MacBook Pro")

        XCTAssertEqual(
            url.absoluteString,
            "https://minutia.example.com/companion/authorize?device=Pratik's%20MacBook%20Pro")
    }

    func test_companionAuthorizeURL_plainDeviceName() {
        let url = MinutiaClient.companionAuthorizeURL(instance: instance, device: "studio")

        XCTAssertEqual(url.absoluteString, "https://minutia.example.com/companion/authorize?device=studio")
    }

    func test_companionAuthorizeURL_appendsStateWhenProvided() {
        let url = MinutiaClient.companionAuthorizeURL(instance: instance, device: "studio", state: "nonce-7")

        XCTAssertEqual(
            url.absoluteString,
            "https://minutia.example.com/companion/authorize?device=studio&state=nonce-7")
    }
}

final class AgendaItemDecodingTests: XCTestCase {
    func test_agendaItem_decodesCamelCaseFixtureWithFractionalAndPlainDates() throws {
        let json = """
        {"seriesId":"11111111-1111-1111-1111-111111111111","meetingId":"22222222-2222-2222-2222-222222222222","title":"Weekly sync","startAt":"2026-07-03T10:00:00.000Z","endAt":"2026-07-03T11:00:00Z","meetingUrl":"https://meet.example.com/abc"}
        """.data(using: .utf8)!

        let item = try MinutiaClient.jsonDecoder.decode(AgendaItem.self, from: json)

        XCTAssertEqual(item.seriesId, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(item.meetingId, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        XCTAssertEqual(item.title, "Weekly sync")
        XCTAssertEqual(item.meetingUrl, "https://meet.example.com/abc")

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(item.startAt, fractional.date(from: "2026-07-03T10:00:00.000Z"))
        XCTAssertEqual(item.endAt, plain.date(from: "2026-07-03T11:00:00Z"))
    }

    func test_agendaItem_decodesNullOptionalFields() throws {
        let json = """
        {"seriesId":null,"meetingId":null,"title":"Ad hoc","startAt":"2026-07-03T09:00:00Z","endAt":"2026-07-03T09:30:00Z","meetingUrl":null}
        """.data(using: .utf8)!

        let item = try MinutiaClient.jsonDecoder.decode(AgendaItem.self, from: json)

        XCTAssertNil(item.seriesId)
        XCTAssertNil(item.meetingId)
        XCTAssertNil(item.meetingUrl)
        XCTAssertEqual(item.title, "Ad hoc")
    }

    func test_agendaItem_rejectsInvalidDate() {
        let json = """
        {"title":"Bad","startAt":"not-a-date","endAt":"2026-07-03T09:30:00Z"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try MinutiaClient.jsonDecoder.decode(AgendaItem.self, from: json))
    }
}

final class AgendaEnvelopeDecodingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(URLProtocolStub.self)
    }

    override func tearDown() {
        URLProtocolStub.responseHandler = nil
        URLProtocol.unregisterClass(URLProtocolStub.self)
        super.tearDown()
    }

    private func stub(status: Int = 200, body: Data) {
        URLProtocolStub.responseHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }

    func test_agenda_decodesEnvelopeAndReturnsEvents() async throws {
        let json = """
        {"connected":true,"syncedAt":"2026-07-03T12:00:00.000Z","syncMode":"incremental","events":[{"id":"x1","calendarId":"primary","eventId":"e1","seriesId":"7d9a1c1e-1111-2222-3333-444455556666","meetingId":null,"seriesKind":"recurring","title":"Weekly Sync","description":null,"startAt":"2026-07-03T10:00:00-07:00","endAt":"2026-07-03T11:00:00-07:00","htmlLink":null,"meetingUrl":"https://meet.example.com/abc","attendeeEmails":[],"organizerEmail":null,"eventType":"default","eventStatus":"confirmed","meetingStatus":"upcoming"}]}
        """.data(using: .utf8)!
        stub(body: json)

        let events = try await makeStubbedClient().agenda()

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].seriesId, UUID(uuidString: "7d9a1c1e-1111-2222-3333-444455556666"))
        XCTAssertNil(events[0].meetingId)
        XCTAssertEqual(events[0].meetingUrl, "https://meet.example.com/abc")

        let offsetFormatter = ISO8601DateFormatter()
        offsetFormatter.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(events[0].startAt, offsetFormatter.date(from: "2026-07-03T10:00:00-07:00"))
    }

    func test_agenda_disconnectedEnvelopeDecodesToEmptyEvents() async throws {
        let json = """
        {"connected":false,"events":[]}
        """.data(using: .utf8)!
        stub(body: json)

        let events = try await makeStubbedClient().agenda()
        XCTAssertTrue(events.isEmpty)
    }
}

final class RegisterSegmentStatusMappingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(URLProtocolStub.self)
    }

    override func tearDown() {
        URLProtocolStub.responseHandler = nil
        URLProtocol.unregisterClass(URLProtocolStub.self)
        super.tearDown()
    }

    private func stub(status: Int) {
        URLProtocolStub.responseHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
    }

    /// 2xx/409 succeed; 503 and all other 4xx give up (false, terminal); 5xx (other than 503) retry (throw).
    func test_registerSegment_mapsEachStatusToContractResult() async {
        let expected: [Int: Bool?] = [
            200: true, 409: true,
            400: false, 402: false, 403: false, 404: false, 415: false, 503: false,
            500: nil, 502: nil,
        ]

        for (status, outcome) in expected {
            stub(status: status)
            switch outcome {
            case .some(let value):
                do {
                    let result = try await makeStubbedClient().registerSegment(meetingId: "m1", seq: 0)
                    XCTAssertEqual(result, value, "status \(status)")
                } catch {
                    XCTFail("status \(status) unexpectedly threw \(error)")
                }
            case .none:
                do {
                    _ = try await makeStubbedClient().registerSegment(meetingId: "m1", seq: 0)
                    XCTFail("status \(status) expected to throw")
                } catch let error as MinutiaClientError {
                    guard case .serverError(let thrownStatus) = error else {
                        return XCTFail("status \(status) threw unexpected error \(error)")
                    }
                    XCTAssertEqual(thrownStatus, status)
                } catch {
                    XCTFail("status \(status) threw unexpected error \(error)")
                }
            }
        }
    }
}

final class RequestTranscriptionStatusTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(URLProtocolStub.self)
    }

    override func tearDown() {
        URLProtocolStub.responseHandler = nil
        URLProtocol.unregisterClass(URLProtocolStub.self)
        super.tearDown()
    }

    private func stub(status: Int) {
        URLProtocolStub.responseHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
    }

    func test_requestTranscription_doesNotThrowOnNon5xxOr503() async {
        for status in [200, 400, 404, 503] {
            stub(status: status)
            do {
                try await makeStubbedClient().requestTranscription(meetingId: "m1", expectedSegments: nil)
            } catch {
                XCTFail("status \(status) unexpectedly threw \(error)")
            }
        }
    }

    func test_requestTranscription_throwsOn5xxExceptFor503() async {
        for status in [500, 502] {
            stub(status: status)
            do {
                try await makeStubbedClient().requestTranscription(meetingId: "m1", expectedSegments: nil)
                XCTFail("status \(status) expected to throw")
            } catch let error as MinutiaClientError {
                guard case .serverError(let thrownStatus) = error else {
                    return XCTFail("status \(status) threw unexpected error \(error)")
                }
                XCTAssertEqual(thrownStatus, status)
            } catch {
                XCTFail("status \(status) threw unexpected error \(error)")
            }
        }
    }
}

final class SignInFormTests: XCTestCase {
    func test_canSubmit_trueForValidEmailAndPassword() {
        XCTAssertTrue(SignInView.canSubmit(email: "user@example.com", password: "hunter2"))
    }

    func test_canSubmit_falseForEmailWithoutAtSign() {
        XCTAssertFalse(SignInView.canSubmit(email: "user.example.com", password: "hunter2"))
    }

    func test_canSubmit_falseForEmailWithoutDomainDot() {
        XCTAssertFalse(SignInView.canSubmit(email: "user@example", password: "hunter2"))
    }

    func test_canSubmit_falseForEmptyPassword() {
        XCTAssertFalse(SignInView.canSubmit(email: "user@example.com", password: ""))
    }

    func test_canSubmit_falseForWhitespacePassword() {
        XCTAssertFalse(SignInView.canSubmit(email: "user@example.com", password: "   "))
    }

    func test_canSubmit_falseForEmptyEmail() {
        XCTAssertFalse(SignInView.canSubmit(email: "  ", password: "hunter2"))
    }
}

final class AuthRedirectTests: XCTestCase {
    func test_redirectURL_isMinutiaAuthCallback() {
        XCTAssertEqual(AuthManager.redirectURL, URL(string: "minutia://auth-callback"))
    }

    func test_redirectURL_roundTripsThroughURLComponents() {
        let components = URLComponents(url: AuthManager.redirectURL, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.scheme, "minutia")
        XCTAssertEqual(components?.host, "auth-callback")
    }

    @MainActor
    func test_tokenHash_extractsFromBrowserCallback() {
        let url = URL(string: "minutia://auth-callback?token_hash=abc-123")!
        XCTAssertEqual(AuthManager.tokenHash(from: url), "abc-123")
    }

    @MainActor
    func test_tokenHash_nilForPKCECodeCallback() {
        let url = URL(string: "minutia://auth-callback?code=pkce-code")!
        XCTAssertNil(AuthManager.tokenHash(from: url))
    }

    @MainActor
    func test_tokenHash_nilForForeignURL() {
        XCTAssertNil(AuthManager.tokenHash(from: URL(string: "https://example.com?token_hash=abc")!))
        XCTAssertNil(AuthManager.tokenHash(from: URL(string: "minutia://other?token_hash=abc")!))
    }
}

final class InstanceConfigStoredTests: XCTestCase {
    private var suiteName = ""
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "app.minutia.instance.tests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)
        InstanceConfig.defaults = testDefaults
    }

    override func tearDown() {
        InstanceConfig.defaults = .standard
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        super.tearDown()
    }

    func test_stored_defaultsToNil() {
        XCTAssertNil(InstanceConfig.stored)
    }

    func test_stored_roundTripsInstanceAndMeta() {
        let instance = URL(string: "https://minutia.example.com")!
        let meta = InstanceMeta(
            name: "Minutia",
            supabaseUrl: URL(string: "https://supabase.example.com")!,
            supabaseAnonKey: "anon-key-value"
        )

        InstanceConfig.stored = (instance: instance, meta: meta)
        let readBack = InstanceConfig.stored

        XCTAssertEqual(readBack?.instance, instance)
        XCTAssertEqual(readBack?.meta, meta)
    }
}

/// The auto-connect fallback decision: the managed cloud default is used only when nothing is
/// stored; a stored self-host instance always wins and is never overwritten by reading it.
final class InstanceConfigResolvedTests: XCTestCase {
    private var suiteName = ""
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "app.minutia.instance.resolved.tests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)
        InstanceConfig.defaults = testDefaults
    }

    override func tearDown() {
        InstanceConfig.defaults = .standard
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        super.tearDown()
    }

    private func storeSelfHost() -> URL {
        let instance = URL(string: "https://oil.internal.example.com")!
        let meta = InstanceMeta(
            name: "Self Host",
            supabaseUrl: URL(string: "https://sb.internal.example.com")!,
            supabaseAnonKey: "anon"
        )
        InstanceConfig.stored = (instance: instance, meta: meta)
        return instance
    }

    func test_defaultInstance_isManagedCloud() {
        XCTAssertEqual(InstanceConfig.defaultInstance, URL(string: "https://app.getminutia.com"))
    }

    func test_resolved_usesDefaultWhenNothingStored() {
        XCTAssertNil(InstanceConfig.stored)
        XCTAssertEqual(InstanceConfig.resolvedInstance, InstanceConfig.defaultInstance)
    }

    func test_resolved_prefersStoredSelfHostOverDefault() {
        let instance = storeSelfHost()
        XCTAssertEqual(InstanceConfig.resolvedInstance, instance)
        XCTAssertNotEqual(InstanceConfig.resolvedInstance, InstanceConfig.defaultInstance)
    }

    func test_resolved_doesNotOverwriteStored() {
        let instance = storeSelfHost()
        _ = InstanceConfig.resolvedInstance
        XCTAssertEqual(InstanceConfig.stored?.instance, instance)
    }
}
