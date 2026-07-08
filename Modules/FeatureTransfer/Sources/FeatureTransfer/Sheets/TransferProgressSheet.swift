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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm + 1) {
                SpinningRingIcon(direction: progress.direction, isComplete: isComplete)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(titleText)
                        .font(Typography.title3.weight(.bold))
                        .foregroundStyle(.primary)
                    Text("\(progress.fileName) · \(percent)% · \(progress.throughput)")
                        .font(Typography.callout)
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
                Text("\(percent)% complete")
                Spacer()
                Text(isComplete ? "Done" : progress.etaDescription)
            }
            .font(Typography.subheadline)
            .foregroundStyle(.secondary)
            .monospacedStat()
            .contentTransition(reduceMotion ? .identity : .numericText())
            .padding(.top, Spacing.xs)

            if isComplete {
                Label("Transfer complete", systemImage: "checkmark.circle.fill")
                    .font(Typography.callout.weight(.semibold))
                    .foregroundStyle(SemanticColor.success)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Spacing.md + 2)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                Button(role: .destructive, action: onCancel) {
                    Text("Cancel transfer").frame(maxWidth: .infinity)
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
            return isComplete ? "Sent to \(progress.counterpartName)" : "Sending to \(progress.counterpartName)"
        case .receiving:
            return isComplete ? "Received from \(progress.counterpartName)" : "Receiving from \(progress.counterpartName)"
        }
    }
}

private struct SpinningRingIcon: View {
    let direction: ActiveTransferProgress.Direction
    let isComplete: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }
    private var tint: Color {
        if isComplete {
            return SemanticColor.success
        }
        return direction == .sending ? SemanticColor.sending : SemanticColor.receiving
    }
    private var fill: Color {
        if isComplete {
            return SemanticColor.successSubtleFill
        }
        return direction == .sending ? SemanticColor.sendingSubtleFill : SemanticColor.receivingSubtleFill
    }

    var body: some View {
        ZStack {
            RoundedRectangle.continuous(Radius.xl)
                .fill(fill)
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: iconName)
                        .font(.system(size: 22))
                        .foregroundStyle(tint)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                }

            if !isComplete {
                ring
                    .frame(width: 52, height: 52)
                    .transition(.opacity)
            } else {
                CompletionBurst(tint: tint, direction: direction)
                    .frame(width: 74, height: 74)
                    .transition(.opacity)

                Circle()
                    .stroke(tint.opacity(0.28), lineWidth: 2)
                    .frame(width: 52, height: 52)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isComplete)
    }

    private var iconName: String {
        if isComplete {
            return "checkmark.circle.fill"
        }
        return direction == .sending ? "paperplane.fill" : "tray.and.arrow.down.fill"
    }

    @ViewBuilder private var ring: some View {
        if reduceMotion {
            trimmedRing
        } else {
            TimelineView(.animation) { context in
                let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
                trimmedRing.rotationEffect(.degrees(angle))
            }
        }
    }

    private var trimmedRing: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
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
