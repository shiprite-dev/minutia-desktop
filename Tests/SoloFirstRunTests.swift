import XCTest
@testable import Minutia

/// A solo user's first run: the record prompt lands on the meeting that is happening, the first launch
/// opens sign-in by itself, and an empty account points at the two ways to get a series.
final class SoloFirstRunTests: XCTestCase {
    private let weekly = UUID()
    private let standup = UUID()
    private let instance = URL(string: "https://minutia.example.com")!

    private func happeningNow(_ title: String, seriesId: UUID?) -> AgendaItem {
        AgendaItem(seriesId: seriesId, meetingId: nil, title: title,
                   startAt: Date(), endAt: Date().addingTimeInterval(1800), meetingUrl: "https://meet.example.com/x")
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "SoloFirstRunTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    private final class Browser {
        var opened: [URL] = []
    }

    private func launch(_ defaults: UserDefaults, signedIn: Bool = false, browser: Browser) {
        FirstRun.openSignInIfNeeded(
            firstLaunch: FirstRun.isFirstLaunch(defaults), signedIn: signedIn,
            signInURL: { MinutiaClient.companionAuthorizeURL(instance: self.instance, device: "Mac") },
            open: { browser.opened.append($0) })
    }

    // MARK: - Recording into the meeting that is happening

    func test_inTheStandupOnZoom_thePromptNamesIt_andTheRecordingGoesToTheStandupSeries() {
        let meeting = AppController.detectedMeeting(
            app: .zoom, live: happeningNow("Daily standup", seriesId: standup), series: [weekly, standup], current: weekly)
        XCTAssertEqual(meeting.prompt.title, "Looks like you're in Daily standup")
        XCTAssertEqual(meeting.prompt.primaryTitle, "Start taking notes")
        XCTAssertEqual(meeting.seriesId, standup)
    }

    func test_inAnUnscheduledZoomCall_thePromptStaysGeneric_andTheLastUsedSeriesIsKept() {
        let meeting = AppController.detectedMeeting(app: .zoom, live: nil, series: [weekly, standup], current: standup)
        XCTAssertEqual(meeting.prompt.title, "Looks like you're in a Zoom meeting")
        XCTAssertEqual(meeting.seriesId, standup)
    }

    func test_aCalendarMeetingWithoutASeriesOfItsOwn_isNamed_butRecordsIntoTheLastUsedSeries() {
        for live in [happeningNow("Coffee chat", seriesId: nil), happeningNow("Coffee chat", seriesId: UUID())] {
            let meeting = AppController.detectedMeeting(app: nil, live: live, series: [weekly, standup], current: standup)
            XCTAssertEqual(meeting.prompt.title, "Looks like you're in Coffee chat")
            XCTAssertEqual(meeting.seriesId, standup)
        }
    }

    func test_withNoUsableLastSeries_theRecordingGoesToTheFirstSeries() {
        let meeting = AppController.detectedMeeting(app: .teams, live: nil, series: [weekly, standup], current: UUID())
        XCTAssertEqual(meeting.seriesId, weekly)
        XCTAssertNil(AppController.detectedMeeting(app: .teams, live: nil, series: [], current: weekly).seriesId)
    }

    // MARK: - First launch opens sign-in

    func test_aFreshInstall_opensBrowserSignInOnItsFirstLaunchOnly() {
        let defaults = freshDefaults()
        let browser = Browser()
        launch(defaults, browser: browser)
        launch(defaults, browser: browser)
        XCTAssertEqual(browser.opened.count, 1)
        XCTAssertEqual(browser.opened.first?.path, "/companion/authorize")
        XCTAssertEqual(browser.opened.first?.host, "minutia.example.com")
    }

    func test_anExistingInstall_neverOpensTheBrowserByItself() {
        let defaults = freshDefaults()
        defaults.set(UUID().uuidString.lowercased(), forKey: DeviceIdentity.defaultsKey)
        let browser = Browser()
        launch(defaults, browser: browser)
        XCTAssertTrue(browser.opened.isEmpty)
    }

    func test_aFreshInstallThatIsAlreadySignedIn_doesNotOpenTheBrowser() {
        let browser = Browser()
        launch(freshDefaults(), signedIn: true, browser: browser)
        XCTAssertTrue(browser.opened.isEmpty)
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
