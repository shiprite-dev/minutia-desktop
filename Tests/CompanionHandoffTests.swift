import XCTest
@testable import Minutia

final class CompanionHandoffTests: XCTestCase {
    private let instance = URL(string: "https://minutia.example.com")!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "handoff-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func jsonBody(_ request: URLRequest) -> NSDictionary? {
        guard let body = request.httpBody, let object = try? JSONSerialization.jsonObject(with: body) else { return nil }
        return object as? NSDictionary
    }

    func test_aCheckIn_saysWhichMacItIsAndWhetherItCanRecordNow() {
        let request = MinutiaClient.checkinRequest(
            instance: instance, token: "t", deviceId: "dev-1", deviceName: "Studio Mac", canClaim: true)
        XCTAssertEqual(request.url, URL(string: "https://minutia.example.com/api/companion/checkin"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(jsonBody(request), ["device_id": "dev-1", "device_name": "Studio Mac", "can_claim": true] as NSDictionary)
    }

    func test_aCheckIn_returnsTheMeetingTheWebAskedThisMacToRecord() {
        let claimed = Data(#"{"claim":{"meeting_id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","series_id":"11111111-2222-3333-4444-555555555555"}}"#.utf8)
        XCTAssertEqual(
            MinutiaClient.decodeCheckin(claimed),
            CheckinClaim(meetingId: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", seriesId: "11111111-2222-3333-4444-555555555555"))
        XCTAssertNil(MinutiaClient.decodeCheckin(Data(#"{"claim":null}"#.utf8)))
        XCTAssertNil(MinutiaClient.decodeCheckin(Data("not json".utf8)))
    }

    func test_recordingEvents_tellTheWebWhatThisMacIsDoing() {
        let started = MinutiaClient.recordingEventRequest(
            instance: instance, token: "t", meetingId: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            deviceId: "dev-1", deviceName: "Studio Mac", event: .started, reason: nil)
        XCTAssertEqual(started.url, URL(string: "https://minutia.example.com/api/companion/recording"))
        XCTAssertEqual(jsonBody(started), [
            "meeting_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "device_id": "dev-1",
            "device_name": "Studio Mac", "event": "started",
        ] as NSDictionary)

        let failed = MinutiaClient.recordingEventRequest(
            instance: instance, token: "t", meetingId: "m1", deviceId: "dev-1", deviceName: "Studio Mac",
            event: .failed, reason: "mic_denied")
        XCTAssertEqual(jsonBody(failed)?["event"] as? String, "failed")
        XCTAssertEqual(jsonBody(failed)?["reason"] as? String, "mic_denied")
    }

    func test_theServerCanRefuseASecondRecorder() {
        XCTAssertEqual(MinutiaClient.decodeRecordingResult(Data(#"{"result":"ok"}"#.utf8)), .ok)
        XCTAssertEqual(MinutiaClient.decodeRecordingResult(Data(#"{"result":"conflict"}"#.utf8)), .conflict)
        XCTAssertEqual(MinutiaClient.decodeRecordingResult(Data(#"{"result":"ignored"}"#.utf8)), .ignored)
        XCTAssertEqual(MinutiaClient.decodeRecordingResult(Data("{}".utf8)), .ignored)
    }

    func test_checkIns_areQuickWhileIdle_slowWhileRecording_andStopWhenSignedOut() {
        XCTAssertEqual(CheckinPolicy.interval(for: .idle), 5)
        XCTAssertEqual(CheckinPolicy.interval(for: .detected(app: "Zoom")), 5)
        XCTAssertEqual(CheckinPolicy.interval(for: .error("x")), 5)
        XCTAssertEqual(CheckinPolicy.interval(for: .recording), 30)
        XCTAssertEqual(CheckinPolicy.interval(for: .finalizing), 30)
        XCTAssertNil(CheckinPolicy.interval(for: .signedOut))
    }

    func test_aMacOnlyTakesAWebRequest_whenSomeoneIsAtIt_andItIsFreeToRecord() {
        XCTAssertTrue(CheckinPolicy.canClaim(phase: .idle, screenLocked: false, idleSeconds: 30))
        XCTAssertFalse(CheckinPolicy.canClaim(phase: .idle, screenLocked: true, idleSeconds: 30))
        XCTAssertFalse(CheckinPolicy.canClaim(phase: .idle, screenLocked: false, idleSeconds: 301))
        XCTAssertFalse(CheckinPolicy.canClaim(phase: .recording, screenLocked: false, idleSeconds: 1))
        XCTAssertFalse(CheckinPolicy.canClaim(phase: .finalizing, screenLocked: false, idleSeconds: 1))
        XCTAssertFalse(CheckinPolicy.canClaim(phase: .signedOut, screenLocked: false, idleSeconds: 1))
    }

    func test_webStarts_askOnceUntilTheUserChoosesAlways_andTheChoiceSticks() {
        XCTAssertEqual(WebStartPolicy.load(from: defaults), .ask)
        XCTAssertEqual(WebStartPolicy.ask.onClaim, .askFirst)
        WebStartPolicy.always.save(to: defaults)
        XCTAssertEqual(WebStartPolicy.load(from: defaults), .always)
        XCTAssertEqual(WebStartPolicy.always.onClaim, .startNow)
    }

    func test_thisMac_keepsOneIdentity() {
        let first = DeviceIdentity.id(in: defaults)
        XCTAssertEqual(DeviceIdentity.id(in: defaults), first)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(first, first.lowercased())
    }

    func test_openingTheAppFromTheWeb_isItsOwnLink() {
        XCTAssertEqual(DeepLink.parse(URL(string: "minutia://open")!), .open)
    }
}
