import XCTest
@testable import Minutia

/// Pure security deciders folded out of the controller and instance config: the record-consent
/// TTL gate (S1) and the discovered-supabaseUrl trust gate (S3), tested in isolation.
final class RecordConsentValidityTests: XCTestCase {
    func test_isRecordConsentValid_trueWithinTtl() {
        let now = Date()
        XCTAssertTrue(AppController.isRecordConsentValid(requestedAt: now.addingTimeInterval(-60), now: now))
    }

    func test_isRecordConsentValid_trueAtTtlBoundary() {
        let now = Date()
        XCTAssertTrue(AppController.isRecordConsentValid(requestedAt: now.addingTimeInterval(-120), now: now))
    }

    func test_isRecordConsentValid_falsePastTtl() {
        let now = Date()
        XCTAssertFalse(AppController.isRecordConsentValid(requestedAt: now.addingTimeInterval(-121), now: now))
    }

    func test_isRecordConsentValid_falseForClockSkew() {
        // requestedAt in the future (negative elapsed) must never validate.
        let now = Date()
        XCTAssertFalse(AppController.isRecordConsentValid(requestedAt: now.addingTimeInterval(10), now: now))
    }
}

final class SupabaseURLValidationTests: XCTestCase {
    private let cloud = URL(string: "https://app.getminutia.com")!
    private let localhost = URL(string: "http://localhost:3000")!

    func test_httpsAllowedForCloudInstance() {
        XCTAssertTrue(InstanceConfig.isValidSupabaseURL(URL(string: "https://sb.example.com")!, instance: cloud))
    }

    func test_httpRejectedForCloudInstance() {
        XCTAssertFalse(InstanceConfig.isValidSupabaseURL(URL(string: "http://attacker.example.com")!, instance: cloud))
    }

    func test_httpAllowedForLoopbackInstance() {
        XCTAssertTrue(InstanceConfig.isValidSupabaseURL(URL(string: "http://localhost:54321")!, instance: localhost))
    }

    func test_nonHttpSchemeRejected() {
        XCTAssertFalse(InstanceConfig.isValidSupabaseURL(URL(string: "ftp://sb.example.com")!, instance: cloud))
    }

    func test_missingHostRejected() {
        XCTAssertFalse(InstanceConfig.isValidSupabaseURL(URL(string: "https:///path")!, instance: cloud))
    }
}
