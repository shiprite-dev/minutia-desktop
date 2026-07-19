import XCTest
@testable import Minutia

/// Parsing of the `minutia://` deep links the browser hands the companion. The record link is
/// the new capture-trigger contract; the auth-callback cases must keep parsing unchanged.
final class DeepLinkTests: XCTestCase {
    private let lower = "0f9c2c9a-1a2b-4c3d-8e4f-5a6b7c8d9e0f"

    func test_record_validUuid() {
        let url = URL(string: "minutia://record?meeting_id=\(lower)")!
        XCTAssertEqual(DeepLink.parse(url), .record(meetingId: lower))
    }

    func test_record_uppercaseUuidIsLowercased() {
        let url = URL(string: "minutia://record?meeting_id=\(lower.uppercased())")!
        XCTAssertEqual(DeepLink.parse(url), .record(meetingId: lower))
    }

    func test_record_missingId_isInvalid() {
        XCTAssertEqual(DeepLink.parse(URL(string: "minutia://record")!), .invalid)
        XCTAssertEqual(DeepLink.parse(URL(string: "minutia://record?meeting_id=")!), .invalid)
    }

    func test_record_malformedId_isInvalid() {
        XCTAssertEqual(
            DeepLink.parse(URL(string: "minutia://record?meeting_id=not-a-uuid")!), .invalid)
        XCTAssertEqual(
            DeepLink.parse(URL(string: "minutia://record?meeting_id=\(lower)-extra")!), .invalid)
    }

    func test_authCallback_tokenHashStillParses() {
        let url = URL(string: "minutia://auth-callback?token_hash=abc123")!
        XCTAssertEqual(DeepLink.parse(url), .authCallback(tokenHash: "abc123", state: nil))
    }

    func test_authCallback_withoutTokenHash_isPkceFlavor() {
        let url = URL(string: "minutia://auth-callback?code=xyz")!
        XCTAssertEqual(DeepLink.parse(url), .authCallback(tokenHash: nil, state: nil))
    }

    func test_authCallback_carriesStateWhenPresent() {
        let url = URL(string: "minutia://auth-callback?token_hash=abc123&state=nonce-9")!
        XCTAssertEqual(DeepLink.parse(url), .authCallback(tokenHash: "abc123", state: "nonce-9"))
    }

    func test_unknownHostAndScheme_areInvalid() {
        XCTAssertEqual(DeepLink.parse(URL(string: "minutia://frobnicate?x=1")!), .invalid)
        XCTAssertEqual(DeepLink.parse(URL(string: "https://record?meeting_id=\(lower)")!), .invalid)
    }
}
