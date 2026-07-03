import XCTest
@testable import Minutia

final class DetectionRulesTests: XCTestCase {
    // MARK: - detectApp

    func test_detectApp_cptHostAlone_isZoom() {
        XCTAssertEqual(DetectionRules.detectApp(processNames: ["CptHost"], bundleIds: []), .zoom)
    }

    func test_detectApp_teams2Bundle_isTeams() {
        XCTAssertEqual(
            DetectionRules.detectApp(processNames: [], bundleIds: ["com.microsoft.teams2"]), .teams)
    }

    func test_detectApp_bothPresent_zoomWins() {
        XCTAssertEqual(
            DetectionRules.detectApp(
                processNames: ["CptHost"], bundleIds: ["com.microsoft.teams2"]), .zoom)
    }

    func test_detectApp_neither_isNil() {
        XCTAssertNil(DetectionRules.detectApp(processNames: ["Finder"], bundleIds: ["com.apple.finder"]))
    }

    func test_detectApp_classicTeamsBundle_isNil() {
        XCTAssertNil(DetectionRules.detectApp(processNames: [], bundleIds: ["com.microsoft.teams"]))
    }

    // MARK: - assess

    func test_assess_micActiveWithApp_isHighWithApp() {
        XCTAssertEqual(
            DetectionRules.assess(micActive: true, app: .zoom, calendarLive: false), .high(.zoom))
    }

    func test_assess_micActiveWithCalendarLive_isHighWithNilApp() {
        XCTAssertEqual(
            DetectionRules.assess(micActive: true, app: nil, calendarLive: true), .high(nil))
    }

    func test_assess_micActiveAlone_isSoft() {
        XCTAssertEqual(DetectionRules.assess(micActive: true, app: nil, calendarLive: false), .soft)
    }

    func test_assess_micInactive_isNone() {
        XCTAssertEqual(DetectionRules.assess(micActive: false, app: .teams, calendarLive: true), .none)
    }

    // MARK: - liveAgendaItem

    func test_liveAgendaItem_inWindowWithUrl_isMatched() {
        let now = Date()
        let item = agendaItem(
            title: "Standup", startAt: now.addingTimeInterval(-60), endAt: now.addingTimeInterval(1800),
            meetingUrl: "https://zoom.us/j/1")
        XCTAssertEqual(DetectionRules.liveAgendaItem([item], now: now)?.title, "Standup")
    }

    func test_liveAgendaItem_inWindowWithoutUrl_isSkipped() {
        let now = Date()
        let item = agendaItem(
            title: "No link", startAt: now.addingTimeInterval(-60), endAt: now.addingTimeInterval(1800),
            meetingUrl: nil)
        XCTAssertNil(DetectionRules.liveAgendaItem([item], now: now))
    }

    func test_liveAgendaItem_twoMinuteEarlyGrace_isIncluded() {
        let now = Date()
        let item = agendaItem(
            title: "Early", startAt: now.addingTimeInterval(110), endAt: now.addingTimeInterval(1800),
            meetingUrl: "https://zoom.us/j/2")
        XCTAssertEqual(DetectionRules.liveAgendaItem([item], now: now)?.title, "Early")
    }

    func test_liveAgendaItem_ended_isExcluded() {
        let now = Date()
        let item = agendaItem(
            title: "Ended", startAt: now.addingTimeInterval(-3600), endAt: now.addingTimeInterval(-60),
            meetingUrl: "https://zoom.us/j/3")
        XCTAssertNil(DetectionRules.liveAgendaItem([item], now: now))
    }

    func test_liveAgendaItem_twoInWindow_earliestWins() {
        let now = Date()
        let later = agendaItem(
            title: "Later", startAt: now.addingTimeInterval(-30), endAt: now.addingTimeInterval(1800),
            meetingUrl: "https://zoom.us/j/4")
        let earlier = agendaItem(
            title: "Earlier", startAt: now.addingTimeInterval(-90), endAt: now.addingTimeInterval(1800),
            meetingUrl: "https://zoom.us/j/5")
        XCTAssertEqual(DetectionRules.liveAgendaItem([later, earlier], now: now)?.title, "Earlier")
    }

    private func agendaItem(title: String, startAt: Date, endAt: Date, meetingUrl: String?) -> AgendaItem {
        AgendaItem(
            seriesId: nil, meetingId: nil, title: title, startAt: startAt, endAt: endAt,
            meetingUrl: meetingUrl)
    }
}
