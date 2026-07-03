import XCTest
@testable import Minutia

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
