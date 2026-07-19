import XCTest
@testable import Minutia

/// Pure decision seams for auth + instance identity correctness: post-connect email resolution,
/// per-instance session isolation, differentiated connect-failure copy, the token-hash dedupe and
/// record-on-success rule, the rejected-callback copy, the cold-launch callback outcome mapping,
/// and the auth-state-change signed-out signal.
final class AuthInstanceIdentityTests: XCTestCase {
    private let cloud = URL(string: "https://app.getminutia.com")!
    private let selfHost = URL(string: "https://minutia.acme.com")!

    // MARK: - A2: SessionIdentity equality

    func test_sessionIdentity_equalWhenInstanceAndEmailMatch() {
        XCTAssertEqual(
            AuthManager.SessionIdentity(instance: cloud, email: "a@b.com"),
            AuthManager.SessionIdentity(instance: cloud, email: "a@b.com"))
    }

    func test_sessionIdentity_differsWhenInstanceDiffers() {
        // The whole point of the identity: same email on a different instance is a different
        // session, so the sink must re-run (reload series, rebind the detector).
        XCTAssertNotEqual(
            AuthManager.SessionIdentity(instance: cloud, email: "a@b.com"),
            AuthManager.SessionIdentity(instance: selfHost, email: "a@b.com"))
    }

    func test_sessionIdentity_differsWhenEmailDiffers() {
        XCTAssertNotEqual(
            AuthManager.SessionIdentity(instance: cloud, email: "a@b.com"),
            AuthManager.SessionIdentity(instance: cloud, email: "c@d.com"))
    }

    func test_sessionIdentity_signedOutEqualsSignedOut() {
        XCTAssertEqual(
            AuthManager.SessionIdentity(instance: nil, email: nil),
            AuthManager.SessionIdentity(instance: nil, email: nil))
    }

    // MARK: - A1: post-connect email resolution

    func test_resolvedEmail_nilSessionClearsPriorEmail() {
        // The bug: an instance with no Keychain session left the previous instance's email in
        // place, leaving a phantom signed-in state. The prior email must never survive.
        XCTAssertNil(AuthManager.resolvedEmail(priorEmail: "old@stale.com", sessionEmail: nil))
    }

    func test_resolvedEmail_sessionEmailWins() {
        XCTAssertEqual(
            AuthManager.resolvedEmail(priorEmail: "old@stale.com", sessionEmail: "new@fresh.com"),
            "new@fresh.com")
    }

    func test_resolvedEmail_ignoresPriorWhenNoPrior() {
        XCTAssertEqual(AuthManager.resolvedEmail(priorEmail: nil, sessionEmail: "new@fresh.com"), "new@fresh.com")
        XCTAssertNil(AuthManager.resolvedEmail(priorEmail: nil, sessionEmail: nil))
    }

    // MARK: - A3: per-instance session storage key

    func test_sessionStorageKey_derivedFromHost() {
        XCTAssertEqual(AuthManager.sessionStorageKey(for: cloud), "sb-minutia-app.getminutia.com")
        XCTAssertEqual(AuthManager.sessionStorageKey(for: selfHost), "sb-minutia-minutia.acme.com")
    }

    func test_sessionStorageKey_distinctPerInstance() {
        XCTAssertNotEqual(
            AuthManager.sessionStorageKey(for: cloud),
            AuthManager.sessionStorageKey(for: selfHost))
    }

    func test_sessionStorageKey_noHostEdge() {
        XCTAssertEqual(AuthManager.sessionStorageKey(for: URL(string: "mailto:x")!), "sb-minutia-default")
    }

    // MARK: - A4: differentiated connect-failure copy

    func test_connectFailureMessage_notAMinutiaInstance_namesHost() {
        XCTAssertEqual(
            AuthManager.connectFailureMessage(
                for: AuthManager.AuthError.notAMinutiaInstance, host: "localhost:3000"),
            "localhost:3000 doesn't look like a Minutia instance. Check the address.")
    }

    func test_connectFailureMessage_notAMinutiaInstance_nilHostFallsBack() {
        XCTAssertEqual(
            AuthManager.connectFailureMessage(for: AuthManager.AuthError.notAMinutiaInstance, host: nil),
            "the server doesn't look like a Minutia instance. Check the address.")
    }

    func test_connectFailureMessage_untrustedInstance() {
        // The trust copy names no host and stays exactly as is regardless of the host passed.
        let message = AuthManager.connectFailureMessage(
            for: AuthManager.AuthError.untrustedInstance, host: "minutia.acme.com")
        XCTAssertEqual(message, "This server's configuration isn't trusted. Contact your administrator.")
        // Must never blame the network for a trust failure: retrying/checking internet would loop.
        XCTAssertFalse(message.lowercased().contains("internet"))
        XCTAssertFalse(message.lowercased().contains("try again"))
    }

    func test_connectFailureMessage_urlError_namesHost() {
        XCTAssertEqual(
            AuthManager.connectFailureMessage(for: URLError(.notConnectedToInternet), host: "app.getminutia.com"),
            "Couldn't reach app.getminutia.com. Check your internet connection and try again.")
    }

