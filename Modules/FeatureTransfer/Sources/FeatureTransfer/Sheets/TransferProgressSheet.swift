import SwiftUI
import DesignSystem

struct TransferProgressSheet: View {
    @Bindable var state: TransferViewState
    let onCancel: () -> Void

    private var percent: Int { Int((state.transferProgress * 100).rounded()) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm + 1) {
                SpinningRingIcon()

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Sending to \(state.transferTarget)")
                        .font(Typography.title3.weight(.bold))
                        .foregroundStyle(.primary)
                    Text("\(state.transferFileName) · \(percent)% · \(state.transferSpeed)")
                        .font(Typography.callout)
                        .foregroundStyle(.secondary)
                        .monospacedStat()
                }

                Spacer(minLength: 0)
            }

            ProgressView(value: state.transferProgress)
                .progressViewStyle(.linear)
                .tint(AccentColor.primary)
                .padding(.top, Spacing.md + 2)

            HStack {
                Text("\(percent)% complete")
                Spacer()
                Text(state.transferETA)
            }
            .font(Typography.subheadline)
            .foregroundStyle(.secondary)
            .monospacedStat()
            .padding(.top, Spacing.xs)

            Button(role: .destructive, action: onCancel) {
                Text("Cancel transfer").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .padding(.top, Spacing.md + 2)
        }
        .padding(Spacing.xl)
        .frame(width: 400)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(130))
                state.transferProgress = state.transferProgress >= 1.0 ? 0.06 : state.transferProgress + 0.02
            }
        }
    }
}

private struct SpinningRingIcon: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        ZStack {
            RoundedRectangle.continuous(Radius.xl)
                .fill(AccentColor.primarySubtleFill)
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: "iphone")
                        .font(.system(size: 22))
                        .foregroundStyle(AccentColor.primary)
                }

            ring
                .frame(width: 52, height: 52)
        }
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
            .stroke(AccentColor.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }
}
