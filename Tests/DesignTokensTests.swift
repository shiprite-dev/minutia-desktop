import SwiftUI
import XCTest
@testable import Minutia

final class DesignTokensTests: XCTestCase {
    private let lightSurface: UInt32 = 0xFFFFFF
    private let darkSurface: UInt32 = 0x1E1E1E

    private func assertReadable(_ name: String, _ text: Token, on surface: (light: UInt32, dark: UInt32),
                                minimum: Double = 4.5, file: StaticString = #filePath, line: UInt = #line) {
        let light = Contrast.ratio(text.hex(dark: false), surface.light)
        let dark = Contrast.ratio(text.hex(dark: true), surface.dark)
        XCTAssertGreaterThanOrEqual(light, minimum, "\(name) in light is \(light)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(dark, minimum, "\(name) in dark is \(dark)", file: file, line: line)
    }

    func test_textTokens_areReadableOnThePanelInLightAndDark() {
        let panel = (light: lightSurface, dark: darkSurface)
        assertReadable("vermilionText", Brand.vermilionText, on: panel)
        assertReadable("ink3", Brand.ink3, on: panel)
        assertReadable("warn", Brand.warn, on: panel)
        assertReadable("success", Brand.success, on: panel)
        assertReadable("danger", Brand.danger, on: panel)
    }

    func test_textTokens_areReadableOnTheSoftAccentNotice() {
        let soft = (light: Brand.accentSoft.hex(dark: false), dark: Brand.accentSoft.hex(dark: true))
        assertReadable("vermilionText on accentSoft", Brand.vermilionText, on: soft)
    }

    func test_primaryButtonLabel_isReadableWhiteOnTheFill() {
        XCTAssertGreaterThanOrEqual(Contrast.ratio(0xFFFFFF, Brand.vermilionFill.hex(dark: false)), 4.5)
        XCTAssertGreaterThanOrEqual(Contrast.ratio(0xFFFFFF, Brand.vermilionFill.hex(dark: true)), 4.5)
    }

    func test_contrast_blackOnWhiteIs21() {
        XCTAssertEqual(Contrast.ratio(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
    }

    func test_reduceMotion_replacesEverySpringWithTheFade() {
        for animation in [Motion.settle, Motion.pop, Motion.snap, Motion.meter] {
            XCTAssertEqual(Motion.resolved(animation, reduce: true), Motion.fade)
            XCTAssertEqual(Motion.resolved(animation, reduce: false), animation)
        }
    }

    func test_fraunces_isBundledAndResolves() {
        XCTAssertTrue(Typo.frauncesAvailable)
    }

    func test_displayFont_neverCrashesAtAnySize() {
        for size in [0, 1, 17, 22, 400] as [CGFloat] { _ = Typo.display(size) }
    }
}

final class BrandMarkTests: XCTestCase {
    func test_fullLevel_showsTheIconProportions() {
        XCTAssertEqual(BrandMark.barHeights(level: 1), [0.44, 0.70, 1.0])
    }

    func test_silence_keepsEveryBarVisibleBelowItsRestHeight() {
        let silent = BrandMark.barHeights(level: 0)
        for (height, rest) in zip(silent, BrandMark.restRatios) {
            XCTAssertGreaterThan(height, 0.1)
            XCTAssertLessThan(height, rest)
        }
    }

    func test_level_isClampedToZeroAndOne() {
        XCTAssertEqual(BrandMark.barHeights(level: 7), BrandMark.barHeights(level: 1))
        XCTAssertEqual(BrandMark.barHeights(level: -3), BrandMark.barHeights(level: 0))
    }

    func test_louderIsNeverShorter() {
        let quiet = BrandMark.barHeights(level: 0.3), loud = BrandMark.barHeights(level: 0.8)
        for (q, l) in zip(quiet, loud) { XCTAssertLessThanOrEqual(q, l) }
    }

    func test_checkPoints_stayInsideTheFrameAndRiseLeftToRight() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let points = BrandMark.checkPoints(in: rect)
        XCTAssertEqual(points.count, 3)
        for point in points { XCTAssertTrue(rect.contains(point), "\(point)") }
        XCTAssertLessThan(points[0].x, points[1].x)
        XCTAssertLessThan(points[1].x, points[2].x)
        XCTAssertGreaterThan(points[1].y, points[0].y)
        XCTAssertLessThan(points[2].y, points[1].y)
    }

    func test_reduceMotion_showsTheFinishedCheckImmediately() {
        XCTAssertEqual(CheckReveal.initialProgress(reduceMotion: true), 1)
        XCTAssertEqual(CheckReveal.initialProgress(reduceMotion: false), 0)
    }
}

final class CelebrationTests: XCTestCase {
    func test_recapReady_playsWhenAFinishLandsCleanly() {
        XCTAssertTrue(Celebration.shouldPlay(from: .finalizing, to: .idle, feedback: nil))
    }

    func test_recapReady_neverPlaysForAFailedOrRedirectedFinish() {
        XCTAssertFalse(Celebration.shouldPlay(from: .finalizing, to: .error("x"), feedback: nil))
        XCTAssertFalse(Celebration.shouldPlay(from: .finalizing, to: .idle, feedback: "Couldn't transcribe"))
        XCTAssertFalse(Celebration.shouldPlay(from: .recording, to: .idle, feedback: nil))
        XCTAssertFalse(Celebration.shouldPlay(from: .signedOut, to: .idle, feedback: nil))
    }

    func test_backToBackMeeting_endsTheCelebrationAtOnce() {
        XCTAssertTrue(Celebration.visible(celebrating: true, phase: .idle))
        XCTAssertFalse(Celebration.visible(celebrating: true, phase: .recording))
        XCTAssertFalse(Celebration.visible(celebrating: true, phase: .detected(app: "Zoom")))
        XCTAssertFalse(Celebration.visible(celebrating: false, phase: .idle))
    }
}

final class FinishingProgressTests: XCTestCase {
    func test_transcribing_showsHowFarItGot() {
        XCTAssertEqual(FinishingProgress.fraction(.transcribing(completed: 3, total: 12)), 0.25)
    }

    func test_noTotalOrOtherSteps_showNoBar() {
        XCTAssertNil(FinishingProgress.fraction(.transcribing(completed: 0, total: 0)))
        XCTAssertNil(FinishingProgress.fraction(.preparingModel))
        XCTAssertNil(FinishingProgress.fraction(.uploadingRecording))
        XCTAssertNil(FinishingProgress.fraction(nil))
    }

    func test_overshoot_isClamped() {
        XCTAssertEqual(FinishingProgress.fraction(.transcribing(completed: 9, total: 4)), 1)
    }
}

final class ErrorActionsTests: XCTestCase {
    func test_micDenied_leadsWithOpeningSystemSettings() {
        let actions = ErrorActions.resolve(isMicError: true)
        XCTAssertEqual(actions.primary, .openSettings)
        XCTAssertEqual(actions.secondary, .retry)
    }

    func test_otherFailures_leadWithRetryAndKeepDismiss() {
        let actions = ErrorActions.resolve(isMicError: false)
        XCTAssertEqual(actions.primary, .retry)
        XCTAssertEqual(actions.secondary, .dismiss)
    }
}

final class SignInStageTests: XCTestCase {
    private func stage(connected: Bool = false, awaiting: Bool = false, connecting: Bool = false,
                       error: String? = nil, retryable: Bool = true) -> SignInStage {
        SignInStage.resolve(isConnected: connected, awaitingBrowser: awaiting, connecting: connecting,
                            errorMessage: error, retryable: retryable)
    }

    func test_connecting_showsTheSpinnerStage() {
        XCTAssertEqual(stage(connecting: true), .connecting)
    }

    func test_connected_offersSignIn() {
        XCTAssertEqual(stage(connected: true), .ready)
    }

    func test_waitingOnTheBrowser_winsOverReady() {
        XCTAssertEqual(stage(connected: true, awaiting: true), .browserPending)
    }

    func test_offline_showsTheFailureWithRetry() {
        XCTAssertEqual(stage(error: "No connection"), .failed(message: "No connection", retryable: true))
    }

    func test_untrustedServer_hidesRetry() {
        XCTAssertEqual(stage(error: "Not a Minutia server", retryable: false), .failed(message: "Not a Minutia server", retryable: false))
    }

    func test_neitherConnectedNorFailed_fallsBackToConnecting() {
        XCTAssertEqual(stage(), .connecting)
    }
}
