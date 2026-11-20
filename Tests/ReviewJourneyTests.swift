import SwiftUI
import XCTest
@testable import Minutia

/// The instance's review routes, driven from shapes captured off the real review-queue route. Saves
/// change what later reads return, the way the server's database does.
final class ReviewServer: URLProtocol {
    struct Seen {
        let method: String
        let host: String
        let path: String
        let query: String?
        let body: [String: Any]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var meetings: [String: [String: Any]] = [:]
    nonisolated(unsafe) private static var order: [String] = []
    nonisolated(unsafe) private static var gone: Set<String> = []
    nonisolated(unsafe) private static var refusals: [String: (Int, String)] = [:]
    nonisolated(unsafe) private static var held: [() -> Void] = []
    nonisolated(unsafe) private static var seen: [Seen] = []
    nonisolated(unsafe) private static var offlineFlag = false
    nonisolated(unsafe) private static var holdFlag = false
    nonisolated(unsafe) private static var loseFlag = false
    nonisolated(unsafe) private static var onRetry: [String: [String: Any]] = [:]
    nonisolated(unsafe) private static var holdRetryFlag = false
    nonisolated(unsafe) private static var refuseRetryFlag = false

    static func reset() {
        lock.withLock {
            meetings = [:]; order = []; gone = []; refusals = [:]; held = []; seen = []
            offlineFlag = false; holdFlag = false; loseFlag = false; onRetry = [:]; holdRetryFlag = false; refuseRetryFlag = false
        }
    }

    static var offline: Bool {
        get { lock.withLock { offlineFlag } }
        set { lock.withLock { offlineFlag = newValue } }
    }

    /// The server saves, then the connection drops before its answer reaches the Mac.
    static var loseAnswers: Bool {
        get { lock.withLock { loseFlag } }
        set { lock.withLock { loseFlag = newValue } }
    }

    static var holdSaves: Bool {
        get { lock.withLock { holdFlag } }
        set { lock.withLock { holdFlag = newValue } }
    }

    /// Try again requests wait until `releaseSaves()`.
    static var holdRetries: Bool {
        get { lock.withLock { holdRetryFlag } }
        set { lock.withLock { holdRetryFlag = newValue } }
    }

    static var refuseRetries: Bool {
        get { lock.withLock { refuseRetryFlag } }
        set { lock.withLock { refuseRetryFlag = newValue } }
    }

    static var retries: [Seen] { requests.filter { $0.method == "POST" } }

    static func put(_ meeting: [String: Any]) {
        let id = meeting["meeting_id"] as! String
        lock.withLock {
            if meetings[id] == nil { order.insert(id, at: 0) }
            meetings[id] = meeting
        }
    }

    static func update(_ id: UUID, _ change: (inout [String: Any]) -> Void) {
        lock.withLock { change(&meetings[id.uuidString.lowercased()]!) }
    }

    static func delete(_ id: UUID) { _ = lock.withLock { gone.insert(id.uuidString.lowercased()) } }

    static func refuse(_ suggestion: UUID, status: Int, code: String) {
        lock.withLock { refusals[suggestion.uuidString.lowercased()] = (status, "{\"error\":\"Server words\",\"code\":\"\(code)\"}") }
    }

    static func afterRetry(_ id: UUID, becomes meeting: [String: Any]) {
        lock.withLock { onRetry[id.uuidString.lowercased()] = meeting }
    }

    static func releaseSaves() {
        let pending = lock.withLock { () -> [() -> Void] in
            defer { held = [] }
            return held
        }
        pending.forEach { $0() }
    }

    static var requests: [Seen] { lock.withLock { seen } }
    static var saves: [Seen] { requests.filter { $0.method == "PATCH" } }
    static var meetingReads: Int { requests.filter { $0.method == "GET" && $0.query?.hasPrefix("meeting=") == true }.count }
    static func pendingRows(_ id: UUID) -> [String] {
        lock.withLock { (meetings[id.uuidString.lowercased()]?["rows"] as? [[String: Any]])?.map { $0["title"] as! String } ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let data = request.httpBody ?? request.httpBodyStream.map(Self.drain) ?? Data()
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let method = request.httpMethod ?? "GET"
        let (outcome, hold) = Self.lock.withLock { () -> (Result<(Int, String), URLError>, Bool) in
            Self.seen.append(Seen(method: method, host: url.host ?? "", path: url.path, query: url.query, body: body))
            if Self.offlineFlag { return (.failure(URLError(.notConnectedToInternet)), false) }
            let answer = Self.answer(method: method, path: url.path, query: url.query, body: body)
            if method == "PATCH" && Self.loseFlag { return (.failure(URLError(.networkConnectionLost)), false) }
            return (.success(answer), (method == "PATCH" && Self.holdFlag) || (method == "POST" && Self.holdRetryFlag))
        }
        let finish = { [self] in
            switch outcome {
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
            case .success(let (status, text)):
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(text.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        if hold { Self.lock.withLock { Self.held.append(finish) } } else { finish() }
    }

    private static func answer(method: String, path: String, query: String?, body: [String: Any]) -> (Int, String) {
        let parts = path.split(separator: "/").map(String.init)
        switch (method, parts.count) {
        case ("GET", _) where path == "/api/companion/review-queue":
            let me = "00000000-0000-0000-0000-000000000001"
            if let query, query.hasPrefix("meeting=") {
                let id = String(query.dropFirst("meeting=".count))
                guard let meeting = meetings[id], !gone.contains(id) else { return (404, "{\"code\":\"meeting_gone\"}") }
                return (200, json(["me": me, "meetings": [meeting]]))
            }
            return (200, json(["me": me, "meetings": order.filter { !gone.contains($0) }.compactMap { meetings[$0] }]))
        case ("PATCH", 5):
            let (meeting, suggestion) = (parts[2], parts[4])
            if gone.contains(meeting) { return (404, "{\"code\":\"suggestion_gone\"}") }
            if let refusal = refusals[suggestion] { return refusal }
            let left = (meetings[meeting]?["rows"] as? [[String: Any]])?.filter { $0["id"] as? String != suggestion }
            meetings[meeting]?["rows"] = left
            return (200, "{\"suggestion\":{},\"code\":\"saved\"}")
        case ("POST", 4):
            if refuseRetryFlag { return (500, "{\"error\":\"Server words\"}") }
            if let next = onRetry[parts[2]] { meetings[parts[2]] = next }
            return (202, "{}")
        default:
            return (404, "{}")
        }
    }

    private static func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

@MainActor
final class TestClock {
    private(set) var now = ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!
    private var sleepers: [(id: UUID, due: Date, resume: CheckedContinuation<Void, Never>)] = []

    var sleeping: Int { sleepers.count }

    func sleep(_ seconds: TimeInterval) async {
        let due = now.addingTimeInterval(seconds)
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { return continuation.resume() }
                sleepers.append((id, due, continuation))
            }
        } onCancel: {
            Task { @MainActor in self.wake(id) }
        }
    }

    private func wake(_ id: UUID) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: index).resume.resume()
    }

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        let due = sleepers.filter { $0.due <= now }
        sleepers.removeAll { $0.due <= now }
        due.forEach { $0.resume.resume() }
    }

    func drain() {
        let all = sleepers
        sleepers = []
        all.forEach { $0.resume.resume() }
    }

    /// How often the review asked the time: it does so as it handles each answer.
    private(set) var nowReads = 0

    var review: ReviewClock {
        ReviewClock(now: { self.nowReads += 1; return self.now }, sleep: { await self.sleep($0) })
    }
}

@MainActor
final class ReviewJourneyTests: XCTestCase {
    private let instance = URL(string: "https://minutia.example.com")!
    private let otherInstance = URL(string: "https://other.example.com")!
    private let meetingId = UUID(uuidString: "3F95FFD6-FD1E-4640-AACC-89E1C051F742")!
    private let priya = UUID(uuidString: "EC4109B3-9E36-4A3D-8701-AC066AF779F1")!
    private var clock: TestClock!
    private var notices: [ReviewNotice] = []
    private var opened: [URL] = []
    private var announcements: [String] = []
    private var reviews: [ReviewController] = []
    private var apps: [AppController] = []
    private var suite: String!

