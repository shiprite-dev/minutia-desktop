import Foundation

enum DueChoice: CaseIterable {
    case today, tomorrow, nextWeek, none

    var title: String {
        switch self {
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .nextWeek: "Next week"
        case .none: "No date"
        }
    }
}

struct ReviewClock {
    var now: @MainActor () -> Date
    var sleep: @MainActor (TimeInterval) async -> Void

    static let live = ReviewClock(now: Date.init, sleep: { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })
}

struct ReviewNotice: Equatable {
    let title: String
    let meetingId: UUID
}

enum ReviewButton: Equatable {
    case keep(Int), skipRest, openRecap, tryAgain, reviewRest, finish

    var title: String {
        switch self {
        case .keep(let n): n > 0 ? ReviewCopy.keep(n) : "Keep"
        case .skipRest: ReviewCopy.skipRest
        case .openRecap: ReviewCopy.openRecap
        case .tryAgain: ReviewCopy.tryAgain
        case .reviewRest: "Review the rest"
        case .finish: "Done"
        }
    }
}

struct ReviewButtonState: Equatable {
    let button: ReviewButton
    let enabled: Bool
    var title: String { button.title }
}

struct ReviewRowItem: Equatable, Identifiable {
    let id: UUID
    let title: String
    let owner: String?
    let due: String?
    let note: String?
    let failed: Bool
    let checked: Bool
    let editable: Bool
}

struct ReviewGroup: Equatable {
    let title: String
    let rows: [ReviewRowItem]
    let lessSureAt: Int?
}

struct ReviewQueueRow: Equatable, Identifiable {
    let id: UUID
    let title: String
    let count: Int
}

/// Owns one meeting's review: polls the server while the AI works, sends each keep or skip in
/// order, and keeps the queue that lights the menu-bar dot. The reducer decides what is shown.
@MainActor
final class ReviewController: ObservableObject {
    static let workingPoll: TimeInterval = 3
    static let readyPoll: TimeInterval = 30
    static let pollLimit: TimeInterval = 15 * 60
    static let doneHold: TimeInterval = 4

    @Published private(set) var model: ReviewModel?
    @Published private(set) var queue: [ReviewMeeting] = []
    @Published private(set) var meeting: ReviewMeeting?
    @Published private(set) var saving = false
    @Published private(set) var hidden = false
    private(set) var me: UUID?

    var announce: (String) -> Void = { _ in }
    var onSignedOut: () -> Void = {}

    private let client: @MainActor () -> MinutiaClient?
    private let clock: ReviewClock
    private let notify: (ReviewNotice) -> Void
    private let defaults: UserDefaults
    private(set) var panelOpen = false
    private var retrying = false
    private var generation = 0
    private var pollStarted = Date.distantPast
    private var pollTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private static let notifiedKey = "review.notifiedMeetings"
    private static let accountKey = "review.notifiedAccount"

    init(
        client: @escaping @MainActor () -> MinutiaClient?, clock: ReviewClock = .live, defaults: UserDefaults = .standard,
        notify: @escaping (ReviewNotice) -> Void
    ) {
        self.client = client
        self.clock = clock
        self.defaults = defaults
        self.notify = notify
    }

    var hasDot: Bool { !queue.isEmpty }
    var shown: ReviewModel? { hidden ? nil : model }

    @discardableResult
    func start(meetingId: UUID) -> Task<Void, Never> {
        closeTask?.cancel()
        closeTask = nil
        hidden = false
        pollStarted = clock.now()
        if model?.meetingId != meetingId {
            let queued = queue.first { $0.meetingId == meetingId }
            meeting = queued
            show(queued.map { ReviewModel.from($0, now: clock.now(), previous: nil) }
                ?? ReviewModel(meetingId: meetingId, screen: .transcribing(elapsed: nil)))
        }
        return Task { await refresh() }
    }

