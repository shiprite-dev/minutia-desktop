import XCTest
@testable import Minutia

/// The companion notepad's local draft: the durable copy of what the user typed during a recording,
/// which must survive a crash, a network drop and a sign-out until the server has it.
final class NotepadDraftTests: XCTestCase {
    private let meeting = "0F9C2C9A-1A2B-4C3D-8E4F-5A6B7C8D9E0F"
    private let instance = URL(string: "https://app.minutia.example")!
    private let user = "aaaa1111-2222-3333-4444-555566667777"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notepad-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func draft(meetingId: String? = nil, instanceURL: URL? = nil, userId: String? = nil) -> NotepadDraft {
        NotepadDraft(
            meetingId: meetingId ?? meeting,
            instanceURL: instanceURL ?? instance,
            userId: userId ?? user,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - Draft revisions

    func test_init_lowercasesMeetingIdAndStartsCleanAndEmpty() {
        let d = draft()
        XCTAssertEqual(d.meetingId, meeting.lowercased())
        XCTAssertEqual(d.text, "")
        XCTAssertEqual(d.revision, 0)
        XCTAssertEqual(d.syncedRevision, 0)
        XCTAssertFalse(d.needsSync)
    }

    func test_edit_bumpsRevisionAndNeedsSync() {
        var d = draft()
        let at = Date(timeIntervalSince1970: 1_700_000_100)
        d.edit("Ship on Friday", at: at)
        XCTAssertEqual(d.text, "Ship on Friday")
        XCTAssertEqual(d.revision, 1)
        XCTAssertEqual(d.updatedAt, at)
        XCTAssertTrue(d.needsSync)
    }

    func test_edit_identicalTextIsNoOp() {
        var d = draft()
        d.edit("a", at: Date(timeIntervalSince1970: 1))
        d.edit("a", at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(d.revision, 1)
        XCTAssertEqual(d.updatedAt, Date(timeIntervalSince1970: 1))
    }

    func test_edit_clampsToMaxLength() {
        var d = draft()
        d.edit(String(repeating: "x", count: NotepadDraft.maxLength + 50), at: Date())
        XCTAssertEqual(d.text.count, NotepadDraft.maxLength)
    }

    /// Clearing the notes is a real edit the server must learn about, not an empty no-op.
    func test_edit_clearingTextStillNeedsSync() {
        var d = draft()
        d.edit("a", at: Date())
        d.markSynced(revision: 1)
        d.edit("", at: Date())
        XCTAssertTrue(d.needsSync)
    }

    /// A sync that started at revision 2 finishing after the user typed revision 3 must leave the
    /// draft dirty, so the newer text is pushed next.
    func test_markSynced_olderRevisionLeavesNewerEditDirty() {
        var d = draft()
        d.edit("a", at: Date())
        d.edit("ab", at: Date())
        d.edit("abc", at: Date())
        d.markSynced(revision: 2)
        XCTAssertEqual(d.syncedRevision, 2)
        XCTAssertTrue(d.needsSync)
    }

    /// Out-of-order completions never move the synced mark backwards or past the latest edit.
    func test_markSynced_isMonotonicAndBoundedByRevision() {
        var d = draft()
        d.edit("a", at: Date())
        d.edit("ab", at: Date())
        d.markSynced(revision: 2)
        d.markSynced(revision: 1)
        XCTAssertEqual(d.syncedRevision, 2)
        d.markSynced(revision: 99)
        XCTAssertEqual(d.syncedRevision, 2)
        XCTAssertFalse(d.needsSync)
    }

    // MARK: - Store

    func test_notesRoot_isUnderMinutiaNotesInAppSupport() throws {
        let url = try NotepadStore.notesRoot(appSupport: root)
        XCTAssertEqual(url.lastPathComponent, "notes")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Minutia")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    /// The notes root must not live inside a capture directory: CaptureSession.stop deletes the
    /// capture directory once transcription is accepted, which would take unsynced notes with it.
    func test_notesRoot_isSiblingOfCapturesRoot() throws {
        let notes = try NotepadStore.notesRoot(appSupport: root)
        let captures = try CaptureStore.capturesRoot(appSupport: root)
        XCTAssertEqual(notes.deletingLastPathComponent(), captures.deletingLastPathComponent())
        XCTAssertNotEqual(notes, captures)
    }

    func test_saveThenLoad_roundTripsAndLooksUpCaseInsensitively() throws {
        var d = draft()
        d.edit("Decision: hire two", at: Date(timeIntervalSince1970: 1_700_000_200))
        try NotepadStore.save(d, in: root)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("\(meeting.lowercased()).json").path))
        XCTAssertEqual(NotepadStore.load(meetingId: meeting, in: root), d)
        XCTAssertEqual(NotepadStore.load(meetingId: meeting.lowercased(), in: root), d)
    }

    func test_load_missingOrCorruptReturnsNil() throws {
        XCTAssertNil(NotepadStore.load(meetingId: meeting, in: root))
        try Data("not json".utf8).write(to: root.appendingPathComponent("\(meeting.lowercased()).json"))
        XCTAssertNil(NotepadStore.load(meetingId: meeting, in: root))
    }

    func test_remove_deletesDraft() throws {
        try NotepadStore.save(draft(), in: root)
        NotepadStore.remove(meetingId: meeting, in: root)
        XCTAssertNil(NotepadStore.load(meetingId: meeting, in: root))
    }

    // MARK: - Recovery replay

    private func dirtyDraft(_ id: String, instanceURL: URL? = nil, userId: String? = nil) -> NotepadDraft {
        var d = draft(meetingId: id, instanceURL: instanceURL, userId: userId)
        d.edit("note for \(id)", at: Date())
        return d
    }

    func test_pendingDrafts_returnsOnlyDirtyDraftsSorted() throws {
        let b = dirtyDraft("bbbbbbbb-0000-0000-0000-000000000000")
        let a = dirtyDraft("aaaaaaaa-0000-0000-0000-000000000000")
        var clean = dirtyDraft("cccccccc-0000-0000-0000-000000000000")
        clean.markSynced(revision: clean.revision)
        for d in [b, a, clean] { try NotepadStore.save(d, in: root) }

        let pending = NotepadStore.pendingDrafts(
            in: root, connectedInstance: instance, connectedUserId: user, excluding: nil)
        XCTAssertEqual(pending.map(\.meetingId), [a.meetingId, b.meetingId])
    }

    /// The live recording's draft is synced by the running notepad, never by the replay sweep.
    func test_pendingDrafts_excludesActiveMeetingCaseInsensitively() throws {
        try NotepadStore.save(dirtyDraft(meeting), in: root)
        let pending = NotepadStore.pendingDrafts(
            in: root, connectedInstance: instance, connectedUserId: user, excluding: meeting.uppercased())
        XCTAssertTrue(pending.isEmpty)
    }

    /// Same gate as capture recovery: notes typed against instance A never go to instance B.
    func test_pendingDrafts_skipsOtherInstanceButToleratesTrailingSlash() throws {
        try NotepadStore.save(dirtyDraft("aaaaaaaa-0000-0000-0000-000000000000",
                                         instanceURL: URL(string: "https://other.example")!), in: root)
        try NotepadStore.save(dirtyDraft("bbbbbbbb-0000-0000-0000-000000000000",
                                         instanceURL: URL(string: "https://app.minutia.example/")!), in: root)
        let pending = NotepadStore.pendingDrafts(
            in: root, connectedInstance: instance, connectedUserId: user, excluding: nil)
        XCTAssertEqual(pending.map(\.meetingId), ["bbbbbbbb-0000-0000-0000-000000000000"])
    }

    /// Notes written by user A must not be uploaded while user B is signed in on the same Mac.
    func test_pendingDrafts_skipsOtherUser() throws {
        try NotepadStore.save(dirtyDraft("aaaaaaaa-0000-0000-0000-000000000000",
                                         userId: "bbbb2222-0000-0000-0000-000000000000"), in: root)
        let pending = NotepadStore.pendingDrafts(
            in: root, connectedInstance: instance, connectedUserId: user, excluding: nil)
        XCTAssertTrue(pending.isEmpty)
    }

    /// Sign-out keeps unsynced notes (they replay when the same user signs back in) and drops the
    /// already-synced ones so nothing private lingers needlessly.
    func test_purgeSynced_keepsDirtyAndRemovesSynced() throws {
        let dirty = dirtyDraft("aaaaaaaa-0000-0000-0000-000000000000")
        var synced = dirtyDraft("bbbbbbbb-0000-0000-0000-000000000000")
        synced.markSynced(revision: synced.revision)
        try NotepadStore.save(dirty, in: root)
        try NotepadStore.save(synced, in: root)

        NotepadStore.purgeSynced(in: root)

        XCTAssertNotNil(NotepadStore.load(meetingId: dirty.meetingId, in: root))
        XCTAssertNil(NotepadStore.load(meetingId: synced.meetingId, in: root))
    }
}
