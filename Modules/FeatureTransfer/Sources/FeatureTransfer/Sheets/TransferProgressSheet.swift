import SwiftUI
import DesignSystem

struct TransferProgressSheet: View {
    let progress: ActiveTransferProgress
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    private var normalizedProgress: Double { min(max(progress.progress, 0), 1) }
    private var percent: Int { Int((normalizedProgress * 100).rounded()) }
    private var isComplete: Bool { normalizedProgress >= 1 }
    private var directionTint: Color {
        progress.direction == .sending ? SemanticColor.sending : SemanticColor.receiving
    }

    // Files always flow leading -> trailing, so the leading badge is the source:
    // this Mac when sending, the counterpart when receiving.
    private var flightLeadingSymbol: String {
        progress.direction == .sending ? "laptopcomputer" : progress.counterpartKind.symbol
    }
    private var flightTrailingSymbol: String {
        progress.direction == .sending ? progress.counterpartKind.symbol : "laptopcomputer"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm + 1) {
                FileFlightView(
                    leadingSymbol: flightLeadingSymbol,
                    trailingSymbol: flightTrailingSymbol,
                    isActive: !isComplete
                )
                .overlay(alignment: .trailing) {
                    if isComplete {
                        // Celebrate arrival over the destination (trailing) badge.
                        // The +17 nudge re-centers the 74pt burst on the 40pt badge.
                        CompletionBurst(tint: SemanticColor.success, direction: progress.direction)
                            .frame(width: 74, height: 74)
                            .offset(x: 17)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isComplete)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(titleText)
                        .appFont(.text(.title3, .bold))
                        .foregroundStyle(.primary)
                    Text(verbatim: "\(progress.fileName) · \(percent)% · \(progress.throughput)")
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedStat()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                }

                Spacer(minLength: 0)
            }

            ProgressView(value: normalizedProgress)
                .progressViewStyle(.linear)
                .tint(directionTint)
                .padding(.top, Spacing.md + 2)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: normalizedProgress)

            HStack {
                Text(FeatureTransferLocalization.format("transfer.progress.percentComplete", percent))
                Spacer()
                if isComplete {
                    Text(FeatureTransferLocalization.resource("transfer.progress.done"))
                } else {
                    Text(progress.etaDescription)
                }
            }
            .appFont(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedStat()
            .contentTransition(reduceMotion ? .identity : .numericText())
            .padding(.top, Spacing.xs)

            if isComplete {
                Label(FeatureTransferLocalization.resource("transfer.progress.complete"), systemImage: "checkmark.circle.fill")
                    .appFont(.text(.callout, .semibold))
                    .foregroundStyle(SemanticColor.success)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Spacing.md + 2)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                Button(role: .destructive, action: onCancel) {
                    Text(FeatureTransferLocalization.resource("general.cancel")).frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .padding(.top, Spacing.md + 2)
                .transition(.opacity)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 400)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isComplete)
    }

    private var titleText: String {
        switch progress.direction {
        case .sending:
            return isComplete
                ? FeatureTransferLocalization.format("transfer.sentTo", progress.counterpartName)
                : FeatureTransferLocalization.format("transfer.progress.sendingTo", progress.counterpartName)
        case .receiving:
            return isComplete
                ? FeatureTransferLocalization.format("transfer.receivedFrom", progress.counterpartName)
                : FeatureTransferLocalization.format("transfer.progress.receivingFrom", progress.counterpartName)
        }
    }
}

private struct CompletionBurst: View {
    let tint: Color
    let direction: ActiveTransferProgress.Direction

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    @State private var animate = false
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        ZStack {
            if reduceMotion {
                Circle()
                    .stroke(tint.opacity(0.24), lineWidth: 2)
                    .frame(width: 58, height: 58)
            } else {
                ForEach(0..<10, id: \.self) { index in
                    Capsule()
                        .fill(tint.opacity(animate ? 0 : 0.75))
                        .frame(width: 3, height: animate ? 10 : 5)
                        .offset(y: animate ? -36 : -22)
                        .rotationEffect(.degrees(Double(index) * 36))
                }

                Image(systemName: direction == .sending ? "paperplane.fill" : "tray.and.arrow.down.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint.opacity(animate ? 0 : 0.8))
                    .offset(x: animate ? 26 : 10, y: animate ? -18 : -7)
                    .blur(radius: animate ? 2 : 0)
            }
        }
        .scaleEffect(animate ? 1.1 : 0.72)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.72)) {
                animate = true
            }
        }
    }
}
