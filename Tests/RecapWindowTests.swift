import AppKit
import CryptoKit
import WebKit
import XCTest
@testable import Minutia

/// A Minutia instance served over a real socket: the handoff mint route, the companion sign-in POST
/// (which checks the nonce against the minted digest and sets a session cookie), the meeting page
/// (redirects to /login without that cookie, as the middleware does), and the sign-in page.
final class FakeMinutia: @unchecked Sendable {
    let server: LocalWebServer
    private let lock = NSLock()
    private var digests: [String] = []
    private var session = "session-1"
    private var mintStatus = 200
    private var meetingReply: LocalWebServer.Reply?
    private var meetingScript = ""
    private var meetingBody = ""
    private var mintDelay: TimeInterval = 0
    private var sessionJSON = AuthServerStub.validSessionBody
    let seriesId = UUID(uuidString: "B6008C45-D6ED-4CD8-BCE4-9646A5994F0B")!

    init() throws { server = try LocalWebServer() }

    func start() async throws -> URL {
        let base = try await server.start()
        server.handle { [unowned self] in self.route($0) }
        return base
    }

    var base: URL { server.base }

    func refuseMints(_ status: Int) { lock.withLock { mintStatus = status } }
    func expireWebSessions() { lock.withLock { session = "session-\(UUID().uuidString)" } }
    func answerMeetings(_ reply: LocalWebServer.Reply?) { lock.withLock { meetingReply = reply } }
    func runOnMeetingPage(_ script: String) { lock.withLock { meetingScript = script } }
    func addToMeetingPage(_ html: String) { lock.withLock { meetingBody = html } }
    func slowMints(_ seconds: TimeInterval) { lock.withLock { mintDelay = seconds } }
    func signInReturns(_ body: String) { lock.withLock { sessionJSON = body } }

    func meetingPath(_ meetingId: UUID) -> String {
        "/series/\(seriesId.uuidString.lowercased())/meetings/\(meetingId.uuidString.lowercased())"
    }

    private func route(_ request: LocalWebServer.Request) -> LocalWebServer.Reply {
        let json = ["Content-Type": "application/json"]
        switch (request.method, request.path) {
        case ("POST", "/api/companion/web-session"):
            let digest = (try? JSONSerialization.jsonObject(with: request.body) as? [String: String])?["nonce_digest"] ?? ""
            return lock.withLock {
                digests.append(digest)
                let reply: LocalWebServer.Reply = switch mintStatus {
                case 200: .respond(status: 200, headers: json, body: "{\"handoff_id\":\"handoff-\(digests.count)\"}")
                case 401: .respond(status: 401, headers: json, body: "{\"error\":\"Not authenticated\"}")
                default: .respond(status: mintStatus, headers: json, body: "{\"error\":\"refused\"}")
                }
                return mintDelay > 0 ? .delayed(mintDelay, reply) : reply
            }
        case ("POST", "/auth/companion-session"):
            let form = request.form
            let nonce = form["nonce"] ?? ""
            let digest = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
            return lock.withLock {
                guard let index = digests.firstIndex(of: digest), form["handoff_id"] == "handoff-\(index + 1)" else {
                    return .respond(status: 303, headers: ["Location": "/login"], body: "")
                }
                return .respond(status: 303, headers: ["Location": form["next"] ?? "/", "Set-Cookie": "sb-session=\(session); Path=/; HttpOnly"], body: "")
            }
        case ("GET", "/login"):
            return .respond(status: 200, headers: [:], body: "<html><body><h1>Sign in to Minutia</h1></body></html>")
        case ("GET", "/report"), ("GET", "/frame-same"):
            return .respond(status: 204, headers: [:], body: "")
        case ("POST", "/auth/v1/token"):
            return .respond(status: 200, headers: json.merging(["X-Supabase-Api-Version": "2024-01-01"]) { $1 }, body: lock.withLock { sessionJSON })
        case ("GET", "/auth/v1/user"):
            return .respond(status: 200, headers: json, body: AuthServerStub.userBody)
        case ("GET", "/rest/v1/meetings"):
            return .respond(status: 200, headers: json, body: "{\"series_id\":\"\(seriesId.uuidString.lowercased())\"}")
        case ("GET", let path) where path.hasPrefix("/series/"):
            return lock.withLock {
                if let meetingReply { return meetingReply }
                guard request.header("Cookie")?.contains("sb-session=\(session)") == true else {
                    return .respond(status: 302, headers: ["Location": "/login?next=\(path)"], body: "")
                }
                return .respond(status: 200, headers: [:], body: "<html><body><h1>Recap for Weekly sync</h1>\(meetingBody)<script>\(meetingScript)</script></body></html>")
            }
        default:
            return .respond(status: 404, headers: json, body: "{}")
        }
    }

    var mintedDigests: [String] { lock.withLock { digests } }
}

/// Stands in for WebKit's data store list; a removal can be made to fail.
@MainActor
final class StoreDouble {
    var ids: [UUID]
    var failing: Set<UUID> = []
    private(set) var removed: [UUID] = []

    init(_ ids: [UUID]) { self.ids = ids }

    var stores: RecapStores {
        RecapStores(all: { self.ids }, remove: { id in
            if self.failing.contains(id) { throw URLError(.cannotRemoveFile) }
            self.removed.append(id)
            self.ids.removeAll { $0 == id }
        })
    }
}

@MainActor
final class RecapWindowTests: XCTestCase {
    private var fake: FakeMinutia!
    private var elsewhere: FakeMinutia!
    private var clock: TestClock!
    private var opened: [URL] = []
    private var copied: [String] = []
    private var announced: [String] = []
    private var asked: [String] = []
    private var chosenFiles: [URL]?
    private var answer = false
    private var typed: String?
    private var holdAnswer: (() async -> (ok: Bool, text: String?))?
    private var signOutChecks = 0
    private var policies: [NSApplication.ActivationPolicy] = []
    private var presence: WindowPresence!
    private var controllers: [RecapWindowController] = []
    private var apps: [AppController] = []
    private var suite: String!
    private let meetingId = UUID(uuidString: "3F95FFD6-FD1E-4640-AACC-89E1C051F742")!
    private let otherMeeting = UUID(uuidString: "9C7E1A2B-3D4F-4A5B-8C6D-7E8F9A0B1C2D")!
    private let signedInUser = "6f0d2c7a-1f43-4b8e-9d1a-2a6f3b9c4e10"

