import AppKit
import Carbon.HIToolbox
import Foundation
import OSLog
import SwiftUI

@MainActor
final class NotepadController: ObservableObject {
    @Published private(set) var draft: NotepadDraft?
    @Published private(set) var lastAttemptFailed = false
    @Published private(set) var shortcutAvailable = false

    var saveState: NotepadSaveState { .of(draft: draft, lastAttemptFailed: lastAttemptFailed) }

    private struct FlushFailed: Error {}

    private static let logger = Logger(subsystem: "app.minutia.desktop", category: "Notepad")
    private static let saveDelay: TimeInterval = 0.3
    private static let closeDelay: TimeInterval = 1.5

    private lazy var panel = NotepadPanel { [unowned self] in
        NSHostingView(rootView: NotepadView(controller: self))
    }
    private lazy var hotKey = GlobalHotKey(
        keyCode: kVK_ANSI_N, modifiers: cmdKey | optionKey
    ) { [weak self] in self?.shortcutPressed() }

    private var client: MinutiaClient?
    private var root: URL?
    private var ended = false
    private var inFlight = false
    private var attempts = 0
    private var lastEditAt: Date?
    private var firstUnsyncedEditAt: Date?
    private var saveTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?

    func begin(meetingId: String, instance: URL, userId: String?, client: MinutiaClient) {
        cancelTimers()
        self.client = client
        root = try? NotepadStore.notesRoot()
        ended = false
        attempts = 0
        lastAttemptFailed = false
        lastEditAt = nil
        firstUnsyncedEditAt = nil
        draft = root.flatMap { NotepadStore.load(meetingId: meetingId, in: $0) }
            ?? NotepadDraft(meetingId: meetingId, instanceURL: instance, userId: userId, createdAt: Date())
        shortcutAvailable = hotKey.register()
        panel.show(focus: false)
        if draft?.needsSync == true {
            firstUnsyncedEditAt = Date()
            scheduleSync(after: NotepadSyncPolicy.idleDelay)
        }
    }

    func update(_ text: String) {
        guard draft != nil else { return }
        let now = Date()
        draft?.edit(text, at: now)
        guard draft?.needsSync == true else { return }
        lastEditAt = now
        if firstUnsyncedEditAt == nil { firstUnsyncedEditAt = now }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.saveDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
        if !inFlight { scheduleSync(after: NotepadSyncPolicy.idleDelay) }
    }

    func showAndFocus() { panel.show(focus: true) }

    func end() {
        guard !ended, draft != nil else { return }
        ended = true
        hotKey.unregister()
        shortcutAvailable = false
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            guard let self else { return }
            _ = try? await withTimeout(seconds: NotepadFinalize.flushTimeout) { try await self.flushNow() }
            try? await Task.sleep(nanoseconds: UInt64(Self.closeDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.panel.fadeOut()
        }
    }

    func flushNow() async throws {
        persist()
        while inFlight { try await Task.sleep(nanoseconds: 50_000_000) }
        while draft?.needsSync == true {
            guard await push() else { throw FlushFailed() }
        }
    }

    func flush(meetingId: String, client: MinutiaClient) async throws {
        if draft?.meetingId == meetingId.lowercased() {
            try await flushNow()
        } else if let root = try? NotepadStore.notesRoot() {
            try await Self.pushStored(meetingId: meetingId, client: client, root: root)
        }
    }

    func replayPending(client: MinutiaClient) async {
        guard let root = try? NotepadStore.notesRoot() else { return }
        let userId = try? await client.supabase.auth.session.user.id.uuidString.lowercased()
        let pending = NotepadStore.pendingDrafts(
            in: root, connectedInstance: client.instance, connectedUserId: userId, excluding: draft?.meetingId)
        for pendingDraft in pending {
            do {
                try await Self.pushStored(meetingId: pendingDraft.meetingId, client: client, root: root)
            } catch {
                Self.logger.error("Notes replay failed for \(pendingDraft.meetingId, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    func signOut() {
        persist()
        cancelTimers()
        hotKey.unregister()
        shortcutAvailable = false
        panel.hide()
        draft = nil
        client = nil
        if let root { NotepadStore.purgeSynced(in: root) }
        root = nil
    }

    nonisolated static func pushStored(meetingId: String, client: MinutiaClient, root: URL) async throws {
        guard var stored = NotepadStore.load(meetingId: meetingId, in: root), stored.needsSync else { return }
        let revision = stored.revision
        try await client.syncCompanionNotes(meetingId: stored.meetingId, text: stored.text)
        stored.markSynced(revision: revision)
        try? NotepadStore.save(stored, in: root)
    }

    private func shortcutPressed() {
        switch NotepadPanelAction.forShortcut(visible: panel.isVisible, isKey: panel.isKey) {
        case .showAndFocus, .focus: panel.show(focus: true)
        case .hide: panel.hide()
        }
    }

    private func persist() {
        guard let draft, draft.revision > 0, let root else { return }
        do { try NotepadStore.save(draft, in: root) } catch {
            Self.logger.error("Notes draft save failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func cancelTimers() {
        saveTask?.cancel()
        syncTask?.cancel()
        closeTask?.cancel()
    }

    private func scheduleSync(after delay: TimeInterval) {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.1) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.syncIfDue()
        }
    }

    private func syncIfDue() async {
        guard draft?.needsSync == true, !inFlight else { return }
        let now = Date()
        if NotepadSyncPolicy.shouldSync(
            needsSync: true, inFlight: inFlight, lastEditAt: lastEditAt,
            firstUnsyncedEditAt: firstUnsyncedEditAt, now: now) {
            await push()
        } else {
            let idleLeft = lastEditAt.map { NotepadSyncPolicy.idleDelay - now.timeIntervalSince($0) } ?? 0
            let maxLeft = firstUnsyncedEditAt.map { NotepadSyncPolicy.maxDelay - now.timeIntervalSince($0) } ?? 0
            scheduleSync(after: min(idleLeft, maxLeft))
        }
    }

    @discardableResult
    private func push() async -> Bool {
        guard !inFlight, let draft, draft.needsSync, let client else { return false }
        inFlight = true
        defer { inFlight = false }
        let revision = draft.revision
        do {
            try await client.syncCompanionNotes(meetingId: draft.meetingId, text: draft.text)
        } catch {
            Self.logger.error("Notes sync failed: \(String(describing: error), privacy: .public)")
            lastAttemptFailed = true
            attempts += 1
            scheduleSync(after: NotepadSyncPolicy.retryDelay(attempt: attempts))
            return false
        }
        guard self.draft?.meetingId == draft.meetingId else { return true }
        self.draft?.markSynced(revision: revision)
        attempts = 0
        lastAttemptFailed = false
        firstUnsyncedEditAt = self.draft?.needsSync == true ? Date() : nil
        if let current = self.draft, let root {
            if ended, !current.needsSync {
                NotepadStore.remove(meetingId: current.meetingId, in: root)
            } else {
                persist()
                if current.needsSync { scheduleSync(after: NotepadSyncPolicy.idleDelay) }
            }
        }
        return true
    }
}
