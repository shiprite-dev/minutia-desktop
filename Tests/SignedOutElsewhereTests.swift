import AVFoundation
import Supabase
import XCTest
@testable import Minutia

/// Stands in for the instance's sign-in server and API, and records every path the app calls.
final class AuthServerStub: URLProtocol {
    nonisolated(unsafe) static var refresh: Result<(Int, String), URLError> = .success((200, "{}"))
    nonisolated(unsafe) static var user: Result<(Int, String), URLError> = .success((200, userBody))
    nonisolated(unsafe) static var signInBody = expiredSessionBody
    nonisolated(unsafe) static var calledPaths: [String] = []
    private static let lock = NSLock()

    static func reset() {
        lock.withLock {
            refresh = .success((200, "{}"))
            user = .success((200, userBody))
            signInBody = expiredSessionBody
            calledPaths = []
        }
    }

    static var paths: [String] { lock.withLock { calledPaths } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let grant = query.first { $0.name == "grant_type" }?.value
        Self.lock.withLock { Self.calledPaths.append(url.path + (grant.map { "?grant_type=\($0)" } ?? "")) }
        let outcome: Result<(Int, String), URLError>
        switch (url.path, grant) {
        case ("/auth/v1/token", "password"): outcome = .success((200, Self.lock.withLock { Self.signInBody }))
        case ("/auth/v1/token", "refresh_token"): outcome = Self.lock.withLock { Self.refresh }
        case ("/auth/v1/user", _): outcome = Self.lock.withLock { Self.user }
        default: outcome = .success((404, "{}"))
        }
        switch outcome {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .success(let (status, body)):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    static let userBody = """
    {"id":"6f0d2c7a-1f43-4b8e-9d1a-2a6f3b9c4e10","aud":"authenticated","role":"authenticated",
     "email":"first@example.com","app_metadata":{"provider":"email"},"user_metadata":{},
     "created_at":"2026-11-20T09:00:00Z","updated_at":"2026-11-20T09:00:00Z"}
    """

    private static func sessionBody(expiresAt: Int) -> String {
        "{\"access_token\":\"access\",\"token_type\":\"bearer\",\"expires_in\":3600,\"expires_at\":\(expiresAt),"
            + "\"refresh_token\":\"old-refresh\",\"user\":\(userBody)}"
    }

    /// A session whose access token has already run out, so the next use must refresh it.
    static var expiredSessionBody: String { sessionBody(expiresAt: Int(Date().timeIntervalSince1970) - 120) }

    /// A session whose access token is still good for most of an hour: signing out on the web does
    /// not touch it, only the server knows the session is gone.
    static var validSessionBody: String { sessionBody(expiresAt: Int(Date().timeIntervalSince1970) + 3000) }

    /// What the instance's sign-in server answers for a still-valid token whose session was ended
    /// (GoTrue v2.158.1, API version 2024-01-01).
    static let sessionEnded = "{\"code\":\"session_not_found\",\"message\":\"Session from session_id claim in JWT does not exist\"}"

    /// Exactly what the instance's sign-in server returns once the session was signed out on the
    /// web (captured from the self-host stack's GoTrue v2.158.1).
    static let signedOutOnTheWeb = "{\"error\":\"invalid_grant\",\"error_description\":\"Invalid Refresh Token: Refresh Token Not Found\"}"

    /// The same refusal from a newer sign-in server answering API version 2024-01-01, which names the reason.
    static let signedOutOnTheWebNewerServer = "{\"code\":\"refresh_token_not_found\",\"message\":\"Invalid Refresh Token: Refresh Token Not Found\"}"
}

@MainActor
final class SignedOutElsewhereTests: XCTestCase {
    private let instance = URL(string: "https://minutia.example.com")!
    private let supabaseURL = URL(string: "https://minutia.example.com")!
    private var suite: String!
    private var defaults: UserDefaults!
    private var controllers: [AppController] = []

    private let signedOutNote = "You were signed out. Sign in again to record."

    override func setUp() async throws {
        suite = "SignedOutElsewhereTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        AuthServerStub.reset()
        URLProtocol.registerClass(AuthServerStub.self)
    }

    override func tearDown() async throws {
        for controller in controllers { controller.handleDetection(.none) }
        controllers = []
        URLProtocol.unregisterClass(AuthServerStub.self)
        AuthServerStub.reset()
        defaults.removePersistentDomain(forName: suite)
    }

    private func signedInAuthManager() async throws -> AuthManager {
        let auth = AuthManager(defaults: defaults)
        await auth.adopt(testSupabase(supabaseURL), instance: instance)
        try await auth.signIn(email: "first@example.com", password: "pw")
        XCTAssertEqual(auth.userEmail, "first@example.com")
        return auth
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    // MARK: - The Mac learns it was signed out

    func test_signedOutOnTheWeb_theMacDropsItsSession_andAsksToSignInAgain() async throws {
        let auth = try await signedInAuthManager()
        AuthServerStub.refresh = .success((400, AuthServerStub.signedOutOnTheWeb))

        let revoked = await auth.dropSessionIfRevoked()

        XCTAssertTrue(revoked)
        XCTAssertNil(auth.userEmail, "the menu must fall back to sign-in")
        XCTAssertEqual(auth.callbackError, signedOutNote)
        XCTAssertNil(auth.supabase?.auth.currentSession, "the refused session must not linger and be retried")
    }

    func test_signedOutOnTheWeb_withANewerServer_alsoAsksToSignInAgain() async throws {
        let auth = try await signedInAuthManager()
        AuthServerStub.refresh = .success((400, AuthServerStub.signedOutOnTheWebNewerServer))

        let revoked = await auth.dropSessionIfRevoked()

        XCTAssertTrue(revoked)
        XCTAssertNil(auth.userEmail)
        XCTAssertEqual(auth.callbackError, signedOutNote)
    }

    func test_minutesAfterSigningOutOnTheWeb_whileTheMacsPassIsStillValid_itStillAsksToSignInAgain() async throws {
        AuthServerStub.signInBody = AuthServerStub.validSessionBody
        let auth = try await signedInAuthManager()
        AuthServerStub.user = .success((403, AuthServerStub.sessionEnded))

        let revoked = await auth.dropSessionIfRevoked()

        XCTAssertTrue(revoked)
        XCTAssertNil(auth.userEmail)
        XCTAssertEqual(auth.callbackError, signedOutNote)
        XCTAssertNil(auth.supabase?.auth.currentSession)
    }

    func test_stillSignedIn_offline_whileThePassIsValid_staysSignedIn() async throws {
        AuthServerStub.signInBody = AuthServerStub.validSessionBody
        let auth = try await signedInAuthManager()
        AuthServerStub.user = .failure(URLError(.notConnectedToInternet))

        let revoked = await auth.dropSessionIfRevoked()

        XCTAssertFalse(revoked)
        XCTAssertEqual(auth.userEmail, "first@example.com")
        XCTAssertNil(auth.callbackError)
    }

    func test_offline_theMacStaysSignedIn_andShowsNoSignedOutNote() async throws {
        let auth = try await signedInAuthManager()
        AuthServerStub.refresh = .failure(URLError(.notConnectedToInternet))

        let revoked = await auth.dropSessionIfRevoked()

        XCTAssertFalse(revoked, "losing the network is not being signed out")
        XCTAssertEqual(auth.userEmail, "first@example.com")
        XCTAssertNil(auth.callbackError)
        XCTAssertNotNil(auth.supabase?.auth.currentSession, "the session survives to be refreshed once back online")
    }

    func test_serverHiccup_theMacStaysSignedIn() async throws {
        let auth = try await signedInAuthManager()
        AuthServerStub.refresh = .success((500, "{\"code\":500,\"msg\":\"Internal Server Error\"}"))

        let revoked = await auth.dropSessionIfRevoked()

        XCTAssertFalse(revoked)
        XCTAssertEqual(auth.userEmail, "first@example.com")
        XCTAssertNil(auth.callbackError)
    }

    // MARK: - Through the menu

    private func signedInController() async throws -> AppController {
        let controller = AppController(defaults: defaults, openURL: { _ in }, micCheck: { (.authorized, true) })
        controllers.append(controller)
        AuthServerStub.signInBody = AuthServerStub.validSessionBody
        let client = testSupabase(supabaseURL)
        await controller.authManager.adopt(client, instance: instance)
        _ = try await client.auth.signIn(email: "first@example.com", password: "pw")
        controller.apply(.signedIn)
        controller.seriesLoaded([Series(id: UUID(), name: "Weekly sync")])
        return controller
    }

    func test_pressingRecord_minutesAfterSigningOutOnTheWeb_startsNoMeeting_andSaysToSignInAgain() async throws {
        let controller = try await signedInController()
        AuthServerStub.user = .success((403, AuthServerStub.sessionEnded))

        controller.startRecording()
        await waitUntil { controller.recordFeedback != nil }

        XCTAssertEqual(controller.authManager.callbackError, signedOutNote)
        XCTAssertEqual(controller.recordFeedback, signedOutNote)
        XCTAssertFalse(AuthServerStub.paths.contains { $0.hasPrefix("/rest/v1/") },
                       "no meeting may be started without a signed-in person: \(AuthServerStub.paths)")
        XCTAssertNotEqual(controller.phase, .recording)
    }

    func test_openingTheMenu_minutesAfterSigningOutOnTheWeb_saysToSignInAgain_beforeAnyClick() async throws {
        let controller = try await signedInController()
        AuthServerStub.user = .success((403, AuthServerStub.sessionEnded))

        controller.reloadSeries()
        await waitUntil { controller.authManager.callbackError != nil }

        XCTAssertEqual(controller.authManager.callbackError, signedOutNote)
        XCTAssertFalse(AuthServerStub.paths.contains { $0.hasPrefix("/rest/v1/") })
    }
}
