import XCTest
@testable import Minutia

/// Pure seams of the notepad's server sync: when a debounced push fires, how failures back off, what
/// the panel's status line says, what the global shortcut does, and the finalize ordering rule that
/// notes reach the meeting before the final transcription request (which runs action-item extraction).
final class NotepadSyncTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Debounce

    func test_shouldSync_falseWhenNothingToSync() {
        XCTAssertFalse(NotepadSyncPolicy.shouldSync(
            needsSync: false, inFlight: false, lastEditAt: t0, firstUnsyncedEditAt: t0,
            now: t0.addingTimeInterval(60)))
    }

    /// One write at a time: a second push while one is in flight could land out of order.
    func test_shouldSync_falseWhileInFlight() {
        XCTAssertFalse(NotepadSyncPolicy.shouldSync(
            needsSync: true, inFlight: true, lastEditAt: t0, firstUnsyncedEditAt: t0,
            now: t0.addingTimeInterval(60)))
    }

    func test_shouldSync_waitsForIdleWhileTyping() {
        XCTAssertFalse(NotepadSyncPolicy.shouldSync(
            needsSync: true, inFlight: false,
            lastEditAt: t0, firstUnsyncedEditAt: t0,
            now: t0.addingTimeInterval(NotepadSyncPolicy.idleDelay - 0.1)))
    }

    func test_shouldSync_firesAfterIdleDelay() {
        XCTAssertTrue(NotepadSyncPolicy.shouldSync(
            needsSync: true, inFlight: false,
            lastEditAt: t0, firstUnsyncedEditAt: t0,
            now: t0.addingTimeInterval(NotepadSyncPolicy.idleDelay)))
    }

    /// Continuous typing never starves the server copy past the max delay.
    func test_shouldSync_firesAtMaxDelayEvenWhileTyping() {
        let now = t0.addingTimeInterval(NotepadSyncPolicy.maxDelay)
        XCTAssertTrue(NotepadSyncPolicy.shouldSync(
            needsSync: true, inFlight: false,
            lastEditAt: now.addingTimeInterval(-0.2), firstUnsyncedEditAt: t0,
            now: now))
    }

    func test_policyConstants_idleShorterThanMax() {
        XCTAssertLessThan(NotepadSyncPolicy.idleDelay, NotepadSyncPolicy.maxDelay)
        XCTAssertLessThanOrEqual(NotepadSyncPolicy.maxDelay, 15)
    }

    // MARK: - Retry backoff

    func test_retryDelay_doublesAndCaps() {
        XCTAssertEqual(NotepadSyncPolicy.retryDelay(attempt: 1), 2)
        XCTAssertEqual(NotepadSyncPolicy.retryDelay(attempt: 2), 4)
        XCTAssertEqual(NotepadSyncPolicy.retryDelay(attempt: 3), 8)
        XCTAssertEqual(NotepadSyncPolicy.retryDelay(attempt: 10), 60)
        XCTAssertEqual(NotepadSyncPolicy.retryDelay(attempt: 0), 2)
    }

    // MARK: - Status line

    private func draft(text: String, synced: Bool) -> NotepadDraft {
        var d = NotepadDraft(
            meetingId: "m", instanceURL: URL(string: "https://x.example")!, userId: nil, createdAt: t0)
        if !text.isEmpty { d.edit(text, at: t0) }
        if synced { d.markSynced(revision: d.revision) }
        return d
    }

    func test_saveState_emptyWhenNoDraftOrUntouched() {
        XCTAssertEqual(NotepadSaveState.of(draft: nil, lastAttemptFailed: false), .empty)
        XCTAssertEqual(NotepadSaveState.of(draft: draft(text: "", synced: false), lastAttemptFailed: false), .empty)
    }

    func test_saveState_savingWhileDirty() {
        XCTAssertEqual(NotepadSaveState.of(draft: draft(text: "a", synced: false), lastAttemptFailed: false), .saving)
    }

    /// Offline or a failed push: the text is safe on disk, and the copy says so instead of an error.
    func test_saveState_savedLocallyWhenLastPushFailed() {
        XCTAssertEqual(NotepadSaveState.of(draft: draft(text: "a", synced: false), lastAttemptFailed: true), .savedLocally)
    }

    func test_saveState_syncedWhenServerHasLatest() {
        XCTAssertEqual(NotepadSaveState.of(draft: draft(text: "a", synced: true), lastAttemptFailed: true), .synced)
    }

    func test_saveState_labels() {
        XCTAssertEqual(NotepadSaveState.empty.label, "")
        XCTAssertEqual(NotepadSaveState.saving.label, "Saving…")
        XCTAssertEqual(NotepadSaveState.synced.label, "Saved to meeting")
        XCTAssertEqual(NotepadSaveState.savedLocally.label, "Saved on this Mac")
    }

    // MARK: - Global shortcut

    func test_shortcut_hiddenPanelShowsAndFocuses() {
        XCTAssertEqual(NotepadPanelAction.forShortcut(visible: false, isKey: false), .showAndFocus)
    }

    /// Visible but unfocused (auto-shown at record start, user still in Zoom): focus it, don't hide.
    func test_shortcut_visibleUnfocusedPanelFocuses() {
        XCTAssertEqual(NotepadPanelAction.forShortcut(visible: true, isKey: false), .focus)
    }

    func test_shortcut_focusedPanelHides() {
        XCTAssertEqual(NotepadPanelAction.forShortcut(visible: true, isKey: true), .hide)
    }

    // MARK: - Finalize ordering

    private actor Log {
        var steps: [String] = []
        func add(_ step: String) { steps.append(step) }
    }

    private struct Boom: Error {}

    func test_flushThenTranscribe_flushesNotesBeforeRequestingTranscription() async throws {
        let log = Log()
        let outcome = try await NotepadFinalize.flushThenTranscribe(
            flush: { await log.add("flush") },
            requestTranscription: { await log.add("transcribe") })
        XCTAssertEqual(outcome, .flushed)
        let steps = await log.steps
        XCTAssertEqual(steps, ["flush", "transcribe"])
    }

    /// A failed flush never blocks finalize: transcription is still requested; notes retry later.
    func test_flushThenTranscribe_failedFlushStillRequestsTranscription() async throws {
        let log = Log()
        let outcome = try await NotepadFinalize.flushThenTranscribe(
            flush: { await log.add("flush"); throw Boom() },
            requestTranscription: { await log.add("transcribe") })
        XCTAssertEqual(outcome, .failed)
        let steps = await log.steps
        XCTAssertEqual(steps, ["flush", "transcribe"])
    }

    /// A hung flush is bounded so the stop sequence cannot stall on notes.
    func test_flushThenTranscribe_hungFlushTimesOutThenRequestsTranscription() async throws {
        let log = Log()
        let started = Date()
        let outcome = try await NotepadFinalize.flushThenTranscribe(
            flushTimeout: 0.2,
            flush: { try await Task.sleep(nanoseconds: 30_000_000_000) },
            requestTranscription: { await log.add("transcribe") })
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let steps = await log.steps
        XCTAssertEqual(steps, ["transcribe"])
    }

    /// A transcription failure still propagates, so the controller keeps the audio and shows Retry.
    func test_flushThenTranscribe_rethrowsTranscriptionFailure() async {
        do {
            _ = try await NotepadFinalize.flushThenTranscribe(
                flush: {},
                requestTranscription: { throw Boom() })
            XCTFail("expected rethrow")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    func test_flushTimeout_fitsInsideFinalizeTimeout() {
        XCTAssertLessThan(NotepadFinalize.flushTimeout, CaptureSession.finalizeTimeout)
        XCTAssertLessThanOrEqual(NotepadFinalize.flushTimeout, 5)
    }

    // MARK: - Request construction

    /// The companion writes only its own column: never notes_markdown or raw_notes_markdown, which
    /// the web editor owns and rewrites on every autosave.
    func test_companionNotesUpdate_encodesOnlyCompanionColumn() throws {
        let data = try JSONEncoder().encode(MinutiaClient.companionNotesUpdate(text: "Owner: Sam"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["companion_notes_markdown"])
        XCTAssertEqual(object["companion_notes_markdown"] as? String, "Owner: Sam")
    }

    func test_companionNotesUpdate_clampsToServerLimit() {
        let long = String(repeating: "y", count: NotepadDraft.maxLength + 1)
        XCTAssertEqual(
            MinutiaClient.companionNotesUpdate(text: long).companion_notes_markdown.count,
            NotepadDraft.maxLength)
    }

    /// Must equal the server CHECK constraint (char_length <= 100000) and COMPANION_NOTES_MAX_LENGTH.
    func test_maxLength_matchesServerConstraint() {
        XCTAssertEqual(NotepadDraft.maxLength, 100_000)
    }

    /// A zero-row update (meeting gone or no access) is a distinct terminal error, never a silent success.
    func test_meetingNotWritable_isDistinctError() {
        XCTAssertNotEqual(MinutiaClientError.meetingNotWritable, MinutiaClientError.featureUnavailable)
    }
}
