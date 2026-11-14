import XCTest
@testable import Minutia

/// A stored draft is replayed only to the user who wrote it: both ids must be known and equal.
/// An unknown id on either side could hand one person's notes to whoever is signed in now.
final class NotepadReplayGateTests: XCTestCase {
    private let instance = URL(string: "https://app.minutia.example")!
    private let user = "aaaa1111-2222-3333-4444-555566667777"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notepad-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func saveDirty(_ meetingId: String, userId: String?) throws {
        var draft = NotepadDraft(meetingId: meetingId, instanceURL: instance, userId: userId, createdAt: Date())
        draft.edit("note", at: Date())
        try NotepadStore.save(draft, in: root)
    }

    private func pending(connectedUserId: String?) -> [String] {
        NotepadStore.pendingDrafts(in: root, connectedInstance: instance, connectedUserId: connectedUserId, excluding: nil)
            .map(\.meetingId)
    }

    func test_draftWithoutUser_isNeverReplayed() throws {
        try saveDirty("aaaaaaaa-0000-0000-0000-000000000000", userId: nil)
        XCTAssertEqual(pending(connectedUserId: user), [])
    }

    func test_unknownConnectedUser_replaysNothing() throws {
        try saveDirty("aaaaaaaa-0000-0000-0000-000000000000", userId: user)
        try saveDirty("bbbbbbbb-0000-0000-0000-000000000000", userId: nil)
        XCTAssertEqual(pending(connectedUserId: nil), [])
    }

    func test_matchingUser_isReplayed() throws {
        try saveDirty("aaaaaaaa-0000-0000-0000-000000000000", userId: user)
        XCTAssertEqual(pending(connectedUserId: user), ["aaaaaaaa-0000-0000-0000-000000000000"])
    }

    func test_matchingUser_comparesCaseInsensitively() throws {
        try saveDirty("aaaaaaaa-0000-0000-0000-000000000000", userId: user.uppercased())
        XCTAssertEqual(pending(connectedUserId: user), ["aaaaaaaa-0000-0000-0000-000000000000"])
    }

    func test_otherUser_isNotReplayed() throws {
        try saveDirty("aaaaaaaa-0000-0000-0000-000000000000", userId: "bbbb2222-0000-0000-0000-000000000000")
        XCTAssertEqual(pending(connectedUserId: user), [])
    }
}
