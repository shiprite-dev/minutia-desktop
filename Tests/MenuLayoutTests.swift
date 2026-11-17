import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Minutia

@MainActor
enum Host {
    static func view<V: View>(_ root: V, dark: Bool = false) -> NSHostingView<some View> {
        let hosting = NSHostingView(rootView: root.environment(\.colorScheme, dark ? .dark : .light))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    static func size<V: View>(_ root: V, dark: Bool = false) -> CGSize {
        view(root, dark: dark).fittingSize
    }

    static func text<V: View>(_ root: V, dark: Bool = false) -> Seen {
        let backdrop = dark ? Color(red: 0.145, green: 0.145, blue: 0.15) : Color.white
        let hosting = NSHostingView(rootView: root.background(backdrop).environment(\.colorScheme, dark ? .dark : .light))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = hosting.appearance
        window.contentView = hosting
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()
        let scale = 3
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return Seen(text: "") }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let image = rep.cgImage else { return Seen(text: "") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return Seen(text: lines.joined(separator: " "))
    }
}

struct Seen {
    let text: String

    private static func normalize(_ value: String) -> String {
        value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    func has(_ expected: String) -> Bool { Self.normalize(text).contains(Self.normalize(expected)) }
}

private let longName = String(repeating: "Quarterly platform reliability and security review ", count: 3).prefix(120).description
private let sampleSeries = [Series(id: UUID(), name: "Weekly Eng Sync"), Series(id: UUID(), name: longName)]

@MainActor
final class MenuLayoutTests: XCTestCase {
    private func assertFits<V: View>(_ name: String, _ view: V, file: StaticString = #filePath, line: UInt = #line) {
        for dark in [false, true] {
            let size = Host.size(view, dark: dark)
            XCTAssertEqual(size.width, 320, "\(name) width (dark: \(dark))", file: file, line: line)
            XCTAssertLessThanOrEqual(size.height, 520, "\(name) height (dark: \(dark))", file: file, line: line)
            XCTAssertGreaterThan(size.height, 40, "\(name) renders", file: file, line: line)
        }
    }

    private var idleModel: IdleModel {
        IdleModel(series: sampleSeries, selected: sampleSeries[0].id, detectedVia: nil, softHint: false,
                  micBanner: false, recovering: false, instance: URL(string: "https://example.com")!)
    }

    func test_everyScreen_isPanelWidthAndFitsInTheBudget() {
        assertFits("idle", IdleScreen(model: idleModel))
        assertFits("detected", IdleScreen(model: { var m = idleModel; m.detectedVia = "Zoom"; return m }()))
        assertFits("everything at once", IdleScreen(model: { var m = idleModel; m.detectedVia = "Zoom"; m.micBanner = true; m.recovering = true; return m }()))
        assertFits("zero series", IdleScreen(model: { var m = idleModel; m.series = []; m.selected = nil; return m }()))
        assertFits("recording", RecordingContent(model: RecordingModel(seriesName: "Weekly Eng Sync", elapsed: 754, level: 0.5, progress: "2 of 3 segments uploaded")))
        assertFits("finishing", FinishingContent(label: "Uploading and requesting transcript", progress: nil, preparingSince: nil))
        assertFits("transcribing", FinishingContent(label: "Transcribing on this Mac, 3 of 12", progress: 0.25, preparingSince: nil))
        assertFits("done", DoneContent())
        assertFits("error", ErrorScreen(message: "Upload failed after several attempts. Your recording is saved on this Mac.", isMicError: false))
        assertFits("mic error", ErrorScreen(message: "Microphone access was denied.", isMicError: true))
        for stage in [SignInStage.connecting, .ready, .browserPending, .failed(message: "Can't reach app.getminutia.com. Check your connection.", retryable: true)] {
            assertFits("sign-in \(stage)", SignInScreen(stage: stage, showsMenuBarHint: true, signInError: nil, email: .constant(""), password: .constant(""), showEmailForm: .constant(true), busy: false))
        }
    }

    func test_veryLongSeriesName_clampsToTwoLinesWithoutGrowingThePanel() {
        let short = Host.size(RecordingContent(model: RecordingModel(seriesName: "Weekly Eng Sync", elapsed: 7457, level: 1, progress: "x")))
        let long = Host.size(RecordingContent(model: RecordingModel(seriesName: longName, elapsed: 7457, level: 1, progress: "x")))
        XCTAssertLessThan(long.height - short.height, 30)
        let huge = Host.size(RecordingContent(model: RecordingModel(seriesName: String(repeating: "W", count: 400), elapsed: 7457, level: 1, progress: "x")))
        XCTAssertEqual(huge.height, long.height, accuracy: 1)
    }

