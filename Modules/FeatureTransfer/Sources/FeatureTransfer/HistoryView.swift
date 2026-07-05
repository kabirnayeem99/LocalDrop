import SwiftUI
import DesignSystem

struct HistoryView: View {
    @State private var entries = HistoryEntry.samples

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent transfers")
                    .font(Typography.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button("Clear all") { entries.removeAll() }
                    .buttonStyle(.plain)
                    .font(Typography.callout.weight(.medium))
                    .foregroundStyle(AccentColor.primary)
            }
            .padding(.horizontal, 30)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.sm + Spacing.xxs)

            List {
                ForEach(entries) { entry in
                    HistoryRowView(entry: entry)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
