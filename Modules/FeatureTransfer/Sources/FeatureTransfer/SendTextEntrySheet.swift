import SwiftUI
import DesignSystem

public struct SendTextEntrySheet: View {
    @State private var draft: String
    @State private var hasAttemptedSubmit = false
    @FocusState private var isEditorFocused: Bool

    private let onStage: @MainActor (String) -> Void
    private let onCancel: @MainActor () -> Void

    public init(
        initialText: String = "",
        onStage: @escaping @MainActor (String) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self._draft = State(initialValue: initialText)
        self.onStage = onStage
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Send Text")
                .font(Typography.title2.weight(.bold))

            Text("LocalDrop saves this text as a temporary .txt file before sending it.")
                .font(Typography.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $draft)
                .font(Typography.body)
                .frame(minHeight: 220)
                .padding(Spacing.xs)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle.continuous(Radius.lg))
                .overlay {
                    RoundedRectangle.continuous(Radius.lg)
                        .strokeBorder(validationTint, lineWidth: 1)
                }
                .focused($isEditorFocused)

            Text(validationMessage)
                .font(Typography.caption1)
                .foregroundStyle(trimmedDraft.isEmpty && hasAttemptedSubmit ? SemanticColor.destructive : .secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                Button("Stage Text") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedDraft.isEmpty)
            }
        }
        .padding(Spacing.xl)
        .frame(minWidth: 520, minHeight: 360)
        .onAppear {
            isEditorFocused = true
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationMessage: String {
        if trimmedDraft.isEmpty {
            return hasAttemptedSubmit ? "Enter text to stage a .txt file." : "Paste or type text to stage a .txt file."
        }
        return "Your text will be staged as a plain-text file on the Send screen."
    }

    private var validationTint: Color {
        trimmedDraft.isEmpty && hasAttemptedSubmit ? SemanticColor.destructive : AccentColor.primary.opacity(0.2)
    }

    private func submit() {
        guard trimmedDraft.isEmpty == false else {
            hasAttemptedSubmit = true
            return
        }
        onStage(trimmedDraft)
    }
}