    func test_longSeriesName_inIdleSelectorDoesNotWidenThePanel() {
        var model = idleModel
        model.selected = sampleSeries[1].id
        XCTAssertEqual(Host.size(IdleScreen(model: model)).width, 320)
    }

    func test_largestTextSize_stillFits() {
        let view = RecordingContent(model: RecordingModel(seriesName: longName, elapsed: 7457, level: 1, progress: "2 of 3 segments uploaded", reconnecting: true, systemAudioDegraded: true, micUnavailable: true))
            .dynamicTypeSize(.accessibility5)
        let size = Host.size(view)
        XCTAssertEqual(size.width, 320)
        XCTAssertLessThanOrEqual(size.height, 520)
    }

    func test_recordingWithEveryNotice_fitsTheBudget() {
        let model = RecordingModel(seriesName: longName, elapsed: 7457, level: 0.2, progress: "2 of 3 segments uploaded", reconnecting: true, systemAudioDegraded: true, micUnavailable: true)
        XCTAssertLessThanOrEqual(Host.size(RecordingContent(model: model)).height, 520)
    }
}

@MainActor
final class MenuStatesSeenTests: XCTestCase {
    private func model(series: [Series] = sampleSeries, selected: UUID? = sampleSeries[0].id, detectedVia: String? = nil) -> IdleModel {
        IdleModel(series: series, selected: selected, detectedVia: detectedVia, softHint: false, micBanner: false,
                  recovering: false, instance: URL(string: "https://example.com")!)
    }

    func test_idle_offersRecordUnderTheSeriesEyebrow() {
        let seen = Host.text(IdleScreen(model: model()))
        XCTAssertTrue(seen.has("Record"), seen.text)
        XCTAssertTrue(seen.has("SERIES"), seen.text)
    }

    func test_zeroSeries_guidesAndHidesRecord_keepingConnectGoogleCalendar() {
        let seen = Host.text(IdleScreen(model: model(series: [], selected: nil)))
        XCTAssertTrue(seen.has("No series yet"), seen.text)
        XCTAssertTrue(seen.has("Connect Google Calendar"), seen.text)
        XCTAssertTrue(seen.has("Create a series"), seen.text)
        XCTAssertFalse(seen.has("SERIES Record"), seen.text)
        XCTAssertFalse(seen.has("Series Record"), seen.text)
    }

    func test_detected_showsTheExistingBannerCopyAndRecord() {
        let seen = Host.text(IdleScreen(model: model(detectedVia: "Zoom")))
        XCTAssertTrue(seen.has(AppController.detectionBannerText(via: "Zoom")), seen.text)
        XCTAssertTrue(seen.has("Record"), seen.text)
    }

    func test_detected_readsInDarkToo() {
        let seen = Host.text(IdleScreen(model: model(detectedVia: "Zoom")), dark: true)
        XCTAssertTrue(seen.has(AppController.detectionBannerText(via: "Zoom")), seen.text)
    }

    func test_recording_namesTheSeriesTheClockAndStop() {
        let seen = Host.text(RecordingContent(model: RecordingModel(seriesName: "Weekly Eng Sync", elapsed: 7457, level: 0.4, progress: "2 of 3 segments uploaded")))
        XCTAssertTrue(seen.has("Weekly Eng Sync"), seen.text)
        XCTAssertTrue(seen.has("2:04:17"), seen.text)
        XCTAssertTrue(seen.has("Stop"), seen.text)
        XCTAssertTrue(seen.has("2 of 3 segments uploaded"), seen.text)
        XCTAssertTrue(seen.has("RECORDING"), seen.text)
    }

    func test_recording_longNameIsTruncatedNotWrappedPastTwoLines() {
        let seen = Host.text(RecordingContent(model: RecordingModel(seriesName: longName, elapsed: 5, level: 0, progress: "x")))
        XCTAssertTrue(seen.has("Quarterly platform"), seen.text)
        XCTAssertFalse(seen.has("security review Quarterly platform reliability and security review Quarterly platform reliability and security review"), seen.text)
    }

    func test_recording_surfacesDegradedAudioAndReconnecting() {
        let seen = Host.text(RecordingContent(model: RecordingModel(seriesName: "S", elapsed: 5, level: 0, progress: "x", reconnecting: true, systemAudioDegraded: true)))
        XCTAssertTrue(seen.has("Reconnecting"), seen.text)
        XCTAssertTrue(seen.has("System audio isn't being captured. Recording your microphone only."), seen.text)
    }