    /// Closing while the AI still works only hides the review; it keeps checking so the
    /// "We'll let you know" promise holds.
    func close() {
        guard let model, Self.working(model.screen) else { return dismiss() }
        closeTask?.cancel()
        closeTask = nil
        hidden = true
    }

    private func dismiss() {
        pollTask?.cancel()
        closeTask?.cancel()
        closeTask = nil
        hidden = false
        model = nil
        meeting = nil
    }

    /// A different account (or none) starts with no posted meetings, so its first queue load is quiet.
    func reset(account: String? = nil) {
        if defaults.string(forKey: Self.accountKey) != account {
            defaults.removeObject(forKey: Self.notifiedKey)
            defaults.set(account, forKey: Self.accountKey)
        }
        generation += 1
        saving = false
        retrying = false
        dismiss()
        queue = []
        me = nil
    }

    @discardableResult
    func setPanelOpen(_ open: Bool) -> Task<Void, Never>? {
        panelOpen = open
        guard open else {
            schedulePoll()
            return nil
        }
        return Task {
            await refresh()
            await refreshQueue()
        }
    }

    func refresh() async {
        guard let id = model?.meetingId, let client = client() else { return }
        let generation = generation
        do {
            let response = try await client.reviewQueue(meetingId: id)
            guard generation == self.generation, model?.meetingId == id else { return }
            me = response.me
            guard let fetched = response.meetings.first(where: { $0.meetingId == id }) else { throw ReviewQueueError.meetingGone }
            meeting = fetched
            merge(fetched)
            if !saving, !retrying { show(ReviewModel.from(fetched, now: clock.now(), previous: model)) }
        } catch ReviewQueueError.meetingGone {
            guard generation == self.generation, !saving else { return }
            queue.removeAll { $0.meetingId == id }
            if model?.meetingId == id { dismiss() }
            return
        } catch ReviewQueueError.signedOut {
            guard generation == self.generation else { return }
            model?.signedOut = true
            onSignedOut()
        } catch {}
        schedulePoll()
    }

    func refreshQueue() async {
        guard let client = client() else { return }
        let generation = generation
        do {
            let response = try await client.reviewQueue(meetingId: nil)
            guard generation == self.generation else { return }
            me = response.me
            queue = Self.sorted(response.meetings.filter(Self.waits))
            let firstLoad = defaults.stringArray(forKey: Self.notifiedKey) == nil
            if firstLoad { defaults.set([String](), forKey: Self.notifiedKey) }
            for meeting in queue { noticeOnce(meeting, post: !panelOpen && !firstLoad) }
        } catch ReviewQueueError.signedOut {
            guard generation == self.generation else { return }
            onSignedOut()
        } catch {}
    }

    func toggle(_ id: UUID) {
        guard var model, !model.readOnly, !saving, Self.isOpen(model.rowState[id]) else { return }
        if model.selection.contains(id) { model.selection.remove(id) } else { model.selection.insert(id) }
        self.model = model
    }

    func setOwner(_ id: UUID, to owner: UUID?) {
        guard model?.readOnly == false else { return }
        model?.edits[id, default: RowEdit()].ownerUserId = owner
    }

    func setDue(_ id: UUID, to choice: DueChoice) {
        guard model?.readOnly == false else { return }
        model?.edits[id, default: RowEdit()].dueDate = Self.dueChange(choice, now: clock.now())
    }

    func keep() async {
        guard let model else { return }
        await save(.accept, shownRows.filter { model.selection.contains($0.id) && Self.isOpen(model.rowState[$0.id]) }.map(\.id))
    }

    func retry(_ id: UUID) async {
        guard model?.rowState[id] == .failed else { return }
        await save(.accept, [id])
    }

    func skipRest() async {
        guard let model else { return }
        await save(.reject, skippable(model).map(\.id))
    }

