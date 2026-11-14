import Foundation

enum NotepadSyncPolicy {
    static let idleDelay: TimeInterval = 2
    static let maxDelay: TimeInterval = 10

    static func shouldSync(
        needsSync: Bool, inFlight: Bool, lastEditAt: Date?, firstUnsyncedEditAt: Date?, now: Date
    ) -> Bool {
        guard needsSync, !inFlight else { return false }
        guard let lastEditAt, let firstUnsyncedEditAt else { return true }
        return now.timeIntervalSince(lastEditAt) >= idleDelay
            || now.timeIntervalSince(firstUnsyncedEditAt) >= maxDelay
    }

    static func retryDelay(attempt: Int) -> TimeInterval {
        min(60, 2 * pow(2, Double(max(attempt, 1) - 1)))
    }
}

enum NotepadSaveState: Equatable {
    case empty, saving, synced, savedLocally

    var label: String {
        switch self {
        case .empty: ""
        case .saving: "Saving…"
        case .synced: "Saved to meeting"
        case .savedLocally: "Saved on this Mac"
        }
    }

    static func of(draft: NotepadDraft?, lastAttemptFailed: Bool) -> NotepadSaveState {
        guard let draft, draft.revision > 0 else { return .empty }
        if !draft.needsSync { return .synced }
        return lastAttemptFailed ? .savedLocally : .saving
    }
}

enum NotepadPanelAction: Equatable {
    case showAndFocus, focus, hide

    static func forShortcut(visible: Bool, isKey: Bool) -> NotepadPanelAction {
        guard visible else { return .showAndFocus }
        return isKey ? .hide : .focus
    }
}

enum NotesFlushOutcome: Equatable { case flushed, failed, timedOut }

enum NotepadFinalize {
    static let flushTimeout: TimeInterval = 5

    static func flushThenTranscribe(
        flushTimeout: TimeInterval = flushTimeout,
        flush: @escaping @Sendable () async throws -> Void,
        requestTranscription: () async throws -> Void
    ) async throws -> NotesFlushOutcome {
        let outcome: NotesFlushOutcome
        do {
            try await withTimeout(seconds: flushTimeout, flush)
            outcome = .flushed
        } catch is TimeoutError {
            outcome = .timedOut
        } catch {
            outcome = .failed
        }
        try await requestTranscription()
        return outcome
    }
}
