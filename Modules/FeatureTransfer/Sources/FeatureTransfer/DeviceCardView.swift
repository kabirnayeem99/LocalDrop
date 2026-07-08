import SwiftUI
import DesignSystem

struct DeviceCardView: View {
    let device: NearbyPeerItem
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }
    @State private var isHovering = false
    @State private var showsAvailabilityPulse = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle.continuous(Radius.xl)
                        .stroke(AccentColor.primary.opacity(0.26), lineWidth: 1.5)
                        .frame(width: 44, height: 44)
                        .scaleEffect(reduceMotion || showsAvailabilityPulse ? 1.32 : 1)
                        .opacity(reduceMotion || showsAvailabilityPulse ? 0 : 0.22)
                        .allowsHitTesting(false)

                    RoundedRectangle.continuous(Radius.xl)
                        .fill(AccentColor.primarySubtleFill)
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: device.kind.symbol)
                                .font(.system(size: 22, weight: .regular))
                                .foregroundStyle(AccentColor.primary)
                        }
                }

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(device.name)
                        .font(Typography.headline)
                        .foregroundStyle(.primary)
                    Text(device.subtitle)
                        .font(Typography.callout)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)

                Spacer(minLength: 0)

                // Send affordance — fades/slides in only while hovering.
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AccentColor.primary)
                    .opacity(isHovering ? 1 : 0)
                    .offset(x: reduceMotion ? 0 : (isHovering ? 0 : 6))
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle.continuous(Radius.xl))
            .overlay {
                RoundedRectangle.continuous(Radius.xl)
                    .strokeBorder(
                        isHovering ? AccentColor.primary.opacity(0.45) : Color(nsColor: .separatorColor),
                        lineWidth: isHovering ? 1 : 0.5
                    )
            }
            .shadow(
                color: .black.opacity((isHovering && !reduceMotion) ? 0.12 : 0),
                radius: (isHovering && !reduceMotion) ? 8 : 0,
                y: (isHovering && !reduceMotion) ? 3 : 0
            )
            .scaleEffect(reduceMotion ? 1 : (isHovering ? 1.015 : 1))
        }
        .buttonStyle(DeviceCardButtonStyle(reduceMotion: reduceMotion))
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                isHovering = hovering
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.7).delay(0.12)) {
                showsAvailabilityPulse = true
            }
        }
    }
}

private struct DeviceCardButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}