    override func setUp() async throws {
        fake = try FakeMinutia()
        _ = try await fake.start()
        elsewhere = try FakeMinutia()
        _ = try await elsewhere.start()
        clock = TestClock()
        opened = []
        copied = []
        announced = []
        signOutChecks = 0
        policies = []
        suite = "RecapWindowTests.\(UUID().uuidString)"
        presence = WindowPresence(setPolicy: { [weak self] in self?.policies.append($0) }, activate: {})
    }

    override func tearDown() async throws {
        for app in apps { await app.recapWindow.forgetWebSessions() }
        for controller in controllers { await controller.forgetWebSessions() }
        controllers = []
        apps = []
        clock.drain()
        fake.server.stop()
        elsewhere.server.stop()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    private func recap(
        userId: String? = UUID().uuidString.lowercased(), stores: RecapStores = .webKit,
        token: @escaping () async throws -> String = { "token" }, user: (() -> String?)? = nil
    ) -> RecapWindowController {
        let base = fake.base
        let user = user ?? { userId }
        let controller = RecapWindowController(
            account: { (MinutiaClient(instance: base, supabase: testSupabase(base), tokenProvider: token), user()) },
            openURL: { [weak self] in self?.opened.append($0) }, copy: { [weak self] in self?.copied.append($0) },
            clock: clock.review, presence: presence, defaults: defaults, stores: stores,
            announce: { [weak self] in self?.announced.append($0) }, onSignedOut: { [weak self] in self?.signOutChecks += 1 },
            dialogs: RecapDialogs(
                chooseFiles: { [weak self] multiple, _, _ in
                    self?.asked.append("files multiple=\(multiple)")
                    return self?.chosenFiles
                },
                ask: { [weak self] kind, message, _ in
                    self?.asked.append("\(kind) \(message)")
                    if let self, let hold = self.holdAnswer { return await hold() }
                    return (self?.answer ?? false, self?.typed)
                }))
        controllers.append(controller)
        return controller
    }

    private func page(_ meeting: UUID) -> URL { fake.base.appendingPathComponent(fake.meetingPath(meeting)) }

    private func waitUntil(_ seconds: TimeInterval = 15, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private func pageText(_ controller: RecapWindowController) async -> String {
        guard let webView = controller.webView else { return "" }
        return (try? await webView.evaluateJavaScript("document.body.innerText") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func onScreen(_ controller: RecapWindowController) -> Seen {
        guard let view = controller.window?.contentView else { return Seen(text: "", frames: []) }
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard let image = Host.capture(view, scale: 2) else { return Seen(text: "", frames: []) }
        return Host.read(image)
    }

    private func toolbarItem(_ controller: RecapWindowController, _ label: String) -> NSToolbarItem? {
        controller.window?.toolbar?.items.first { $0.label == label }
    }

    private func click(_ item: NSToolbarItem?, file: StaticString = #filePath, line: UInt = #line) {
        guard let item, let action = item.action else { return XCTFail("no toolbar item", file: file, line: line) }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    private func press(_ characters: String, _ modifiers: NSEvent.ModifierFlags, in window: NSWindow?, file: StaticString = #filePath, line: UInt = #line) {
        guard let window, let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)
        else { return XCTFail("no window", file: file, line: line) }
        XCTAssertTrue(window.performKeyEquivalent(with: event), "\(characters) was not handled", file: file, line: line)
    }

    private func openedRecap(_ controller: RecapWindowController, _ meeting: UUID? = nil) async {
        await controller.show(meetingId: meeting ?? meetingId, seriesId: fake.seriesId, title: "Weekly sync").value
        await waitUntil { controller.screen == .page }
    }

    /// An earlier visit leaves this account's window signed in on the web, then the next handoff is refused.
    private func signedInEarlier(_ userId: String, thenRefuse status: Int) async {
        _ = await madeStore(userId)
        fake.refuseMints(status)
    }

    private func store(_ userId: String) -> UUID { RecapWindowController.storeIdentifier(instance: fake.base, userId: userId) }

    /// Opens and closes a window for `userId`, so the app has made that account's store.
    private func madeStore(_ userId: String) async -> UUID {
        let controller = recap(userId: userId)
        await openedRecap(controller)
        controller.window?.performClose(nil)
        await waitUntil { controller.window == nil }
        return store(userId)
    }

    private func paths(after count: Int = 0) -> [String] {
        fake.server.requests.dropFirst(count).map { "\($0.method) \($0.path)" }
    }

    // MARK: - Navigation rules

    func test_whereEachLinkOpens_sameServerInTheWindow_everythingElseOutside_scriptsAndLocalSchemesNowhere() {
        let instance = URL(string: "https://minutia.example.com")!
        let decide = { (url: String, newWindow: Bool, download: Bool) in
            RecapNavigation.decide(url: URL(string: url)!, instance: instance, isNewWindow: newWindow, isDownload: download)
        }
        XCTAssertEqual(decide("https://minutia.example.com/issues/42", false, false), .allow)
        XCTAssertEqual(decide("https://MINUTIA.example.com:443/series", false, false), .allow)
        XCTAssertEqual(decide("https://github.com/shiprite-dev", false, false), .openInBrowser)
        XCTAssertEqual(decide("http://minutia.example.com/issues/42", false, false), .openInBrowser)
        XCTAssertEqual(decide("https://minutia.example.com:8443/issues/42", false, false), .openInBrowser)
        XCTAssertEqual(decide("https://minutia.example.com/issues/42", true, false), .openInBrowser)
        XCTAssertEqual(decide("https://minutia.example.com/api/export.csv", false, true), .openInBrowser)
        XCTAssertEqual(decide("mailto:owner@example.com", false, false), .openInBrowser)
        XCTAssertEqual(decide("javascript:alert(document.cookie)", false, false), .deny)
        XCTAssertEqual(decide("file:///etc/passwd", false, false), .deny)
        XCTAssertEqual(decide("about:blank", false, false), .deny)
        XCTAssertEqual(decide("data:text/html,<h1>hi</h1>", false, false), .deny)
        XCTAssertEqual(decide("blob:https://minutia.example.com/1b4e28ba-2fa1-11d2-883f-0016d3cca427", false, false), .deny)
        XCTAssertEqual(decide("minutia://record", false, false), .deny)
    }

    func test_eachAccountOnEachServer_getsItsOwnWebData() {
        let main = URL(string: "https://minutia.example.com")!
        XCTAssertEqual(RecapWindowController.storeIdentifier(instance: main, userId: signedInUser).uuidString, "9FADF137-EB6F-11BB-B458-04CB859563E7")
        XCTAssertEqual(RecapWindowController.storeIdentifier(instance: URL(string: "https://other.example.com")!, userId: signedInUser).uuidString,
                       "D6DD7CCB-7401-3545-51B0-5F4BA910F270")
        XCTAssertEqual(RecapWindowController.storeIdentifier(instance: main, userId: "ec4109b3-9e36-4a3d-8701-ac066af779f1").uuidString,
                       "CEBAE5DD-5D03-1921-BA5D-FFFF3D7E30A3")
    }

    // MARK: - Signing in

    func test_firstOpen_signsInWithAOneTimeHandoff_andShowsTheRecapWithoutTheSignInPage() async throws {
        let controller = recap()
        await openedRecap(controller)

        XCTAssertEqual(paths(), ["POST /api/companion/web-session", "POST /auth/companion-session", "GET \(fake.meetingPath(meetingId))"])
        let post = try XCTUnwrap(fake.server.requests("/auth/companion-session").first)
        let nonce = try XCTUnwrap(post.form["nonce"])
        XCTAssertEqual(fake.mintedDigests, [SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()])
        XCTAssertEqual(post.form["handoff_id"], "handoff-1")
        XCTAssertEqual(post.form["next"], fake.meetingPath(meetingId))
        XCTAssertEqual(post.header("Content-Type"), "application/x-www-form-urlencoded")
        let text = await pageText(controller)
        XCTAssertEqual(text, "Recap for Weekly sync")
        XCTAssertEqual(controller.webView?.isHidden, false)
        XCTAssertEqual(controller.window?.title, "Weekly sync")
    }

    func test_theAppsSignInPost_carriesHeadersTheServerAccepts() async throws {
        let controller = recap()
        await openedRecap(controller)
        let post = try XCTUnwrap(fake.server.requests("/auth/companion-session").first)
        let fetchSite = post.header("Sec-Fetch-Site")
        let origin = post.header("Origin")
        XCTAssertEqual(fetchSite, "none")
        XCTAssertEqual(origin, "null")
        XCTAssertTrue(serverTrusts(fetchSite: fetchSite, origin: origin, appOrigin: fake.base.absoluteString))
    }

    /// The server's rule, src/lib/companion/web-handoff.ts isTrustedSubmit.
    private func serverTrusts(fetchSite: String?, origin: String?, appOrigin: String) -> Bool {
        if let fetchSite, fetchSite != "none", fetchSite != "same-origin" { return false }
        guard let origin else { return true }
        if origin == "null" { return fetchSite == "none" }
        return origin == appOrigin
    }

    func test_reopeningAfterClosing_signsInAgainWithANewHandoff_soTheWindowIsAlwaysTheMacsAccount() async {
        let controller = recap(userId: "ec4109b3-9e36-4a3d-8701-ac066af779f1")
        await openedRecap(controller)
        controller.window?.performClose(nil)
        await waitUntil { controller.window == nil }
        let before = fake.server.requests.count

        await openedRecap(controller)

        XCTAssertEqual(paths(after: before), ["POST /api/companion/web-session", "POST /auth/companion-session", "GET \(fake.meetingPath(meetingId))"])
        XCTAssertEqual(fake.server.requests("/auth/companion-session").last?.form["handoff_id"], "handoff-2")
        let text = await pageText(controller)
        XCTAssertEqual(text, "Recap for Weekly sync")
    }

    func test_aRefusedHandoff_loadsTheMeeting_soTheWebSignInPageShows_andAsksOnlyOnce() async {
        let user = UUID().uuidString.lowercased()
        await signedInEarlier(user, thenRefuse: 429)
        let before = fake.server.requests.count
        let controller = recap(userId: user)
        await openedRecap(controller)

        let text = await pageText(controller)
        XCTAssertEqual(text, "Sign in to Minutia")
        XCTAssertEqual(paths(after: before), ["POST /api/companion/web-session", "GET \(fake.meetingPath(meetingId))", "GET /login"])
        XCTAssertEqual(opened, [])
    }

    func test_theServerSayingSignedOut_runsTheMacsSignOutCheck_andShowsTheWebSignIn() async {
        let user = UUID().uuidString.lowercased()
        await signedInEarlier(user, thenRefuse: 401)
        let before = fake.server.requests.count
        let controller = recap(userId: user)
        await openedRecap(controller)

        XCTAssertEqual(signOutChecks, 1)
        let text = await pageText(controller)
        XCTAssertEqual(text, "Sign in to Minutia")
    }

    func test_anOlderServer_opensTheMeetingInTheBrowser_andNoWindowStays() async {
        fake.refuseMints(404)
        let controller = recap()
        await controller.show(meetingId: meetingId, seriesId: fake.seriesId, title: "Weekly sync").value
        await waitUntil { opened.count == 1 && controller.window == nil }

        XCTAssertEqual(opened.map(\.absoluteString), [page(meetingId).absoluteString])
        XCTAssertEqual(policies, [.regular, .accessory])
    }

    func test_threeTryAgainPressesDuringASlowSignIn_askForOneHandoff() async {
        fake.slowMints(1)
        let controller = recap()
        controller.show(meetingId: meetingId, seriesId: fake.seriesId, title: "Weekly sync")
        await waitUntil { fake.server.requests("/api/companion/web-session").count == 1 }
        controller.tryAgain()
        controller.tryAgain()
        controller.tryAgain()

        await waitUntil { controller.screen == .page }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fake.mintedDigests.count, 1)
        XCTAssertEqual(fake.server.requests("/auth/companion-session").count, 1)
        let text = await pageText(controller)
        XCTAssertEqual(text, "Recap for Weekly sync")
    }

    func test_closingDuringASlowSignIn_thenReopening_usesTheHandoffAlreadyMinted() async {
        fake.slowMints(0.6)
        let controller = recap()
        controller.show(meetingId: meetingId, seriesId: fake.seriesId, title: "Weekly sync")
        await waitUntil { fake.server.requests("/api/companion/web-session").count == 1 }
        controller.window?.performClose(nil)
        try? await Task.sleep(nanoseconds: 900_000_000)

        await openedRecap(controller)

        XCTAssertEqual(fake.mintedDigests.count, 1)
        XCTAssertEqual(fake.server.requests("/auth/companion-session").map { $0.form["handoff_id"] }, ["handoff-1"])
    }

    func test_aHandoffMintedForOneAccount_isNeverPostedForTheNextAccount() async {
        fake.slowMints(0.6)
        var account = UUID().uuidString.lowercased()
        let controller = recap(user: { account })
        controller.show(meetingId: meetingId, seriesId: fake.seriesId, title: "Weekly sync")
        await waitUntil { fake.server.requests("/api/companion/web-session").count == 1 }
        controller.window?.performClose(nil)
        try? await Task.sleep(nanoseconds: 900_000_000)
        account = UUID().uuidString.lowercased()

        await openedRecap(controller)

        XCTAssertEqual(fake.mintedDigests.count, 2)
        XCTAssertEqual(fake.server.requests("/auth/companion-session").map { $0.form["handoff_id"] }, ["handoff-2"])
    }

    // MARK: - What the window shows

    func test_offlineWhileSigningIn_saysYoureOffline_withTryAgain() async {
        let controller = recap(token: { throw URLError(.notConnectedToInternet) })
        await controller.show(meetingId: meetingId, seriesId: fake.seriesId, title: "Weekly sync").value
        await waitUntil { controller.screen == .offline }

        XCTAssertEqual(announced, ["You're offline"])
        XCTAssertEqual(opened, [])
        let seen = onScreen(controller)
        XCTAssertTrue(seen.hasLine("You're offline"), seen.text)
        XCTAssertTrue(seen.hasLine("Try again"), seen.text)
        XCTAssertFalse(seen.has("Taking longer than usual"), seen.text)
        XCTAssertEqual(controller.webView?.isHidden, true)
    }

    func test_theConnectionDropsWhileLoading_saysYoureOffline_andTryAgainShowsTheRecap() async {
        fake.answerMeetings(.drop)
        let controller = recap()
        await controller.show(meetingId: meetingId, seriesId: fake.seriesId, title: "Weekly sync").value
        await waitUntil { controller.screen == .offline }
        XCTAssertEqual(announced, ["You're offline"])
        let seen = onScreen(controller)
        XCTAssertTrue(seen.hasLine("You're offline"), seen.text)
        XCTAssertFalse(seen.has("Recap for Weekly sync"), seen.text)

        fake.answerMeetings(nil)
        controller.tryAgain()
        await waitUntil { controller.screen == .page }
        let text = await pageText(controller)
        XCTAssertEqual(text, "Recap for Weekly sync")
        XCTAssertEqual(fake.mintedDigests.count, 1, "the window is already signed in")
    }

    func test_aSlowServer_showsTheTitle_thenAfterEightSecondsSaysTakingLonger_withTryAgainAndOpenInBrowser() async {
        fake.answerMeetings(.hang)
        let controller = recap()
        await controller.show(meetingId: meetingId, seriesId: fake.seriesId, title: "Weekly sync").value
        await waitUntil { fake.server.requests(fake.meetingPath(meetingId)).count == 1 }

        clock.advance(7.9)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(announced, [])
        let early = onScreen(controller)
        XCTAssertTrue(early.hasLine("Weekly sync"), early.text)
        XCTAssertFalse(early.has("Taking longer than usual"), early.text)
        XCTAssertEqual(controller.webView?.isHidden, true)

        clock.advance(0.1)
        await waitUntil { controller.screen == .slow }
        XCTAssertEqual(announced, ["Taking longer than usual"])
        let late = onScreen(controller)
        XCTAssertTrue(late.hasLine("Taking longer than usual"), late.text)
        XCTAssertTrue(late.hasLine("Try again"), late.text)
        XCTAssertTrue(late.hasLine("Open in browser"), late.text)

        controller.openInBrowser()
        XCTAssertEqual(opened.map(\.absoluteString), [page(meetingId).absoluteString])
    }

    func test_theSlowNoticeNeverAppearsAfterTheWindowCloses() async {
        fake.answerMeetings(.hang)
        let controller = recap()
        await controller.show(meetingId: meetingId, seriesId: fake.seriesId, title: "Weekly sync").value
        await waitUntil { fake.server.requests(fake.meetingPath(meetingId)).count == 1 }
        controller.window?.performClose(nil)
        await waitUntil { controller.window == nil }

        clock.advance(8)
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(announced, [])
        XCTAssertNotEqual(controller.screen, .slow)
        XCTAssertEqual(policies, [.regular, .accessory])
    }

    func test_aServerCertificateTheMacRejects_saysItCantOpenSecurely_withOpenInBrowser() async throws {
        fake.answerMeetings(.hang)
        let controller = recap()
        await controller.show(meetingId: meetingId, seriesId: fake.seriesId, title: "Weekly sync").value
        let webView = try XCTUnwrap(controller.webView)
        controller.webView(webView, didFailProvisionalNavigation: nil, withError: URLError(.serverCertificateUntrusted) as NSError)

        XCTAssertEqual(announced, ["Can't open this server securely"])
        let seen = onScreen(controller)
        XCTAssertTrue(seen.hasLine("Can't open this server securely"), seen.text)
        XCTAssertTrue(seen.hasLine("Open in browser"), seen.text)
        XCTAssertFalse(seen.has("You're offline"), seen.text)
        XCTAssertFalse(seen.has("Try again"), seen.text)
    }

    func test_whatEachLoadFailureShows() {
        let offline: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut, .dnsLookupFailed, .dataNotAllowed]
        for code in offline { XCTAssertEqual(RecapScreen.failure(URLError(code)), .offline, "\(code)") }
        let slow: [URLError.Code] = [.badServerResponse, .internationalRoamingOff, .callIsActive, .resourceUnavailable, .httpTooManyRedirects, .zeroByteResource, .badURL]
        for code in slow { XCTAssertEqual(RecapScreen.failure(URLError(code)), .slow, "\(code)") }
        let insecure: [Error] = [
            URLError(.serverCertificateUntrusted), URLError(.secureConnectionFailed), URLError(.serverCertificateHasBadDate),
            URLError(.clientCertificateRequired), NSError(domain: "WebKitErrorDomain", code: -1202), NSError(domain: "WebKitErrorDomain", code: -1200),
        ]
        for error in insecure { XCTAssertEqual(RecapScreen.failure(error), .insecure, "\(error)") }
        XCTAssertNil(RecapScreen.failure(URLError(.cancelled)), "a navigation the window itself stopped shows nothing")
        XCTAssertNil(RecapScreen.failure(NSError(domain: "WebKitErrorDomain", code: 102)), "a link handed to the browser shows nothing")
    }

    func test_aFailureThatIsNotTheConnection_saysTakingLonger_withTryAgainAndOpenInBrowser() async throws {
        fake.answerMeetings(.hang)
        let controller = recap()
        await controller.show(meetingId: meetingId, seriesId: fake.seriesId, title: "Weekly sync").value
        let webView = try XCTUnwrap(controller.webView)
        controller.webView(webView, didFailProvisionalNavigation: nil, withError: URLError(.badServerResponse) as NSError)

        XCTAssertEqual(announced, ["Taking longer than usual"])
        let seen = onScreen(controller)
        XCTAssertTrue(seen.hasLine("Taking longer than usual"), seen.text)
        XCTAssertTrue(seen.hasLine("Try again"), seen.text)
        XCTAssertTrue(seen.hasLine("Open in browser"), seen.text)
        XCTAssertFalse(seen.has("You're offline"), seen.text)
    }

    func test_everyCertificateFailure_fromEitherWebKitCallback_saysItCantOpenSecurely() async throws {
        fake.answerMeetings(.hang)
        let controller = recap()
        await openedRecapLoading(controller)
        let webView = try XCTUnwrap(controller.webView)
        let failures: [NSError] = [
            URLError(.serverCertificateUntrusted) as NSError, URLError(.secureConnectionFailed) as NSError,
            NSError(domain: "WebKitErrorDomain", code: -1202),
        ]
        for error in failures {
            for provisional in [true, false] {
                controller.tryAgain()
                await waitUntil { controller.screen == .loading }
                if provisional {
                    controller.webView(webView, didFailProvisionalNavigation: nil, withError: error)
                } else {
                    controller.webView(webView, didFail: nil, withError: error)
                }
                XCTAssertEqual(controller.screen, .insecure, "\(error.domain) \(error.code) provisional: \(provisional)")
            }
        }
        XCTAssertEqual(announced, Array(repeating: "Can't open this server securely", count: 6))
    }

    private func openedRecapLoading(_ controller: RecapWindowController) async {
        await controller.show(meetingId: meetingId, seriesId: fake.seriesId, title: "Weekly sync").value
        await waitUntil { fake.server.requests(fake.meetingPath(meetingId)).count == 1 }
    }

    // MARK: - One window

    func test_theSameMeetingFocusesTheWindow_anotherMeetingNavigatesItWithoutSigningInAgain() async {
        let controller = recap()
        await openedRecap(controller)
        let window = controller.window
        let before = fake.server.requests.count

        await controller.show(meetingId: meetingId, seriesId: fake.seriesId, title: "Weekly sync").value
        XCTAssertEqual(controller.screen, .page, "the recap stays on screen, no skeleton")
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(fake.server.requests.count, before, "the same meeting only comes to the front")
        XCTAssertTrue(controller.window === window)

        await controller.show(meetingId: otherMeeting, seriesId: fake.seriesId, title: "Board prep").value
        await waitUntil { controller.screen == .page && controller.webView?.url?.path == fake.meetingPath(otherMeeting) }
        XCTAssertEqual(paths(after: before), ["GET \(fake.meetingPath(otherMeeting))"])
        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(controller.window?.title, "Board prep")
        XCTAssertEqual(NSApp.windows.filter { $0.frameAutosaveName == "MinutiaRecap" && $0.isVisible }.count, 1)
    }

    func test_copyLink_copiesTheMeetingsWebAddress_neverTheSignInHandoff() async {
        let controller = recap()
        await openedRecap(controller)

        click(toolbarItem(controller, "Copy link"))
        click(toolbarItem(controller, "Open in browser"))

        XCTAssertEqual(copied, [page(meetingId).absoluteString])
        XCTAssertEqual(opened.map(\.absoluteString), [page(meetingId).absoluteString])
    }

    func test_keyboard_commandBracketGoesBack_commandRReloads_commandShiftCCopiesTheLink() async {
        let controller = recap()
        await openedRecap(controller)
        await controller.show(meetingId: otherMeeting, seriesId: fake.seriesId, title: "Board prep").value
        await waitUntil { controller.screen == .page && controller.webView?.url?.path == fake.meetingPath(otherMeeting) }

        press("C", [.command, .shift], in: controller.window)
        XCTAssertEqual(copied, [page(otherMeeting).absoluteString])

        press("[", .command, in: controller.window)
        await waitUntil { controller.webView?.url?.path == fake.meetingPath(meetingId) && controller.webView?.isLoading == false }
        try? await Task.sleep(nanoseconds: 300_000_000)

        let before = fake.server.requests(fake.meetingPath(meetingId)).count
        press("r", .command, in: controller.window)
        await waitUntil { fake.server.requests(fake.meetingPath(meetingId)).count == before + 1 }
    }

    func test_commandW_closesTheWindow_andTheDockIconGoes_whileTheAppKeepsRunning() async throws {
        let controller = recap()
        await openedRecap(controller)
        let window = try XCTUnwrap(controller.window)

        press("w", .command, in: window)

        await waitUntil { controller.window == nil }
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(policies, [.regular, .accessory])
    }

    func test_theDockIconStays_whileSettingsClosesAndTheRecapIsStillOpen() async {
        let controller = recap()
        presence.opened("settings")
        await openedRecap(controller)

        presence.closed("settings")
        XCTAssertEqual(policies, [.regular])

        controller.window?.performClose(nil)
        await waitUntil { controller.window == nil }
        XCTAssertEqual(policies, [.regular, .accessory])
    }

    func test_theDockIconStays_whileTheNotesWindowOpenedAfterTheRecapIsStillOpen() async {
        let notes = NotepadPanel(presence: presence) { NSView() }
        let controller = recap()
        await openedRecap(controller)
        notes.show(focus: false)

        controller.window?.performClose(nil)
        await waitUntil { controller.window == nil }
        XCTAssertEqual(policies, [.regular])

        notes.hide()
        XCTAssertEqual(policies, [.regular, .accessory])
    }

    func test_recordingWithOnlyTheNotesWindow_neverGivesADockIcon() {
        let notes = NotepadPanel(presence: presence) { NSView() }

        notes.show(focus: false)
        notes.show(focus: true)
        notes.hide()
        notes.show(focus: false)

        XCTAssertEqual(policies, [], "the notes window never turns the menu-bar app into a Dock app")
        notes.hide()
        XCTAssertEqual(policies, [])
    }

    func test_recapWindow_remembersItsSizeAndPosition() async {
        defer { UserDefaults.standard.removeObject(forKey: "NSWindow Frame MinutiaRecap") }
        let controller = recap()
        await openedRecap(controller)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 700)
        let frame = NSRect(x: visible.minX + 37, y: visible.minY + 23, width: 600, height: 450)
        controller.window?.setFrame(frame, display: false)
        controller.window?.performClose(nil)
        await waitUntil { controller.window == nil }

        let reopened = recap()
        await openedRecap(reopened)
        XCTAssertEqual(reopened.window?.frame, frame)
    }

    func test_wakingFromSleep_reloadsTheMeeting() async {
        let controller = recap()
        await openedRecap(controller)
        let before = fake.server.requests(fake.meetingPath(meetingId)).count

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)

        await waitUntil { fake.server.requests(fake.meetingPath(meetingId)).count == before + 1 && controller.screen == .page }
        XCTAssertEqual(fake.mintedDigests.count, 1)
    }

