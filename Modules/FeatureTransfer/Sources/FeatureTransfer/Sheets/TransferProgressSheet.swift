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
    private var directionTint: Color {
        progress.direction == .sending ? SemanticColor.sending : SemanticColor.receiving
    }
    private var isComplete: Bool { progress.status == .completed }
    private var overallProgressTarget: Double? { progress.overallProgressValue }

    var body: some View {
        VStack(spacing: 0) {
            TransferMergeCompletionView(
                direction: progress.direction,
                counterpartKind: progress.counterpartKind,
                isComplete: isComplete,
                tint: directionTint,
                reduceMotion: reduceMotion
            )
            .accessibilityHidden(true)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.lg)

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    overallSection

                    ForEach(progress.files) { file in
                        TransferFileProgressRow(
                            fileProgress: file,
                            tint: directionTint,
                            animationSeed: animationSeed
                        )
                    }
                }
                .padding(.horizontal, Spacing.xs)
                .padding(.bottom, Spacing.md)
            }
            .frame(maxHeight: 300)

            if let secondaryStatusLine = progress.secondaryStatusLine {
                Text(secondaryStatusLine)
                    .appFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedStat()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Spacing.sm)
            }

            footerButton
                .padding(.top, Spacing.md + 2)
        }
        .padding(Spacing.xl)
        .frame(width: 460)
        .task(id: progress.id) {
            displayedOverallProgress = overallProgressTarget ?? displayedOverallProgress
            animationSeed = 0
        }
        .task(id: presentationTaskID) {
            await animateDisplayedProgress()
        }
    }

    private var overallSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.counterpartName)
                        .appFont(.text(.callout, .semibold))
                    if let batchPositionLabel = progress.batchPositionLabel {
                        Text(batchPositionLabel)
                            .appFont(.caption1)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let overallProgressTarget {
                    Text(FeatureTransferLocalization.format("transfer.progress.percentComplete", displayedPercent(for: overallProgressTarget)))
                        .appFont(.text(.callout, .semibold))
                        .foregroundStyle(directionTint)
                        .monospacedStat()
                } else {
                    Text(progress.status == .completed ? "Complete" : "In Progress")
                        .appFont(.text(.callout, .semibold))
                        .foregroundStyle(directionTint)
                }
            }

            if overallProgressTarget != nil {
                ProgressView(value: displayedOverallProgress)
                    .progressViewStyle(.linear)
                    .tint(directionTint)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(directionTint)
            }

            Text(progress.aggregateByteProgressLabel)
                .appFont(.caption1)
                .foregroundStyle(.secondary)
                .monospacedStat()
        }
        .padding(.bottom, Spacing.xs)
    }

    @ViewBuilder
    private var footerButton: some View {
        if isComplete {
            Button(action: onCancel) {
                Text(FeatureTransferLocalization.resource("transfer.progress.done"))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        } else {
            Button(role: .destructive, action: onCancel) {
                Text(FeatureTransferLocalization.resource("general.cancel"))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
        }
    }

    private func displayedPercent(for target: Double) -> Int {
        if target >= 1 || progress.status == .completed {
            return 100
        }
        return min(max(Int((displayedOverallProgress * 100).rounded(.down)), 0), 99)
    }

    private var presentationTaskID: String {
        "\(progress.id)-\(progress.displayableTransferredBytes)-\(progress.status)"
    }

    @MainActor
    private func animateDisplayedProgress() async {
        guard let target = overallProgressTarget else { return }
        if reduceMotion || progress.status != .running {
            displayedOverallProgress = target
            animationSeed &+= 1
            return
        }

        while displayedOverallProgress < target {
            let remaining = target - displayedOverallProgress
            let step = min(max(remaining * 0.55, 0.01), 0.08)
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                displayedOverallProgress = min(displayedOverallProgress + step, target)
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
        case .queued:
            return .secondary
        case .transferring, .retrying:
            return tint
        }
    }

    private var isActive: Bool {
        fileProgress.status == .transferring || fileProgress.status == .retrying
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(fileProgress.fileName)
                    .appFont(.text(.callout, .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text(fileProgress.statusLabel)
                    .appFont(.caption1)
                    .foregroundStyle(rowTint)
                    .monospacedStat()
            }

            if let progressValue = fileProgress.determinateProgress {
                ProgressView(value: progressValue)
                    .progressViewStyle(.linear)
                    .tint(rowTint)
            } else if isActive {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(rowTint)
            }

            Text(fileProgress.byteProgressLabel)
                .appFont(.caption1)
                .foregroundStyle(.secondary)
                .monospacedStat()

            if let errorSummary = fileProgress.errorSummary,
               fileProgress.status == .failed || fileProgress.status == .canceled {
                Text(errorSummary)
                    .appFont(.caption1)
                    .foregroundStyle(rowTint)
                    .lineLimit(2)
            }
        }
        .padding(Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(rowTint.opacity(isActive ? 0.22 : 0.08), lineWidth: 1)
        }
        .scaleEffect(isActive && animationSeed.isMultiple(of: 2) == false ? 1.01 : 1)
    }
}

private struct TransferMergeCompletionView: View {
    let direction: ActiveTransferProgress.Direction
    let counterpartKind: DeviceKind
    let isComplete: Bool
    let tint: Color
    let reduceMotion: Bool

    @State private var mergeInFlight = false
    @State private var showMergedSuccess = false

    private var leadingSymbol: String {
        direction == .sending ? "laptopcomputer" : counterpartKind.symbol
    }

    private var trailingSymbol: String {
        direction == .sending ? counterpartKind.symbol : "laptopcomputer"
    }

    var body: some View {
        ZStack {
            if reduceMotion {
                Image(systemName: isComplete ? "checkmark.circle.fill" : "arrow.left.and.right.circle.fill")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(isComplete ? SemanticColor.success : tint)
                    .transition(.opacity.combined(with: .scale))
            } else {
                FileFlightView(
                    leadingSymbol: leadingSymbol,
                    trailingSymbol: trailingSymbol,
                    isActive: !isComplete
                )
                .scaleEffect(1.18)
                .opacity(isComplete ? 0 : 1)

                if isComplete {
                    Image(systemName: leadingSymbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(tint)
                        .offset(x: mergeInFlight ? -10 : -64, y: 0)
                        .scaleEffect(mergeInFlight ? 0.9 : 1)
                        .opacity(showMergedSuccess ? 0 : 1)
                        .blur(radius: showMergedSuccess ? 2 : 0)

                    Image(systemName: trailingSymbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(tint)
                        .offset(x: mergeInFlight ? 10 : 64, y: 0)
                        .scaleEffect(mergeInFlight ? 0.9 : 1)
                        .opacity(showMergedSuccess ? 0 : 1)
                        .blur(radius: showMergedSuccess ? 2 : 0)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(SemanticColor.success)
                        .scaleEffect(showMergedSuccess ? 1 : 0.72)
                        .opacity(showMergedSuccess ? 1 : 0)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 88)
        .onAppear {
            guard !reduceMotion else { return }
            if isComplete {
                startCompletionSequence()
            } else {
                resetCompletionSequence()
            }
        }
        .onChange(of: isComplete) { _, newValue in
            guard !reduceMotion else { return }
            if newValue {
                startCompletionSequence()
            } else {
                resetCompletionSequence()
            }
        }
    }

    private func resetCompletionSequence() {
        mergeInFlight = false
        showMergedSuccess = false
    }

    private func startCompletionSequence() {
        resetCompletionSequence()
        withAnimation(.easeInOut(duration: 0.42)) {
            mergeInFlight = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.24)) {
                    showMergedSuccess = true
                }
            }
        }
    }
}