    func tryAgain() async {
        guard !retrying, let failed = model, let id = failed.meetingId, let client = client() else { return }
        let transcription = failed.screen == .transcriptionFailed
        guard transcription || (failed.screen == .findingFailed && meeting?.reviewer == true) else { return }
        let generation = generation
        retrying = true
        show(ReviewModel(meetingId: id, screen: transcription ? .transcribing(elapsed: nil) : .finding))
        do {
            if transcription {
                try await client.requestTranscription(meetingId: id.uuidString.lowercased(), expectedSegments: nil)
            } else {
                try await client.regenerateSuggestions(meetingId: id)
            }
        } catch {
            guard generation == self.generation else { return }
            retrying = false
            if model?.meetingId == id { show(failed) }
            if case MinutiaClientError.signedOut = error { onSignedOut() }
            return
        }
        guard generation == self.generation else { return }
        retrying = false
        pollStarted = clock.now()
        await refresh()
    }

    func reviewRest() {
        guard let meeting else { return }
        show(ReviewModel.from(meeting, now: clock.now(), previous: nil))
    }

    private func save(_ action: ReviewAction, _ ids: [UUID]) async {
        guard !saving, !ids.isEmpty, let current = model, !current.readOnly, let meetingId = current.meetingId,
              let client = client() else { return }
        let generation = generation
        saving = true
        pollTask?.cancel()
        for id in ids { model?.rowState[id] = .saving }
        for (index, id) in ids.enumerated() {
            let edit = action == .accept ? model?.edits[id] : nil
            let result = await client.review(
                meetingId: meetingId, suggestionId: id, action: action, ownerUserId: edit?.ownerUserId,
                dueDate: edit?.dueDate ?? .leave)
            guard generation == self.generation else { return }
            guard var next = model, next.meetingId == meetingId else { saving = false; return }
            next.apply(result, to: id)
            if result == .signedOut {
                for rest in ids[(index + 1)...] { next.rowState[rest] = .failed }
                show(next)
                onSignedOut()
                break
            }
            show(next)
        }
        saving = false
        await refresh()
    }

    private func show(_ next: ReviewModel) {
        let before = model
        model = next
        let line = spoken(next)
        let sameScreen = before?.meetingId == next.meetingId && before?.readOnly == next.readOnly && spoken(before) == line
        if !hidden, !sameScreen, let line { announce(line) }
        if next.screen == .ready, !next.readOnly, let meeting, meeting.meetingId == next.meetingId {
            noticeOnce(meeting, post: !panelOpen || hidden)
        }
        if hidden, !Self.working(next.screen) { return dismiss() }
        if case .done = next.screen {
            if closeTask == nil { scheduleClose() }
        } else {
            closeTask?.cancel()
            closeTask = nil
        }
    }

    private func noticeOnce(_ meeting: ReviewMeeting, post: Bool) {
        var notified = Set((defaults.stringArray(forKey: Self.notifiedKey) ?? []).compactMap(UUID.init))
        guard Self.waits(meeting), notified.insert(meeting.meetingId).inserted else { return }
        defaults.set(notified.map(\.uuidString), forKey: Self.notifiedKey)
        if post { notify(ReviewNotice(title: ReviewCopy.notificationTitle(count: meeting.rows.count, series: meeting.seriesName), meetingId: meeting.meetingId)) }
    }

    private func scheduleClose() {
        let generation = generation
        closeTask = Task { [weak self, clock] in
            await clock.sleep(Self.doneHold)
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            closeTask = nil
            dismiss()
        }
    }

    private func schedulePoll() {
        pollTask?.cancel()
        guard let interval = pollInterval else { return }
        pollTask = Task { [weak self, clock] in
            await clock.sleep(interval)
            guard let self, !Task.isCancelled else { return }
            Task { await self.refresh() }
        }
    }

    private var pollInterval: TimeInterval? {
        switch model?.screen {
        case let screen? where Self.working(screen):
            clock.now().timeIntervalSince(pollStarted) < Self.pollLimit ? Self.workingPoll : nil
        case .ready:
            panelOpen && !saving ? Self.readyPoll : nil
        default:
            nil
        }
    }

