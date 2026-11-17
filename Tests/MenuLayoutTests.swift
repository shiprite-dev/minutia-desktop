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

    static func render<V: View>(_ root: V, dark: Bool = false, spin: TimeInterval = 0.6, contrastBackdrop: Bool = true) -> CGImage? {
        let backdrop = dark ? Color(red: 0.145, green: 0.145, blue: 0.15) : Color(red: 0.96, green: 0.96, blue: 0.96)
        let hosting = NSHostingView(rootView: root.background(backdrop).environment(\.colorScheme, dark ? .dark : .light))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = hosting.appearance
        window.contentView = hosting
        RunLoop.current.run(until: Date().addingTimeInterval(spin))
        hosting.layoutSubtreeIfNeeded()
        let scale = 3
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep.cgImage
    }

    static func text<V: View>(_ root: V, dark: Bool = false) -> Seen {
        guard let image = render(root, dark: dark) else { return Seen(text: "", frames: []) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let found = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
        }
        return Seen(text: found.map(\.0).joined(separator: " "), frames: found)
    }

    static func pixels(_ image: CGImage) -> (width: Int, height: Int, data: [UInt8]) {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (image.width, image.height, data)
    }

    private static func isFill(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        abs(Int(r) - 0xD4) < 24 && abs(Int(g) - 0x35) < 24 && Int(b) < 40
    }

    static func fillBands<V: View>(_ root: V, atPoint x: CGFloat) -> Int {
        guard let image = render(root) else { return 0 }
        let (width, height, data) = pixels(image)
        let column = min(width - 1, Int(x * CGFloat(width) / 320))
        var bands = 0, inBand = false
        for row in 0..<height {
            let i = (row * width + column) * 4
            let on = isFill(data[i], data[i + 1], data[i + 2])
            if on && !inBand { bands += 1 }
            inBand = on
        }
        return bands
    }

    static func vermilionPixels<V: View>(_ root: V, spin: TimeInterval) -> Int {
        guard let image = render(root, spin: spin) else { return 0 }
        let (width, height, data) = pixels(image)
        var count = 0
        for i in stride(from: 0, to: width * height * 4, by: 4)
        where abs(Int(data[i]) - 0xE2) < 14 && abs(Int(data[i + 1]) - 0x3A) < 14 && Int(data[i + 2]) < 20 { count += 1 }
        return count
    }
}

struct Seen {
    let text: String
    let frames: [(String, CGRect)]

    private static let homoglyphs: [Character: Character] = [
        "\u{0430}": "a", "\u{0435}": "e", "\u{043E}": "o", "\u{0440}": "p", "\u{0441}": "c", "\u{0445}": "x", "\u{0443}": "y",
        "\u{043C}": "m", "\u{0442}": "t", "\u{043D}": "h", "\u{043A}": "k", "\u{0432}": "b",
    ]

    private static func normalize(_ value: String) -> String {
        let folded = String(value.lowercased().map { homoglyphs[$0] ?? $0 }.map { $0 == "|" || $0 == "i" ? "l" : $0 })
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
            .replacingOccurrences(of: "rn", with: "m")
    }

    func has(_ expected: String) -> Bool {
        let needle = Self.normalize(expected)
        return !needle.isEmpty && Self.normalize(text).contains(needle)
    }

    func frame(of expected: String) -> CGRect? {
        frames.first { Self.normalize($0.0).contains(Self.normalize(expected)) }?.1
    }
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
        assertFits("consent", ConsentNotice(hasClaim: false))
        assertFits("consent with claim", ConsentNotice(hasClaim: true))
        assertFits("feedback", FeedbackNotice(message: "That recording could not be started. Try again in a moment."))

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

    func test_footer_isPanelWidthWithOrWithoutTheUpdateChip() {
        for update in [false, true] { XCTAssertEqual(Host.size(FooterBar(updateAvailable: update)).width, 320) }
    }

