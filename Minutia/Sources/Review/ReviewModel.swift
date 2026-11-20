import Foundation

struct RowEdit: Equatable {
    var ownerUserId: UUID?
    var dueDate: DueDateChange = .leave
}

enum ReviewScreen: Equatable {
    case transcribing(elapsed: Duration?), finding, slow, ready, none(moreOnWeb: Int)
    case nobodySpoke, notAvailable, transcriptionFailed, findingFailed
    case done(kept: Int, updated: Int), partlyDone(kept: Int, left: Int)

    var message: String {
        switch self {
        case .transcribing: ReviewCopy.transcribing
        case .finding: ReviewCopy.finding
        case .slow: ReviewCopy.slow
        case .none(let more): more > 0 ? "\(ReviewCopy.none) \(ReviewCopy.moreOnWeb(more))" : ReviewCopy.none
        case .nobodySpoke: ReviewCopy.nobody
        case .transcriptionFailed: ReviewCopy.transcriptionFailed
        case .findingFailed: ReviewCopy.findingFailed
        case .done(let kept, let updated): ReviewCopy.done(kept: kept, updated: updated)
        case .partlyDone(let kept, let left): ReviewCopy.partly(kept: kept, left: left)
        case .ready, .notAvailable: ""
        }
    }
}

enum RowState: Equatable {
    case idle, saving, saved, gone(ReviewCopy.Note), failed
}

struct ReviewModel: Equatable {
    static let confident = 0.8
    static let shownNewRows = 5
    static let slowAfter: TimeInterval = 120
    static let failedAfter: TimeInterval = 600
    static let elapsedAfter: TimeInterval = 20

    var meetingId: UUID?
    var statusAt: Date?
    var aliases: [UUID: UUID] = [:]
    var screen: ReviewScreen
    var newRows: [ReviewRow] = []
    var updateRows: [ReviewRow] = []
    var moreOnWeb = 0
    var readOnly = false
    var signedOut = false
    var selection: Set<UUID> = []
    var edits: [UUID: RowEdit] = [:]
    var rowState: [UUID: RowState] = [:]
    var listUpdated = false

    var lessSureIndex: Int? { newRows.firstIndex { $0.confidence < Self.confident } }

    var keepCount: Int {
        (newRows + updateRows).filter {
            selection.contains($0.id) && [.idle, .failed].contains(rowState[$0.id] ?? .idle)
        }.count
    }

