import XCTest
@testable import Minutia

/// The S2 session-fixation gate: an inbound `minutia://auth-callback` is honored only when it
/// binds to a locally-initiated sign-in that is still pending, not already signed in, and (once
/// the server echoes it) carries a matching state nonce.
@MainActor
final class AuthCallbackDecisionTests: XCTestCase {
    private let now = Date()

    private func pending(_ nonce: String = "nonce-1", ageSeconds: TimeInterval = 10) -> AuthManager.PendingAuth {
        AuthManager.PendingAuth(nonce: nonce, startedAt: now.addingTimeInterval(-ageSeconds))
    }

    func test_alreadySignedIn_rejects() {
        XCTAssertEqual(
            AuthManager.authCallbackDecision(
                alreadySignedIn: true, pending: pending(), callbackState: nil, now: now),
            .rejectAlreadySignedIn)
    }

    func test_alreadySignedIn_takesPrecedenceOverEverything() {
        XCTAssertEqual(
            AuthManager.authCallbackDecision(
                alreadySignedIn: true, pending: nil, callbackState: "mismatch", now: now),
            .rejectAlreadySignedIn)
    }

    func test_nilPending_rejects() {
        XCTAssertEqual(
            AuthManager.authCallbackDecision(
                alreadySignedIn: false, pending: nil, callbackState: nil, now: now),
            .rejectNoPendingFlow)
    }

    func test_expiredPending_rejects() {
        XCTAssertEqual(
            AuthManager.authCallbackDecision(
                alreadySignedIn: false, pending: pending(ageSeconds: 901), callbackState: nil, now: now),
            .rejectNoPendingFlow)
    }

    func test_futureDatedPending_rejects() {
        XCTAssertEqual(
            AuthManager.authCallbackDecision(
                alreadySignedIn: false, pending: pending(ageSeconds: -10), callbackState: nil, now: now),
            .rejectNoPendingFlow)
    }

    func test_stateMismatch_rejects() {
        XCTAssertEqual(
            AuthManager.authCallbackDecision(
                alreadySignedIn: false, pending: pending("nonce-1"), callbackState: "other", now: now),
            .rejectStateMismatch)
    }

    func test_validPendingNilState_accepts() {
        XCTAssertEqual(
            AuthManager.authCallbackDecision(
                alreadySignedIn: false, pending: pending(), callbackState: nil, now: now),
            .accept)
    }

    func test_validPendingMatchingState_accepts() {
        XCTAssertEqual(
            AuthManager.authCallbackDecision(
                alreadySignedIn: false, pending: pending("nonce-1"), callbackState: "nonce-1", now: now),
            .accept)
    }

    func test_boundaryAtTtl_accepts() {
        XCTAssertEqual(
            AuthManager.authCallbackDecision(
                alreadySignedIn: false, pending: pending(ageSeconds: 900), callbackState: nil, now: now),
            .accept)
    }

    func test_state_extractsFromCallback() {
        XCTAssertEqual(AuthManager.state(from: URL(string: "minutia://auth-callback?state=xyz")!), "xyz")
    }

    func test_state_nilWhenAbsent() {
        XCTAssertNil(AuthManager.state(from: URL(string: "minutia://auth-callback?token_hash=abc")!))
    }

    func test_state_nilForForeignURL() {
        XCTAssertNil(AuthManager.state(from: URL(string: "https://example.com?state=xyz")!))
        XCTAssertNil(AuthManager.state(from: URL(string: "minutia://other?state=xyz")!))
    }
}