    // MARK: - What the page may do

    func test_aFileInputOnThePage_opensTheFilePanel_andThePageGetsTheChosenFiles() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("issues.csv")
        try Data("title\nSend the budget\n".utf8).write(to: file)
        chosenFiles = [file]
        fake.addToMeetingPage("<input type=file id=pick multiple onchange=\"fetch('/report?files='+[...this.files].map(f=>f.name).join(','))\">")
        let controller = recap()
        await openedRecap(controller)

        _ = try? await controller.webView?.evaluateJavaScript("document.getElementById('pick').click(); 1")
        await waitUntil { !fake.server.requests("/report").isEmpty }
        XCTAssertEqual(asked, ["files multiple=true"])
        XCTAssertEqual(fake.server.requests("/report").map(\.query), ["files=issues.csv"])
    }

    func test_thePagesConfirmAlertAndPrompt_showWhatThePersonAnswers() async {
        answer = true
        typed = "Board prep"
        fake.runOnMeetingPage(
            "alert('Saved'); fetch('/report?confirm='+confirm('Delete this item?')+'&prompt='+encodeURIComponent(prompt('Rename the series', 'Weekly sync')))")
        let controller = recap()
        await openedRecap(controller)

        await waitUntil { !fake.server.requests("/report").isEmpty }
        XCTAssertEqual(asked, ["alert Saved", "confirm Delete this item?", "prompt(defaultText: Optional(\"Weekly sync\")) Rename the series"])
        XCTAssertEqual(fake.server.requests("/report").map(\.query), ["confirm=true&prompt=Board%20prep"])
    }

    func test_aPageQuestionWithNoWindow_isAnsweredAtOnce_withoutAsking() async {
        answer = true
        typed = "Board prep"
        chosenFiles = [URL(fileURLWithPath: "/tmp/issues.csv")]
        let controller = recap()

        let confirmed = await controller.pageAsks(.confirm, "Delete this item?")
        let prompted = await controller.pageAsks(.prompt(defaultText: nil), "Rename the series")
        let files = await controller.pageChoosesFiles(multiple: true, directories: false)

        XCTAssertEqual(confirmed.ok, false)
        XCTAssertNil(prompted.ok ? prompted.text : nil)
        XCTAssertNil(files)
        XCTAssertEqual(asked, [], "nothing is shown without the recap window")
    }

    func test_aSecondPageQuestionWhileOneIsOpen_getsTheDefaultAtOnce() async {
        let controller = recap()
        await openedRecap(controller)
        var release: CheckedContinuation<(ok: Bool, text: String?), Never>?
        holdAnswer = { await withCheckedContinuation { release = $0 } }

        var kept: Bool?
        Task { kept = await controller.pageAsks(.confirm, "Delete this item?").ok }
        await waitUntil { release != nil }
        var answered: [String] = []
        Task {
            let second = await controller.pageAsks(.confirm, "Delete that one too?")
            let files = await controller.pageChoosesFiles(multiple: false, directories: false)
            answered = ["confirm \(second.ok)", "files \(files.map(\.count) ?? 0)"]
        }
        await waitUntil { !answered.isEmpty }
        XCTAssertEqual(answered, ["confirm false", "files 0"])
        XCTAssertEqual(asked, ["confirm Delete this item?"], "one question at a time")

        release?.resume(returning: (true, nil))
        await waitUntil { kept != nil }
        XCTAssertEqual(kept, true, "the open question keeps the person's answer")
    }

    func test_closingTheWindowWithAQuestionOpen_answersItOnceWithTheDefault() async {
        let controller = recap()
        await openedRecap(controller)
        var release: CheckedContinuation<(ok: Bool, text: String?), Never>?
        holdAnswer = { await withCheckedContinuation { release = $0 } }
        var answers: [Bool] = []

        Task {
            let answer = await controller.pageAsks(.confirm, "Delete this item?")
            answers.append(answer.ok)
        }
        await waitUntil { release != nil }
        controller.window?.close()
        await waitUntil { !answers.isEmpty }
        XCTAssertEqual(answers, [false])

        release?.resume(returning: (true, nil))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(answers, [false], "a late answer is not delivered a second time")
    }

    func test_thePageAskingForTheMicrophoneOrCamera_isRefused() async throws {
        let catcher = FrameCatcher()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(catcher, name: "frame")
        let page = WKWebView(frame: .zero, configuration: configuration)
        page.loadHTMLString("<script>webkit.messageHandlers.frame.postMessage(1)</script>", baseURL: fake.base)
        await waitUntil { catcher.frame != nil }
        let frame = try XCTUnwrap(catcher.frame)
        let controller = recap()
        await openedRecap(controller)
        let webView = try XCTUnwrap(controller.webView)

        for type in [WKMediaCaptureType.microphone, .camera, .cameraAndMicrophone] {
            let decision = await controller.webView(webView, decideMediaCapturePermissionsFor: frame.securityOrigin, initiatedBy: frame, type: type)
            XCTAssertEqual(decision, .deny, "\(type.rawValue)")
        }
    }

    func test_linksToOtherSitesNewWindowsAndMail_openOutside_andTheRecapStays() async {
        let controller = recap()
        await openedRecap(controller)

        _ = try? await controller.webView?.evaluateJavaScript("location.href = 'https://github.com/shiprite-dev'; 1")
        await waitUntil { opened.count == 1 }
        _ = try? await controller.webView?.evaluateJavaScript("window.open('\(page(otherMeeting).absoluteString)', '_blank'); 1")
        await waitUntil { opened.count == 2 }
        _ = try? await controller.webView?.evaluateJavaScript("location.href = 'mailto:owner@example.com'; 1")
        await waitUntil { opened.count == 3 }
        _ = try? await controller.webView?.evaluateJavaScript("location.href = 'javascript:document.title=1'; 1")
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com/shiprite-dev", page(otherMeeting).absoluteString, "mailto:owner@example.com"])
        XCTAssertEqual(controller.webView?.url?.path, fake.meetingPath(meetingId))
        let text = await pageText(controller)
        XCTAssertEqual(text, "Recap for Weekly sync")
    }

    func test_aServerRedirectToAnotherSite_opensInTheBrowser_andNeverLoadsInTheWindow() async {
        let away = elsewhere.base.appendingPathComponent("away").absoluteString
        fake.answerMeetings(.respond(status: 302, headers: ["Location": away], body: ""))
        let controller = recap()
        await controller.show(meetingId: meetingId, seriesId: fake.seriesId, title: "Weekly sync").value

        await waitUntil { opened.count == 1 }
        XCTAssertEqual(opened.map(\.absoluteString), [away])
        XCTAssertEqual(elsewhere.server.requests.count, 0)
    }

    func test_aFrameFromAnotherSiteIsBlocked_andAFrameFromTheSameServerLoads() async {
        fake.addToMeetingPage("<iframe src=\"\(elsewhere.base.absoluteString)/frame\"></iframe><iframe src=\"/frame-same\"></iframe>")
        let controller = recap()
        await openedRecap(controller)

        await waitUntil { fake.server.requests("/frame-same").count == 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(elsewhere.server.requests.count, 0)
        XCTAssertEqual(opened, [])
    }

    // MARK: - Web data removal

    func test_theExactLineMatcher_rejectsNegationsExtraWordsAndDigits() {
        let seen = Seen(text: "", frames: [("You're not offline", .zero), ("You're offline now", .zero), ("Keep 12", .zero), ("Taking longer than usual", .zero)])
        XCTAssertFalse(seen.hasLine("You're offline"))
        XCTAssertFalse(seen.hasLine("Keep 1"))
        XCTAssertFalse(seen.hasLine("Taking longer"))
        XCTAssertTrue(seen.hasLine("Taking longer than usual"))
        let screen = Seen(text: "", frames: [("Weekly sync", CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.05)), ("Not available", CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05))])
        XCTAssertTrue(screen.reads(["Weekly sync", "Not available"]))
        XCTAssertFalse(screen.reads(["Weekly sync", "available"]), "an extra word is not the same screen")
        XCTAssertFalse(screen.reads(["Weekly sync"]), "a missing line is not the same screen")
        XCTAssertFalse(screen.reads(["Not available", "Weekly sync"]), "order counts")
        let withIcons = Seen(text: "", frames: [
            ("Weekly sync", CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.05)), ("X", CGRect(x: 0.9, y: 0.8, width: 0.03, height: 0.05)),
            ("!", CGRect(x: 0.1, y: 0.6, width: 0.03, height: 0.05)), ("Not available", CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05)),
        ])
        XCTAssertTrue(withIcons.reads(["Weekly sync", "Not available"]), "a lone icon glyph is not a word")
        let glued = Seen(text: "", frames: [("Weekly sync", CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.05)), ("X Not available", CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05))])
        XCTAssertFalse(glued.reads(["Weekly sync", "Not available"]), "a glyph inside a line still counts")
        let negated = Seen(text: "", frames: [("Weekly sync", CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.05)), ("Not not available", CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05))])
        XCTAssertFalse(negated.reads(["Weekly sync", "Not available"]), "a negated line is not the same screen")
    }

    func test_launchPruning_leavesDataStoresTheAppDidNotMake() async {
        let made = await madeStore(UUID().uuidString.lowercased())
        let foreign = UUID()
        let stores = StoreDouble([made, foreign])

        await recap(stores: stores.stores).pruneStores(keeping: nil)

        XCTAssertEqual(stores.removed, [made])
        XCTAssertEqual(stores.ids, [foreign])
    }

    func test_aRemovalThatFails_isRetriedAtTheNextLaunch() async {
        let stuck = await madeStore(UUID().uuidString.lowercased())
        let first = StoreDouble([stuck])
        first.failing = [stuck]
        await recap(stores: first.stores).forgetWebSessions()
        XCTAssertEqual(first.ids, [stuck])

        let nextLaunch = StoreDouble([])
        await recap(stores: nextLaunch.stores).pruneStores(keeping: nil)

        XCTAssertEqual(nextLaunch.removed, [stuck])
    }

    // MARK: - Through the app

    private func app(stores: RecapStores = .webKit) -> AppController {
        let app = AppController(
            defaults: defaults, openURL: { [weak self] in self?.opened.append($0) }, micCheck: { (.authorized, true) },
            reviewClock: clock.review, windowPresence: presence, recapStores: stores)
        apps.append(app)
        return app
    }

    private func signedInApp(stores: RecapStores = .webKit) async throws -> AppController {
        let app = app(stores: stores)
        await app.authManager.adopt(testSupabase(fake.base), instance: fake.base)
        try await app.authManager.signIn(email: "first@example.com", password: "pw")
        return app
    }

    private var signedInStore: UUID {
        NSUUID(uuidBytes: Array(SHA256.hash(data: Data("\(fake.base.absoluteString)|\(signedInUser)".utf8)))) as UUID
    }

    private func storeGone(_ store: UUID) async -> Bool {
        for _ in 0..<100 {
            if await !WKWebsiteDataStore.allDataStoreIdentifiers.contains(store) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    func test_openRecap_fromThePanel_opensTheSignedInWindow() async throws {
        let app = try await signedInApp()

        app.openRecap(meetingId)

        await waitUntil { app.recapWindow.screen == .page }
        let text = await pageText(app.recapWindow)
        XCTAssertEqual(text, "Recap for Weekly sync")
        XCTAssertEqual(opened, [])
    }

    func test_openRecap_onAnOlderServer_opensTheMeetingInTheBrowser() async throws {
        fake.refuseMints(404)
        let app = try await signedInApp()

        app.openRecap(meetingId)

        await waitUntil { opened.count == 1 }
        XCTAssertEqual(opened.map(\.absoluteString), [page(meetingId).absoluteString])
        await waitUntil { app.recapWindow.window == nil }
    }

    func test_openingTheRecapOffline_withAnExpiredMacSession_saysYoureOffline_andOpensNoBrowser() async throws {
        fake.signInReturns(AuthServerStub.expiredSessionBody)
        let app = try await signedInApp()
        fake.server.stop()

        await app.recapWindow.show(meetingId: meetingId, seriesId: fake.seriesId, title: "Weekly sync").value

        await waitUntil { app.recapWindow.screen == .offline }
        XCTAssertEqual(opened, [])
        let seen = onScreen(app.recapWindow)
        XCTAssertTrue(seen.hasLine("You're offline"), seen.text)
    }

    func test_webSessionExpiresWhileReading_reloadShowsSignIn_macStaysSignedIn() async throws {
        let app = try await signedInApp()
        app.openRecap(meetingId)
        await waitUntil { app.recapWindow.screen == .page }

        fake.expireWebSessions()
        press("r", .command, in: app.recapWindow.window)

        await waitUntil { app.recapWindow.webView?.url?.path == "/login" && app.recapWindow.webView?.isLoading == false }
        let text = await pageText(app.recapWindow)
        XCTAssertEqual(text, "Sign in to Minutia")
        XCTAssertEqual(app.authManager.userEmail, "first@example.com", "the Mac stays signed in")
        XCTAssertNotNil(app.recapWindow.window, "the window stays open")
    }

    func test_signingOutOnTheMac_closesTheWindow_andErasesItsWebData() async throws {
        let app = try await signedInApp()
        app.openRecap(meetingId)
        await waitUntil { app.recapWindow.screen == .page }
        let before = await WKWebsiteDataStore.allDataStoreIdentifiers
        XCTAssertTrue(before.contains(signedInStore))

        await app.authManager.signOut()

        await waitUntil { app.recapWindow.window == nil }
        let gone = await storeGone(signedInStore)
        XCTAssertTrue(gone)
    }

    func test_switchingTheMacToAnotherServer_closesTheWindow_andErasesItsWebData() async throws {
        let app = try await signedInApp()
        app.openRecap(meetingId)
        await waitUntil { app.recapWindow.screen == .page }

        await app.authManager.adopt(testSupabase(elsewhere.base), instance: elsewhere.base)

        await waitUntil { app.recapWindow.window == nil }
        let gone = await storeGone(signedInStore)
        XCTAssertTrue(gone)
    }

    func test_launchingSignedOut_erasesEveryRecapWebStore_andNothingElse() async {
        let made = [await madeStore(UUID().uuidString.lowercased()), await madeStore(UUID().uuidString.lowercased())]
        let foreign = UUID()
        let leftovers = StoreDouble(made + [foreign])
        let app = app(stores: leftovers.stores)
        await app.authManager.adopt(testSupabase(fake.base), instance: fake.base)

        await app.restoreSession()

        XCTAssertEqual(Set(leftovers.removed), Set(made))
        XCTAssertEqual(leftovers.ids, [foreign])
    }

    func test_launchingSignedIn_keepsThisAccountsWebStore_andErasesTheRest() async throws {
        let stale = await madeStore(UUID().uuidString.lowercased())
        let stores = StoreDouble([signedInStore, stale])
        let app = try await signedInApp(stores: stores.stores)

        await app.restoreSession()

        XCTAssertEqual(stores.removed, [stale])
        XCTAssertEqual(stores.ids, [signedInStore])
    }
}

private final class FrameCatcher: NSObject, WKScriptMessageHandler {
    var frame: WKFrameInfo?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        frame = message.frameInfo
    }
}
