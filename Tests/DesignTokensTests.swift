import SwiftUI
import XCTest
@testable import Minutia

final class DesignTokensTests: XCTestCase {
    private let lightPanels: [UInt32] = [0xF5F5F5, 0xFFFFFF]
    private let darkPanels: [UInt32] = [0x252526, 0x2C2C2E]

    private func assertReadable(_ name: String, _ text: Token, light: [UInt32], dark: [UInt32],
                                minimum: Double = 4.5, file: StaticString = #filePath, line: UInt = #line) {
        for surface in light {
            let ratio = Contrast.ratio(text.hex(dark: false), surface)
            XCTAssertGreaterThanOrEqual(ratio, minimum, "\(name) on \(String(surface, radix: 16)) in light is \(ratio)", file: file, line: line)
        }
        for surface in dark {
            let ratio = Contrast.ratio(text.hex(dark: true), surface)
            XCTAssertGreaterThanOrEqual(ratio, minimum, "\(name) on \(String(surface, radix: 16)) in dark is \(ratio)", file: file, line: line)
        }
    }

    private var softLight: [UInt32] { [Brand.accentSoft.hex(dark: false), Brand.warnSoft.hex(dark: false)] }
    private var softDark: [UInt32] { [Brand.accentSoft.hex(dark: true), Brand.warnSoft.hex(dark: true)] }

    func test_textTokens_areReadableOnTheRealPanelSurfaces() {
        for (name, token) in [("ink2", Brand.ink2), ("ink3", Brand.ink3), ("vermilionText", Brand.vermilionText), ("warn", Brand.warn)] {
            assertReadable(name, token, light: lightPanels, dark: darkPanels)
        }
    }

    func test_bodyAndCaptionText_isReadableInsideEveryNoticeFill() {
        assertReadable("ink2 in notices", Brand.ink2, light: softLight, dark: softDark)
        assertReadable("warn icon in notices", Brand.warn, light: softLight, dark: softDark, minimum: 3)
        assertReadable("vermilionText on accent notice", Brand.vermilionText,
                       light: [Brand.accentSoft.hex(dark: false)], dark: [Brand.accentSoft.hex(dark: true)])
    }

    func test_greyHierarchy_secondInkIsMoreProminentThanThirdInBothSchemes() {
        XCTAssertGreaterThan(Contrast.ratio(Brand.ink2.hex(dark: false), 0xF5F5F5), Contrast.ratio(Brand.ink3.hex(dark: false), 0xF5F5F5))
        XCTAssertGreaterThan(Contrast.ratio(Brand.ink2.hex(dark: true), 0x252526), Contrast.ratio(Brand.ink3.hex(dark: true), 0x252526))
    }

