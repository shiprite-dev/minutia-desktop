import XCTest
@testable import Minutia

final class ReviewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let owner = UUID()
    private let mid = UUID()

    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    private func row(
        _ title: String, type: String = "new_item", confidence: Double = 0.9, id: UUID = UUID()
    ) -> ReviewRow {
        ReviewRow(
            id: id, type: type, category: "action", title: title, ownerName: "", ownerUserId: nil, dueDate: nil,
            confidence: confidence, relatedIssueNumber: type == "status_update" ? 12 : nil,
            relatedIssueTitle: nil, suggestedStatus: nil)
    }

    private func meeting(
        id: UUID? = nil, transcription: String? = "completed", suggestions: String? = "ready", reason: String? = nil,
        endedAgo: TimeInterval = 600, statusAgo: TimeInterval = 600, reviewer: Bool = true,
        rows: [ReviewRow] = [], webOnly: Int = 0, noTimes: Bool = false
    ) -> ReviewMeeting {
        ReviewMeeting(
            meetingId: id ?? mid, seriesId: UUID(), seriesName: "Weekly sync", endedAt: noTimes ? nil : ago(endedAgo),
            transcriptionStatus: transcription, suggestionsStatus: suggestions, suggestionsReason: reason,
            statusAt: noTimes ? nil : ago(statusAgo), reviewer: reviewer, members: [], rows: rows, webOnlyCount: webOnly)
    }

    private func screen(_ m: ReviewMeeting) -> ReviewScreen {
        ReviewModel.from(m, now: now, previous: nil).screen
    }

    func test_transcribing_showsNoElapsedTimeUntilPast20Seconds() {
        for status in ["pending", "processing"] {
            let early = screen(meeting(transcription: status, suggestions: "pending", endedAgo: 20))
            XCTAssertEqual(early, .transcribing(elapsed: nil))
            XCTAssertEqual(early.message, "Transcribing")
            XCTAssertEqual(
                screen(meeting(transcription: status, suggestions: "pending", endedAgo: 21)),
                .transcribing(elapsed: .seconds(21)))
        }
    }

    func test_transcribing_exactlyTwoMinutesIsNotSlowButTwoMinutesOneSecondIs() {
        XCTAssertEqual(
            screen(meeting(transcription: "pending", suggestions: "pending", endedAgo: 120)),
            .transcribing(elapsed: .seconds(120)))
        let slow = screen(meeting(transcription: "pending", suggestions: "pending", endedAgo: 121))
        XCTAssertEqual(slow, .slow)
        XCTAssertEqual(slow.message, "Taking longer than usual. We'll let you know when it's ready.")
    }

    func test_finding_slowAfterTwoMinutes_failedAfterTenMinutesStrictly() {
        let finding = screen(meeting(suggestions: "pending", statusAgo: 120))
        XCTAssertEqual(finding, .finding)
        XCTAssertEqual(finding.message, "Finding action items")
        XCTAssertEqual(screen(meeting(suggestions: "pending", statusAgo: 121)), .slow)
        XCTAssertEqual(screen(meeting(suggestions: "pending", statusAgo: 600)), .slow)
        let stuck = screen(meeting(suggestions: "pending", statusAgo: 601))
        XCTAssertEqual(stuck, .findingFailed)
        XCTAssertEqual(stuck.message, "We couldn't find action items this time.")
    }

    func test_transcriptionFailed_saysSo() {
        let s = screen(meeting(transcription: "failed", suggestions: "pending"))
        XCTAssertEqual(s, .transcriptionFailed)
        XCTAssertEqual(s.message, "We couldn't transcribe this meeting.")
    }

    func test_findingFailed_whenProviderFailed() {
        let s = screen(meeting(suggestions: "failed", reason: "provider_error"))
        XCTAssertEqual(s, .findingFailed)
        XCTAssertEqual(s.message, "We couldn't find action items this time.")
    }

    func test_nobodySpoke_onlyForNoContent() {
        let s = screen(meeting(suggestions: "skipped", reason: "no_content"))
        XCTAssertEqual(s, .nobodySpoke)
        XCTAssertEqual(s.message, "We didn't hear anyone speak in this recording.")
    }

    func test_notAvailable_whenAIIsOffForThisAccountOrServer() {
        for reason in ["feature_unavailable", "not_configured"] {
            XCTAssertEqual(screen(meeting(suggestions: "skipped", reason: reason)), .notAvailable)
        }
        XCTAssertEqual(screen(meeting(suggestions: "skipped", reason: nil)), .notAvailable)
    }

    func test_ready_threeConfidentItemsAreAllPreSelectedAndKeepSaysThree() {
        let rows = [row("A"), row("B", confidence: 0.8), row("C", confidence: 0.95)]
        let model = ReviewModel.from(meeting(rows: rows), now: now, previous: nil)
        XCTAssertEqual(model.screen, .ready)
        XCTAssertEqual(model.selection, Set(rows.map(\.id)))
        XCTAssertEqual(model.keepCount, 3)
        XCTAssertEqual(ReviewCopy.keep(model.keepCount), "Keep 3")
        XCTAssertNil(model.lessSureIndex)
    }

    func test_ready_lessSureItemsComeAfterTheConfidentOnesAndStartUnselected() {
        let unsure = row("Maybe", confidence: 0.79)
        let first = row("First", confidence: 0.85)
        let second = row("Second", confidence: 0.9)
        let model = ReviewModel.from(meeting(rows: [unsure, first, second]), now: now, previous: nil)
        XCTAssertEqual(model.newRows.map(\.title), ["First", "Second", "Maybe"])
        XCTAssertEqual(model.lessSureIndex, 2)
        XCTAssertEqual(model.selection, [first.id, second.id])
        XCTAssertEqual(ReviewCopy.keep(model.keepCount), "Keep 2")
    }

    func test_ready_statusUpdatesSitInTheirOwnGroupAndCountTowardKeep() {
        let update = row("Contract renewed", type: "status_update", confidence: 0.85)
        let model = ReviewModel.from(meeting(rows: [row("New"), update]), now: now, previous: nil)
        XCTAssertEqual(model.newRows.map(\.title), ["New"])
        XCTAssertEqual(model.updateRows.map(\.title), ["Contract renewed"])
        XCTAssertEqual(ReviewCopy.keep(model.keepCount), "Keep 2")
    }

    func test_ready_sevenNewItemsShowFiveAndTheRestPlusWebOnlyGoToTheWeb() {
        let rows = (1...7).map { row("Item \($0)") }
        let model = ReviewModel.from(meeting(rows: rows, webOnly: 3), now: now, previous: nil)
        XCTAssertEqual(model.newRows.map(\.title), (1...5).map { "Item \($0)" })
        XCTAssertEqual(model.moreOnWeb, 5)
        XCTAssertEqual(ReviewCopy.moreOnWeb(model.moreOnWeb), "5 more on the web")
        XCTAssertEqual(ReviewCopy.keep(model.keepCount), "Keep 5")
    }

    func test_ready_aConfidentItemIsNeverHiddenBehindLessSureOnes() {
        let rows = (1...5).map { row("Unsure \($0)", confidence: 0.5) } + [row("Sure", confidence: 0.99)]
        let model = ReviewModel.from(meeting(rows: rows), now: now, previous: nil)
        XCTAssertEqual(model.newRows.first?.title, "Sure")
        XCTAssertEqual(model.newRows.count, 5)
        XCTAssertEqual(model.moreOnWeb, 1)
    }

    func test_none_saysNoActionItemsAndMentionsWebOnlyOnes() {
        let plain = screen(meeting())
        XCTAssertEqual(plain, .none(moreOnWeb: 0))
        XCTAssertEqual(plain.message, "No action items this time.")
        let withWeb = screen(meeting(webOnly: 2))
        XCTAssertEqual(withWeb, .none(moreOnWeb: 2))
        XCTAssertEqual(withWeb.message, "No action items this time. 2 more on the web")
    }

    func test_notAReviewer_seesRowsWithNothingSelectedToKeep() {
        let model = ReviewModel.from(meeting(reviewer: false, rows: [row("A"), row("B")]), now: now, previous: nil)
        XCTAssertEqual(model.screen, .ready)
        XCTAssertTrue(model.readOnly)
        XCTAssertEqual(model.selection, [])
        XCTAssertEqual(ReviewCopy.keep(model.keepCount), "Keep 0")
    }

    func test_rerun_keepsOwnerEditAndDeselectionOnMatchedRows_andFlagsTheVanishedOne() {
        let ownerEdit = RowEdit(ownerUserId: owner, dueDate: .set("2026-12-01"))
        let kept = row("Send the budget.")
        let dropped = row("Old thing")
        let deselected = row("Call vendor")
        var before = ReviewModel.from(meeting(rows: [kept, dropped, deselected]), now: now, previous: nil)
        before.edits[kept.id] = ownerEdit
        before.selection.remove(deselected.id)
        let rerun = meeting(statusAgo: 300, rows: [row("  send the BUDGET "), row("Call Vendor!"), row("Brand new", confidence: 0.9)])
        let after = ReviewModel.from(rerun, now: now, previous: before)
        let budget = after.newRows[0], vendor = after.newRows[1], fresh = after.newRows[2]
        XCTAssertNotEqual(budget.id, kept.id)
        XCTAssertEqual(after.edits[budget.id], ownerEdit)
        XCTAssertTrue(after.selection.contains(budget.id))
        XCTAssertFalse(after.selection.contains(vendor.id))
        XCTAssertTrue(after.selection.contains(fresh.id))
        XCTAssertEqual(after.edits[fresh.id], nil)
        XCTAssertTrue(after.listUpdated)
    }

    func test_rerun_doesNotFlagTheListWhenTheVanishedRowWasJustKept() {
        let a = row("Send the budget"), b = row("Call vendor")
        var before = ReviewModel.from(meeting(rows: [a, b]), now: now, previous: nil)
        before.apply(.saved, to: a.id)
        let after = ReviewModel.from(meeting(rows: [row("Call vendor")]), now: now, previous: before)
        XCTAssertFalse(after.listUpdated)
        XCTAssertEqual(after.newRows.map(\.title), ["Send the budget", "Call vendor"])
        XCTAssertEqual(after.rowState[a.id], .saved)
    }

    func test_rerun_doesNotFlagTheListWhenNothingChanged() {
        let a = row("Send the budget")
        let before = ReviewModel.from(meeting(rows: [a]), now: now, previous: nil)
        XCTAssertFalse(ReviewModel.from(meeting(rows: [row("Send the budget")]), now: now, previous: before).listUpdated)
    }

    func test_everyServerAnswerShowsTheRightNoteOrState() {
        let cases: [(ReviewSaveResult, RowState, String?)] = [
            (.saved, .saved, nil),
            (.alreadyReviewed, .gone(.alreadyReviewed), "Already reviewed on the web"),
            (.alreadyInState, .gone(.alreadyDone), "Already done"),
            (.suggestionGone, .gone(.itemRemoved), "That item was removed"),
            (.itemGone, .gone(.itemRemoved), "That item was removed"),
            (.cannotKeepDuplicate, .gone(.alreadyReviewed), "Already reviewed on the web"),
            (.invalidRequest, .failed, nil),
            (.retryable, .failed, nil),
        ]
        for (result, state, note) in cases {
            let a = row("A"), b = row("B")
            var model = ReviewModel.from(meeting(rows: [a, b]), now: now, previous: nil)
            model.apply(result, to: a.id)
            XCTAssertEqual(model.rowState[a.id], state, "\(result)")
            if case .gone(let n) = state { XCTAssertEqual(n.text, note, "\(result)") }
            XCTAssertEqual(model.rowState[b.id] ?? .idle, .idle, "\(result)")
        }
    }

    func test_notReviewerAnswer_turnsThePanelReadOnlyAndKeepsTheRowAvailable() {
        for result in [ReviewSaveResult.notReviewer, .notAMember] {
            let a = row("A")
            var model = ReviewModel.from(meeting(rows: [a]), now: now, previous: nil)
            model.apply(result, to: a.id)
            XCTAssertTrue(model.readOnly, "\(result)")
            XCTAssertEqual(model.rowState[a.id], .idle, "\(result)")
            XCTAssertEqual(model.keepCount, 0, "\(result)")
            XCTAssertEqual(model.screen, .ready, "\(result)")
        }
    }

    func test_signedOutAnswer_marksTheModelAndLeavesTheItemPending() {
        let a = row("A")
        var model = ReviewModel.from(meeting(rows: [a]), now: now, previous: nil)
        model.apply(.signedOut, to: a.id)
        XCTAssertTrue(model.signedOut)
        XCTAssertEqual(model.rowState[a.id], .failed)
        XCTAssertEqual(model.keepCount, 1)
        XCTAssertEqual(model.screen, .ready)
    }

    func test_aFailedSave_keepsTheSelectionSoTryAgainStillKeepsIt() {
        let a = row("A"), b = row("B")
        var model = ReviewModel.from(meeting(rows: [a, b]), now: now, previous: nil)
        model.apply(.saved, to: a.id)
        model.apply(.retryable, to: b.id)
        XCTAssertEqual(model.screen, .ready)
        XCTAssertEqual(model.keepCount, 1)
        XCTAssertEqual(model.doneLine, "")
        model.apply(.saved, to: b.id)
        XCTAssertEqual(model.screen, .done(kept: 2, updated: 0))
    }

    func test_midRun_doesNotSayDoneUntilEverySelectedRowIsResolved() {
        let a = row("A"), b = row("B")
        var model = ReviewModel.from(meeting(rows: [a, b]), now: now, previous: nil)
        model.apply(.saved, to: a.id)
        XCTAssertEqual(model.screen, .ready)
        XCTAssertEqual(model.keepCount, 1)
    }

    func test_done_countsKeptAndUpdatedWithPluralRules() {
        let cases: [(Int, Int, String)] = [
            (2, 1, "2 items tracked, 1 updated"),
            (1, 0, "1 item tracked"),
            (0, 1, "1 updated"),
            (1, 2, "1 item tracked, 2 updated"),
        ]
        for (k, u, line) in cases {
            let news = (0..<k).map { row("New \($0)") }
            let ups = (0..<u).map { row("Update \($0)", type: "status_update") }
            var model = ReviewModel.from(meeting(rows: news + ups), now: now, previous: nil)
            for r in news + ups { model.apply(.saved, to: r.id) }
            XCTAssertEqual(model.screen, .done(kept: k, updated: u))
            XCTAssertEqual(model.doneLine, line)
        }
    }

    func test_partlyDone_whenSomeRowsAreLeftUnselected_thenSkipTheRestFinishesIt() {
        let a = row("A"), b = row("B"), c = row("C", confidence: 0.4)
        var model = ReviewModel.from(meeting(rows: [a, b, c]), now: now, previous: nil)
        model.apply(.saved, to: a.id)
        model.apply(.saved, to: b.id)
        XCTAssertEqual(model.screen, .partlyDone(kept: 2, left: 1))
        XCTAssertEqual(model.doneLine, "2 items tracked. 1 still to review.")
        model.apply(.saved, to: c.id)
        XCTAssertEqual(model.screen, .done(kept: 2, updated: 0))
        XCTAssertEqual(model.doneLine, "2 items tracked")
    }

    func test_partlyDone_singularItemAndPluralLeft() {
        let a = row("A"), b = row("B", confidence: 0.1), c = row("C", confidence: 0.1)
        var model = ReviewModel.from(meeting(rows: [a, b, c]), now: now, previous: nil)
        model.apply(.saved, to: a.id)
        XCTAssertEqual(model.doneLine, "1 item tracked. 2 still to review.")
    }

    func test_rowsReviewedOnTheWebDuringTheRun_stillLetTheRestFinishAsDone() {
        let a = row("A"), b = row("B")
        var model = ReviewModel.from(meeting(rows: [a, b]), now: now, previous: nil)
        model.apply(.saved, to: a.id)
        model.apply(.alreadyReviewed, to: b.id)
        XCTAssertEqual(model.screen, .done(kept: 1, updated: 0))
        XCTAssertEqual(model.doneLine, "1 item tracked")
    }

    func test_olderMeetingWithoutStatuses_showsNotAvailable() {
        XCTAssertEqual(screen(meeting(suggestions: nil)), .notAvailable)
        XCTAssertEqual(screen(meeting(transcription: nil, suggestions: "ready")), .notAvailable)
        XCTAssertEqual(screen(meeting(transcription: "pending", suggestions: nil, endedAgo: 5)), .notAvailable)
    }

    func test_olderMeetingWithoutTimestamps_isNeverSlowOrFailed() {
        let finding = meeting(suggestions: "pending", noTimes: true)
        XCTAssertEqual(screen(finding), .finding)
        let transcribing = meeting(transcription: "pending", suggestions: "pending", noTimes: true)
        XCTAssertEqual(screen(transcribing), .transcribing(elapsed: nil))
    }

    func test_doneWithNothingKept_saysNoItemsTracked() {
        let a = row("A")
        var model = ReviewModel.from(meeting(rows: [a]), now: now, previous: nil)
        model.apply(.alreadyReviewed, to: a.id)
        XCTAssertEqual(model.screen, .done(kept: 0, updated: 0))
        XCTAssertEqual(model.doneLine, "No items tracked")
    }

    func test_partlyDone_countsAKeptStatusUpdate() {
        let update = row("Contract renewed", type: "status_update"), left = row("Maybe", confidence: 0.2)
        var model = ReviewModel.from(meeting(rows: [left, update]), now: now, previous: nil)
        model.apply(.saved, to: update.id)
        XCTAssertEqual(model.doneLine, "1 item tracked. 1 still to review.")
    }

    func test_partlyDone_withNothingKept_saysNoItemsTracked() {
        let gone = row("A"), left = row("Maybe", confidence: 0.2)
        var model = ReviewModel.from(meeting(rows: [gone, left]), now: now, previous: nil)
        model.apply(.alreadyReviewed, to: gone.id)
        XCTAssertEqual(model.doneLine, "No items tracked. 1 still to review.")
    }

    func test_refreshAfterKeepingOne_doesNotForgetItWhenTheNextOneIsKept() {
        let a = row("A"), b = row("B")
        var model = ReviewModel.from(meeting(rows: [a, b]), now: now, previous: nil)
        model.apply(.saved, to: a.id)
        model = ReviewModel.from(meeting(rows: [b]), now: now, previous: model)
        XCTAssertEqual(model.screen, .ready)
        model.apply(.saved, to: b.id)
        XCTAssertEqual(model.screen, .done(kept: 2, updated: 0))
        XCTAssertEqual(model.doneLine, "2 items tracked")
    }

    func test_aKeepWhoseAnswerWasLost_andThatLeftThePendingList_countsAsTracked() {
        let a = row("A")
        var model = ReviewModel.from(meeting(rows: [a]), now: now, previous: nil)
        model.apply(.retryable, to: a.id)
        XCTAssertEqual(model.screen, .ready)
        model = ReviewModel.from(meeting(rows: []), now: now, previous: model)
        XCTAssertEqual(model.screen, .done(kept: 1, updated: 0))
        XCTAssertEqual(model.doneLine, "1 item tracked")
    }

    func test_aSkipWhoseAnswerWasLost_andThatLeftThePendingList_countsAsSkipped() {
        let b = row("B", confidence: 0.5)
        var model = ReviewModel.from(meeting(rows: [b]), now: now, previous: nil)
        model.apply(.retryable, to: b.id)
        model = ReviewModel.from(meeting(rows: []), now: now, previous: model)
        XCTAssertEqual(model.screen, .done(kept: 0, updated: 0))
        XCTAssertEqual(model.doneLine, "No items tracked")
    }

    func test_aLostKeepThatIsStillPending_staysCouldntSave() {
        let a = row("A")
        var model = ReviewModel.from(meeting(rows: [a]), now: now, previous: nil)
        model.apply(.retryable, to: a.id)
        model = ReviewModel.from(meeting(rows: [a]), now: now, previous: model)
        XCTAssertEqual(model.rowState[a.id], .failed)
        XCTAssertEqual(model.keepCount, 1)
    }

    func test_aRefusedKeepThatLeftThePendingList_isNotCountedAsTracked() {
        let a = row("A")
        var model = ReviewModel.from(meeting(rows: [a]), now: now, previous: nil)
        model.apply(.invalidRequest, to: a.id)
        model = ReviewModel.from(meeting(rows: []), now: now, previous: model)
        XCTAssertEqual(model.screen, .none(moreOnWeb: 0))
    }

    func test_refreshAfterEverythingWasKept_staysOnTheDoneScreen() {
        let a = row("A"), u = row("Contract renewed", type: "status_update")
        var model = ReviewModel.from(meeting(rows: [a, u]), now: now, previous: nil)
        model.apply(.saved, to: a.id)
        model.apply(.saved, to: u.id)
        model = ReviewModel.from(meeting(rows: []), now: now, previous: model)
        XCTAssertEqual(model.screen, .done(kept: 1, updated: 1))
        XCTAssertEqual(model.doneLine, "1 item tracked, 1 updated")
    }

    func test_rerun_aRowStillSavingStaysSavingAndItsLateResultLandsOnTheShownRow() {
        let a = row("Send the budget")
        var before = ReviewModel.from(meeting(rows: [a]), now: now, previous: nil)
        before.rowState[a.id] = .saving
        var after = ReviewModel.from(meeting(statusAgo: 300, rows: [row("Send the budget")]), now: now, previous: before)
        let shown = after.newRows[0].id
        XCTAssertNotEqual(shown, a.id)
        XCTAssertEqual(after.rowState[shown], .saving)
        after.apply(.saved, to: a.id)
        XCTAssertEqual(after.rowState[shown], .saved)
        XCTAssertEqual(after.screen, .done(kept: 1, updated: 0))
    }

    func test_twoRerunsInARow_aLateResultForTheFirstIdStillLandsOnTheShownRow() {
        let a = row("Send the budget")
        var m = ReviewModel.from(meeting(rows: [a]), now: now, previous: nil)
        m.rowState[a.id] = .saving
        m = ReviewModel.from(meeting(statusAgo: 300, rows: [row("Send the budget")]), now: now, previous: m)
        m = ReviewModel.from(meeting(statusAgo: 100, rows: [row("Send the budget")]), now: now, previous: m)
        m.apply(.saved, to: a.id)
        XCTAssertEqual(m.rowState[m.newRows[0].id], .saved)
    }

    func test_rerun_twoRowsWithTheSameTitle_eachTakesItsOwnOldRowSoNoneIsStuckSaving() {
        let first = row("Send the budget"), second = row("Send the budget")
        var before = ReviewModel.from(meeting(rows: [first, second]), now: now, previous: nil)
        before.rowState[first.id] = .saving
        before.selection = [first.id]
        var after = ReviewModel.from(
            meeting(statusAgo: 300, rows: [row("Send the budget"), row("Send the budget")]), now: now, previous: before)
        let shown = after.newRows.map(\.id)
        XCTAssertEqual(shown.map { after.rowState[$0] ?? .idle }, [.saving, .idle])
        XCTAssertEqual(after.selection, [shown[0]])
        after.apply(.saved, to: first.id)
        XCTAssertEqual(after.rowState[shown[0]], .saved)
        XCTAssertEqual(after.rowState[shown[1]] ?? .idle, .idle)
    }

    func test_rerun_aThirdSameTitleRowWithNoOldRowStartsIdleAndUnselected() {
        let before = ReviewModel.from(meeting(rows: [row("Ship it"), row("Ship it")]), now: now, previous: nil)
        let after = ReviewModel.from(
            meeting(statusAgo: 300, rows: [row("Ship it"), row("Ship it"), row("Ship it")]), now: now, previous: before)
        XCTAssertEqual(after.selection.count, 2)
        XCTAssertFalse(after.selection.contains(after.newRows[2].id))
    }

    func test_manyRerunsInARow_aliasesAreDroppedOnceNothingIsInFlight() {
        var m = ReviewModel.from(meeting(rows: [row("Ship it")]), now: now, previous: nil)
        for n in 1...5 {
            m = ReviewModel.from(meeting(statusAgo: TimeInterval(600 - n), rows: [row("Ship it")]), now: now, previous: m)
        }
        XCTAssertEqual(m.aliases.count, 0)
        m.rowState[m.newRows[0].id] = .saving
        let before = m.newRows[0].id
        m = ReviewModel.from(meeting(statusAgo: 100, rows: [row("Ship it")]), now: now, previous: m)
        XCTAssertEqual(m.aliases.count, 1)
        m.apply(.saved, to: before)
        m = ReviewModel.from(meeting(statusAgo: 50, rows: []), now: now, previous: m)
        XCTAssertEqual(m.aliases.count, 0)
    }

    func test_plainRefresh_rowsReviewedOnTheWebJustVanishWithoutAListUpdatedNote() {
        let a = row("A"), b = row("B")
        let before = ReviewModel.from(meeting(rows: [a, b]), now: now, previous: nil)
        let after = ReviewModel.from(meeting(rows: [b]), now: now, previous: before)
        XCTAssertFalse(after.listUpdated)
        XCTAssertEqual(after.newRows.map(\.title), ["B"])
    }

    func test_listUpdatedNote_appearsOnARerunThatLosesARow_andClearsOnTheNextRerunThatLosesNothing() {
        let before = ReviewModel.from(meeting(rows: [row("A"), row("B")]), now: now, previous: nil)
        let lost = ReviewModel.from(meeting(statusAgo: 300, rows: [row("B")]), now: now, previous: before)
        XCTAssertTrue(lost.listUpdated)
        let plain = ReviewModel.from(meeting(statusAgo: 300, rows: [row("B")]), now: now, previous: lost)
        XCTAssertTrue(plain.listUpdated)
        let clean = ReviewModel.from(meeting(statusAgo: 100, rows: [row("B")]), now: now, previous: lost)
        XCTAssertFalse(clean.listUpdated)
    }

    func test_aPreviousModelFromAnotherMeeting_isIgnored() {
        let a = row("A")
        var other = ReviewModel.from(meeting(id: UUID(), rows: [a]), now: now, previous: nil)
        other.edits[a.id] = RowEdit(ownerUserId: owner)
        other.selection = []
        other.apply(.saved, to: a.id)
        let after = ReviewModel.from(meeting(rows: [row("A")]), now: now, previous: other)
        XCTAssertEqual(after.screen, .ready)
        XCTAssertEqual(after.newRows.count, 1)
        XCTAssertEqual(after.selection, [after.newRows[0].id])
        XCTAssertNil(after.edits[after.newRows[0].id])
        XCTAssertFalse(after.listUpdated)
    }

    func test_notificationTitle_usesSingularForOneItem() {
        XCTAssertEqual(ReviewCopy.notificationTitle(count: 1, series: "Weekly sync"), "1 action item from Weekly sync")
        XCTAssertEqual(ReviewCopy.notificationTitle(count: 3, series: "Weekly sync"), "3 action items from Weekly sync")
    }

    func test_normalizedTitle_matchesTheServerOnEverySharedCase() throws {
        struct Case: Decodable { let input: String; let expected: String }
        let url = try XCTUnwrap(
            Bundle(for: ReviewModelTests.self).url(forResource: "normalize-title-cases", withExtension: "json"))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertEqual(cases.count, 7)
        for c in cases { XCTAssertEqual(ReviewModel.normalizedTitle(c.input), c.expected, c.input) }
    }
}
