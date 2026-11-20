import SwiftUI

/// The post-meeting review in the menu panel. Every word and choice comes from `ReviewController`;
/// this view only lays it out.
struct ReviewView: View {
    @ObservedObject var review: ReviewController
    let onOpenRecap: (UUID) -> Void
    @FocusState private var focused: UUID?
    @Environment(\.motionReduced) private var reduceMotion

    var body: some View {
        if let model = review.shown {
            VStack(alignment: .leading, spacing: 0) {
                header
                if model.listUpdated { ReviewNote(text: ReviewCopy.Note.listUpdated.text) }
                content(model)
                footer(model)
            }
            .frame(width: Space.panelWidth, alignment: .leading)
            .animation(Motion.resolved(Motion.settle, reduce: reduceMotion), value: model.screen)
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.space) {
                guard let focused else { return .ignored }
                review.toggle(focused)
                return .handled
            }
            .onKeyPress(.return) {
                guard review.buttons.first?.button == .keep(model.keepCount), model.keepCount > 0 else { return .ignored }
                Task { await review.keep() }
                return .handled
            }
            .onKeyPress(.escape) {
                review.close()
                return .handled
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(review.title).font(Typo.bodyStrong).lineLimit(1)
                Text(review.subtitle).font(Typo.caption).foregroundStyle(Brand.ink3)
            }
            Spacer()
            Button(action: review.close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle())
            .accessibilityLabel("Close review")
        }
        .padding(EdgeInsets(top: Space.x3, leading: 14, bottom: Space.x2, trailing: Space.x2))
    }

    @ViewBuilder
    private func content(_ model: ReviewModel) -> some View {
        switch model.screen {
        case .transcribing(let elapsed):
            ReviewSteps(transcribing: true, elapsed: elapsed)
            ReviewSkeleton()
        case .finding:
            ReviewSteps(transcribing: false, elapsed: nil)
            ReviewSkeleton()
        case .slow:
            ReviewSteps(transcribing: model.meetingId != nil && review.meeting?.transcriptionStatus != "completed", elapsed: nil)
            ReviewNote(text: ReviewCopy.slow)
        case .ready:
            rows
        case .done, .partlyDone, .none, .nobodySpoke, .notAvailable, .transcriptionFailed, .findingFailed:
            ReviewEnd(screen: model.screen, moreOnWeb: review.moreOnWeb, onMore: openRecap)
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(review.groups, id: \.title) { group in
                ReviewSection(title: group.title)
                ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                    if index == group.lessSureAt { ReviewDivider(title: ReviewCopy.lessSure) }
                    ReviewRowView(
                        row: row, owners: review.ownerChoices, focused: focused == row.id,
                        onToggle: { review.toggle(row.id) },
                        onOwner: { review.setOwner(row.id, to: $0) },
                        onDue: { review.setDue(row.id, to: $0) },
                        onRetry: { Task { await review.retry(row.id) } })
                        .focusable()
                        .focused($focused, equals: row.id)
                }
            }
            if let more = review.moreOnWeb {
                Button(more, action: openRecap).buttonStyle(ReviewLinkStyle()).padding(.horizontal, Space.x2).padding(.vertical, 6)
            }
            if let note = review.readOnlyNote { ReviewNote(text: note) }
        }
        .padding(EdgeInsets(top: Space.x1, leading: 6, bottom: 6, trailing: 6))
        .onAppear { focused = review.groups.first?.rows.first?.id }
    }

    @ViewBuilder
    private func footer(_ model: ReviewModel) -> some View {
        let buttons = review.buttons
        switch model.screen {
        case .transcribing, .finding:
            HairlineRule()
            Text("You can close this. We'll let you know.")
                .font(Typo.caption).foregroundStyle(Brand.ink3)
                .padding(EdgeInsets(top: 10, leading: 14, bottom: Space.x3, trailing: 14))
        default:
            if !buttons.isEmpty {
                HairlineRule()
                HStack(spacing: Space.x2) {
                    ForEach(buttons.filter { $0.button != .openRecap }, id: \.title) { state in
                        Button(state.title) { act(state.button) }
                            .buttonStyle(ReviewPillStyle(prominent: state.button == buttons.first?.button && state.button != .reviewRest))
                            .disabled(!state.enabled)
                    }
                    Spacer()
                    if buttons.contains(where: { $0.button == .openRecap }) {
                        Button(ReviewCopy.openRecap, action: openRecap).buttonStyle(ReviewLinkStyle())
                    }
                }
                .padding(EdgeInsets(top: 10, leading: 14, bottom: Space.x3, trailing: 14))
            }
        }
    }

    private func act(_ button: ReviewButton) {
        switch button {
        case .keep: Task { await review.keep() }
        case .skipRest: Task { await review.skipRest() }
        case .tryAgain: Task { await review.tryAgain() }
        case .reviewRest: review.reviewRest()
        case .finish: review.close()
        case .openRecap: openRecap()
        }
    }

    private func openRecap() {
        if let id = review.model?.meetingId { onOpenRecap(id) }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let ids = review.groups.flatMap(\.rows).map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let index = focused.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
        focused = ids[min(ids.count - 1, max(0, index + step))]
        return .handled
    }
}