    func test_darkNoticeFills_sitLighterThanThePanelAndStayLowChroma() {
        for fill in [Brand.accentSoft, Brand.warnSoft] {
            let hex = fill.hex(dark: true)
            XCTAssertGreaterThan(Contrast.luminance(hex), Contrast.luminance(0x252526))
            let channels = [(hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF]
            XCTAssertLessThanOrEqual(channels.max()! - channels.min()!, 40)
        }
    }

    func test_primaryButtonLabel_isReadableWhiteOnTheFill() {
        XCTAssertGreaterThanOrEqual(Contrast.ratio(0xFFFFFF, Brand.vermilionFill.hex(dark: false)), 4.5)
        XCTAssertGreaterThanOrEqual(Contrast.ratio(0xFFFFFF, Brand.vermilionFill.hex(dark: true)), 4.5)
    }

    func test_contrast_blackOnWhiteIs21() {
        XCTAssertEqual(Contrast.ratio(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
    }

    func test_increaseContrast_strengthensHairlinesBordersAndQuietText() {
        XCTAssertEqual(Hairline.width(.standard), 0.5)
        XCTAssertEqual(Hairline.width(.increased), 1)
        XCTAssertEqual(Hairline.noticeBorder(.standard), 0)
        XCTAssertEqual(Hairline.noticeBorder(.increased), 1)
        XCTAssertFalse(Hairline.quietTextIsStrong(.standard))
        XCTAssertTrue(Hairline.quietTextIsStrong(.increased))
    }

    func test_reduceMotion_replacesEverySpringWithTheFade() {
        for animation in [Motion.settle, Motion.pop, Motion.snap, Motion.meter] {
            XCTAssertEqual(Motion.resolved(animation, reduce: true), Motion.fade)
            XCTAssertEqual(Motion.resolved(animation, reduce: false), animation)
        }
    }

    func test_loops_runOnlyWhileThePanelIsOpenAndMotionIsAllowed() {
        XCTAssertTrue(Loops.isRunning(visible: true, reduceMotion: false))
        XCTAssertFalse(Loops.isRunning(visible: false, reduceMotion: false))
        XCTAssertFalse(Loops.isRunning(visible: true, reduceMotion: true))
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

    func test_barsOnlyFrame_isCroppedToTheBars() {
        let size = BrandMark.frame(barHeight: 20, includesCheck: false)
        let union = (0..<3).map { BrandMark.barRect(index: $0, barHeight: 20, includesCheck: false) }.reduce(CGRect.null) { $0.union($1) }
        XCTAssertEqual(union.minX, 0, accuracy: 0.01)
        XCTAssertEqual(union.width, size.width, accuracy: 0.01)
        XCTAssertEqual(union.height, size.height, accuracy: 0.01)
    }

    func test_checkFrame_holdsTheWholeCheckStroke() {
        let size = BrandMark.frame(barHeight: 20, includesCheck: true)
        let rect = CGRect(origin: .zero, size: size)
        let stroke = BrandMark.checkStroke(barHeight: 20)
        for point in BrandMark.checkPoints(in: rect) {
            XCTAssertGreaterThanOrEqual(point.x - stroke / 2, -0.01)
            XCTAssertLessThanOrEqual(point.x + stroke / 2, size.width + 0.01)
            XCTAssertGreaterThanOrEqual(point.y - stroke / 2, -0.01)
            XCTAssertLessThanOrEqual(point.y + stroke / 2, size.height + 0.01)
        }
    }

    func test_checkStroke_matchesTheIconProportion() {
        XCTAssertEqual(BrandMark.checkStroke(barHeight: 340), 84, accuracy: 0.001)
    }

    func test_eachBarFollowsItsOwnLevel() {
        let heights = BrandMark.barHeights(levels: [0, 0.5, 1])
        XCTAssertLessThan(heights[0] / BrandMark.restRatios[0], heights[1] / BrandMark.restRatios[1])
        XCTAssertLessThan(heights[1] / BrandMark.restRatios[1], heights[2] / BrandMark.restRatios[2])
    }

    func test_levelHistory_keepsTheLastThreeAndFillsFromTheCurrentLevel() {
        XCTAssertEqual(LevelHistory.push([0.1, 0.2, 0.3], 0.4), [0.2, 0.3, 0.4])
        XCTAssertEqual(LevelHistory.perBar([], current: 0.6), [0.6, 0.6, 0.6])
        XCTAssertEqual(LevelHistory.perBar([0.1], current: 0.1), [0.1, 0.1, 0.1])
    }

    func test_screenReaderLevel_isAPercentClampedToTheRange() {
        XCTAssertEqual(LevelHistory.percent(0.456), 46)
        XCTAssertEqual(LevelHistory.percent(7), 100)
        XCTAssertEqual(LevelHistory.percent(-1), 0)
    }

    func test_reduceMotion_showsTheFinishedCheckImmediately() {
        XCTAssertEqual(CheckReveal.initialProgress(reduceMotion: true), 1)
        XCTAssertEqual(CheckReveal.initialProgress(reduceMotion: false), 0)
    }
}

final class CelebrationTests: XCTestCase {
    private let cue = RecapCue(meetingId: UUID(), seriesId: UUID(), instance: URL(string: "https://example.com")!)

    func test_sentScreen_showsOnlyOverIdleWithACue() {
        XCTAssertTrue(Celebration.visible(cue: cue, phase: .idle))
        XCTAssertFalse(Celebration.visible(cue: nil, phase: .idle))
    }

    func test_backToBackMeeting_endsTheCelebrationAtOnce() {
        XCTAssertFalse(Celebration.visible(cue: cue, phase: .recording))
        XCTAssertFalse(Celebration.visible(cue: cue, phase: .detected(app: "Zoom")))
        XCTAssertFalse(Celebration.visible(cue: cue, phase: .error("x")))
    }

    func test_hold_keepsTheFinishedCheckOnScreenAfterItDraws() {
        let drawn = 0.18 + CheckReveal.drawDuration + CheckReveal.popHold
        XCTAssertEqual(Celebration.hold(reduceMotion: false), drawn + 1.6, accuracy: 0.001)
        XCTAssertEqual(Celebration.hold(reduceMotion: true), 1.6, accuracy: 0.001)
    }

    func test_popHold_outlastsThePopSpringsPeak() {
        XCTAssertGreaterThanOrEqual(CheckReveal.popHold, 0.24)
    }

    func test_webEndedStop_hasNoCue_andAManualStopThatSentTheTranscriptHasOne() {
        let id = UUID(), url = URL(string: "https://example.com")!
        XCTAssertNil(AppController.recapCue(reason: .webEnded, transcriptRequested: true, meetingId: id, seriesId: nil, instance: url))
        XCTAssertNil(AppController.recapCue(reason: .manual, transcriptRequested: false, meetingId: id, seriesId: nil, instance: url))
        XCTAssertNil(AppController.recapCue(reason: .manual, transcriptRequested: true, meetingId: nil, seriesId: nil, instance: url))
        XCTAssertEqual(AppController.recapCue(reason: .manual, transcriptRequested: true, meetingId: id, seriesId: nil, instance: url)?.meetingId, id)
        XCTAssertNotNil(AppController.recapCue(reason: .localEnded, transcriptRequested: true, meetingId: id, seriesId: nil, instance: url))
    }
}

final class PanelHapticTests: XCTestCase {
    func test_buzzesWhenRecordingStartsAndWhenStopIsPressed() {
        XCTAssertNotNil(PanelHaptic.feedback(from: .idle, to: .recording))
        XCTAssertNotNil(PanelHaptic.feedback(from: .detected(app: "Zoom"), to: .recording))
        XCTAssertNotNil(PanelHaptic.feedback(from: .recording, to: .finalizing))
    }

    func test_staysQuietForFailuresAndEverythingElse() {
        XCTAssertNil(PanelHaptic.feedback(from: .recording, to: .error("x")))
        XCTAssertNil(PanelHaptic.feedback(from: .finalizing, to: .idle))
        XCTAssertNil(PanelHaptic.feedback(from: .idle, to: .detected(app: nil)))
        XCTAssertNil(PanelHaptic.feedback(from: .signedOut, to: .idle))
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
