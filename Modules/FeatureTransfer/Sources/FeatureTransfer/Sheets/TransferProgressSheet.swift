import DesignSystem
import SwiftUI

struct TransferProgressSheet: View {
    let progress: ActiveTransferProgress
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    @State private var displayedOverallProgress = 0.0
    @State private var animationSeed = 0
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    private var targetOverallProgress: Double {
        progress.status == .completed ? 1 : min(max(progress.overallProgress, 0), 1)
    }

    private var displayedOverallPercent: Int {
        if progress.status == .completed || displayedOverallProgress >= 1 {
            return 100
        }
        return min(max(Int((displayedOverallProgress * 100).rounded(.down)), 0), 99)
    }

    private var directionTint: Color {
        progress.direction == .sending ? SemanticColor.sending : SemanticColor.receiving
    }

    private var isComplete: Bool {
        progress.status == .completed || displayedOverallProgress >= 1
    }

    private var percentSpring: Animation {
        .spring(response: 0.3, dampingFraction: 0.8)
    }

    private var flightLeadingSymbol: String {
        progress.direction == .sending ? "laptopcomputer" : progress.counterpartKind.symbol
    }

    private var flightTrailingSymbol: String {
        progress.direction == .sending ? progress.counterpartKind.symbol : "laptopcomputer"
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                FileFlightView(
                    leadingSymbol: flightLeadingSymbol,
                    trailingSymbol: flightTrailingSymbol,
                    isActive: !isComplete
                )
                .scaleEffect(1.18)
                .frame(maxWidth: .infinity)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.lg)
                .overlay(alignment: .trailing) {
                    if isComplete {
                        CompletionBurst(tint: SemanticColor.success, direction: progress.direction)
                            .frame(width: 82, height: 82)
                            .offset(x: 18)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    overallProgressSection

                    ForEach(progress.resolvedFileProgress) { fileProgress in
                        TransferFileProgressRow(
                            fileProgress: fileProgress,
                            tint: directionTint,
                            animationSeed: animationSeed
                        )
                    }
                }
                .padding(.horizontal, Spacing.xs)
                .padding(.bottom, Spacing.md)
            }
            .frame(maxHeight: 260)

            HStack {
                Text(progress.etaDescription)
                Spacer()
                if progress.remainingItemCount > 0 {
                    Text(
                        FeatureTransferLocalization.format(
                            "transfer.status.itemsRemaining",
                            progress.remainingItemCount
                        )
                    )
                }
            }
            .appFont(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedStat()
            .contentTransition(reduceMotion ? .identity : .numericText())
            .padding(.top, Spacing.sm)
            .animation(reduceMotion ? nil : percentSpring, value: animationSeed)

            if isComplete {
                VStack(spacing: Spacing.sm) {
                    Label(FeatureTransferLocalization.resource("transfer.progress.complete"), systemImage: "checkmark.circle.fill")
                        .appFont(.text(.callout, .semibold))
                        .foregroundStyle(SemanticColor.success)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))

                    Button(action: onCancel) {
                        Text(FeatureTransferLocalization.resource("transfer.progress.done")).frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, Spacing.md + 2)
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
        .frame(width: 440)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isComplete)
        .task(id: progress.id) {
            displayedOverallProgress = targetOverallProgress
            animationSeed = 0
        }
        .task(id: presentationTaskID) {
            await animateDisplayedProgress()
        }
    }

    private var overallProgressSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack {
                if let batchPositionLabel = progress.batchPositionLabel {
                    Text(batchPositionLabel)
                        .appFont(.text(.callout, .semibold))
                        .foregroundStyle(.primary)
                }
                Spacer()
                Text(FeatureTransferLocalization.format("transfer.progress.percentComplete", displayedOverallPercent))
                    .appFont(.text(.callout, .semibold))
                    .foregroundStyle(directionTint)
                    .monospacedStat()
            }

            ProgressView(value: displayedOverallProgress)
                .progressViewStyle(.linear)
                .tint(directionTint)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: displayedOverallProgress)

            if let overallByteLabel {
                Text(overallByteLabel)
                    .appFont(.caption1)
                    .foregroundStyle(.secondary)
                    .monospacedStat()
            }
        }
        .padding(.bottom, Spacing.xs)
    }

    private var overallByteLabel: String? {
        byteProgressLabel(
            transferred: progress.status == .completed ? progress.totalBytes : progress.transferredBytes,
            total: progress.totalBytes
        )
    }

    private func byteProgressLabel(transferred: Int64?, total: Int64?) -> String? {
        guard let total else { return nil }
        let resolvedTransferred = min(max(transferred ?? 0, 0), total)
        let transferredLabel = ByteCountFormatter.string(fromByteCount: resolvedTransferred, countStyle: .file)
        let totalLabel = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return "\(transferredLabel) / \(totalLabel)"
    }

    private var presentationTaskID: String {
        "\(progress.id)-\(targetOverallProgress)-\(progress.status)"
    }

    @MainActor
    private func animateDisplayedProgress() async {
        let resolvedTarget = targetOverallProgress
        if reduceMotion || progress.status != .running {
            if displayedOverallProgress != resolvedTarget {
                displayedOverallProgress = resolvedTarget
                animationSeed &+= 1
            }
            return
        }

        while displayedOverallProgress < resolvedTarget {
            let remaining = resolvedTarget - displayedOverallProgress
            let step = min(max(remaining * 0.55, 0.01), 0.08)
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(percentSpring) {
                displayedOverallProgress = min(displayedOverallProgress + step, resolvedTarget)
                animationSeed &+= 1
            }
        }
    }
}

private struct TransferFileProgressRow: View {
    let fileProgress: TransferFileProgress
    let tint: Color
    let animationSeed: Int

    private var rowTint: Color {
        switch fileProgress.status {
        case .completed:
            return SemanticColor.success
        case .failed, .canceled:
            return SemanticColor.destructive
        case .pending:
            return .secondary
        case .running:
            return tint
        }
    }

    private var byteLabel: String? {
        guard let totalBytes = fileProgress.totalBytes else { return nil }
        let transferred = min(max(fileProgress.transferredBytes ?? 0, 0), totalBytes)
        let transferredLabel = ByteCountFormatter.string(fromByteCount: transferred, countStyle: .file)
        let totalLabel = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(transferredLabel) / \(totalLabel)"
    }

    private var statusLabel: String {
        switch fileProgress.status {
        case .completed:
            return FeatureTransferLocalization.string(forKey: "transfer.progress.done")
        case .failed:
            return "Failed"
        case .canceled:
            return FeatureTransferLocalization.string(forKey: "transfer.status.canceled")
        case .pending, .running:
            return FeatureTransferLocalization.format("transfer.progress.percentComplete", fileProgress.stablePercent)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(fileProgress.fileName)
                    .appFont(.text(.callout, .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text(statusLabel)
                    .appFont(.caption1)
                    .foregroundStyle(rowTint)
                    .monospacedStat()
                    .contentTransition(.numericText())
            }

            ProgressView(value: fileProgress.progress)
                .progressViewStyle(.linear)
                .tint(rowTint)

            if let byteLabel {
                Text(byteLabel)
                    .appFont(.caption1)
                    .foregroundStyle(.secondary)
                    .monospacedStat()
            }
        }
        .padding(Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(rowTint.opacity(fileProgress.status == .running ? 0.22 : 0.08), lineWidth: 1)
        }
        .scaleEffect(fileProgress.status == .running && animationSeed.isMultiple(of: 2) == false ? 1.01 : 1)
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