private struct ReviewRowView: View {
    let row: ReviewRowItem
    let owners: [ReviewMember]
    let focused: Bool
    let onToggle: () -> Void
    let onOwner: (UUID?) -> Void
    let onDue: (DueChoice) -> Void
    let onRetry: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if row.editable || row.note != nil {
                Toggle(isOn: Binding(get: { row.checked }, set: { _ in onToggle() })) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!row.editable)
                    .accessibilityLabel("Keep: \(row.title)")
            }
            VStack(alignment: .leading, spacing: Space.x1) {
                Text(row.title).font(Typo.body).lineLimit(2).help(row.title)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    if let note = row.note {
                        state(note)
                    } else {
                        if let owner = row.owner { chip(owner, editable: row.editable) { ownerMenu } }
                        if let due = row.due { chip(due, editable: row.editable) { dueMenu } }
                    }
                }
            }
        }
        .padding(.horizontal, Space.x2)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(hovered || focused ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 7))
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func state(_ note: String) -> some View {
        if row.failed {
            Button(note, action: onRetry).buttonStyle(.plain).foregroundStyle(Brand.vermilionText)
                .font(Typo.caption).accessibilityHint("Saves this item again")
        } else if note == ReviewCopy.saving {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(note)
            }
            .font(Typo.caption).foregroundStyle(Brand.ink3)
        } else {
            Text(note).font(Typo.caption).foregroundStyle(note == "Kept" ? AnyShapeStyle(Brand.ok) : AnyShapeStyle(Brand.warn))
        }
    }

    @ViewBuilder
    private func chip<Items: View>(_ text: String, editable: Bool, @ViewBuilder items: () -> Items) -> some View {
        if editable {
            Menu(text, content: items)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .font(Typo.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary, lineWidth: 0.5))
                .accessibilityLabel("\(text). Change")
        } else {
            Text(text).font(Typo.caption).foregroundStyle(Brand.ink2)
                .padding(.horizontal, 7).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary, lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private var ownerMenu: some View {
        ForEach(owners, id: \.id) { member in
            Button(member.name) { onOwner(member.id) }
        }
    }

    @ViewBuilder
    private var dueMenu: some View {
        ForEach(DueChoice.allCases, id: \.self) { choice in
            Button(choice.title) { onDue(choice) }
        }
    }
}

private struct ReviewSteps: View {
    let transcribing: Bool
    let elapsed: Duration?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(ReviewCopy.transcribing, now: transcribing, done: !transcribing)
            step(ReviewCopy.finding, now: !transcribing, done: false)
        }
        .padding(EdgeInsets(top: Space.x2, leading: 14, bottom: Space.x1, trailing: 14))
    }

    private func step(_ label: String, now: Bool, done: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if done { Image(systemName: "checkmark").foregroundStyle(Brand.ok) }
                else if now { ProgressView().controlSize(.small) }
                else { Image(systemName: "circle").foregroundStyle(Brand.ink3) }
            }
            .frame(width: 16, height: 16)
            Text(label).foregroundStyle(now ? AnyShapeStyle(.primary) : AnyShapeStyle(Brand.ink3))
            Spacer()
            if now, let elapsed {
                Text(RecordingView.timestamp(TimeInterval(elapsed.components.seconds)))
                    .font(Typo.caption.monospacedDigit()).foregroundStyle(Brand.ink3)
            }
        }
        .font(Typo.body)
        .accessibilityElement(children: .combine)
    }
}

private struct ReviewSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach([0.86, 0.64, 0.74], id: \.self) { width in
                RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.07))
                    .frame(width: (Space.panelWidth - 44) * width, height: 10)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .accessibilityHidden(true)
    }
}

