import XCTest
import Supabase
@testable import Minutia

/// A notes update that matched no row (the meeting is gone or not writable by this user) will never
/// succeed, so it stops retrying and says so calmly while the draft stays on disk. Anything else,
/// including the server not having the notes column yet (PostgREST PGRST204), keeps retrying.
final class NotepadTerminalSyncTests: XCTestCase {
    func test_meetingNotWritable_isTerminal() {
        XCTAssertTrue(NotepadSyncPolicy.isTerminal(MinutiaClientError.meetingNotWritable))
    }

    func test_missingColumnOnServer_staysRetriable() {
        let error = PostgrestError(
            code: "PGRST204",
            message: "Could not find the 'companion_notes_markdown' column of 'meetings' in the schema cache")
        XCTAssertFalse(NotepadSyncPolicy.isTerminal(error))
    }

    func test_networkAndServerFailures_stayRetriable() {
        XCTAssertFalse(NotepadSyncPolicy.isTerminal(URLError(.notConnectedToInternet)))
        XCTAssertFalse(NotepadSyncPolicy.isTerminal(URLError(.timedOut)))
        XCTAssertFalse(NotepadSyncPolicy.isTerminal(MinutiaClientError.serverError(status: 502)))
        XCTAssertFalse(NotepadSyncPolicy.isTerminal(PostgrestError(code: "PGRST301", message: "JWT expired")))
    }

    private func dirtyDraft() -> NotepadDraft {
        var draft = NotepadDraft(
            meetingId: "0f9c2c9a-1a2b-4c3d-8e4f-5a6b7c8d9e0f",
            instanceURL: URL(string: "https://app.minutia.example")!,
            userId: "u1", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        draft.edit("a", at: Date(timeIntervalSince1970: 1_700_000_001))
        return draft
    }

    func test_saveState_stoppedSyncReadsKeptOnThisMac() {
        XCTAssertEqual(NotepadSaveState.of(draft: dirtyDraft(), lastAttemptFailed: true, syncStopped: true), .keptLocally)
        XCTAssertEqual(NotepadSaveState.keptLocally.label, "Kept on this Mac")
    }

    func test_saveState_syncedDraftStaysSyncedEvenIfStopped() {
        var draft = dirtyDraft()
        draft.markSynced(revision: draft.revision)
        XCTAssertEqual(NotepadSaveState.of(draft: draft, lastAttemptFailed: false, syncStopped: true), .synced)
    }

    func test_saveState_notStopped_keepsExistingStates() {
        XCTAssertEqual(NotepadSaveState.of(draft: dirtyDraft(), lastAttemptFailed: true, syncStopped: false), .savedLocally)
        XCTAssertEqual(NotepadSaveState.of(draft: dirtyDraft(), lastAttemptFailed: false, syncStopped: false), .saving)
    }
}
