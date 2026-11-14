import SwiftUI

struct NotepadView: View {
    @ObservedObject var controller: NotepadController
    @FocusState private var focused: Bool

    private static let placeholder = "Jot notes as the meeting runs. Minutia merges them with the transcript when you stop."

    var body: some View {
        let text = controller.draft?.text ?? ""
        let status = controller.saveState.label
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { text }, set: { controller.update($0) }))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .defaultFocus($focused, true)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .accessibilityLabel("Meeting notes")
                if text.isEmpty {
                    Text(Self.placeholder)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            HStack {
                Text(status)
                    .accessibilityLabel("Notes status")
                    .accessibilityValue(status)
                Spacer()
                if controller.shortcutAvailable {
                    Text("⌥⌘N").accessibilityHidden(true)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}
