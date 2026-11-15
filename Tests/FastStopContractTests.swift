import XCTest
@testable import Minutia

final class FastStopContractTests: XCTestCase {
    private let instance = URL(string: "https://minutia.example.com")!

    private func jsonBody(_ request: URLRequest) -> NSDictionary? {
        guard let body = request.httpBody, let object = try? JSONSerialization.jsonObject(with: body) else { return nil }
        return object as? NSDictionary
    }

    func test_aTailPiece_isRegisteredUnderItsSeqWithItsOwnStartTime() {
        let request = MinutiaClient.registerSegmentRequest(
            instance: instance, meetingId: "m1", seq: 13, offsetSeconds: 3_340.5, token: "t")
        XCTAssertEqual(jsonBody(request), [
            "paths": ["me": "m1/seg-13-me.m4a", "them": "m1/seg-13-them.m4a"],
            "offset_seconds": 3_340.5,
        ] as NSDictionary)
    }

    func test_theStopTranscription_asksTheServerNotToWaitOnActionItems() {
        let request = MinutiaClient.finalTranscribeRequest(
            instance: instance, meetingId: "m1", expectedSegments: 14, deferExtraction: true, token: "t")
        XCTAssertEqual(jsonBody(request), ["expected_segments": 14, "defer_extraction": true] as NSDictionary)
    }

    func test_recovery_keepsTheOriginalTranscriptionBody() {
        let request = MinutiaClient.finalTranscribeRequest(
            instance: instance, meetingId: "m1", expectedSegments: nil, token: "t")
        XCTAssertNil(jsonBody(request)?["defer_extraction"])
    }

    func test_theRecapOpenedAtStop_asksThePageToWriteTheRecap() {
        let url = MinutiaClient.recapURL(
            instance: instance,
            seriesId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            meetingId: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            autoRecap: true)
        XCTAssertEqual(
            url.absoluteString,
            "https://minutia.example.com/series/11111111-2222-3333-4444-555555555555/meetings/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee?recap=auto")
    }

    func test_aStop_allowsAMinuteToFinalize() {
        XCTAssertEqual(CaptureSession.finalizeTimeout, 60)
    }
}
