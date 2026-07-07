import SwiftUI
import DesignSystem

struct HistoryView: View {
    @Bindable var store: TransferFeatureStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent transfers")
                    .font(Typography.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button("Clear all") { store.clearHistory() }
                    .buttonStyle(.plain)
                    .font(Typography.callout.weight(.medium))
                    .foregroundStyle(AccentColor.primary)
            }
            .padding(.horizontal, 30)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.sm + Spacing.xxs)

            List {
                ForEach(store.historyEntries) { entry in
                    HistoryRowView(entry: entry)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