    func test_consentAboveIdle_staysPanelWidthAndInBudget() {
        let stack = VStack(spacing: 0) { ConsentNotice(hasClaim: true); IdleScreen(model: idleModel) }.environment(\.consentPending, true)
        let size = Host.size(stack)
        XCTAssertEqual(size.width, 320)
        XCTAssertLessThanOrEqual(size.height, 520)
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

final class SeenMatcherTests: XCTestCase {
    private func seen(_ text: String) -> Seen { Seen(text: text, frames: []) }

    func test_rejectsTextThatSaysTheOpposite() {
        XCTAssertFalse(seen("Your recording is NOT saved on this Mac").has("Your recording is saved on this Mac"))
        XCTAssertFalse(seen("Your recording is no longer saved on this Mac").has("Your recording is saved on this Mac"))
    }

    func test_rejectsAnyWrongDigit() {
        XCTAssertFalse(seen("Transcribing on this Mac, 2 of 5").has("Transcribing on this Mac, 2 of 3"))
        XCTAssertFalse(seen("Downloading model 12%").has("Downloading model 42%"))
        XCTAssertFalse(seen("Downloading model 4%").has("Downloading model 42%"))
    }

    func test_acceptsTheSameTextAndKnownOcrConfusions() {
        XCTAssertTrue(seen("Your recording is saved on this Mac. Retry Dismiss").has("Your recording is saved on this Mac"))
        XCTAssertTrue(seen("Your recording is saved on this \u{041C}\u{0430}\u{0441}").has("Your recording is saved on this Mac"))
        XCTAssertTrue(seen("Weekly Eng Sync Ill").has("Weekly Eng Sync Ill"))
        XCTAssertTrue(seen("QuarterIy platforrn review").has("Quarterly platform review"))
        XCTAssertTrue(seen("Downloading model 42%").has("Downloading model 42%"))
    }
}

@MainActor
final class MenuStatesSeenTests: XCTestCase {
    private func model(series: [Series] = sampleSeries, selected: UUID? = sampleSeries[0].id, detectedVia: String? = nil) -> IdleModel {
        IdleModel(series: series, selected: selected, detectedVia: detectedVia, softHint: false, micBanner: false,
                  recovering: false, instance: URL(string: "https://example.com")!)
    }

    private var idleModel: IdleModel { model() }

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

    func test_done_saysItWasSentInPlainWordsAndOffersTheRecap() {
        let seen = Host.text(DoneContent())
        XCTAssertTrue(seen.has("Sent. Your recap is on its way"), seen.text)
        XCTAssertTrue(seen.has("Open recap"), seen.text)
        XCTAssertFalse(seen.has("Recap is ready"), seen.text)
    }

    func test_twoHourRecording_withALongName_stillShowsMostOfTheName() {
        let seen = Host.text(RecordingContent(model: RecordingModel(seriesName: longName, elapsed: 7457, level: 0, progress: "x")))
        XCTAssertTrue(seen.has("Quarterly platform reliability and security review"), seen.text)
        XCTAssertTrue(seen.has("2:04:17"), seen.text)
    }

    func test_notes_alignsWithTheRestOfTheColumn() throws {
        let seen = Host.text(RecordingContent(model: RecordingModel(seriesName: "Weekly Eng Sync", elapsed: 5, level: 0, progress: "x")))
        let notes = try XCTUnwrap(seen.frame(of: "Notes"))
        XCTAssertLessThan(notes.minX, 0.2)
    }

    func test_updateChip_sitsInTheMiddleOfThePanel() throws {
        let chip = try XCTUnwrap(Host.text(FooterBar(updateAvailable: true)).frame(of: "Update available"))
        XCTAssertEqual(chip.midX, 0.5, accuracy: 0.02)
    }

    func test_emailSignIn_opensFromAQuietButtonAndShowsTheFields() {
        let closed = Host.text(SignInScreen(stage: .ready, showsMenuBarHint: false, signInError: nil, email: .constant(""), password: .constant(""), showEmailForm: .constant(false), busy: false))
        let open = Host.text(SignInScreen(stage: .ready, showsMenuBarHint: false, signInError: nil, email: .constant(""), password: .constant(""), showEmailForm: .constant(true), busy: false))
        XCTAssertFalse(closed.has("Sign in with Google"), closed.text)
        XCTAssertTrue(open.has("Sign in with Google"), open.text)
        XCTAssertTrue(open.has("Use email instead"), open.text)
    }

    func test_secondaryButton_keepsItsLabelAwayFromItsBorder() {
        let label = Text("Open System Settings").font(Typo.body)
        let bare = Host.size(label).width
        let button = Host.size(Button(action: {}) { label }.buttonStyle(SecondaryButtonStyle()).fixedSize()).width
        XCTAssertGreaterThanOrEqual(button - bare, 24)
    }

    func test_meetingPromptCapsule_isReadableInLightAndDark() {
        let content = MeetingPromptContent(title: "Meeting detected", symbol: "waveform", primaryTitle: "Start taking notes", secondaryTitle: nil)
        for dark in [false, true] {
            let seen = Host.text(MeetingPromptView(content: content, onStart: {}, onDismiss: {}).padding(24), dark: dark)
            XCTAssertTrue(seen.has("Meeting detected"), "dark: \(dark) \(seen.text)")
            XCTAssertTrue(seen.has("Start taking notes"), "dark: \(dark) \(seen.text)")
        }
    }

    func test_doneWithReduceMotion_showsTheFinishedCheckAtOnce_andWithoutItDrawsFirst() {
        let still = Host.vermilionPixels(DoneContent().environment(\.reduceMotionOverride, true), spin: 0.05)
        let animated = Host.vermilionPixels(DoneContent().environment(\.reduceMotionOverride, false), spin: 0.05)
        XCTAssertGreaterThan(still, 50)
        XCTAssertEqual(animated, 0)
    }

    func test_consentOverIdle_showsOneVermilionFill_notTwo() {
        for hasClaim in [false, true] {
            let view = VStack(spacing: 0) { ConsentNotice(hasClaim: hasClaim); IdleScreen(model: idleModel) }.environment(\.consentPending, true)
            XCTAssertEqual(Host.fillBands(view, atPoint: 30), 1, "claim: \(hasClaim)")
        }
        XCTAssertEqual(Host.fillBands(IdleScreen(model: idleModel), atPoint: 30), 1)
    }

    func test_consentOverAnEmptyAccount_showsOneVermilionFill() {
        let view = VStack(spacing: 0) { ConsentNotice(hasClaim: true); IdleScreen(model: model(series: [], selected: nil)) }.environment(\.consentPending, true)
        XCTAssertEqual(Host.fillBands(view, atPoint: 30), 1)
        XCTAssertEqual(Host.fillBands(IdleScreen(model: model(series: [], selected: nil)), atPoint: 30), 1)
    }

    func test_consentOverError_showsOneVermilionFill() {
        let view = VStack(spacing: 0) { ConsentNotice(hasClaim: true); ErrorScreen(message: "Upload failed.", isMicError: false) }.environment(\.consentPending, true)
        XCTAssertEqual(Host.fillBands(view, atPoint: 30), 1)
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
        XCTAssertTrue(seen.has("a meeting. Get the issues log."), seen.text)
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
