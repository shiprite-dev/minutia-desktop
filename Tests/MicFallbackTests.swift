import XCTest
@testable import Minutia

final class MicFallbackTests: XCTestCase {
    private let noConnection = NSError(domain: "com.apple.coreaudio.avfaudio", code: -10876)

    func test_noInputDevice_continuesOnSystemAudio() {
        XCTAssertEqual(
            CaptureSession.micFailureDisposition(for: MicCapture.CaptureError.noInputDevice, systemAudioAvailable: true),
            .continueWithoutMic)
    }

    func test_engineNoConnection_continuesOnSystemAudio() {
        XCTAssertEqual(
            CaptureSession.micFailureDisposition(for: noConnection, systemAudioAvailable: true),
            .continueWithoutMic)
    }

    func test_noInputDevice_isFatalWhenSystemAudioIsAlsoUnavailable() {
        XCTAssertEqual(
            CaptureSession.micFailureDisposition(for: MicCapture.CaptureError.noInputDevice, systemAudioAvailable: false),
            .fatal)
        XCTAssertEqual(
            CaptureSession.micFailureDisposition(for: noConnection, systemAudioAvailable: false),
            .fatal)
    }

    func test_permissionDenied_staysFatal() {
        XCTAssertEqual(
            CaptureSession.micFailureDisposition(for: MicCapture.CaptureError.permissionDenied, systemAudioAvailable: true),
            .fatal)
    }

    func test_otherEngineErrors_stayFatal() {
        let other = NSError(domain: "com.apple.coreaudio.avfaudio", code: -10875)
        XCTAssertEqual(CaptureSession.micFailureDisposition(for: other, systemAudioAvailable: true), .fatal)
        XCTAssertEqual(
            CaptureSession.micFailureDisposition(for: MicCapture.CaptureError.converterUnavailable, systemAudioAvailable: true),
            .fatal)
    }

    func test_fatalMessageForNoAudioSources_isPlainLanguage() {
        let message = CaptureSession.failureMessage(for: MicCapture.CaptureError.noInputDevice)
        XCTAssertEqual(message, "No microphone or meeting audio found to record.")
        XCTAssertFalse(message.contains("10876"))
    }

    func test_micUnavailableNotice_copy() {
        XCTAssertEqual(CaptureSession.micUnavailableNotice, "No microphone found. Recording meeting audio only.")
    }
}
