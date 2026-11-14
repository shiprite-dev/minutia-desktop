import Foundation

struct NotepadDraft: Codable, Equatable {
    static let maxLength = 100_000

    let meetingId: String
    let instanceURL: URL
    let userId: String?
    private(set) var text: String
    private(set) var revision: Int
    private(set) var syncedRevision: Int
    private(set) var updatedAt: Date

    init(meetingId: String, instanceURL: URL, userId: String?, createdAt: Date) {
        self.meetingId = meetingId.lowercased()
        self.instanceURL = instanceURL
        self.userId = userId
        text = ""
        revision = 0
        syncedRevision = 0
        updatedAt = createdAt
    }

    var needsSync: Bool { revision > syncedRevision }

    static func clamp(_ text: String) -> String {
        text.unicodeScalars.count <= maxLength
            ? text : String(String.UnicodeScalarView(text.unicodeScalars.prefix(maxLength)))
    }

    mutating func edit(_ newText: String, at date: Date) {
        let clamped = Self.clamp(newText)
        guard clamped != text else { return }
        text = clamped
        revision += 1
        updatedAt = date
    }

    mutating func markSynced(revision synced: Int) {
        syncedRevision = max(syncedRevision, min(synced, revision))
    }
}

enum NotepadStore {
    static func notesRoot(appSupport: URL? = nil) throws -> URL {
        let base = try appSupport ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = base
            .appendingPathComponent("Minutia", isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func file(_ meetingId: String, in root: URL) -> URL {
        root.appendingPathComponent("\(meetingId.lowercased()).json")
    }

    static func save(_ draft: NotepadDraft, in root: URL) throws {
        try JSONEncoder().encode(draft).write(to: file(draft.meetingId, in: root), options: .atomic)
    }

    static func load(meetingId: String, in root: URL) -> NotepadDraft? {
        guard let data = try? Data(contentsOf: file(meetingId, in: root)) else { return nil }
        return try? JSONDecoder().decode(NotepadDraft.self, from: data)
    }

    static func remove(meetingId: String, in root: URL) {
        try? FileManager.default.removeItem(at: file(meetingId, in: root))
    }

    static func removeIfSynced(meetingId: String, in root: URL) {
        if let draft = load(meetingId: meetingId, in: root), !draft.needsSync { remove(meetingId: meetingId, in: root) }
    }

    private static func allDrafts(in root: URL) -> [NotepadDraft] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(NotepadDraft.self, from: Data(contentsOf: $0)) }
    }

    static func pendingDrafts(
        in root: URL, connectedInstance: URL, connectedUserId: String?, excluding activeMeetingId: String?
    ) -> [NotepadDraft] {
        let active = activeMeetingId?.lowercased()
        let connected = InstanceConfig.normalize(connectedInstance.absoluteString) ?? connectedInstance
        return allDrafts(in: root)
            .filter { draft in
                guard draft.needsSync, draft.meetingId != active else { return false }
                let instance = InstanceConfig.normalize(draft.instanceURL.absoluteString) ?? draft.instanceURL
                guard instance == connected else { return false }
                if let user = draft.userId, let connectedUserId, user != connectedUserId { return false }
                return true
            }
            .sorted { $0.meetingId < $1.meetingId }
    }

    static func purgeSynced(in root: URL) {
        for draft in allDrafts(in: root) where !draft.needsSync { remove(meetingId: draft.meetingId, in: root) }
    }
}