private struct ReviewEnd: View {
    let screen: ReviewScreen
    let moreOnWeb: String?
    let onMore: () -> Void

    var body: some View {
        VStack(spacing: Space.x2) {
            if let kind { ReviewBadge(kind: kind) }
            if !big.isEmpty {
                Text(big).font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let small { Text(small).font(.system(size: 12)).foregroundStyle(Brand.ink3) }
        }
        .frame(maxWidth: .infinity)
        .padding(EdgeInsets(top: 22, leading: 18, bottom: 14, trailing: 18))
        .accessibilityElement(children: .combine)
        if case .none = screen, let moreOnWeb {
            Button(moreOnWeb, action: onMore).buttonStyle(ReviewLinkStyle()).frame(maxWidth: .infinity).padding(.bottom, Space.x3)
        }
    }

    private var kind: ReviewBadge.Kind? {
        switch screen {
        case .notAvailable: nil
        case .nobodySpoke: .dash
        case .transcriptionFailed, .findingFailed: .bang
        default: .check
        }
    }

    private var big: String {
        if case .none = screen { return ReviewCopy.none }
        return screen.message
    }

    private var small: String? {
        switch screen {
        case .done: "On your board now."
        case .partlyDone: "The dot stays until you finish."
        default: nil
        }
    }
}

private struct ReviewBadge: View {
    enum Kind { case check, dash, bang }
    let kind: Kind
    @Environment(\.motionReduced) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        ZStack {
            Circle().fill(fill)
            switch kind {
            case .check:
                CheckShape().trim(from: 0, to: drawn || reduceMotion ? 1 : 0)
                    .stroke(Brand.ok, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 20, height: 20)
            case .dash: Image(systemName: "minus").font(.system(size: 16, weight: .bold)).foregroundStyle(Brand.ink3)
            case .bang: Image(systemName: "exclamationmark").font(.system(size: 16, weight: .bold)).foregroundStyle(Brand.vermilionText)
            }
        }
        .frame(width: 38, height: 38)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: CheckReveal.drawDuration).delay(CheckReveal.delay)) { drawn = true }
        }
    }

    private var fill: AnyShapeStyle {
        switch kind {
        case .check: AnyShapeStyle(Brand.okSoft)
        case .dash: AnyShapeStyle(.primary.opacity(0.06))
        case .bang: AnyShapeStyle(Brand.accentSoft)
        }
    }
}

private struct ReviewSection: View {
    let title: String

    var body: some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.ink3)
            .padding(EdgeInsets(top: Space.x2, leading: Space.x2, bottom: Space.x1, trailing: Space.x2))
            .accessibilityAddTraits(.isHeader)
    }
}

private struct ReviewDivider: View {
    let title: String

    var body: some View {
        HStack(spacing: Space.x2) {
            Text(title).font(.system(size: 11)).foregroundStyle(Brand.ink3)
            HairlineRule()
        }
        .padding(EdgeInsets(top: 6, leading: Space.x2, bottom: 2, trailing: Space.x2))
    }
}

struct ReviewNote: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Brand.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, Space.x2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .padding(EdgeInsets(top: 6, leading: Space.x2, bottom: Space.x1, trailing: Space.x2))
    }
}

private struct ReviewPillStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 11)
            .padding(.vertical, Space.x1)
            .background(prominent ? AnyShapeStyle(Brand.vermilionFill) : AnyShapeStyle(.primary.opacity(configuration.isPressed ? 0.1 : 0.06)),
                        in: RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.45)
            .fixedSize()
    }
}

private struct ReviewLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5))
            .foregroundStyle(Brand.vermilionText)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// One review row: the idle queue entry, or the line that waits under a recording.
struct ReviewQueueLine: View {
    let row: ReviewQueueRow
    var action: (() -> Void)?

    var body: some View {
        let content = HStack(spacing: Space.x2) {
            Text(row.title).font(Typo.body).foregroundStyle(action == nil ? AnyShapeStyle(Brand.ink2) : AnyShapeStyle(.primary))
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Text("\(row.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(Brand.vermilionFill, in: Capsule())
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Space.x2)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        if let action {
            Button(action: action) { content }.buttonStyle(.plain).accessibilityLabel(row.title)
        } else {
            content.accessibilityElement(children: .combine)
        }
    }
}