    static func normalizedTitle(_ title: String) -> String {
        let collapsed = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.replacingOccurrences(of: #"[\p{P}\s]+$"#, with: "", options: .regularExpression)
    }

    static func from(_ meeting: ReviewMeeting, now: Date, previous: ReviewModel?) -> ReviewModel {
        let previous = previous.flatMap { $0.meetingId == meeting.meetingId ? $0 : nil }
        var model = screen(for: meeting, now: now, previous: previous)
        model.meetingId = meeting.meetingId
        model.statusAt = meeting.statusAt
        return model
    }

    private static func screen(for meeting: ReviewMeeting, now: Date, previous: ReviewModel?) -> ReviewModel {
        let transcribingFor = meeting.endedAt.map { now.timeIntervalSince($0) } ?? 0
        let findingFor = meeting.statusAt.map { now.timeIntervalSince($0) } ?? 0
        switch (meeting.transcriptionStatus, meeting.suggestionsStatus, meeting.suggestionsReason) {
        case (nil, _, _) where meeting.rows.isEmpty:
            return ReviewModel(screen: .notAvailable)
        case (_, nil, _):
            return ReviewModel(screen: .notAvailable)
        case ("failed", _, _):
            return ReviewModel(screen: .transcriptionFailed)
        case ("pending", _, _), ("processing", _, _):
            if transcribingFor > slowAfter { return ReviewModel(screen: .slow) }
            let elapsed: Duration? = transcribingFor > elapsedAfter ? .seconds(Int(transcribingFor)) : nil
            return ReviewModel(screen: .transcribing(elapsed: elapsed))
        case (_, "pending", _):
            if findingFor > failedAfter { return ReviewModel(screen: .findingFailed) }
            return ReviewModel(screen: findingFor > slowAfter ? .slow : .finding)
        case (_, "failed", _):
            return ReviewModel(screen: .findingFailed)
        case (_, "skipped", "no_content"):
            return ReviewModel(screen: .nobodySpoke)
        case (_, "ready", _):
            return ready(meeting, previous: previous)
        default:
            return ReviewModel(screen: .notAvailable)
        }
    }

    private static func ready(_ meeting: ReviewMeeting, previous: ReviewModel?) -> ReviewModel {
        let carried = (previous?.newRows ?? []) + (previous?.updateRows ?? [])
        let resolved = carried.filter { (previous?.rowState[$0.id] ?? .idle).isResolved }
        let resolvedIds = Set(resolved.map(\.id))
        let fresh = meeting.rows.filter { !resolvedIds.contains($0.id) }
        let all = fresh.filter { $0.type == "new_item" }
        let ordered = all.filter { $0.confidence >= confident } + all.filter { $0.confidence < confident }
        let shownNew = Array(ordered.prefix(shownNewRows))
        let updates = fresh.filter { $0.type == "status_update" }
        let more = meeting.webOnlyCount + ordered.count - shownNew.count
        let keptNew = resolved.filter { $0.type == "new_item" }, keptUpdates = resolved.filter { $0.type == "status_update" }
        guard !(shownNew + updates + resolved).isEmpty else {
            return ReviewModel(screen: .none(moreOnWeb: more), moreOnWeb: more, readOnly: !meeting.reviewer)
        }
        var model = ReviewModel(
            screen: .ready, newRows: keptNew + shownNew, updateRows: keptUpdates + updates, moreOnWeb: more,
            readOnly: !meeting.reviewer)
        for row in resolved {
            model.rowState[row.id] = previous?.rowState[row.id]
            if previous?.selection.contains(row.id) == true { model.selection.insert(row.id) }
            model.edits[row.id] = previous?.edits[row.id]
        }
        let unresolved = carried.filter { !resolvedIds.contains($0.id) }
        var earlier = Dictionary(grouping: unresolved, by: { normalizedTitle($0.title) })
        var aliases = previous?.aliases ?? [:]
        for row in shownNew + updates {
            let key = normalizedTitle(row.title)
            if let previous, let old = earlier[key]?.first {
                earlier[key]?.removeFirst()
                if previous.selection.contains(old.id) { model.selection.insert(row.id) }
                model.edits[row.id] = previous.edits[old.id]
                model.rowState[row.id] = previous.rowState[old.id]
                aliases[row.id] = nil
                if old.id != row.id {
                    aliases = aliases.mapValues { $0 == old.id ? row.id : $0 }
                    aliases[old.id] = row.id
                }
            } else if earlier[key] == nil && row.confidence >= confident {
                model.selection.insert(row.id)
            }
        }
        model.aliases = aliases.filter { model.rowState[$0.value] == .saving }
        if model.readOnly { model.selection = [] }
        if let previous {
            let present = Set((shownNew + updates).map { normalizedTitle($0.title) })
            let rerun = previous.statusAt != meeting.statusAt
            let vanished = unresolved.contains { !present.contains(normalizedTitle($0.title)) }
            model.listUpdated = rerun ? vanished : previous.listUpdated
        }
        model.settle()
        return model
    }

    mutating func apply(_ result: ReviewSaveResult, to shownId: UUID) {
        let id = aliases[shownId] ?? shownId
        switch result {
        case .saved: rowState[id] = .saved
        case .alreadyReviewed, .cannotKeepDuplicate: rowState[id] = .gone(.alreadyReviewed)
        case .alreadyInState: rowState[id] = .gone(.alreadyDone)
        case .suggestionGone, .itemGone: rowState[id] = .gone(.itemRemoved)
        case .notReviewer, .notAMember:
            readOnly = true
            selection = []
            rowState[id] = .idle
        case .signedOut:
            signedOut = true
            rowState[id] = .failed
        case .invalidRequest, .retryable: rowState[id] = .failed
        }
        settle()
    }

    private mutating func settle() {
        guard screen == .ready || screen.isPartlyDone else { return }
        let shown = newRows + updateRows
        let open = shown.filter { !(rowState[$0.id] ?? .idle).isResolved }
        guard open.count < shown.count, !open.contains(where: { selection.contains($0.id) }) else { return }
        let kept = newRows.filter { selection.contains($0.id) && rowState[$0.id] == .saved }.count
        let updated = updateRows.filter { selection.contains($0.id) && rowState[$0.id] == .saved }.count
        screen = open.isEmpty ? .done(kept: kept, updated: updated) : .partlyDone(kept: kept + updated, left: open.count)
    }

    var doneLine: String { screen.message }
}

private extension RowState {
    var isResolved: Bool {
        switch self { case .saved, .gone: true; default: false }
    }
}

private extension ReviewScreen {
    var isPartlyDone: Bool { if case .partlyDone = self { true } else { false } }
}
