import XCTest
@testable import Minutia

/// A solo user's first run: the record prompt lands on the meeting that is happening, the first launch
/// opens sign-in by itself, and an empty account points at the two ways to get a series.
final class SoloFirstRunTests: XCTestCase {
    private let weekly = UUID()
    private let standup = UUID()
    private let instance = URL(string: "https://minutia.example.com")!

    private func agendaItem(seriesId: UUID?, title: String = "Weekly sync") -> AgendaItem {
        AgendaItem(seriesId: seriesId, meetingId: nil, title: title,
                   startAt: Date(), endAt: Date().addingTimeInterval(1800), meetingUrl: "https://meet.example.com/x")
    }

    func test_aLiveAgendaItem_selectsItsSeries_overTheLastUsed() {
        let chosen = AppController.defaultSeries(
            available: [weekly, standup], live: agendaItem(seriesId: standup), last: weekly)
        XCTAssertEqual(chosen, standup)
    }

    func test_noLiveItem_keepsTheLastUsedSeries() {
        XCTAssertEqual(AppController.defaultSeries(available: [weekly, standup], live: nil, last: standup), standup)
    }

    func test_aLiveItemWithoutARecordableSeries_fallsBackToLastUsed() {
        XCTAssertEqual(
            AppController.defaultSeries(available: [weekly, standup], live: agendaItem(seriesId: nil), last: standup),
            standup)
        XCTAssertEqual(
            AppController.defaultSeries(available: [weekly, standup], live: agendaItem(seriesId: UUID()), last: standup),
            standup)
    }

    func test_noLiveItemAndNoValidLastUsed_fallsBackToTheFirst() {
        XCTAssertEqual(AppController.defaultSeries(available: [weekly, standup], live: nil, last: UUID()), weekly)
        XCTAssertEqual(AppController.defaultSeries(available: [weekly, standup], live: nil, last: nil), weekly)
        XCTAssertNil(AppController.defaultSeries(available: [], live: nil, last: weekly))
    }

    func test_theRecordPrompt_namesTheLiveMeeting() {
        let content = MeetingPrompt.content(for: .zoom, meeting: "Weekly sync")
        XCTAssertEqual(content.title, "Looks like you're in Weekly sync")
        XCTAssertEqual(content.primaryTitle, "Start taking notes")
        XCTAssertEqual(MeetingPrompt.content(for: .zoom, meeting: nil), MeetingPrompt.content(for: .zoom))
    }

    func test_theFirstLaunch_opensSignInExactlyOnce() {
        let suite = "SoloFirstRunTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let launches = [FirstRun.isFirstLaunch(defaults), FirstRun.isFirstLaunch(defaults)]
        let opened = launches.filter { FirstRun.opensSignIn(firstLaunch: $0, signedIn: false) }
        XCTAssertEqual(opened.count, 1)
        XCTAssertFalse(FirstRun.opensSignIn(firstLaunch: true, signedIn: true), "a restored session needs no sign-in")
    }

    func test_anExistingInstall_neverOpensSignInByItself() {
        let suite = "SoloFirstRunTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(UUID().uuidString.lowercased(), forKey: DeviceIdentity.defaultsKey)
        XCTAssertFalse(FirstRun.opensSignIn(firstLaunch: FirstRun.isFirstLaunch(defaults), signedIn: false))
    }

    func test_theEmptyState_linksBuildFromTheInstance() {
        XCTAssertEqual(MinutiaClient.connectCalendarURL(instance: instance).absoluteString,
                       "https://minutia.example.com/api/auth/google")
        XCTAssertEqual(MinutiaClient.createSeriesURL(instance: instance).absoluteString,
                       "https://minutia.example.com/series")
    }
}
