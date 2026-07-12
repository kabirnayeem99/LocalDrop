import SwiftUI
import DesignSystem

struct HistoryRowView: View {
    let entry: HistoryEntry
    let store: TransferFeatureStore

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    @State private var highlightFreshEntry = false

    private var hasFile: Bool { entry.fileURL != nil }
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

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
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xxs)
        .background(rowBackground, in: RoundedRectangle.continuous(Radius.lg))
        .overlay {
            RoundedRectangle.continuous(Radius.lg)
                .strokeBorder(rowBorder, lineWidth: 0.5)
        }
        .onAppear {
            guard reduceMotion == false, entry.outcome == .completed, isRecentlyCompleted else { return }
            highlightFreshEntry = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                withAnimation(.easeOut(duration: 0.35)) {
                    highlightFreshEntry = false
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: highlightFreshEntry)
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

    private var isRecentlyCompleted: Bool {
        abs(entry.timestamp.timeIntervalSinceNow) < 8
    }

    private var rowBackground: Color {
        if highlightFreshEntry {
            return SemanticColor.successSubtleFill
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var rowBorder: Color {
        highlightFreshEntry ? SemanticColor.success.opacity(0.18) : Color(nsColor: .separatorColor)
    }
}
