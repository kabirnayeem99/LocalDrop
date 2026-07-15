import SwiftUI
import DesignSystem

public struct SendTextEntrySheet: View {
    @State private var draft: String
    @State private var hasAttemptedSubmit = false
    @FocusState private var isEditorFocused: Bool
    @Environment(\.accentTheme) private var accentTheme

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
            Text(FeatureTransferLocalization.resource("sendText.title"))
                .appFont(.text(.title2, .bold))

            Text(FeatureTransferLocalization.resource("sendText.description"))
                .appFont(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $draft)
                .appFont(.body)
                .frame(minHeight: 220)
                .padding(Spacing.xs)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle.continuous(Radius.lg))
                .overlay {
                    RoundedRectangle.continuous(Radius.lg)
                        .strokeBorder(validationTint, lineWidth: 1)
                }
                .focused($isEditorFocused)

            Text(validationMessage)
                .appFont(.caption1)
                .foregroundStyle(trimmedDraft.isEmpty && hasAttemptedSubmit ? SemanticColor.destructive : .secondary)

            HStack {
                Spacer()
                Button(FeatureTransferLocalization.resource("general.cancel")) {
                    onCancel()
                }
                Button(FeatureTransferLocalization.resource("sendText.stageText")) {
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
            return hasAttemptedSubmit
                ? FeatureTransferLocalization.string(forKey: "sendText.validationEmpty")
                : FeatureTransferLocalization.string(forKey: "sendText.validationHint")
        }
        return FeatureTransferLocalization.string(forKey: "sendText.validationInfo")
    }

    private var validationTint: Color {
        trimmedDraft.isEmpty && hasAttemptedSubmit ? SemanticColor.destructive : accentTheme.primary.opacity(0.2)
    }

    private func submit() {
        guard trimmedDraft.isEmpty == false else {
            hasAttemptedSubmit = true
            return
        }
        onStage(trimmedDraft)
    }
}
