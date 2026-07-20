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

    // MARK: - detectBrowserMeeting

    func test_detectBrowserMeeting_knownBrowserWithInput_isHit() {
        for id in DetectionRules.browserBundleIds {
            XCTAssertTrue(
                DetectionRules.detectBrowserMeeting(inputBundleIds: [id]),
                "\(id) should be recognized as a browser meeting")
        }
    }

    func test_detectBrowserMeeting_helperProcessForEveryBrowser_isHit() {
        // CoreAudio commonly attributes browser mic input to a helper/content process, not the
        // top-level bundle id, so every browser's `.helper` child must also register.
        for id in DetectionRules.browserBundleIds {
            XCTAssertTrue(
                DetectionRules.detectBrowserMeeting(inputBundleIds: ["\(id).helper"]),
                "\(id).helper should be recognized as a browser meeting")
        }
    }

    func test_detectBrowserMeeting_webKitContentAndGPUHelpers_isHit() {
        XCTAssertTrue(
            DetectionRules.detectBrowserMeeting(inputBundleIds: ["com.apple.WebKit.WebContent"]))
        XCTAssertTrue(
            DetectionRules.detectBrowserMeeting(inputBundleIds: ["com.apple.WebKit.GPU"]))
    }

    func test_detectBrowserMeeting_nonBrowserInput_isNoHit() {
        XCTAssertFalse(
            DetectionRules.detectBrowserMeeting(inputBundleIds: ["com.apple.Preview", "com.tinyspeck.slackmacgap"]))
    }

    func test_detectBrowserMeeting_dotBoundaryNegatives_isNoHit() {
        // `com.google.ChromeCast` is a sibling, not a dot-scoped child of `com.google.Chrome`;
        // `com.apple.WebKitFakeNo` starts with `com.apple.WebKit` but not `com.apple.WebKit.`.
        XCTAssertFalse(DetectionRules.detectBrowserMeeting(inputBundleIds: ["com.google.ChromeCast"]))
        XCTAssertFalse(DetectionRules.detectBrowserMeeting(inputBundleIds: ["com.apple.WebKitFakeNo"]))
        XCTAssertFalse(DetectionRules.detectBrowserMeeting(inputBundleIds: ["com.spotify.client"]))
    }

    func test_detectBrowserMeeting_emptySet_isNoHit() {
        XCTAssertFalse(DetectionRules.detectBrowserMeeting(inputBundleIds: []))
    }

    func test_detectBrowserMeeting_mixedSet_isHit() {
        XCTAssertTrue(
            DetectionRules.detectBrowserMeeting(inputBundleIds: ["com.apple.Preview", "com.google.Chrome"]))
    }

    // MARK: - browserSignalConfirmed (two consecutive polls)

    func test_browserSignalConfirmed_zeroHits_isFalse() {
        XCTAssertFalse(DetectionRules.browserSignalConfirmed(previousPollHit: false, currentPollHit: false))
    }

    func test_browserSignalConfirmed_singleRisingHit_isFalse() {
        // One poll's blip (e.g. a 2-second dictation) must not count as a meeting.
        XCTAssertFalse(DetectionRules.browserSignalConfirmed(previousPollHit: false, currentPollHit: true))
    }

    func test_browserSignalConfirmed_twoConsecutiveHits_isTrue() {
        XCTAssertTrue(DetectionRules.browserSignalConfirmed(previousPollHit: true, currentPollHit: true))
    }

    func test_browserSignalConfirmed_hitThenGap_isFalse() {
        XCTAssertFalse(DetectionRules.browserSignalConfirmed(previousPollHit: true, currentPollHit: false))
    }

    /// A hit, a gap, then a hit is two isolated single hits: the rising edge restarts, so it must
    /// still take a further consecutive poll to confirm. Threads the raw hit through as the detector
    /// does.
    func test_browserSignalConfirmed_hitGapHit_neverConfirms() {
        var previous = false
        let polls = [true, false, true]
        var confirmations: [Bool] = []
        for hit in polls {
            confirmations.append(
                DetectionRules.browserSignalConfirmed(previousPollHit: previous, currentPollHit: hit))
            previous = hit
        }
        XCTAssertEqual(confirmations, [false, false, false])
    }

    // MARK: - assess

    func test_assess_micActiveWithApp_isHighWithApp() {
        XCTAssertEqual(
            DetectionRules.assess(micActive: true, app: .zoom, calendarLive: false, browserActive: false),
            .high(.zoom))
    }

    func test_assess_micActiveWithCalendarLive_isHighWithNilApp() {
        XCTAssertEqual(
            DetectionRules.assess(micActive: true, app: nil, calendarLive: true, browserActive: false),
            .high(nil))
    }

    func test_assess_micActiveAlone_isSoft() {
        XCTAssertEqual(
            DetectionRules.assess(micActive: true, app: nil, calendarLive: false, browserActive: false),
            .soft)
    }

    func test_assess_micInactive_isNone() {
        XCTAssertEqual(
            DetectionRules.assess(micActive: false, app: .teams, calendarLive: true, browserActive: false),
            .none)
    }

    // MARK: - assess: browser signal and precedence

    func test_assess_micActiveWithBrowserOnly_isHighBrowser() {
        XCTAssertEqual(
            DetectionRules.assess(micActive: true, app: nil, calendarLive: false, browserActive: true),
            .high(.browser))
    }

    func test_assess_micInactiveWithBrowserHit_isNone() {
        XCTAssertEqual(
            DetectionRules.assess(micActive: false, app: nil, calendarLive: false, browserActive: true),
            .none)
    }

    func test_assess_nativeAppWinsOverBrowser() {
        XCTAssertEqual(
            DetectionRules.assess(micActive: true, app: .zoom, calendarLive: false, browserActive: true),
            .high(.zoom))
        XCTAssertEqual(
            DetectionRules.assess(micActive: true, app: .teams, calendarLive: false, browserActive: true),
            .high(.teams))
    }

    func test_assess_calendarWinsOverBrowser() {
        XCTAssertEqual(
            DetectionRules.assess(micActive: true, app: nil, calendarLive: true, browserActive: true),
            .high(nil))
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