    override func setUp() async throws {
        clock = TestClock()
        notices = []
        opened = []
        announcements = []
        suite = "ReviewJourneyTests.\(UUID().uuidString)"
        ReviewServer.reset()
        URLProtocol.registerClass(ReviewServer.self)
    }

    override func tearDown() async throws {
        reviews.forEach { $0.reset() }
        for app in apps {
            app.review.reset()
            app.handleDetection(.none)
        }
        reviews = []
        apps = []
        clock.drain()
        ReviewServer.holdSaves = false
        ReviewServer.releaseSaves()
        URLProtocol.unregisterClass(ReviewServer.self)
        ReviewServer.reset()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    // MARK: - Builders from the captured route response

    private func fixtureMeeting() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: ReviewJourneyTests.self).url(forResource: "review-queue-meeting", withExtension: "json"))
        let queue = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap((queue["meetings"] as? [[String: Any]])?.first)
    }

    private func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func row(_ id: UUID, _ title: String, confidence: Double = 0.92, type: String = "new_item") throws -> [String: Any] {
        var row = try XCTUnwrap((fixtureMeeting()["rows"] as? [[String: Any]])?[type == "new_item" ? 0 : 2])
        row["id"] = id.uuidString.lowercased()
        row["title"] = title
        row["confidence"] = confidence
        return row
    }

    private func meeting(
        _ id: UUID? = nil, transcription: String = "completed", suggestions: String? = "ready", rows: [[String: Any]] = [],
        reviewer: Bool = true, webOnly: Int = 0, endedAgo: TimeInterval = 60, statusAgo: TimeInterval = 0
    ) throws -> [String: Any] {
        var meeting = try fixtureMeeting()
        meeting["meeting_id"] = (id ?? meetingId).uuidString.lowercased()
        meeting["transcription_status"] = transcription
        meeting["suggestions_status"] = suggestions ?? NSNull()
        meeting["ended_at"] = stamp(clock.now.addingTimeInterval(-endedAgo))
        meeting["status_at"] = stamp(clock.now.addingTimeInterval(-statusAgo))
        meeting["reviewer"] = reviewer
        meeting["rows"] = rows
        meeting["web_only_count"] = webOnly
        return meeting
    }

    private func review() -> ReviewController {
        let review = ReviewController(
            client: { [instance] in Self.client(instance) }, clock: clock.review, defaults: UserDefaults(suiteName: suite)!,
            notify: { [weak self] in self?.notices.append($0) })
        review.announce = { [weak self] in self?.announcements.append($0) }
        reviews.append(review)
        return review
    }

    private static func client(_ instance: URL) -> MinutiaClient {
        MinutiaClient(instance: instance, supabase: testSupabase(URL(string: "https://supabase.example.com")!), tokenProvider: { "token" })
    }

    private func app() -> AppController {
        let app = AppController(
            defaults: UserDefaults(suiteName: suite)!, openURL: { [weak self] in self?.opened.append($0) }, micCheck: { (.authorized, true) },
            reviewClock: clock.review, postReviewNotice: { [weak self] in self?.notices.append($0) },
            reviewClient: { auth in auth.instance.map(Self.client) })
        app.announce = { [weak self] in self?.announcements.append($0) }
        apps.append(app)
        return app
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    /// Moves time on once something is waiting on it, so a poll scheduled a moment ago is not skipped.
    private func tick(_ seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil({ clock.sleeping > 0 }, file: file, line: line)
        clock.advance(seconds)
    }

    private func openPanel(_ review: ReviewController) async {
        await review.setPanelOpen(true)?.value
    }

    private func texts(_ review: ReviewController) -> [String] {
        review.groups.flatMap { [$0.title] + $0.rows.map(\.title) }
    }

    private func note(_ review: ReviewController, _ title: String) -> String? {
        review.groups.flatMap(\.rows).first { $0.title == title }?.note
    }

    // MARK: - Journeys

    func test_afterStop_progressThenThreeConfidentItems_keepThreeSaysThreeTracked() async throws {
        let app = app()
        await app.authManager.adopt(testSupabase(instance), instance: instance)
        app.apply(.signedIn)
        app.panelOpened()
        ReviewServer.put(try meeting(transcription: "processing", suggestions: nil, endedAgo: 0))

        app.apply(.recordStarted)
        app.apply(.recordStopped)
        app.apply(.finalized)
        app.presentRecapCue(RecapCue(meetingId: meetingId, seriesId: nil, instance: instance))
        await waitUntil { app.review.title == "Weekly sync" }
        XCTAssertEqual(app.review.model?.screen.message, "Transcribing")

        ReviewServer.update(meetingId) { $0["transcription_status"] = "completed"; $0["suggestions_status"] = "pending"; $0["status_at"] = self.stamp(self.clock.now) }
        await tick(3)
        await waitUntil { app.review.model?.screen == .finding }
        XCTAssertEqual(app.review.model?.screen.message, "Finding action items")

        let ids = [UUID(), UUID(), UUID()]
        let rows = try [row(ids[0], "Send the budget"), row(ids[1], "Book the Acme interview", confidence: 0.9), row(ids[2], "Draft the hiring plan", confidence: 0.85)]
        ReviewServer.update(meetingId) { $0["suggestions_status"] = "ready"; $0["rows"] = rows }
        await tick(3)
        await waitUntil { app.review.model?.screen == .ready }
        XCTAssertEqual(texts(app.review), ["New items", "Send the budget", "Book the Acme interview", "Draft the hiring plan"])
        XCTAssertEqual(app.review.buttons.map(\.title), ["Keep 3", "Skip the rest", "Open recap"])

        await app.review.keep()

        XCTAssertEqual(ReviewServer.saves.map(\.path), ids.map { "/api/meetings/3f95ffd6-fd1e-4640-aacc-89e1c051f742/suggestions/\($0.uuidString.lowercased())" })
        XCTAssertEqual(ReviewServer.saves.map { $0.body["action"] as? String }, ["accept", "accept", "accept"])
        XCTAssertEqual(app.review.model?.doneLine, "3 items tracked")
        XCTAssertEqual(app.review.buttons.map(\.title), ["Done", "Open recap"])
        XCTAssertEqual(ReviewServer.pendingRows(meetingId), [])
        XCTAssertEqual(announcements, ["Recording started", "Transcribing", "Finding action items", "3 action items from Weekly sync", "3 items tracked"])
        XCTAssertTrue(notices.isEmpty, "the panel was open, so nothing is posted")

        await tick(4)
        await waitUntil { app.review.model == nil }
        XCTAssertFalse(app.review.hasDot)
    }

    func test_openRecap_opensThatMeetingsPageOnTheWeb() async throws {
        let app = app()
        await app.authManager.adopt(testSupabase(instance), instance: instance)
        app.apply(.signedIn)
        ReviewServer.put(try meeting(rows: [row(UUID(), "Send the budget")]))
        app.presentRecapCue(RecapCue(meetingId: meetingId, seriesId: nil, instance: instance))
        await waitUntil { app.review.model?.screen == .ready }

        app.openRecap(meetingId)

        await waitUntil { opened.count == 1 }
        XCTAssertEqual(opened.map(\.absoluteString), [
            "https://minutia.example.com/series/b6008c45-d6ed-4cd8-bce4-9646a5994f0b/meetings/3f95ffd6-fd1e-4640-aacc-89e1c051f742",
        ])
    }

    func test_afterStop_noPageOpens_andTheReviewShowsTranscribingThenFinding() async throws {
        let app = app()
        await app.authManager.adopt(testSupabase(instance), instance: instance)
        app.apply(.signedIn)
        app.panelOpened()
        ReviewServer.put(try meeting(transcription: "processing", suggestions: nil, endedAgo: 0))
        app.apply(.recordStarted)
        app.apply(.recordStopped)

        app.finishStop(
            CaptureSession.StopResult(expectedSegments: 3, transcriptRequested: true), reason: .manual,
            meetingId: meetingId, seriesId: UUID(), instance: instance)

        XCTAssertEqual(app.phase, .idle)
        await waitUntil { app.review.model?.screen == .transcribing(elapsed: nil) && app.review.title == "Weekly sync" }
        ReviewServer.update(meetingId) { $0["transcription_status"] = "completed"; $0["suggestions_status"] = "pending"; $0["status_at"] = self.stamp(self.clock.now) }
        await tick(3)
        await waitUntil { app.review.model?.screen == .finding }
        XCTAssertEqual(opened, [], "the recap opens only from Open recap")
    }

    func test_keepWhoseAnswerIsLost_endsAsTracked_neverAsNoActionItems() async throws {
        ReviewServer.put(try meeting(rows: [row(UUID(), "Send the budget")]))
        let review = review()
        await openPanel(review)
        review.start(meetingId: meetingId)
        await waitUntil { review.model?.screen == .ready }

        ReviewServer.loseAnswers = true
        await review.keep()

        XCTAssertEqual(ReviewServer.pendingRows(meetingId), [], "the server kept it")
        XCTAssertEqual(review.model?.doneLine, "1 item tracked")
        XCTAssertEqual(ReviewServer.saves.count, 1)
    }

    func test_offlineAtKeep_eachRowSaysCouldntSave_andRetryKeepsItOnce() async throws {
        let (first, second) = (UUID(), UUID())
        ReviewServer.put(try meeting(rows: [row(first, "Send the budget"), row(second, "Book the Acme interview")]))
        let review = review()
        await openPanel(review)
        review.start(meetingId: meetingId)
        await waitUntil { review.model?.screen == .ready }

        ReviewServer.offline = true
        await review.keep()
        XCTAssertEqual(note(review, "Send the budget"), "Couldn't save. Try again.")
        XCTAssertEqual(note(review, "Book the Acme interview"), "Couldn't save. Try again.")
        XCTAssertEqual(review.buttons.first?.title, "Keep 2", "the selection survives a failed save")
        XCTAssertEqual(review.model?.screen, .ready)

        ReviewServer.offline = false
        await review.retry(first)
        XCTAssertEqual(note(review, "Send the budget"), "Kept")
        XCTAssertEqual(note(review, "Book the Acme interview"), "Couldn't save. Try again.")
        XCTAssertEqual(review.buttons.first?.title, "Keep 1")

        await review.keep()
        XCTAssertEqual(review.model?.doneLine, "2 items tracked")
        let accepted = ReviewServer.saves.filter { $0.path.hasSuffix(first.uuidString.lowercased()) }.count
        XCTAssertEqual(accepted, 2, "one refused while offline, one kept: never sent again after it was kept")
        XCTAssertEqual(ReviewServer.saves.count, 4)
        XCTAssertEqual(ReviewServer.pendingRows(meetingId), [])
    }

    func test_reviewedOnTheWebFirst_rowSaysAlreadyReviewed_andLeaves() async throws {
        let (first, second, third) = (UUID(), UUID(), UUID())
        ReviewServer.put(try meeting(rows: [row(first, "Send the budget"), row(second, "Book the Acme interview"), row(third, "Draft the hiring plan")]))
        let review = review()
        await openPanel(review)
        review.start(meetingId: meetingId)
        await waitUntil { review.model?.screen == .ready }

        ReviewServer.update(meetingId) { $0["rows"] = ($0["rows"] as! [[String: Any]]).filter { $0["title"] as? String != "Draft the hiring plan" } }
        await tick(30)
        await waitUntil { review.groups.first?.rows.count == 2 }
        XCTAssertEqual(texts(review), ["New items", "Send the budget", "Book the Acme interview"])
        XCTAssertEqual(review.buttons.first?.title, "Keep 2")

        ReviewServer.refuse(first, status: 409, code: "already_reviewed")
        ReviewServer.update(meetingId) { $0["rows"] = ($0["rows"] as! [[String: Any]]).filter { $0["title"] as? String != "Send the budget" } }
        ReviewServer.holdSaves = true
        let keeping = Task { await review.keep() }
        await waitUntil { ReviewServer.saves.count == 1 }
        XCTAssertEqual(note(review, "Send the budget"), "Saving")
        XCTAssertEqual(note(review, "Book the Acme interview"), "Saving")
        ReviewServer.releaseSaves()
        await waitUntil { ReviewServer.saves.count == 2 }
        XCTAssertEqual(note(review, "Send the budget"), "Already reviewed on the web")
        XCTAssertEqual(note(review, "Book the Acme interview"), "Saving")
        ReviewServer.holdSaves = false
        ReviewServer.releaseSaves()
        await keeping.value

        XCTAssertEqual(review.model?.doneLine, "1 item tracked")
        XCTAssertEqual(ReviewServer.saves.count, 2)
        XCTAssertEqual(ReviewServer.pendingRows(meetingId), [])
    }

    func test_skipTheRest_skipsOnlyUntickedShownRows_neverWebOnlyOnes() async throws {
        let sure = [UUID(), UUID()], unsure = [UUID(), UUID(), UUID(), UUID(), UUID()]
        let rows = try [row(sure[0], "Send the budget"), row(sure[1], "Book the Acme interview", confidence: 0.85)]
            + unsure.enumerated().map { try row($1, "Maybe \($0 + 1)", confidence: 0.6) }
        ReviewServer.put(try meeting(rows: rows, webOnly: 2))
        let review = review()
        await openPanel(review)
        review.start(meetingId: meetingId)
        await waitUntil { review.model?.screen == .ready }
        XCTAssertEqual(texts(review), ["New items", "Send the budget", "Book the Acme interview", "Maybe 1", "Maybe 2", "Maybe 3"])
        XCTAssertEqual(review.groups.first?.lessSureAt, 2)
        XCTAssertEqual(review.moreOnWeb, "4 more on the web")

        review.toggle(unsure[0])
        await review.skipRest()
        let skipped = ReviewServer.saves.map { ($0.path.split(separator: "/").last.map(String.init), $0.body["action"] as? String) }
        XCTAssertEqual(skipped.map(\.0), [unsure[1], unsure[2]].map { $0.uuidString.lowercased() })
        XCTAssertEqual(skipped.map(\.1), ["reject", "reject"])
        XCTAssertEqual(texts(review), ["New items", "Send the budget", "Book the Acme interview", "Maybe 1", "Maybe 4", "Maybe 5"],
                       "skipped rows leave and the two that did not fit move up, still unticked")
        XCTAssertEqual(review.moreOnWeb, "2 more on the web")

        await review.keep()
        XCTAssertEqual(ReviewServer.saves.suffix(3).map { $0.body["action"] as? String }, ["accept", "accept", "accept"])
        XCTAssertEqual(ReviewServer.pendingRows(meetingId), ["Maybe 4", "Maybe 5"], "rows the Mac never showed are left alone")
        XCTAssertEqual(review.model?.doneLine, "3 items tracked. 2 still to review.")
    }

    func test_panelClosedWhenReady_postsOneNotification_reviewOpensTheMeeting() async throws {
        let app = app()
        await app.authManager.adopt(testSupabase(instance), instance: instance)
        app.apply(.signedIn)
        ReviewServer.put(try meeting(suggestions: "pending"))
        app.presentRecapCue(RecapCue(meetingId: meetingId, seriesId: nil, instance: instance))
        app.panelClosed()
        await waitUntil { app.review.model?.screen == .finding }

        let rows = try [row(UUID(), "Send the budget"), row(UUID(), "Book the Acme interview"), row(UUID(), "Vendor may slip", confidence: 0.6)]
        ReviewServer.update(meetingId) { $0["suggestions_status"] = "ready"; $0["rows"] = rows }
        await tick(3)
        await waitUntil { notices.count == 1 }
        XCTAssertEqual(notices, [ReviewNotice(title: "3 action items from Weekly sync", meetingId: meetingId)])
        XCTAssertTrue(app.review.hasDot)

        XCTAssertEqual(clock.sleeping, 0, "nothing to watch while Ready sits behind a closed panel")
        let opening = app.panelOpened()
        app.panelClosed()
        await opening?.value
        XCTAssertEqual(notices.count, 1)

        app.review.close()
        XCTAssertNil(app.review.model)
        let tapped = try XCTUnwrap(AppController.reviewMeetingId(
            actionId: AppController.reviewActionId, userInfo: [AppController.reviewMeetingIdUserInfoKey: meetingId.uuidString]))
        app.openReview(meetingId: tapped)
        XCTAssertEqual(app.review.model?.meetingId, meetingId)
        XCTAssertEqual(texts(app.review), ["New items", "Send the budget", "Book the Acme interview", "Vendor may slip"])
        XCTAssertNil(AppController.reviewMeetingId(actionId: AppController.stopRecordingActionId, userInfo: [:]))
        XCTAssertEqual(notices.count, 1, "reopening a meeting that was already announced does not post it again")
    }

    func test_notificationsDenied_dotStillShows() async throws {
        let review = ReviewController(client: { [instance] in Self.client(instance) }, clock: clock.review, defaults: UserDefaults(suiteName: suite)!, notify: { _ in })
        reviews.append(review)
        ReviewServer.put(try meeting(suggestions: "pending"))
        review.start(meetingId: meetingId)
        await waitUntil { review.model?.screen == .finding }
        XCTAssertFalse(review.hasDot)
        XCTAssertEqual(MenuBarIcon.accessibilityLabel(phase: .idle, pendingConsent: false, reviewDot: MenuBarIcon.showsDot(phase: .idle, hasDot: review.hasDot)), "Minutia, idle")

        ReviewServer.update(meetingId) { $0["suggestions_status"] = "ready"; $0["rows"] = [try! self.row(UUID(), "Send the budget")] }
        await tick(3)
        await waitUntil { review.hasDot }
        let dot = MenuBarIcon.showsDot(phase: .idle, hasDot: review.hasDot)
        XCTAssertTrue(dot)
        XCTAssertEqual(MenuBarIcon.accessibilityLabel(phase: .idle, pendingConsent: false, reviewDot: dot), "Minutia, idle, items to review")
        XCTAssertFalse(MenuBarIcon.showsDot(phase: .recording, hasDot: true), "the recording glyph wins")
    }

    func test_inAnotherCall_queueWaitsAsOneLineUnderRecording() async throws {
        let app = app()
        await app.authManager.adopt(testSupabase(instance), instance: instance)
        app.apply(.signedIn)
        let rows = try [row(UUID(), "Send the budget"), row(UUID(), "Book the Acme interview"), row(UUID(), "Vendor may slip", confidence: 0.6)]
        ReviewServer.put(try meeting(rows: rows, endedAgo: 3600))
        await app.review.refreshQueue()
        XCTAssertTrue(app.review.hasDot)

        app.apply(.recordStarted)

        XCTAssertEqual(app.phase, .recording)
        XCTAssertEqual(app.review.waitingLine, "Weekly sync · today · 3 to review")
        XCTAssertNil(app.review.model, "the review waits instead of covering the recording")
        app.apply(.recordStopped)
        app.apply(.finalized)
        XCTAssertTrue(app.review.hasDot)
        XCTAssertEqual(app.review.queueRows.map(\.title), ["Weekly sync · today · 3 to review"])
        XCTAssertTrue(ReviewServer.saves.isEmpty)
    }

    func test_queueRow_saysYesterdayAndTheWeekdayForOlderMeetings() async throws {
        let older = UUID()
        ReviewServer.put(try meeting(older, rows: [row(UUID(), "Vendor may slip")], endedAgo: 3 * 86_400))
        ReviewServer.put(try meeting(rows: [row(UUID(), "Send the budget"), row(UUID(), "Draft the hiring plan")], endedAgo: 86_400))
        let review = review()
        await review.refreshQueue()
        XCTAssertEqual(review.queueRows.map(\.title), ["Weekly sync · yesterday · 2 to review", "Weekly sync · Tuesday · 1 to review"])
    }

    func test_notYourSeries_readOnlyRows_noDot() async throws {
        let (first, second) = (UUID(), UUID())
        ReviewServer.put(try meeting(rows: [row(first, "Send the budget"), row(second, "Vendor may slip", confidence: 0.6)], reviewer: false))
        let review = review()
        review.start(meetingId: meetingId)
        await waitUntil { review.model?.screen == .ready }

        XCTAssertEqual(texts(review), ["New items", "Send the budget", "Vendor may slip"])
        XCTAssertEqual(review.groups.flatMap(\.rows).map(\.editable), [false, false])
        XCTAssertEqual(review.readOnlyNote, "The series owner reviews these.")
        XCTAssertEqual(review.buttons.map(\.title), ["Open recap"])
        review.toggle(second)
        await review.keep()
        await review.skipRest()
        XCTAssertTrue(ReviewServer.saves.isEmpty)
        XCTAssertFalse(review.hasDot)
        XCTAssertTrue(notices.isEmpty, "only the person who reviews is told")
        XCTAssertEqual(announcements, ["Transcribing", "The series owner reviews these."])
    }

    func test_keepThenPanelClosesMidSave_reopenMatchesTheServer() async throws {
        let first = UUID()
        ReviewServer.put(try meeting(rows: [row(first, "Send the budget")]))
        let review = review()
        await openPanel(review)
        review.start(meetingId: meetingId)
        await waitUntil { review.model?.screen == .ready }

        ReviewServer.holdSaves = true
        let keeping = Task { await review.keep() }
        await waitUntil { ReviewServer.saves.count == 1 }
        let reads = ReviewServer.meetingReads
        review.setPanelOpen(false)
        await review.setPanelOpen(true)?.value
        XCTAssertEqual(ReviewServer.meetingReads, reads + 1)
        XCTAssertEqual(review.model?.screen, .ready, "the server already holds the save; the answer is still on its way")
        XCTAssertEqual(note(review, "Send the budget"), "Saving")

        ReviewServer.holdSaves = false
        ReviewServer.releaseSaves()
        await keeping.value
        XCTAssertEqual(review.model?.doneLine, "1 item tracked")
        XCTAssertEqual(ReviewServer.pendingRows(meetingId), [])
        review.setPanelOpen(false)
        await review.setPanelOpen(true)?.value
        XCTAssertEqual(review.model?.doneLine, "1 item tracked")
    }

    func test_instanceSwitchedDuringReview_oldRowsNeverPostToTheNewServer() async throws {
        let app = app()
        await app.authManager.adopt(testSupabase(instance), instance: instance)
        app.apply(.signedIn)
        app.panelOpened()
        ReviewServer.put(try meeting(rows: [row(UUID(), "Send the budget"), row(UUID(), "Book the Acme interview")]))
        app.presentRecapCue(RecapCue(meetingId: meetingId, seriesId: nil, instance: instance))
        await waitUntil { app.review.model?.screen == .ready }

        ReviewServer.holdSaves = true
        let keeping = Task { await app.review.keep() }
        await waitUntil { ReviewServer.saves.count == 1 }
        await app.authManager.adopt(testSupabase(otherInstance), instance: otherInstance)
        XCTAssertNil(app.review.model)
        XCTAssertFalse(app.review.hasDot)

        ReviewServer.releaseSaves()
        await keeping.value
        XCTAssertEqual(ReviewServer.saves.map(\.host), ["minutia.example.com"], "the second row never posts anywhere")
        XCTAssertFalse(ReviewServer.requests.contains { $0.host == "other.example.com" && $0.method == "PATCH" })
        XCTAssertNil(app.review.model, "the old answer does not bring the old review back")
    }

    func test_switchingAwayAndBackMidSave_theOldKeepDoesNotCarryOnIntoTheNewReview() async throws {
        let app = app()
        await app.authManager.adopt(testSupabase(instance), instance: instance)
        app.apply(.signedIn)
        app.panelOpened()
        ReviewServer.put(try meeting(rows: [row(UUID(), "Send the budget"), row(UUID(), "Book the Acme interview")]))
        app.presentRecapCue(RecapCue(meetingId: meetingId, seriesId: nil, instance: instance))
        await waitUntil { app.review.model?.screen == .ready }

        ReviewServer.holdSaves = true
        let keeping = Task { await app.review.keep() }
        await waitUntil { ReviewServer.saves.count == 1 }
        await app.authManager.adopt(testSupabase(otherInstance), instance: otherInstance)
        await app.authManager.adopt(testSupabase(instance), instance: instance)
        app.apply(.signedIn)
        app.openReview(meetingId: meetingId)
        await waitUntil { app.review.model?.screen == .ready }

        ReviewServer.holdSaves = false
        ReviewServer.releaseSaves()
        await keeping.value
        XCTAssertEqual(ReviewServer.saves.count, 1, "the second row waits for the person to press Keep again")
        XCTAssertEqual(texts(app.review), ["New items", "Book the Acme interview"])
        XCTAssertEqual(app.review.buttons.first?.title, "Keep 1")
    }

    func test_meetingDeletedOnTheWeb_dropsFromQueueAndDotClears() async throws {
        let (first, second) = (UUID(), UUID())
        ReviewServer.put(try meeting(rows: [row(first, "Send the budget"), row(second, "Book the Acme interview")]))
        let review = review()
        await openPanel(review)
        await review.refreshQueue()
        XCTAssertTrue(review.hasDot)
        let starting = review.start(meetingId: meetingId)
        XCTAssertEqual(review.model?.screen, .ready, "a queued meeting opens straight to its rows")
        await starting.value
        XCTAssertEqual(ReviewServer.meetingReads, 1)

        ReviewServer.delete(meetingId)
        await review.keep()

        XCTAssertEqual(ReviewServer.saves.count, 2)
        XCTAssertNil(review.model)
        XCTAssertFalse(review.hasDot)
        await review.refreshQueue()
        XCTAssertFalse(review.hasDot)
    }

    // MARK: - Try again

    func test_couldntFindItems_tryAgainAsksForTheListAgain_andShowsFindingAgain() async throws {
        ReviewServer.put(try meeting(suggestions: "failed"))
        ReviewServer.afterRetry(meetingId, becomes: try meeting(suggestions: "pending"))
        let review = review()
        await openPanel(review)
        review.start(meetingId: meetingId)
        await waitUntil { review.model?.screen == .findingFailed }
        XCTAssertEqual(review.model?.screen.message, "We couldn't find action items this time.")
        XCTAssertEqual(review.buttons.map(\.title), ["Try again", "Done", "Open recap"])

        await review.tryAgain()

        XCTAssertEqual(ReviewServer.requests.filter { $0.method == "POST" }.map(\.path), ["/api/meetings/3f95ffd6-fd1e-4640-aacc-89e1c051f742/suggestions"])
        XCTAssertEqual(review.model?.screen.message, "Finding action items")
        let reads = ReviewServer.meetingReads
        await tick(3)
        await waitUntil { ReviewServer.meetingReads == reads + 1 }
    }

    func test_couldntTranscribe_tryAgainReRunsTranscription() async throws {
        ReviewServer.put(try meeting(transcription: "failed", suggestions: "pending", endedAgo: 0))
        ReviewServer.afterRetry(meetingId, becomes: try meeting(transcription: "processing", suggestions: nil, endedAgo: 0))
        let review = review()
        review.start(meetingId: meetingId)
        await waitUntil { review.model?.screen == .transcriptionFailed }
        XCTAssertEqual(review.model?.screen.message, "We couldn't transcribe this meeting.")

        await review.tryAgain()

        XCTAssertEqual(ReviewServer.requests.filter { $0.method == "POST" }.map(\.path), ["/api/meetings/3f95ffd6-fd1e-4640-aacc-89e1c051f742/transcribe"])
        XCTAssertEqual(review.model?.screen.message, "Transcribing")
    }

    func test_someoneElsesFailedMeeting_offersOnlyTheRecap() async throws {
        ReviewServer.put(try meeting(suggestions: "failed", reviewer: false))
        let review = review()
        review.start(meetingId: meetingId)
        await waitUntil { review.model?.screen == .findingFailed }
        XCTAssertEqual(review.buttons.map(\.title), ["Done", "Open recap"])
    }

    // MARK: - We'll let you know

    func test_closedWhileFinding_keepsChecking_andPostsOneNotificationWhenReady() async throws {
        ReviewServer.put(try meeting(suggestions: "pending"))
        let review = review()
        await openPanel(review)
        await review.start(meetingId: meetingId).value
        XCTAssertEqual(review.shown?.screen.message, "Finding action items")

        review.close()
        XCTAssertNil(review.shown, "the review is out of the way")
        XCTAssertEqual(Host.size(panel(review)).height, 0)
        let rows = try [row(UUID(), "Send the budget"), row(UUID(), "Book the Acme interview"), row(UUID(), "Draft the hiring plan")]
        ReviewServer.update(meetingId) { $0["suggestions_status"] = "ready"; $0["rows"] = rows }
        await tick(3)
        await waitUntil { notices.count == 1 }

        XCTAssertEqual(notices, [ReviewNotice(title: "3 action items from Weekly sync", meetingId: meetingId)])
        XCTAssertNil(review.shown)
        XCTAssertEqual(review.queueRows.map(\.title), ["Weekly sync · today · 3 to review"])
        XCTAssertEqual(clock.sleeping, 0, "nothing left to watch once it is ready")
        await review.refreshQueue()
        await review.start(meetingId: meetingId).value
        XCTAssertEqual(texts(review), ["New items", "Send the budget", "Book the Acme interview", "Draft the hiring plan"])
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(announcements, ["Transcribing", "Finding action items", "3 action items from Weekly sync"])
    }

    func test_closedWhileFinding_andItFails_nothingIsPostedAndTheReviewIsGone() async throws {
        ReviewServer.put(try meeting(suggestions: "pending"))
        let review = review()
        await review.start(meetingId: meetingId).value
        review.close()
        ReviewServer.update(meetingId) { $0["suggestions_status"] = "failed" }
        await tick(3)
        await waitUntil { review.model == nil }
        XCTAssertNil(review.shown)
        XCTAssertEqual(clock.sleeping, 0)
        XCTAssertTrue(notices.isEmpty)
    }

    private func pending(_ title: String, _ id: UUID = UUID()) throws -> [String: Any] {
        try meeting(id, rows: [row(UUID(), title)], endedAgo: 3600)
    }

    func test_firstQueueLoad_postsNothingForMeetingsAlreadyWaiting_andALaterOnePostsOnce() async throws {
        let review = review()
        for title in ["Send the budget", "Book the Acme interview", "Draft the hiring plan"] { ReviewServer.put(try pending(title)) }
        await review.refreshQueue()
        XCTAssertEqual(review.queueRows.count, 3)
        XCTAssertTrue(notices.isEmpty, "meetings already waiting at the first load are not news")

        let fourth = UUID()
        ReviewServer.put(try pending("Vendor may slip", fourth))
        await review.refreshQueue()
        XCTAssertEqual(notices, [ReviewNotice(title: "1 action item from Weekly sync", meetingId: fourth)])
        await review.refreshQueue()
        XCTAssertEqual(notices.count, 1)

        let fifth = UUID()
        ReviewServer.put(try pending("Renew the contract", fifth))
        let restarted = self.review()
        await restarted.refreshQueue()
        XCTAssertEqual(notices.map(\.meetingId), [fourth, fifth], "a restart posts only what is new, never twice")

        ReviewServer.put(try meeting(UUID(), rows: [row(UUID(), "Vendor may slip")], reviewer: false))
        await restarted.refreshQueue()
        XCTAssertEqual(notices.count, 2, "only the person who reviews is told")

        await openPanel(restarted)
        ReviewServer.put(try pending("Draft the hiring plan"))
        await restarted.refreshQueue()
        restarted.setPanelOpen(false)
        await restarted.refreshQueue()
        XCTAssertEqual(notices.count, 2, "a meeting first seen in the open panel is not posted later")
    }

    func test_firstQueueLoadWithNothingWaiting_theFirstMeetingThatAppearsIsPosted() async throws {
        let review = review()
        await review.refreshQueue()
        let first = UUID()
        ReviewServer.put(try pending("Send the budget", first))
        await review.refreshQueue()
        XCTAssertEqual(notices, [ReviewNotice(title: "1 action item from Weekly sync", meetingId: first)])
    }

    func test_anotherAccount_startsFresh_soWhatItAlreadyHasWaitingIsNotPosted() async throws {
        let review = review()
        review.reset(account: "pat@example.com https://minutia.example.com")
        ReviewServer.put(try pending("Send the budget"))
        await review.refreshQueue()
        XCTAssertTrue(notices.isEmpty)

        review.reset(account: "pat@example.com https://minutia.example.com")
        let whileAway = UUID()
        ReviewServer.put(try pending("Book the Acme interview", whileAway))
        await review.refreshQueue()
        XCTAssertEqual(notices.map(\.meetingId), [whileAway], "the same account coming back keeps its list")

        review.reset(account: "sam@example.com https://other.example.com")
        ReviewServer.put(try pending("Draft the hiring plan"))
        await review.refreshQueue()
        XCTAssertEqual(notices.count, 1, "a different account's first load is quiet")

        review.reset(account: nil)
        ReviewServer.put(try pending("Vendor may slip"))
        review.reset(account: "sam@example.com https://other.example.com")
        await review.refreshQueue()
        XCTAssertEqual(notices.count, 1, "signing out and back in starts fresh too")
    }

    func test_eightItems_theNotificationAndTheQueueLineCountAllEight() async throws {
        ReviewServer.put(try meeting(suggestions: "pending"))
        let review = review()
        await review.start(meetingId: meetingId).value
        let rows = try (1...8).map { try row(UUID(), "Item \($0)") }
        ReviewServer.update(meetingId) { $0["suggestions_status"] = "ready"; $0["rows"] = rows }
        await tick(3)
        await waitUntil { notices.count == 1 }

        XCTAssertEqual(notices, [ReviewNotice(title: "8 action items from Weekly sync", meetingId: meetingId)])
        XCTAssertEqual(review.queueRows.map(\.title), ["Weekly sync · today · 8 to review"])
        XCTAssertEqual(review.moreOnWeb, "3 more on the web")
        XCTAssertEqual(announcements.last, "8 action items from Weekly sync")
    }

    func test_aReadyCheckThatOnlyChangesTheCount_isNotAnnouncedAgain() async throws {
        let rows = try [row(UUID(), "Send the budget"), row(UUID(), "Book the Acme interview"), row(UUID(), "Draft the hiring plan")]
        ReviewServer.put(try meeting(rows: rows))
        let review = review()
        await openPanel(review)
        await review.start(meetingId: meetingId).value
        XCTAssertEqual(announcements, ["3 action items from Weekly sync"])

        ReviewServer.update(meetingId) { $0["rows"] = Array(rows.prefix(2)) }
        await tick(30)
        await waitUntil { texts(review) == ["New items", "Send the budget", "Book the Acme interview"] }
        XCTAssertEqual(announcements, ["3 action items from Weekly sync"])
    }

    // MARK: - Try again

    func test_tryAgain_flipsToTranscribingTheMomentItIsPressed() async throws {
        ReviewServer.put(try meeting(transcription: "failed", suggestions: nil))
        ReviewServer.afterRetry(meetingId, becomes: try meeting(transcription: "processing", suggestions: nil, endedAgo: 0))
        let review = review()
        await openPanel(review)
        await review.start(meetingId: meetingId).value
        XCTAssertEqual(review.shown?.screen.message, "We couldn't transcribe this meeting.")

        ReviewServer.holdRetries = true
        let pressing = Task { await review.tryAgain() }
        await waitUntil { ReviewServer.retries.count == 1 }
        XCTAssertEqual(review.shown?.screen.message, "Transcribing", "the answer is still on its way")
        XCTAssertEqual(review.buttons, [])

        ReviewServer.releaseSaves()
        await pressing.value
        XCTAssertEqual(ReviewServer.retries.map(\.path), ["/api/meetings/3f95ffd6-fd1e-4640-aacc-89e1c051f742/transcribe"])
        XCTAssertEqual(review.shown?.screen, .transcribing(elapsed: nil))
    }

    func test_tryAgain_aSecondPressSendsNothing_andARefusalReturnsToTheFailedScreen() async throws {
        ReviewServer.put(try meeting(suggestions: "failed"))
        let review = review()
        await openPanel(review)
        await review.start(meetingId: meetingId).value
        XCTAssertEqual(review.shown?.screen.message, "We couldn't find action items this time.")

        ReviewServer.holdRetries = true
        ReviewServer.refuseRetries = true
        let pressing = Task { await review.tryAgain() }
        await waitUntil { ReviewServer.retries.count == 1 }
        XCTAssertEqual(review.shown?.screen.message, "Finding action items")
        await review.setPanelOpen(true)?.value
        XCTAssertEqual(review.shown?.screen.message, "Finding action items", "a check that lands meanwhile does not undo the press")
        await review.tryAgain()
        XCTAssertEqual(ReviewServer.retries.count, 1)

        ReviewServer.releaseSaves()
        await pressing.value
        XCTAssertEqual(review.shown?.screen.message, "We couldn't find action items this time.")
        XCTAssertEqual(review.buttons.map(\.title), ["Try again", "Done", "Open recap"])
        XCTAssertEqual(review.buttons.map(\.enabled), [true, true, true])
    }

    // MARK: - One review at a time

    func test_meetingAsDoneTimer_neverClosesMeetingBsReview() async throws {
        let other = UUID()
        ReviewServer.put(try meeting(rows: [row(UUID(), "Send the budget")]))
        ReviewServer.put(try meeting(other, rows: [row(UUID(), "Vendor may slip")]))
        let review = review()
        await openPanel(review)
        await review.start(meetingId: meetingId).value
        await review.keep()
        XCTAssertEqual(review.shown?.doneLine, "1 item tracked")
        await waitUntil { clock.sleeping == 1 }

        await review.start(meetingId: other).value
        let reads = ReviewServer.meetingReads
        clock.advance(ReviewController.doneHold)
        await tick(ReviewController.readyPoll - ReviewController.doneHold)
        await waitUntil { ReviewServer.meetingReads == reads + 1 }
        XCTAssertEqual(review.shown?.meetingId, other)
        XCTAssertEqual(texts(review), ["New items", "Vendor may slip"])
    }

    func test_reviewTap_neverTogglesAnOpenPanel_andWithoutTheStatusItemTheNextClickShowsIt() async throws {
        let app = app()
        await app.authManager.adopt(testSupabase(instance), instance: instance)
        app.apply(.signedIn)
        ReviewServer.put(try meeting(rows: [row(UUID(), "Send the budget")]))
        var clicks = 0
        app.openPanel = { clicks += 1; return false }

        app.openReview(meetingId: meetingId)
        XCTAssertEqual(clicks, 1)
        await waitUntil { app.review.shown?.screen == .ready }
        let seen = Host.text(MenuContent(controller: app, updater: UpdaterController()))
        XCTAssertTrue(seen.has("Send the budget"), seen.text)

        app.panelOpened()
        app.openReview(meetingId: meetingId)
        XCTAssertEqual(clicks, 1, "an open panel is not clicked shut")
    }

    // MARK: - Owner and due date

    func test_changingOwnerAndDue_sendsThemWithTheKeep() async throws {
        let (first, second) = (UUID(), UUID())
        ReviewServer.put(try meeting(rows: [row(first, "Send the budget"), row(second, "Book the Acme interview")]))
        let review = review()
        await openPanel(review)
        await review.refreshQueue()
        review.start(meetingId: meetingId)
        let rows = review.groups.flatMap(\.rows)
        XCTAssertEqual(rows.map(\.owner), ["Priya Shah", "Priya Shah"])
        XCTAssertEqual(rows.map(\.due), ["Nov 25", "Nov 25"])
        XCTAssertEqual(review.ownerChoices.map(\.name), ["Me", "Priya Shah"])

        review.setOwner(first, to: UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        review.setDue(first, to: .tomorrow)
        review.setDue(second, to: .none)
        let edited = review.groups.flatMap(\.rows)
        XCTAssertEqual(edited.map(\.owner), ["Me", "Priya Shah"])
        XCTAssertEqual(edited.map(\.due), ["Tomorrow", "No date"])

        await review.keep()
        XCTAssertEqual(ReviewServer.saves[0].body["owner_user_id"] as? String, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(ReviewServer.saves[0].body["due_date"] as? String, "2026-11-21")
        XCTAssertNil(ReviewServer.saves[1].body["owner_user_id"])
        XCTAssertTrue(ReviewServer.saves[1].body["due_date"] is NSNull)
    }

    func test_dueChoices_landOnTheRightDayInThePersonsCalendar() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let lateEvening = ISO8601DateFormatter().date(from: "2026-11-20T14:30:00Z")!
        XCTAssertEqual(ReviewController.dueChange(.today, now: lateEvening, calendar: tokyo), .set("2026-11-20"))
        XCTAssertEqual(ReviewController.dueChange(.tomorrow, now: lateEvening, calendar: tokyo), .set("2026-11-21"))
        XCTAssertEqual(ReviewController.dueChange(.nextWeek, now: lateEvening, calendar: tokyo), .set("2026-11-27"))
        XCTAssertEqual(ReviewController.dueChange(.none, now: lateEvening, calendar: tokyo), .clear)
        var utcMinus = Calendar(identifier: .gregorian)
        utcMinus.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(ReviewController.dueChange(.today, now: ISO8601DateFormatter().date(from: "2026-11-21T03:00:00Z")!, calendar: utcMinus), .set("2026-11-20"))
    }

    func test_statusChange_readsAsTheItemAndItsNewStatus() async throws {
        var update = try row(UUID(), "Contract renewed", confidence: 0.85, type: "status_update")
        update["suggested_status"] = "in_progress"
        ReviewServer.put(try meeting(rows: [row(UUID(), "Send the budget"), update]))
        let review = review()
        review.start(meetingId: meetingId)
        await waitUntil { review.model?.screen == .ready }
        XCTAssertEqual(texts(review), ["New items", "Send the budget", "Updates to existing items", "#1479 Renew the contract → In progress"])
        XCTAssertNil(review.groups[1].rows[0].owner)

        await review.keep()
        XCTAssertEqual(review.model?.doneLine, "1 item tracked, 1 updated")
    }

    // MARK: - Polling

    func test_whileFinding_checksEveryThreeSeconds_untilReady_thenEvery30WhileShowing_andStopsWhenClosed() async throws {
        ReviewServer.put(try meeting(suggestions: "pending"))
        let review = review()
        await openPanel(review)
        review.start(meetingId: meetingId)
        await waitUntil { ReviewServer.meetingReads == 1 && review.model?.screen == .finding }

        await tick(2.9)
        XCTAssertEqual(clock.sleeping, 1, "the next check is still waiting")
        XCTAssertEqual(ReviewServer.meetingReads, 1)
        clock.advance(0.1)
        await waitUntil { ReviewServer.meetingReads == 2 }
        await tick(3)
        await waitUntil { ReviewServer.meetingReads == 3 }

        ReviewServer.update(meetingId) { $0["suggestions_status"] = "ready"; $0["rows"] = [try! self.row(UUID(), "Send the budget")] }
        await tick(3)
        await waitUntil { review.model?.screen == .ready }
        await tick(29)
        XCTAssertEqual(clock.sleeping, 1, "the next check is still waiting")
        XCTAssertEqual(ReviewServer.meetingReads, 4)
        clock.advance(1)
        await waitUntil { ReviewServer.meetingReads == 5 }
        await tick(30)
        await waitUntil { ReviewServer.meetingReads == 6 && clock.sleeping == 1 }

        review.setPanelOpen(false)
        await waitUntil { clock.sleeping == 0 }
        clock.advance(60)
        XCTAssertEqual(clock.sleeping, 0)
        XCTAssertEqual(ReviewServer.meetingReads, 6)
    }

    func test_transcribingForever_stopsCheckingAfterFifteenMinutes() async throws {
        ReviewServer.put(try meeting(transcription: "processing", suggestions: nil, endedAgo: 0))
        let review = review()
        await review.start(meetingId: meetingId).value
        for n in 2...300 {
            await tick(3)
            await waitUntil { ReviewServer.meetingReads == n && clock.sleeping == 1 }
        }
        let looked = clock.nowReads
        await tick(3)
        await waitUntil { ReviewServer.meetingReads == 301 && clock.nowReads > looked }
        XCTAssertEqual(clock.sleeping, 0, "no check is scheduled after fifteen minutes")
        XCTAssertEqual(review.model?.screen.message, "Taking longer than usual. We'll let you know when it's ready.")
        clock.advance(6)
        XCTAssertEqual(ReviewServer.meetingReads, 301)
        XCTAssertEqual(announcements, ["Transcribing", "Taking longer than usual. We'll let you know when it's ready."])
    }

    // MARK: - On screen

    private func readyReview(_ rows: [[String: Any]], webOnly: Int = 0) async throws -> ReviewController {
        ReviewServer.put(try meeting(rows: rows, webOnly: webOnly))
        let review = review()
        await openPanel(review)
        await review.start(meetingId: meetingId).value
        XCTAssertEqual(review.shown?.screen, .ready)
        return review
    }

    private func panel(_ review: ReviewController) -> ReviewView {
        ReviewView(review: review, onOpenRecap: { _ in })
    }

    func test_keyboard_arrowsMove_spaceTicks_returnKeeps_escapeCloses() async throws {
        let ids = [UUID(), UUID(), UUID()]
        let review = try await readyReview([row(ids[0], "Send the budget"), row(ids[1], "Book the Acme interview"), row(ids[2], "Draft the hiring plan")])
        let window = KeyWindow(panel(review))
        XCTAssertTrue(window.seen().has("Keep 3"))

        window.press(.down)
        window.press(.space)
        XCTAssertEqual(review.groups.flatMap(\.rows).map(\.checked), [true, false, true])
        XCTAssertTrue(window.seen().has("Keep 2"))
        window.press(.up)
        window.press(.space)
        XCTAssertEqual(review.groups.flatMap(\.rows).map(\.checked), [false, false, true])
        XCTAssertTrue(window.seen().has("Keep 1"))

        window.press(.return)
        await waitUntil { review.shown?.screen == .partlyDone(kept: 1, left: 2) }
        XCTAssertEqual(ReviewServer.saves.map(\.path), ["/api/meetings/3f95ffd6-fd1e-4640-aacc-89e1c051f742/suggestions/\(ids[2].uuidString.lowercased())"])
        XCTAssertTrue(window.seen().has("1 item tracked"))

        window.press(.escape)
        XCTAssertNil(review.shown)
        XCTAssertFalse(window.seen().has("tracked"))
    }

    func test_everyControlInTheReview_hasASpokenName() async throws {
        let review = try await readyReview([row(UUID(), "Send the budget"), row(UUID(), "Vendor may slip", confidence: 0.6)])
        let window = KeyWindow(panel(review))
        XCTAssertEqual(window.controls().map(\.label).sorted(), [
            "Close review", "Keep 1", "Keep: Send the budget", "Keep: Vendor may slip", "Nov 25. Change", "Nov 25. Change",
            "Open recap", "Priya Shah. Change", "Priya Shah. Change", "Skip the rest",
        ])

        await review.keep()
        await review.skipRest()
        XCTAssertEqual(review.shown?.doneLine, "1 item tracked")
        window.spin(0.3)
        XCTAssertEqual(window.controls().map(\.label).sorted(), ["Close review", "Done", "Open recap"])
    }

    func test_aLongTitle_showsTwoLines_andTheWholeTitleOnHover() async throws {
        let title = "Send the revised quarterly budget to finance once the vendor confirms the renewal price and the team has signed off on headcount for the spring"
        let review = try await readyReview([row(UUID(), title)])
        let window = KeyWindow(panel(review))
        let seen = window.seen()
        XCTAssertTrue(seen.has("Send the revised quarterly"), seen.text)
        XCTAssertFalse(seen.has("headcount for the spring"), "clamped to two lines: \(seen.text)")
        XCTAssertTrue(window.helps().contains(title))
    }

    func test_readyWithFiveNewItemsTwoUpdatesAndTheFooter_fitsThePanel() async throws {
        var rows = try (1...5).map { try row(UUID(), "Follow up on item \($0) with the team") }
        for n in 1...2 {
            var update = try row(UUID(), "Contract renewed \(n)", confidence: 0.85, type: "status_update")
            update["suggested_status"] = "in_progress"
            rows.append(update)
        }
        let review = try await readyReview(rows, webOnly: 1)
        for dark in [false, true] {
            let size = Host.size(panel(review), dark: dark)
            XCTAssertEqual(size.width, 320, "dark: \(dark)")
            XCTAssertLessThanOrEqual(size.height, 520, "dark: \(dark)")
            let seen = Host.text(panel(review), dark: dark)
            for words in ["Keep 7", "Skip the rest", "Open recap", "1 more on the web", "Follow up on item 5", "In progress"] {
                XCTAssertTrue(seen.has(words), "dark: \(dark) missing \(words): \(seen.text)")
            }
        }
    }

    func test_doneCheck_drawsAtOnceWithReduceMotion_andAnimatesWithout() async throws {
        let review = try await readyReview([row(UUID(), "Send the budget")])
        await review.keep()
        XCTAssertEqual(review.shown?.doneLine, "1 item tracked")
        let still = Self.okPixels(panel(review).environment(\.reduceMotionOverride, true))
        let drawing = Self.okPixels(panel(review).environment(\.reduceMotionOverride, false))
        XCTAssertGreaterThan(still, 50)
        XCTAssertEqual(drawing, 0)
    }

    func test_notAvailable_isAPlainEndWithDoneAndOpenRecap_andNoCheck() async throws {
        ReviewServer.put(try meeting(suggestions: nil))
        let review = review()
        await review.start(meetingId: meetingId).value
        XCTAssertEqual(review.shown?.screen, .notAvailable)
        let seen = Host.text(panel(review))
        XCTAssertTrue(seen.has("Done"), seen.text)
        XCTAssertTrue(seen.has("Open recap"), seen.text)
        XCTAssertEqual(Self.okPixels(panel(review).environment(\.reduceMotionOverride, true)), 0)
    }

    func test_aDetectedMeeting_coversTheReview_andTheReviewComesBackAfter() async throws {
        let app = app()
        await app.authManager.adopt(testSupabase(instance), instance: instance)
        app.apply(.signedIn)
        ReviewServer.put(try meeting(rows: [row(UUID(), "Send the budget")]))
        app.presentRecapCue(RecapCue(meetingId: meetingId, seriesId: nil, instance: instance))
        await waitUntil { app.review.shown?.screen == .ready }
        let menu = MenuContent(controller: app, updater: UpdaterController())
        XCTAssertTrue(Host.text(menu).has("Send the budget"))

        app.handleDetection(.high(.zoom))
        let during = Host.text(menu)
        XCTAssertFalse(during.has("Send the budget"), during.text)
        XCTAssertTrue(during.has("Zoom"), during.text)

        app.handleDetection(.none)
        let after = Host.text(menu)
        XCTAssertTrue(after.has("Send the budget"), after.text)
    }

    private static func okPixels<V: View>(_ root: V) -> Int {
        guard let image = Host.render(root, spin: 0.05) else { return 0 }
        let (width, height, data) = Host.pixels(image)
        return (0..<(width * height)).filter { index in
            abs(Int(data[index * 4]) - 0x2D) < 14 && abs(Int(data[index * 4 + 1]) - 0x7A) < 14 && abs(Int(data[index * 4 + 2]) - 0x4B) < 14
        }.count
    }
}

/// A focused, key window holding a view, so real key presses reach SwiftUI.
@MainActor
final class KeyWindow {
    enum Key { case up, down, space, `return`, escape }
    private let window: NSWindow
    private let hosting: NSHostingView<AnyView>

    init<V: View>(_ root: V) {
        hosting = NSHostingView(rootView: AnyView(root.background(Host.backdrop(dark: false)).environment(\.colorScheme, .light)))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = hosting.appearance
        window.contentView = hosting
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        spin(0.5)
    }

    deinit { MainActor.assumeIsolated { window.orderOut(nil) } }

    func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    func press(_ key: Key) {
        let (code, text): (UInt16, String) = switch key {
        case .up: (126, String(UnicodeScalar(NSUpArrowFunctionKey)!))
        case .down: (125, String(UnicodeScalar(NSDownArrowFunctionKey)!))
        case .space: (49, " ")
        case .return: (36, "\r")
        case .escape: (53, "\u{1B}")
        }
        let flags: NSEvent.ModifierFlags = [.up, .down].contains(key) ? [.numericPad, .function] : []
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            window.sendEvent(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: code)!)
        }
        spin(0.2)
    }

    func seen() -> Seen {
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        spin(0.2)
        hosting.layoutSubtreeIfNeeded()
        return Host.capture(hosting).map(Host.read) ?? Seen(text: "", frames: [])
    }

    private func elements() -> [NSObject] {
        // SwiftUI builds its accessibility tree only once an accessibility client asks for it.
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute as CFString, &windows)
        spin(0.3)
        var found: [NSObject] = []
        func walk(_ node: NSObject) {
            for case let child as NSObject in Self.ask(node, #selector(NSAccessibilityProtocol.accessibilityChildren)) as? [Any] ?? [] {
                found.append(child)
                walk(child)
            }
        }
        walk(hosting)
        return found
    }

    /// SwiftUI's accessibility nodes answer the accessibility selectors without declaring the protocol.
    private static func ask(_ node: NSObject, _ selector: Selector) -> Any? {
        node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
    }

    func controls() -> [(role: String, label: String)] {
        let roles: [NSAccessibility.Role] = [.button, .checkBox, .popUpButton, .menuButton, .link]
        return elements().compactMap { node in
            guard let role = Self.ask(node, #selector(NSAccessibilityProtocol.accessibilityRole)) as? String,
                  roles.map(\.rawValue).contains(role) else { return nil }
            let label = Self.ask(node, #selector(NSAccessibilityProtocol.accessibilityLabel)) as? String ?? ""
            let title = Self.ask(node, #selector(NSAccessibilityProtocol.accessibilityTitle))
            return (role, label.isEmpty ? (title as? NSAttributedString)?.string ?? title as? String ?? "" : label)
        }
    }

    func helps() -> [String] {
        elements().compactMap { Self.ask($0, #selector(NSAccessibilityProtocol.accessibilityHelp)) as? String }
    }
}
