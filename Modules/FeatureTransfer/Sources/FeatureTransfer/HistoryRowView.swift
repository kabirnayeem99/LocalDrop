import SwiftUI
import DesignSystem

struct HistoryRowView: View {
    let entry: HistoryEntry

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
                Text(entry.timestamp)
                    .font(Typography.subheadline)
                    .foregroundStyle(.secondary)
                Label(entry.outcome.label, systemImage: entry.outcome.symbol)
                    .font(Typography.subheadline.weight(.semibold))
                    .foregroundStyle(outcomeTint)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, Spacing.xxs)
    }

    private var directionSymbol: String {
        entry.direction == .received ? "arrow.down" : "arrow.up"
    }

    private var iconTint: Color {
        switch entry.outcome {
        case .completed: return AccentColor.primary
        case .declined: return Color(nsColor: .systemRed)
        }
    }

    private var outcomeTint: Color {
        switch entry.outcome {
        case .completed: return Color(nsColor: .systemGreen)
        case .declined: return Color(nsColor: .systemRed)
        }
    }
}
