import AVFoundation
import XCTest
@testable import Minutia

/// A solo user's first run, driven through the controller the way the app drives it: the record
/// prompt lands on the meeting that is happening, the first launch opens sign-in by itself once, and
/// an empty account points at the two ways to get a series.
@MainActor
final class SoloFirstRunTests: XCTestCase {
    private let weekly = Series(id: UUID(), name: "Weekly sync")
    private let standup = Series(id: UUID(), name: "Daily standup")
    private let instance = URL(string: "https://minutia.example.com")!
    private var suite: String!
    private var defaults: UserDefaults!
    private var opened: [URL] = []
    private var controllers: [AppController] = []

    override func setUp() async throws {
        suite = "SoloFirstRunTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        opened = []
    }

    override func tearDown() async throws {
        for controller in controllers {
            controller.handleDetection(.none)
            controller.authManager.cancelBrowserSignIn()
        }
        controllers = []
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeController(mic: AVAuthorizationStatus = .authorized) -> AppController {
        let controller = AppController(
            defaults: defaults, openURL: { [weak self] in self?.opened.append($0) }, micCheck: { (mic, true) })
        controllers.append(controller)
        return controller
    }

    private func signedInController(series: [Series], mic: AVAuthorizationStatus = .authorized) -> AppController {
        let controller = makeController(mic: mic)
        controller.apply(.signedIn)
        controller.seriesLoaded(series)
        return controller
    }

    private func event(_ title: String, _ series: Series?, start: Date, minutes: Double = 30) -> AgendaItem {
        AgendaItem(seriesId: series?.id, meetingId: nil, title: title, startAt: start,
                   endAt: start.addingTimeInterval(minutes * 60), meetingUrl: "https://meet.example.com/x")
    }

    private func happeningNow(_ title: String, _ series: Series?) -> AgendaItem {
        event(title, series, start: Date().addingTimeInterval(-60))
    }

    private var lastUsed: String? { defaults.string(forKey: AppController.lastSeriesKey) }

    private func connect(_ controller: AppController, to url: URL? = nil) async {
        let url = url ?? instance
        await controller.authManager.adopt(testSupabase(url), instance: url)
    }

    // MARK: - Recording into the meeting that is happening

    func test_joiningTheStandupOnZoom_thePromptNamesIt_andRecordGoesToTheStandup() {
        let controller = signedInController(series: [weekly, standup])
        controller.detector.liveAgendaItem = happeningNow("Daily standup", standup)
        controller.handleDetection(.high(.zoom))

        XCTAssertEqual(controller.meetingPromptPanel.content?.title, "Looks like you're in Daily standup")
        XCTAssertEqual(controller.selectedSeriesId, standup.id)
        XCTAssertNil(lastUsed, "a detected meeting is not the user's choice, so last-used is untouched")
    }

    func test_backToBackMeetings_joiningAMinuteEarly_namesAndRecordsTheNextOne() {
        let tenOClock = Date().addingTimeInterval(-29 * 60)
        let agenda = [event("Daily standup", standup, start: tenOClock),
                      event("Weekly sync", weekly, start: tenOClock.addingTimeInterval(30 * 60))]
        let controller = signedInController(series: [weekly, standup])
        controller.detector.liveAgendaItem = DetectionRules.liveAgendaItem(agenda, now: Date())
        controller.handleDetection(.high(.zoom))

        XCTAssertEqual(controller.meetingPromptPanel.content?.title, "Looks like you're in Weekly sync")
        XCTAssertEqual(controller.selectedSeriesId, weekly.id)
    }

    func test_aSeriesPickedMidMeeting_survivesTheDetectionReFiring() {
        let controller = signedInController(series: [weekly, standup])
        controller.detector.liveAgendaItem = happeningNow("Daily standup", standup)
        controller.handleDetection(.high(.browser))
        controller.pickSeries(weekly.id)
        controller.handleDetection(.high(.zoom))

        XCTAssertEqual(controller.selectedSeriesId, weekly.id)
        XCTAssertEqual(lastUsed, weekly.id.uuidString)
    }

    func test_signingInWhileAlreadyOnACall_keepsTheLastUsedSeries() {
        defaults.set(weekly.id.uuidString, forKey: AppController.lastSeriesKey)
        let controller = makeController()
        controller.apply(.signedIn)
        controller.detector.liveAgendaItem = happeningNow("Daily standup", standup)
        controller.handleDetection(.high(.zoom))
        XCTAssertEqual(lastUsed, weekly.id.uuidString, "detection before the series load must not wipe last-used")

        controller.seriesLoaded([weekly, standup])
        XCTAssertEqual(controller.selectedSeriesId, standup.id, "once loaded, the live meeting's series is picked")
        XCTAssertEqual(lastUsed, weekly.id.uuidString)
    }

    func test_joiningBeforeTheCalendarCatchesUp_updatesThePromptAndSeriesOnceTheEventAppears() {
        defaults.set(weekly.id.uuidString, forKey: AppController.lastSeriesKey)
        let controller = signedInController(series: [weekly, standup])
        controller.handleDetection(.high(.zoom))
        XCTAssertEqual(controller.meetingPromptPanel.content?.title, "Looks like you're in a Zoom meeting")
        XCTAssertEqual(controller.selectedSeriesId, weekly.id)

        controller.detector.liveAgendaItem = happeningNow("Daily standup", standup)
        XCTAssertEqual(controller.meetingPromptPanel.content?.title, "Looks like you're in Daily standup")
        XCTAssertEqual(controller.selectedSeriesId, standup.id)
    }

    func test_afterTheStandupEnds_theNextUnscheduledCallRecordsIntoTheLastUsedSeries() {
        defaults.set(weekly.id.uuidString, forKey: AppController.lastSeriesKey)
        let controller = signedInController(series: [weekly, standup])
        controller.detector.liveAgendaItem = happeningNow("Daily standup", standup)
        controller.handleDetection(.high(.zoom))
        XCTAssertEqual(controller.selectedSeriesId, standup.id)

        controller.handleDetection(.none)
        controller.detector.liveAgendaItem = nil
        controller.handleDetection(.high(.zoom))

        XCTAssertEqual(controller.meetingPromptPanel.content?.title, "Looks like you're in a Zoom meeting")
        XCTAssertEqual(controller.selectedSeriesId, weekly.id)
    }

    private func recordTheDetectedStandup(_ controller: AppController) {
        controller.detector.liveAgendaItem = happeningNow("Daily standup", standup)
        controller.handleDetection(.high(.zoom))
        XCTAssertEqual(controller.selectedSeriesId, standup.id)
        controller.apply(.recordStarted)
        controller.apply(.recordStopped)
        controller.handleDetection(.none)
        controller.detector.liveAgendaItem = nil
    }

    func test_afterRecordingTheStandup_theNextUnscheduledCallRecordsIntoTheLastUsedSeries() {
        defaults.set(weekly.id.uuidString, forKey: AppController.lastSeriesKey)
        let controller = signedInController(series: [weekly, standup])
        recordTheDetectedStandup(controller)
        controller.apply(.finalized)
        controller.handleDetection(.high(.zoom))

        XCTAssertEqual(controller.meetingPromptPanel.content?.title, "Looks like you're in a Zoom meeting")
        XCTAssertEqual(controller.selectedSeriesId, weekly.id)
    }

    func test_whenTheStandupRecordingFailsToFinish_RecordStillReturnsToTheLastUsedSeries() {
        defaults.set(weekly.id.uuidString, forKey: AppController.lastSeriesKey)
        let controller = signedInController(series: [weekly, standup])
        recordTheDetectedStandup(controller)
        controller.apply(.failed("Could not finish the notes."))

        XCTAssertEqual(controller.selectedSeriesId, weekly.id)
    }

    func test_theCalendarCatchingUp_doesNotOverrideAManualPick() {
        let controller = signedInController(series: [weekly, standup])
        controller.handleDetection(.high(.zoom))
        controller.pickSeries(weekly.id)
        controller.detector.liveAgendaItem = happeningNow("Daily standup", standup)
        XCTAssertEqual(controller.selectedSeriesId, weekly.id)
    }

    func test_whenTheAgendaCannotBeFetched_thePromptIsStillOffered_withTheLastUsedSeries() {
        defaults.set(standup.id.uuidString, forKey: AppController.lastSeriesKey)
        let controller = signedInController(series: [weekly, standup])
        controller.detector.liveAgendaItem = nil
        controller.handleDetection(.high(.zoom))

        XCTAssertEqual(controller.meetingPromptPanel.content?.title, "Looks like you're in a Zoom meeting")
        XCTAssertEqual(controller.meetingPromptPanel.content?.primaryTitle, "Start taking notes")
        XCTAssertEqual(controller.selectedSeriesId, standup.id)
    }

    func test_detectionWhileRecording_changesNothing() {
        let controller = signedInController(series: [weekly, standup])
        controller.apply(.recordStarted)
        controller.detector.liveAgendaItem = happeningNow("Daily standup", standup)
        controller.handleDetection(.high(.zoom))

        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(controller.selectedSeriesId, weekly.id)
        XCTAssertNil(controller.meetingPromptPanel.content)
    }

    func test_acceptingThePromptWithTheMicDenied_saysWhyAndOffersSystemSettings() async {
        let controller = makeController(mic: .denied)
        await connect(controller)
        controller.apply(.signedIn)
        controller.seriesLoaded([weekly])
        controller.handleDetection(.high(.zoom))
        controller.startRecording()

        guard case .error(let message) = controller.phase else { return XCTFail("expected the error screen") }
        XCTAssertTrue(message.contains("System Settings"))
        XCTAssertTrue(AppController.isMicPermissionError(message: message), "the error screen shows Open System Settings")
    }

    // MARK: - First launch opens sign-in

    func test_aFreshInstall_opensBrowserSignInOnceTheConnectionIsReady_exactlyOnce() async {
        XCTAssertTrue(FirstRun.isFirstLaunch(defaults))
        let controller = makeController()
        await connect(controller)
        await connect(controller, to: URL(string: "https://other.example.com")!)

        XCTAssertEqual(opened.count, 1)
        let state = opened.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first(where: { $0.name == "state" })?.value
        XCTAssertEqual(opened.first?.path, "/companion/authorize")
        XCTAssertEqual(state, controller.authManager.pendingAuth?.nonce, "the opened page is the sign-in this app is waiting on")
    }

    func test_onFirstLaunch_theSignInScreenWaitsOnTheBrowserTabItOpened_insteadOfOfferingAnotherSignIn() async {
        XCTAssertTrue(FirstRun.isFirstLaunch(defaults))
        let controller = makeController()
        XCTAssertFalse(controller.authManager.awaitingBrowserSignIn)
        await connect(controller)

        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(controller.authManager.awaitingBrowserSignIn, "the menu shows Check your browser and Start over")
        controller.authManager.cancelBrowserSignIn()
        XCTAssertFalse(controller.authManager.awaitingBrowserSignIn, "Start over brings back Sign in with browser")
    }

    func test_signInTestsNeverTouchTheInstalledAppsPendingSignIn() async {
        let before = UserDefaults.standard.data(forKey: "app.minutia.pendingAuth")
        XCTAssertTrue(FirstRun.isFirstLaunch(defaults))
        await connect(makeController())
        XCTAssertEqual(UserDefaults.standard.data(forKey: "app.minutia.pendingAuth"), before)
    }

    func test_anOfflineFirstLaunch_opensSignInWhenTheConnectionComesBack_onlyOnce() async {
        XCTAssertTrue(FirstRun.isFirstLaunch(defaults))
        let controller = makeController()
        XCTAssertTrue(opened.isEmpty, "no connection, nothing to open yet")

        await connect(controller)
        XCTAssertEqual(opened.count, 1)

        let relaunched = makeController()
        await connect(relaunched)
        XCTAssertEqual(opened.count, 1)
    }

    func test_anExistingInstall_neverOpensTheBrowserByItself() async {
        defaults.set(UUID().uuidString.lowercased(), forKey: DeviceIdentity.defaultsKey)
        XCTAssertFalse(FirstRun.isFirstLaunch(defaults))
        await connect(makeController())
        XCTAssertTrue(opened.isEmpty)
    }

    func test_whenTheBrowserNeverComesBack_theAppStaysOnSignIn_andDoesNotReopenTheBrowser() async {
        XCTAssertTrue(FirstRun.isFirstLaunch(defaults))
        let controller = makeController()
        await connect(controller)
        controller.authManager.cancelBrowserSignIn()
        await connect(controller, to: URL(string: "https://other.example.com")!)

        XCTAssertEqual(controller.phase, .signedOut, "the sign-in screen, with its Sign in button, stays up")
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(controller.authManager.beginBrowserSignIn(device: "Mac").path, "/companion/authorize")
    }

    // MARK: - Empty account

    func test_anEmptyAccount_offersConnectingGoogleCalendar_thenCreatingASeries_onItsOwnInstance() {
        let links = MenuLink.emptySeries(instance: instance)
        XCTAssertEqual(links.primary, MenuLink(
            title: "Connect Google Calendar", url: URL(string: "https://minutia.example.com/api/auth/google")!))
        XCTAssertEqual(links.secondary, MenuLink(
            title: "Create a series", url: URL(string: "https://minutia.example.com/series")!))
    }
}
