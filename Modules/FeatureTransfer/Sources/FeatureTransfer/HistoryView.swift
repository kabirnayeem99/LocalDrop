import SwiftUI
import DesignSystem

struct HistoryView: View {
    @Bindable var store: TransferFeatureStore
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    @State private var showsClearConfirmation = false
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent transfers")
                    .font(Typography.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button("Clear all") { showsClearConfirmation = true }
                    .buttonStyle(.plain)
                    .font(Typography.callout.weight(.medium))
                    .foregroundStyle(store.historyEntries.isEmpty ? .secondary : SemanticColor.destructive)
                    .disabled(store.historyEntries.isEmpty)
            }
            .padding(.horizontal, 30)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.sm + Spacing.xxs)

            if store.historyEntries.isEmpty {
                HistoryEmptyState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.historyEntries) { entry in
                        HistoryRowView(entry: entry)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: store.historyEntries.isEmpty)
        .confirmationDialog(
            "Clear transfer history?",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear all", role: .destructive) {
                store.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the recent transfer list from this device.")
        }
    }
}

private struct HistoryEmptyState: View {
    var body: some View {
        VStack(spacing: Spacing.sm) {
            ZStack {
                Circle()
                    .fill(SemanticColor.discoverySubtleFill)
                    .frame(width: 58, height: 58)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(SemanticColor.discovery)
            }

            Text("No recent transfers")
                .font(Typography.headline)
                .foregroundStyle(.primary)
            Text("Completed and declined transfers will appear here.")
                .font(Typography.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(Spacing.xl)
    }
}