    private func merge(_ fetched: ReviewMeeting) {
        queue.removeAll { $0.meetingId == fetched.meetingId }
        if Self.waits(fetched) { queue = Self.sorted(queue + [fetched]) }
    }

    private func spoken(_ model: ReviewModel?) -> String? {
        guard let model else { return nil }
        switch model.screen {
        case .transcribing: return ReviewCopy.transcribing
        case .notAvailable: return nil
        case .ready:
            return model.readOnly
                ? ReviewCopy.readOnly
                : ReviewCopy.notificationTitle(count: meeting?.rows.count ?? 0, series: meeting?.seriesName ?? "")
        default: return model.screen.message
        }
    }

    private nonisolated static func waits(_ meeting: ReviewMeeting) -> Bool { meeting.reviewer && !meeting.rows.isEmpty }

    private nonisolated static func sorted(_ meetings: [ReviewMeeting]) -> [ReviewMeeting] {
        meetings.sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
    }

    private nonisolated static func working(_ screen: ReviewScreen) -> Bool {
        switch screen {
        case .transcribing, .finding, .slow: true
        default: false
        }
    }

    private nonisolated static func isOpen(_ state: RowState?) -> Bool { [.idle, .failed].contains(state ?? .idle) }

    nonisolated static func dueChange(_ choice: DueChoice, now: Date, calendar: Calendar = .current) -> DueDateChange {
        let days: Int
        switch choice {
        case .none: return .clear
        case .today: days = 0
        case .tomorrow: days = 1
        case .nextWeek: days = 7
        }
        let day = calendar.dateComponents([.year, .month, .day], from: calendar.date(byAdding: .day, value: days, to: now)!)
        return .set(String(format: "%04d-%02d-%02d", day.year!, day.month!, day.day!))
    }
}

// MARK: - What the panel shows

extension ReviewController {
    private var shownRows: [ReviewRow] { (model?.newRows ?? []) + (model?.updateRows ?? []) }

    private func skippable(_ model: ReviewModel) -> [ReviewRow] {
        shownRows.filter { !model.selection.contains($0.id) && (model.rowState[$0.id] ?? .idle) == .idle }
    }

    private func skipped(_ id: UUID) -> Bool { model?.rowState[id] == .saved && model?.selection.contains(id) == false }

    var title: String { meeting?.seriesName ?? "" }

