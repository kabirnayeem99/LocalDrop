import SwiftUI
import DesignSystem

struct HistoryRowView: View {
    let entry: HistoryEntry
    let store: TransferFeatureStore

    private var hasFile: Bool { entry.fileURL != nil }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            RoundedRectangle.continuous(Radius.md)
                .fill(iconTint.opacity(0.1))
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: directionSymbol)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(iconTint)
                }

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(entry.fileName)
                    .font(Typography.headline)
                    .foregroundStyle(.primary)
                Text(entry.subtitle)
                    .font(Typography.callout)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)

            Spacer(minLength: Spacing.sm)

            VStack(alignment: .trailing, spacing: Spacing.xxs) {
                Text(entry.timestampDisplay)
                    .font(Typography.subheadline)
                    .foregroundStyle(.secondary)
                Label(entry.outcome.label, systemImage: entry.outcome.symbol)
                    .font(Typography.subheadline.weight(.semibold))
                    .foregroundStyle(outcomeTint)
                    .labelStyle(.titleAndIcon)
            }

            fileActionsMenu
        }
        .padding(.vertical, Spacing.xxs)
    }

    private var fileActionsMenu: some View {
        Menu {
            Button {
                store.revealInFinder(entry)
            } label: {
                Label("history.revealInFinder", systemImage: "folder")
            }
            Button {
                store.openHistoryItem(entry)
            } label: {
                Label("history.open", systemImage: "arrow.up.forward.app")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
        .disabled(hasFile == false)
        .help(hasFile ? "history.rowHelp" : "history.locationUnavailable")
    }

    private var directionSymbol: String {
        entry.direction == .received ? "arrow.down" : "arrow.up"
    }

    private var iconTint: Color {
        switch entry.outcome {
        case .completed: return SemanticColor.success
        case .declined: return SemanticColor.destructive
        }
    }

    private var outcomeTint: Color {
        switch entry.outcome {
        case .completed: return SemanticColor.success
        case .declined: return SemanticColor.destructive
        }
    }
}
