import XCTest
@testable import Minutia

final class StopEndsMeetingTests: XCTestCase {
    /// The same two columns the web's End meeting button writes, and nothing else.
    func test_endMeetingUpdate_marksTheMeetingCompletedAtTheGivenTime() throws {
        let ended = Date(timeIntervalSince1970: 1_763_190_000)
        let data = try JSONEncoder().encode(MinutiaClient.endMeetingUpdate(now: ended))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["status", "completed_at"])
        XCTAssertEqual(object["status"] as? String, "completed")
        let stamp = try XCTUnwrap(object["completed_at"] as? String)
        XCTAssertEqual(ISO8601DateFormatter().date(from: stamp), ended)
    }

    /// Only series owners and facilitators may change a meeting's status, so a participant's stop
    /// must still succeed when ending the meeting is refused.
    func test_endingTheMeeting_aRefusalNeverFailsTheStop() async {
        struct Refused: Error {}
        var attempted = false
        await CaptureSession.endMeetingIfAllowed { attempted = true; throw Refused() }
        XCTAssertTrue(attempted)
    }
}