    var subtitle: String {
        guard let model else { return "" }
        let day = meeting?.endedAt.map { Self.relativeDay($0, now: clock.now()) }.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
        guard model.screen == .ready, !model.readOnly else { return day }
        let left = shownRows.filter { Self.isOpen(model.rowState[$0.id]) }.count
        return [day, "\(left) to review"].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var readOnlyNote: String? { model?.readOnly == true ? ReviewCopy.readOnly : nil }

    var moreOnWeb: String? {
        guard let more = model?.moreOnWeb, more > 0 else { return nil }
        return ReviewCopy.moreOnWeb(more)
    }

    var buttons: [ReviewButtonState] {
        guard let model else { return [] }
        let recap = ReviewButtonState(button: .openRecap, enabled: true)
        let finish = ReviewButtonState(button: .finish, enabled: true)
        switch model.screen {
        case .ready where model.readOnly:
            return [recap]
        case .ready:
            return [
                ReviewButtonState(button: .keep(model.keepCount), enabled: !saving && model.keepCount > 0),
                ReviewButtonState(button: .skipRest, enabled: !saving && !skippable(model).isEmpty),
                recap,
            ]
        case .transcriptionFailed:
            return [ReviewButtonState(button: .tryAgain, enabled: !retrying), finish, recap]
        case .findingFailed where meeting?.reviewer == true:
            return [ReviewButtonState(button: .tryAgain, enabled: !retrying), finish, recap]
        case .partlyDone:
            return [ReviewButtonState(button: .reviewRest, enabled: true), finish, recap]
        case .transcribing, .finding, .slow:
            return []
        default:
            return [finish, recap]
        }
    }

    var groups: [ReviewGroup] {
        guard let model, model.screen == .ready else { return [] }
        let new = model.newRows.filter { !skipped($0.id) }
        let updates = model.updateRows.filter { !skipped($0.id) }
        var groups: [ReviewGroup] = []
        if !new.isEmpty {
            groups.append(ReviewGroup(
                title: ReviewCopy.groupNew, rows: new.map { item($0, model) },
                lessSureAt: new.firstIndex { $0.confidence < ReviewModel.confident }))
        }
        if !updates.isEmpty {
            groups.append(ReviewGroup(title: ReviewCopy.groupUpdates, rows: updates.map { item($0, model) }, lessSureAt: nil))
        }
        return groups
    }

    var ownerChoices: [ReviewMember] {
        let members = meeting?.members ?? []
        return members.filter { $0.id == me }.map { ReviewMember(id: $0.id, name: "Me") } + members.filter { $0.id != me }
    }

    var queueRows: [ReviewQueueRow] {
        queue.map { meeting in
            let day = meeting.endedAt.map { Self.relativeDay($0, now: clock.now()) } ?? ""
            return ReviewQueueRow(
                id: meeting.meetingId, title: ReviewCopy.queueRow(series: meeting.seriesName, day: day, count: meeting.rows.count),
                count: meeting.rows.count)
        }
    }

    var waitingLine: String? { queueRows.first?.title }

    private func item(_ row: ReviewRow, _ model: ReviewModel) -> ReviewRowItem {
        let state = model.rowState[row.id] ?? .idle
        let isUpdate = row.type == "status_update"
        return ReviewRowItem(
            id: row.id, title: Self.rowTitle(row),
            owner: isUpdate ? nil : ownerName(row, model.edits[row.id]),
            due: isUpdate ? nil : dueName(row, model.edits[row.id]),
            note: Self.note(state), failed: state == .failed, checked: model.selection.contains(row.id),
            editable: !model.readOnly && !saving && Self.isOpen(state))
    }

    private func ownerName(_ row: ReviewRow, _ edit: RowEdit?) -> String {
        guard let owner = edit?.ownerUserId ?? row.ownerUserId else { return row.ownerName.isEmpty ? "No owner" : row.ownerName }
        if owner == me { return "Me" }
        return meeting?.members.first { $0.id == owner }?.name ?? row.ownerName
    }

    private func dueName(_ row: ReviewRow, _ edit: RowEdit?) -> String {
        let day: String?
        switch edit?.dueDate ?? .leave {
        case .leave: day = row.dueDate
        case .clear: day = nil
        case .set(let value): day = value
        }
        guard let day else { return DueChoice.none.title }
        let now = clock.now()
        if let choice = [DueChoice.today, .tomorrow, .nextWeek].first(where: { Self.dueChange($0, now: now) == .set(day) }) {
            return choice.title
        }
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd"
        guard let date = parse.date(from: day) else { return day }
        parse.dateFormat = "MMM d"
        return parse.string(from: date)
    }

    nonisolated static func rowTitle(_ row: ReviewRow) -> String {
        guard row.type == "status_update", let number = row.relatedIssueNumber else { return row.title }
        let status = (row.suggestedStatus ?? "").replacingOccurrences(of: "_", with: " ")
        return "#\(number) \(row.relatedIssueTitle ?? row.title) → \(status.prefix(1).uppercased() + status.dropFirst())"
    }

    nonisolated static func note(_ state: RowState) -> String? {
        switch state {
        case .idle: nil
        case .saving: ReviewCopy.saving
        case .saved: "Kept"
        case .gone(let note): note.text
        case .failed: ReviewCopy.couldntSave
        }
    }

    nonisolated static func relativeDay(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "yesterday" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = days < 7 ? "EEEE" : "MMM d"
        return formatter.string(from: date)
    }
}
