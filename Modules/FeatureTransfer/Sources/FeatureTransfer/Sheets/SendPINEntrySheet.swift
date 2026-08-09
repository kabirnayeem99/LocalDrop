import SwiftUI
import DesignSystem

/// Sender-side PIN entry.
///
/// A sheet of its own rather than a field inside `TransferProgressSheet`: the 401 arrives during
/// `/prepare-upload`, before a single byte moves, so there is no progress for it to live next to.
///
/// There is deliberately no "remember this PIN" affordance. The value typed here is handed to the
/// in-flight retry and dropped.
struct SendPINEntrySheet: View {
    let prompt: SendPINPrompt
    let onSubmit: @MainActor (String) -> Void
    let onCancel: @MainActor () -> Void

    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool
    @Environment(\.accentTheme) private var accentTheme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "lock.fill")
                    .appFont(.text(.title2, .semibold))
                    .foregroundStyle(accentTheme.primary)
                Text(FeatureTransferLocalization.resource("pinEntry.title"))
                    .appFont(.text(.title2, .bold))
            }

            Text(FeatureTransferLocalization.format("pinEntry.description", prompt.peerName))
                .appFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField(
                FeatureTransferLocalization.string(forKey: "pinEntry.placeholder"),
                text: $draft
            )
            .textFieldStyle(.roundedBorder)
            .appFont(.body)
            .focused($isFieldFocused)
            .onSubmit { submit() }
            .accessibilityLabel(Text(FeatureTransferLocalization.resource("pinEntry.placeholder")))

            // The first 401 is not an error — the recipient simply requires a PIN. Only a refused
            // submission earns error styling.
            if prompt.isFirstAttempt == false {
                Label {
                    Text(FeatureTransferLocalization.resource("pinEntry.incorrectPIN"))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .appFont(.text(.caption, .semibold))
                .foregroundStyle(SemanticColor.destructive)
                .accessibilityAddTraits(.isStaticText)
            }

            HStack {
                Spacer()
                Button(FeatureTransferLocalization.resource("general.cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button(FeatureTransferLocalization.resource("pinEntry.submit")) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedDraft.isEmpty)
            }
        }
        .padding(Spacing.xl)
        .frame(minWidth: 380)
        // A fresh, empty field per attempt: the refused PIN is not left sitting on screen.
        .id(prompt.id)
        .onAppear { isFieldFocused = true }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard trimmedDraft.isEmpty == false else { return }
        onSubmit(trimmedDraft)
    }
}
