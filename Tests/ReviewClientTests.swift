import CryptoKit
import XCTest
@testable import Minutia

private final class ReviewStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> Result<(Int, String), URLError>)?
    nonisolated(unsafe) static var seen: [URLRequest] = []
    nonisolated(unsafe) static var seenBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.seen.append(request)
        Self.seenBodies.append(request.httpBody ?? request.httpBodyStream.map(Self.drain) ?? Data())
        switch Self.handler?(request) ?? .failure(URLError(.badURL)) {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .success(let (status, body)):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
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

final class ReviewClientTests: XCTestCase {
    private let instance = URL(string: "https://minutia.example.com")!
    private let meeting = UUID(uuidString: "3F95FFD6-FD1E-4640-AACC-89E1C051F742")!
    private let suggestion = UUID(uuidString: "F04A05E1-1FF7-4B9F-A50B-3BDF2A7DB083")!

    override func setUp() {
        super.setUp()
        ReviewStub.handler = nil
        ReviewStub.seen = []
        ReviewStub.seenBodies = []
        URLProtocol.registerClass(ReviewStub.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(ReviewStub.self)
        ReviewStub.handler = nil
        super.tearDown()
    }

    private func client() -> MinutiaClient {
        MinutiaClient(
            instance: instance,
            supabase: testSupabase(URL(string: "https://supabase.example.com")!),
            tokenProvider: { "test-access-token" })
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle(for: ReviewClientTests.self).url(forResource: name, withExtension: "json"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func respond(_ status: Int, _ body: String) {
        ReviewStub.handler = { _ in .success((status, body)) }
    }

    private func save(action: ReviewAction = .accept, owner: UUID? = nil, due: String? = nil) async -> ReviewSaveResult {
        await client().review(meetingId: meeting, suggestionId: suggestion, action: action, ownerUserId: owner, dueDate: due)
    }

    func test_queueList_decodesTheServersRealAnswer() async throws {
        respond(200, try fixture("review-queue-list"))
        let queue = try await client().reviewQueue(meetingId: nil)

        XCTAssertEqual(queue.me, UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        XCTAssertEqual(queue.meetings.count, 1)
        let m = queue.meetings[0]
        XCTAssertEqual(m.seriesName, "Weekly sync")
        XCTAssertEqual(m.transcriptionStatus, "completed")
        XCTAssertEqual(m.suggestionsStatus, "ready")
        XCTAssertNil(m.suggestionsReason)
        XCTAssertTrue(m.reviewer)
        XCTAssertEqual(m.webOnlyCount, 2)
        XCTAssertEqual(m.members.map(\.name), ["Priya Shah", "Test User"])
        XCTAssertEqual(m.rows.map(\.title), ["Send the budget", "Vendor may slip", "Contract renewed"])
        XCTAssertEqual(m.rows.map(\.type), ["new_item", "new_item", "status_update"])
        XCTAssertEqual(m.rows[0].ownerName, "Priya")
        XCTAssertEqual(m.rows[0].dueDate, "2026-11-25")
        XCTAssertEqual(m.rows[0].confidence, 0.92)
        XCTAssertNil(m.rows[1].ownerUserId)
        XCTAssertEqual(m.rows[2].relatedIssueNumber, 1478)
        XCTAssertEqual(m.rows[2].relatedIssueTitle, "Renew the contract")
        XCTAssertEqual(m.rows[2].suggestedStatus, "resolved")
        XCTAssertEqual(ReviewStub.seen.last?.url?.path, "/api/companion/review-queue")
        XCTAssertNil(ReviewStub.seen.last?.url?.query)
        XCTAssertEqual(ReviewStub.seen.last?.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
    }

    func test_queueForOneMeeting_asksForThatMeetingInLowercase() async throws {
        respond(200, try fixture("review-queue-meeting"))
        let queue = try await client().reviewQueue(meetingId: meeting)

        XCTAssertEqual(queue.meetings[0].rows.map(\.title), ["Send the budget", "Vendor may slip", "Contract renewed"])
        XCTAssertEqual(ReviewStub.seen.last?.url?.query, "meeting=3f95ffd6-fd1e-4640-aacc-89e1c051f742")
    }

    func test_queueForADeletedMeeting_isToldApartFromOtherFailures() async {
        respond(404, "{\"code\":\"meeting_gone\"}")
        do {
            _ = try await client().reviewQueue(meetingId: meeting)
            XCTFail("expected meetingGone")
        } catch {
            XCTAssertEqual(error as? ReviewQueueError, .meetingGone)
        }
    }

    func test_queueWhileSignedOut_saysSignedOut() async {
        respond(401, "{}")
        do {
            _ = try await client().reviewQueue(meetingId: nil)
            XCTFail("expected signedOut")
        } catch {
            XCTAssertEqual(error as? ReviewQueueError, .signedOut)
        }
    }

    func test_queueOnAServerError_isAFailureNotAnEmptyList() async {
        respond(500, "{}")
        do {
            _ = try await client().reviewQueue(meetingId: nil)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? ReviewQueueError, .failed)
        }
    }

    func test_saving_sendsTheEditsAndReportsSaved() async {
        respond(200, "{\"suggestion\":{},\"code\":\"saved\"}")
        let owner = UUID(uuidString: "EC4109B3-9E36-4A3D-8701-AC066AF779F1")!
        let result = await save(owner: owner, due: "2026-11-27")

        XCTAssertEqual(result, .saved)
        let request = ReviewStub.seen[0]
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path,
                       "/api/meetings/3f95ffd6-fd1e-4640-aacc-89e1c051f742/suggestions/f04a05e1-1ff7-4b9f-a50b-3bdf2a7db083")
        let body = try? JSONSerialization.jsonObject(with: ReviewStub.seenBodies[0]) as? [String: Any]
        XCTAssertEqual(body?["action"] as? String, "accept")
        XCTAssertEqual(body?["owner_user_id"] as? String, "ec4109b3-9e36-4a3d-8701-ac066af779f1")
        XCTAssertEqual(body?["due_date"] as? String, "2026-11-27")
    }

    func test_skipping_sendsRejectWithoutEdits() async {
        respond(200, "{\"suggestion\":{},\"code\":\"saved\"}")
        _ = await save(action: .reject)
        let body = try? JSONSerialization.jsonObject(with: ReviewStub.seenBodies[0]) as? [String: Any]
        XCTAssertEqual(body?["action"] as? String, "reject")
        XCTAssertEqual(Set(body?.keys ?? [:].keys), ["action"])
    }

    func test_clearingTheDueDate_sendsNullNotAbsent() async {
        respond(200, "{\"code\":\"saved\"}")
        _ = await save(due: "")
        let raw = String(data: ReviewStub.seenBodies[0], encoding: .utf8) ?? ""
        XCTAssertTrue(raw.contains("\"due_date\":null"), raw)
    }

    func test_everyRefusalMapsToWhatThePersonSees() async {
        let cases: [(Int, String, ReviewSaveResult)] = [
            (409, "already_reviewed", .alreadyReviewed),
            (409, "already_in_state", .alreadyInState),
            (404, "suggestion_gone", .suggestionGone),
            (404, "item_gone", .itemGone),
            (403, "not_reviewer", .notReviewer),
            (400, "not_a_member", .notAMember),
            (400, "cannot_keep_duplicate", .cannotKeepDuplicate),
            (400, "invalid_request", .invalidRequest),
            (500, "boom", .retryable),
            (503, "unavailable", .retryable),
            (418, "something_new", .retryable),
        ]
        for (status, code, expected) in cases {
            respond(status, "{\"code\":\"\(code)\"}")
            let result = await save()
            XCTAssertEqual(result, expected, "\(status) \(code)")
        }
    }

    func test_signedOutSave_isNotRetried() async {
        respond(401, "{}")
        let result = await save()
        XCTAssertEqual(result, .signedOut)
    }

    func test_droppedConnection_keepsTheRowForRetry() async {
        ReviewStub.handler = { _ in .failure(URLError(.networkConnectionLost)) }
        let result = await save()
        XCTAssertEqual(result, .retryable)
    }

    func test_regenerate_postsToTheMeetingsSuggestionsRoute() async throws {
        respond(202, "{}")
        try await client().regenerateSuggestions(meetingId: meeting)
        XCTAssertEqual(ReviewStub.seen[0].httpMethod, "POST")
        XCTAssertEqual(ReviewStub.seen[0].url?.path, "/api/meetings/3f95ffd6-fd1e-4640-aacc-89e1c051f742/suggestions")
    }

    func test_regenerate_throwsWhenTheServerRefuses() async {
        respond(500, "{}")
        do {
            try await client().regenerateSuggestions(meetingId: meeting)
            XCTFail("expected throw")
        } catch {}
    }

    func test_handoff_sendsOnlyTheDigestAndReturnsTheHandoffId() async throws {
        respond(200, "{\"handoff_id\":\"abc_DEF-123\"}")
        let id = try await client().webSessionHandoff(nonceDigest: String(repeating: "a", count: 64))

        XCTAssertEqual(id, "abc_DEF-123")
        XCTAssertEqual(ReviewStub.seen[0].httpMethod, "POST")
        XCTAssertEqual(ReviewStub.seen[0].url?.path, "/api/companion/web-session")
        let body = try? JSONSerialization.jsonObject(with: ReviewStub.seenBodies[0]) as? [String: String]
        XCTAssertEqual(body, ["nonce_digest": String(repeating: "a", count: 64)])
    }

    func test_handoffRefused_throws() async {
        respond(429, "{}")
        do {
            _ = try await client().webSessionHandoff(nonceDigest: "x")
            XCTFail("expected throw")
        } catch {}
    }

    func test_windowRequest_postsAFormWithLowercaseIdsAndEncodedFields() throws {
        let request = MinutiaClient.companionSessionRequest(
            instance: instance, handoffId: "id_1-x", nonce: "n+/=&", next: "/series/ABC?meeting=DEF&x=1")

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://minutia.example.com/auth/companion-session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)
        XCTAssertEqual(body, "handoff_id=id_1-x&nonce=n%2B%2F%3D%26&next=%2Fseries%2FABC%3Fmeeting%3DDEF%26x%3D1")
    }

    func test_nonceDigest_matchesAHandComputedSHA256() {
        // printf 'abc' | shasum -a 256
        XCTAssertEqual(
            MinutiaClient.handoffDigest(of: "abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func test_freshNonce_isLongUnguessableUrlSafeAndMatchesItsDigest() {
        let a = MinutiaClient.makeHandoffNonce()
        let b = MinutiaClient.makeHandoffNonce()

        XCTAssertNotEqual(a.nonce, b.nonce)
        XCTAssertEqual(a.nonce.count, 43)
        XCTAssertNil(a.nonce.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertEqual(a.digest, MinutiaClient.handoffDigest(of: a.nonce))
        XCTAssertEqual(a.digest.count, 64)
        XCTAssertEqual(a.digest, a.digest.lowercased())
    }
}