    func test_finishing_tellsTheUserTheyCanLeave() {
        let seen = Host.text(FinishingContent(label: "Uploading and requesting transcript", progress: nil, preparingSince: nil))
        XCTAssertTrue(seen.has("Uploading and requesting transcript"), seen.text)
        XCTAssertTrue(seen.has("You can close this. Minutia finishes in the background."), seen.text)
    }

    func test_done_saysRecapIsReady() {
        XCTAssertTrue(Host.text(DoneContent()).has("Recap is ready"))
    }

    func test_failedUpload_showsTheMessageRetryAndDismiss() {
        let seen = Host.text(ErrorScreen(message: "Upload failed. Your recording is saved on this Mac.", isMicError: false))
        XCTAssertTrue(seen.has("Upload failed. Your recording is saved on this Mac."), seen.text)
        XCTAssertTrue(seen.has("Retry"), seen.text)
        XCTAssertTrue(seen.has("Dismiss"), seen.text)
        XCTAssertFalse(seen.has("Open System Settings"), seen.text)
    }

    func test_micDenied_offersSystemSettingsAndRetry() {
        let seen = Host.text(ErrorScreen(message: "Microphone access was denied.", isMicError: true))
        XCTAssertTrue(seen.has("Open System Settings"), seen.text)
        XCTAssertTrue(seen.has("Retry"), seen.text)
    }

    private func signIn(_ stage: SignInStage, hint: Bool = false, error: String? = nil) -> Seen {
        Host.text(SignInScreen(stage: stage, showsMenuBarHint: hint, signInError: error, email: .constant(""), password: .constant(""), showEmailForm: .constant(false), busy: false))
    }

    func test_signedOut_invitesBrowserSignInAndKeepsEmailQuiet() {
        let seen = signIn(.ready)
        XCTAssertTrue(seen.has("Sign in with browser"), seen.text)
        XCTAssertTrue(seen.has("Use email instead"), seen.text)
        XCTAssertTrue(seen.has("Record a meeting. Get the issues log."), seen.text)
    }

    func test_signedOut_firstRunShowsTheMenuBarHint() {
        XCTAssertTrue(signIn(.ready, hint: true).has(FirstRun.menuBarHint))
        XCTAssertFalse(signIn(.ready, hint: false).has(FirstRun.menuBarHint))
    }

    func test_signInWaiting_offersStartOver() {
        let seen = signIn(.browserPending)
        XCTAssertTrue(seen.has("Check your browser to finish signing in."), seen.text)
        XCTAssertTrue(seen.has("Start over"), seen.text)
        XCTAssertFalse(seen.has("Sign in with browser"), seen.text)
    }

    func test_connecting_canBeCancelled() {
        let seen = signIn(.connecting)
        XCTAssertTrue(seen.has("Connecting to Minutia"), seen.text)
        XCTAssertTrue(seen.has("Cancel"), seen.text)
    }

    func test_offline_showsMessageRetryAndSelfHostLink() {
        let seen = signIn(.failed(message: "Can't reach the server.", retryable: true))
        XCTAssertTrue(seen.has("Can't reach the server."), seen.text)
        XCTAssertTrue(seen.has("Try again"), seen.text)
        XCTAssertTrue(seen.has("Using a self-hosted server?"), seen.text)
    }

    func test_notAMinutiaServer_hasNoRetry() {
        let seen = signIn(.failed(message: "Not a Minutia server.", retryable: false))
        XCTAssertFalse(seen.has("Try again"), seen.text)
        XCTAssertTrue(seen.has("Using a self-hosted server?"), seen.text)
    }

    func test_signInFailure_isShownAboveTheButton() {
        XCTAssertTrue(signIn(.ready, error: "Invalid login").has("Invalid login"))
    }

    func test_footer_showsUpdateChipOnlyWhenAvailable() {
        XCTAssertTrue(Host.text(FooterBar(updateAvailable: true)).has("Update available"))
        XCTAssertFalse(Host.text(FooterBar(updateAvailable: false)).has("Update available"))
        XCTAssertTrue(Host.text(FooterBar(updateAvailable: false)).has("Quit"))
    }

    func test_modelDownload_showsTheExistingLabel() {
        XCTAssertTrue(Host.text(ModelDownloadRow(label: "Downloading model 42%", fraction: 0.42)).has("Downloading model 42%"))
    }
}