    func test_connectFailureMessage_unknownError_nilHostFallsBack() {
        let other = NSError(domain: "x", code: 1)
        XCTAssertEqual(
            AuthManager.connectFailureMessage(for: other, host: nil),
            "Couldn't reach the server. Check your internet connection and try again.")
    }

    func test_isRetryableConnectFailure_deterministicVerdictsAreNot() {
        // Untrusted config and not-an-instance cannot change on retry; offering "Try again"
        // would loop the same verdict forever.
        XCTAssertFalse(AuthManager.isRetryableConnectFailure(AuthManager.AuthError.untrustedInstance))
        XCTAssertFalse(AuthManager.isRetryableConnectFailure(AuthManager.AuthError.notAMinutiaInstance))
    }

    func test_isRetryableConnectFailure_transportFailuresAre() {
        XCTAssertTrue(AuthManager.isRetryableConnectFailure(URLError(.notConnectedToInternet)))
        XCTAssertTrue(AuthManager.isRetryableConnectFailure(NSError(domain: "x", code: 1)))
    }

    // MARK: - A7: token-hash dedupe + record-on-success

    func test_tokenHashAction_processesFreshHash() {
        XCTAssertEqual(AuthManager.tokenHashAction(incoming: "abc", lastHandled: nil), .process)
        XCTAssertEqual(AuthManager.tokenHashAction(incoming: "abc", lastHandled: "def"), .process)
    }

    func test_tokenHashAction_skipsDuplicate() {
        XCTAssertEqual(AuthManager.tokenHashAction(incoming: "abc", lastHandled: "abc"), .skipDuplicate)
    }

    func test_shouldRecordTokenHash_onlyOnSuccess() {
        // A failed first click must NOT record the hash, or the retry of the same link becomes a
        // permanent silent no-op.
        XCTAssertFalse(AuthManager.shouldRecordTokenHash(verifySucceeded: false))
        XCTAssertTrue(AuthManager.shouldRecordTokenHash(verifySucceeded: true))
    }

    // MARK: - A8: rejected-callback copy

    func test_rejectionMessage_staleForNoPendingAndMismatch() {
        let stale = "That sign-in link is stale or was already used. Request a new one from the app."
        XCTAssertEqual(AuthManager.rejectionMessage(for: .rejectNoPendingFlow), stale)
        XCTAssertEqual(AuthManager.rejectionMessage(for: .rejectStateMismatch), stale)
    }

    func test_rejectionMessage_silentForAlreadySignedInAndAccept() {
        XCTAssertNil(AuthManager.rejectionMessage(for: .rejectAlreadySignedIn))
        XCTAssertNil(AuthManager.rejectionMessage(for: .accept))
    }

    // MARK: - A9: cold-launch callback outcome mapping

    func test_preExchangeOutcome_noClientIsIgnored() {
        XCTAssertEqual(AuthManager.preExchangeOutcome(hasClient: false, decision: .accept), .ignored)
        XCTAssertEqual(AuthManager.preExchangeOutcome(hasClient: false, decision: .rejectNoPendingFlow), .ignored)
    }

    func test_preExchangeOutcome_acceptProceeds() {
        XCTAssertNil(AuthManager.preExchangeOutcome(hasClient: true, decision: .accept))
    }

    func test_preExchangeOutcome_rejectedDecisionsAreRejected() {
        XCTAssertEqual(AuthManager.preExchangeOutcome(hasClient: true, decision: .rejectAlreadySignedIn), .rejected)
        XCTAssertEqual(AuthManager.preExchangeOutcome(hasClient: true, decision: .rejectNoPendingFlow), .rejected)
        XCTAssertEqual(AuthManager.preExchangeOutcome(hasClient: true, decision: .rejectStateMismatch), .rejected)
    }

    func test_callbackOutcome_equatable() {
        XCTAssertEqual(AuthManager.CallbackOutcome.signedIn("a@b.com"), .signedIn("a@b.com"))
        XCTAssertNotEqual(AuthManager.CallbackOutcome.signedIn("a@b.com"), .signedIn(nil))
        XCTAssertEqual(AuthManager.CallbackOutcome.failed("boom"), .failed("boom"))
        XCTAssertNotEqual(AuthManager.CallbackOutcome.failed("boom"), .rejected)
    }

    // MARK: - A11: auth-state-change signed-out signal

    func test_authStateSignalsSignedOut_onlyForSignedOut() {
        XCTAssertTrue(AuthManager.authStateSignalsSignedOut(.signedOut))
        XCTAssertFalse(AuthManager.authStateSignalsSignedOut(.signedIn))
        XCTAssertFalse(AuthManager.authStateSignalsSignedOut(.tokenRefreshed))
        XCTAssertFalse(AuthManager.authStateSignalsSignedOut(.initialSession))
        XCTAssertFalse(AuthManager.authStateSignalsSignedOut(.userUpdated))
    }
}

/// A5: the instance-discovery request is time-bounded so a black-holed connect cannot spin forever.
final class MetaRequestTimeoutTests: XCTestCase {
    func test_metaRequest_isBounded() {
        let request = InstanceConfig.metaRequest(instance: URL(string: "https://app.getminutia.com")!)
        XCTAssertEqual(request.timeoutInterval, 10)
    }
}
