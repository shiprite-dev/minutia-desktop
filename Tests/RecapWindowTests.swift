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
                return mintStatus == 200
                    ? .respond(status: 200, headers: json, body: "{\"handoff_id\":\"handoff-\(digests.count)\"}")
                    : .respond(status: mintStatus, headers: json, body: "{\"error\":\"refused\"}")
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
        case ("GET", "/report"):
            return .respond(status: 204, headers: [:], body: "")
        case ("POST", "/auth/v1/token"):
            return .respond(status: 200, headers: json.merging(["X-Supabase-Api-Version": "2024-01-01"]) { $1 }, body: AuthServerStub.validSessionBody)
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
                return .respond(status: 200, headers: [:], body: "<html><body><h1>Recap for Weekly sync</h1><script>\(meetingScript)</script></body></html>")
            }
        default:
            return .respond(status: 404, headers: json, body: "{}")
        }
    }

    var mintedDigests: [String] { lock.withLock { digests } }
}

@MainActor
final class RecapWindowTests: XCTestCase {
    private var fake: FakeMinutia!
    private var clock: TestClock!
    private var opened: [URL] = []
    private var copied: [String] = []
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
        clock = TestClock()
        opened = []
        copied = []
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
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private func recap(userId: String? = UUID().uuidString.lowercased(), token: @escaping () async throws -> String = { "token" }) -> RecapWindowController {
        let base = fake.base
        let controller = RecapWindowController(
            account: { (MinutiaClient(instance: base, supabase: testSupabase(base), tokenProvider: token), userId) },
            openURL: { [weak self] in self?.opened.append($0) }, copy: { [weak self] in self?.copied.append($0) },
            clock: clock.review, presence: presence)
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

    private func openedRecap(_ controller: RecapWindowController, _ meeting: UUID? = nil) async {
        await controller.show(meetingId: meeting ?? meetingId, seriesId: fake.seriesId, title: "Weekly sync").value
        await waitUntil { controller.screen == .page }
    }

    // MARK: - Navigation rules

    func test_whereEachLinkOpens_sameServerInTheWindow_everythingElseInTheBrowser_scriptsNowhere() {
        let instance = URL(string: "https://minutia.example.com")!
        let decide = { (url: String, main: Bool, download: Bool) in
            RecapNavigation.decide(url: URL(string: url)!, instance: instance, isMainFrame: main, isDownload: download)
        }
        XCTAssertEqual(decide("https://minutia.example.com/issues/42", true, false), .allow)
        XCTAssertEqual(decide("https://MINUTIA.example.com:443/series", true, false), .allow)
        XCTAssertEqual(decide("https://github.com/shiprite-dev", true, false), .openInBrowser)
        XCTAssertEqual(decide("http://minutia.example.com/issues/42", true, false), .openInBrowser)
        XCTAssertEqual(decide("https://minutia.example.com:8443/issues/42", true, false), .openInBrowser)
        XCTAssertEqual(decide("https://minutia.example.com/issues/42", false, false), .openInBrowser)
        XCTAssertEqual(decide("https://minutia.example.com/api/export.csv", true, true), .openInBrowser)
        XCTAssertEqual(decide("javascript:alert(document.cookie)", true, false), .deny)
        XCTAssertEqual(decide("file:///etc/passwd", true, false), .deny)
        XCTAssertEqual(decide("minutia://record", true, false), .deny)
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

        XCTAssertEqual(fake.server.requests.map { "\($0.method) \($0.path)" }, [
            "POST /api/companion/web-session",
            "POST /auth/companion-session",
            "GET \(fake.meetingPath(meetingId))",
        ])
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

    func test_reopening_withTheWebSessionStillValid_loadsTheRecapWithoutAnotherHandoff() async {
        let first = recap(userId: "ec4109b3-9e36-4a3d-8701-ac066af779f1")
        await openedRecap(first)
        first.window?.performClose(nil)
        await waitUntil { first.window == nil }
        let before = fake.server.requests.count

        await openedRecap(first)

        XCTAssertEqual(fake.server.requests.dropFirst(before).map { "\($0.method) \($0.path)" }, ["GET \(fake.meetingPath(meetingId))"])
        XCTAssertEqual(fake.mintedDigests.count, 1)
        let text = await pageText(first)
        XCTAssertEqual(text, "Recap for Weekly sync")
    }

    func test_anExpiredWebSession_mintsOneHandoff_andNeverShowsTheSignInPage() async {
        let controller = recap()
        await openedRecap(controller)
        controller.window?.performClose(nil)
        await waitUntil { controller.window == nil }
        fake.expireWebSessions()

        await openedRecap(controller)

        XCTAssertEqual(fake.mintedDigests.count, 2)
        XCTAssertEqual(fake.server.requests("/login").count, 0)
        let text = await pageText(controller)
        XCTAssertEqual(text, "Recap for Weekly sync")
    }

    func test_aRefusedHandoff_showsTheWebSignInPage_andAsksOnlyOnce() async {
        fake.refuseMints(429)
        let controller = recap()
        await openedRecap(controller)

        let text = await pageText(controller)
        XCTAssertEqual(text, "Sign in to Minutia")
        XCTAssertEqual(fake.mintedDigests.count, 1)
        XCTAssertEqual(fake.server.requests("/auth/companion-session").count, 0)
        XCTAssertEqual(opened, [])
    }

    func test_anOlderServer_opensTheMeetingInTheBrowser_andNoWindowStays() async {
        fake.refuseMints(404)
        let controller = recap()
        await controller.show(meetingId: meetingId, seriesId: fake.seriesId, title: "Weekly sync").value
        await waitUntil { opened.count == 1 && controller.window == nil }

        XCTAssertEqual(opened.map(\.absoluteString), [page(meetingId).absoluteString])
        XCTAssertEqual(policies, [.regular, .accessory])
    }

    // MARK: - What the window shows

    func test_offlineWhileSigningIn_saysYoureOffline_withTryAgain() async {
        let controller = recap(token: { throw URLError(.notConnectedToInternet) })
        await controller.show(meetingId: meetingId, seriesId: fake.seriesId, title: "Weekly sync").value
        await waitUntil { controller.screen == .offline }

        let seen = onScreen(controller)
        XCTAssertTrue(seen.has("You're offline"), seen.text)
        XCTAssertTrue(seen.has("Try again"), seen.text)
        XCTAssertFalse(seen.has("Taking longer than usual"), seen.text)
        XCTAssertEqual(controller.webView?.isHidden, true)
    }

    func test_theConnectionDropsWhileLoading_saysYoureOffline_andTryAgainShowsTheRecap() async {
        fake.answerMeetings(.drop)
        let controller = recap()
        await controller.show(meetingId: meetingId, seriesId: fake.seriesId, title: "Weekly sync").value
        await waitUntil { controller.screen == .offline }
        let seen = onScreen(controller)
        XCTAssertTrue(seen.has("You're offline"), seen.text)
        XCTAssertFalse(seen.has("Recap for Weekly sync"), seen.text)

        fake.answerMeetings(nil)
        controller.tryAgain()
        await waitUntil { controller.screen == .page }
        let text = await pageText(controller)
        XCTAssertEqual(text, "Recap for Weekly sync")
    }

    func test_aSlowServer_showsTheTitle_thenAfterEightSecondsSaysTakingLonger_withTryAgainAndOpenInBrowser() async {
        fake.answerMeetings(.hang)
        let controller = recap()
        await controller.show(meetingId: meetingId, seriesId: fake.seriesId, title: "Weekly sync").value
        await waitUntil { fake.server.requests(fake.meetingPath(meetingId)).count == 1 }

        clock.advance(7.9)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let early = onScreen(controller)
        XCTAssertTrue(early.has("Weekly sync"), early.text)
        XCTAssertFalse(early.has("Taking longer than usual"), early.text)
        XCTAssertEqual(controller.webView?.isHidden, true)

        clock.advance(0.1)
        await waitUntil { controller.screen == .slow }
        let late = onScreen(controller)
        XCTAssertTrue(late.has("Taking longer than usual"), late.text)
        XCTAssertTrue(late.has("Try again"), late.text)
        XCTAssertTrue(late.has("Open in browser"), late.text)

        controller.openInBrowser()
        XCTAssertEqual(opened.map(\.absoluteString), [page(meetingId).absoluteString])
    }

    func test_aServerCertificateTheMacRejects_saysItCantOpenSecurely_withOpenInBrowser() async throws {
        fake.answerMeetings(.hang)
        let controller = recap()
        await controller.show(meetingId: meetingId, seriesId: fake.seriesId, title: "Weekly sync").value
        let webView = try XCTUnwrap(controller.webView)
        controller.webView(webView, didFailProvisionalNavigation: nil, withError: URLError(.serverCertificateUntrusted) as NSError)

        let seen = onScreen(controller)
        XCTAssertTrue(seen.has("Can't open this server securely"), seen.text)
        XCTAssertTrue(seen.has("Open in browser"), seen.text)
        XCTAssertFalse(seen.has("You're offline"), seen.text)
        XCTAssertFalse(seen.has("Try again"), seen.text)
    }

    // MARK: - One window

    func test_theSameMeetingFocusesTheWindow_anotherMeetingNavigatesIt() async {
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

    func test_commandW_closesTheWindow_andTheDockIconGoes_whileTheAppKeepsRunning() async throws {
        let controller = recap()
        await openedRecap(controller)
        let window = try XCTUnwrap(controller.window)
        let commandW = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))

        XCTAssertTrue(window.performKeyEquivalent(with: commandW))

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

    func test_wakingFromSleep_reloadsTheMeeting() async {
        let controller = recap()
        await openedRecap(controller)
        let before = fake.server.requests(fake.meetingPath(meetingId)).count

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)

        await waitUntil { fake.server.requests(fake.meetingPath(meetingId)).count == before + 1 && controller.screen == .page }
    }

    // MARK: - What the page may do

    func test_thePageAskingForTheMicrophone_isRefused() async {
        fake.runOnMeetingPage(
            "navigator.mediaDevices.getUserMedia({audio:true}).then(()=>fetch('/report?mic=granted')).catch(e=>fetch('/report?mic='+e.name))")
        let controller = recap()
        await openedRecap(controller)

        await waitUntil { !fake.server.requests("/report").isEmpty }
        XCTAssertEqual(fake.server.requests("/report").map(\.query), ["mic=NotAllowedError"])
    }

    func test_linksToOtherSitesAndNewWindows_openInTheBrowser_andTheRecapStays() async {
        let controller = recap()
        await openedRecap(controller)

        _ = try? await controller.webView?.evaluateJavaScript("location.href = 'https://github.com/shiprite-dev'; 1")
        await waitUntil { opened.count == 1 }
        _ = try? await controller.webView?.evaluateJavaScript("window.open('\(page(otherMeeting).absoluteString)', '_blank'); 1")
        await waitUntil { opened.count == 2 }
        _ = try? await controller.webView?.evaluateJavaScript("location.href = 'javascript:document.title=1'; 1")
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com/shiprite-dev", page(otherMeeting).absoluteString])
        XCTAssertEqual(controller.webView?.url?.path, fake.meetingPath(meetingId))
        let text = await pageText(controller)
        XCTAssertEqual(text, "Recap for Weekly sync")
    }

    // MARK: - Through the app

    private func signedInApp() async throws -> AppController {
        let app = AppController(
            defaults: UserDefaults(suiteName: suite)!, openURL: { [weak self] in self?.opened.append($0) }, micCheck: { (.authorized, true) },
            reviewClock: clock.review, windowPresence: presence)
        apps.append(app)
        await app.authManager.adopt(testSupabase(fake.base), instance: fake.base)
        try await app.authManager.signIn(email: "first@example.com", password: "pw")
        return app
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

    func test_signingOutOnTheMac_closesTheWindow_andErasesItsWebData() async throws {
        let app = try await signedInApp()
        app.openRecap(meetingId)
        await waitUntil { app.recapWindow.screen == .page }
        let digest = Array(SHA256.hash(data: Data("\(fake.base.absoluteString)|\(signedInUser)".utf8)))
        let store = NSUUID(uuidBytes: digest) as UUID
        let before = await WKWebsiteDataStore.allDataStoreIdentifiers
        XCTAssertTrue(before.contains(store))

        await app.authManager.signOut()

        await waitUntil { app.recapWindow.window == nil }
        var after = await WKWebsiteDataStore.allDataStoreIdentifiers
        for _ in 0..<100 where after.contains(store) {
            try? await Task.sleep(nanoseconds: 50_000_000)
            after = await WKWebsiteDataStore.allDataStoreIdentifiers
        }
        XCTAssertFalse(after.contains(store))
    }
}
