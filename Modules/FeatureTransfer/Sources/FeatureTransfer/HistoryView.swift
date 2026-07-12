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
                Text("history.title")
                    .font(Typography.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button("history.clearAll") { showsClearConfirmation = true }
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
                ScrollView {
                    LazyVStack(spacing: Spacing.xs + Spacing.xxs) {
                        ForEach(store.historyEntries) { entry in
                            HistoryRowView(entry: entry, store: store)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .opacity.combined(with: .scale(scale: 0.96))
                                ))
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.bottom, Spacing.xl)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: store.historyEntries.isEmpty)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: store.historyEntries.map(\.id))
        .confirmationDialog(
            "history.clearConfirmTitle",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("history.clearAll", role: .destructive) {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    store.clearHistory()
                }
            }
            Button("general.cancel", role: .cancel) {}
        } message: {
            Text("history.clearAllMessage")
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

                Text("history.noTransfers")
                    .font(Typography.headline)
                    .foregroundStyle(.primary)
                Text("history.noTransfersHelp")
                .font(Typography.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(Spacing.xl)
    }
}
