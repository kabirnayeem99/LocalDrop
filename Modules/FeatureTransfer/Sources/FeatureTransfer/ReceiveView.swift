import SwiftUI
import DesignSystem

struct ReceiveView: View {
    @Bindable var state: TransferViewState

    var body: some View {
        VStack(spacing: 0) {
            ReceiveHero()
                .frame(width: 220, height: 220)

            Text(state.deviceName)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.top, Spacing.xl + Spacing.xxs)

            (Text("Waiting to receive · ")
                .foregroundStyle(.secondary)
             + Text("#\(state.waitingIdentifier)")
                .foregroundStyle(AccentColor.primary))
                .font(Typography.body.weight(.medium))
                .padding(.top, Spacing.xxs)

            VStack(spacing: Spacing.sm) {
                Text("Quick Save")
                    .font(Typography.caption1.weight(.semibold))
                    .textCase(.uppercase)
                    .kerning(0.3)
                    .foregroundStyle(.secondary)

                Picker("Quick Save", selection: $state.quickSave) {
                    ForEach(QuickSaveMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .tint(AccentColor.primary)
            }
            .padding(.top, Spacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xl)
    }
}

private struct ReceiveHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            PulseRingView(ringCount: 2, color: AccentColor.primary.opacity(0.5), lineWidth: 1.5, duration: 2.8)
                .frame(width: 150, height: 150)

            RotatingDashedRing()
                .frame(width: 190, height: 190)

            RoundedRectangle.continuous(Radius.xxl + Radius.lg)
                .fill(AccentColor.primary)
                .frame(width: 128, height: 128)
                .overlay {
                    BrandMark(variant: .monoLight)
                        .frame(width: 60, height: 60)
                }
                .shadow(color: AccentColor.primary.opacity(0.4), radius: 20, y: 12)
        }
    }
}

private struct RotatingDashedRing: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        if reduceMotion {
            ring
        } else {
            TimelineView(.animation) { context in
                let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 26) / 26 * 360
                ring.rotationEffect(.degrees(angle))
            }
        }
    }

    private var ring: some View {
        Circle()
            .strokeBorder(
                AccentColor.primary.opacity(0.28),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 6])
            )
    }
}
