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
