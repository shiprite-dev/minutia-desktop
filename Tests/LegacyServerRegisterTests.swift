import XCTest
@testable import Minutia

/// A server without two-channel support answers the `paths` register body with 400 "Invalid segment
/// path." (its validator only accepts `<meeting>/seg-<n>.<ext>`, a file the companion no longer
/// uploads). That is terminal per segment, never retried, and the stop path must then ask for the
/// final transcription without an expected segment count so the server transcribes the whole
/// recording instead of waiting on fast-lane segments that never registered.
final class LegacyServerRegisterTests: XCTestCase {
    func test_legacyInvalidPathRejection_isTerminalNotRetried() {
        let body = Data(#"{"error":"Invalid segment path.","request_id":"r1"}"#.utf8)
        XCTAssertEqual(MinutiaClient.classify(status: 400, body: body), .terminalOther)
    }

    func test_expectedSegments_allRegistered_reportsTheCount() {
        XCTAssertEqual(CaptureSession.expectedSegments(enqueued: 4, registered: 4), 4)
    }

    func test_expectedSegments_noneRegisteredOnLegacyServer_isNil() {
        XCTAssertNil(CaptureSession.expectedSegments(enqueued: 4, registered: 0))
    }

    func test_expectedSegments_partiallyRegistered_isNil() {
        XCTAssertNil(CaptureSession.expectedSegments(enqueued: 4, registered: 3))
    }

    func test_expectedSegments_noSegments_isNil() {
        XCTAssertNil(CaptureSession.expectedSegments(enqueued: 0, registered: 0))
    }
}
