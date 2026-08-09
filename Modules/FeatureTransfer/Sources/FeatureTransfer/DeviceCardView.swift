import SwiftUI
import DesignSystem

struct DeviceCardView: View {
    let device: NearbyPeerItem
    /// Name to render — a favorite's `aliasOverride` when one is set, otherwise the announced alias.
    let displayName: String
    let isFavorite: Bool
    let action: () -> Void
    let toggleFavorite: () -> Void

    init(
        device: NearbyPeerItem,
        displayName: String? = nil,
        isFavorite: Bool = false,
        toggleFavorite: @escaping () -> Void = {},
        action: @escaping () -> Void
    ) {
        self.device = device
        self.displayName = displayName ?? device.name
        self.isFavorite = isFavorite
        self.toggleFavorite = toggleFavorite
        self.action = action
    }

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    @Environment(\.accentTheme) private var accentTheme
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }
    @State private var isHovering = false
    @State private var showsAvailabilityPulse = false

    var body: some View {
        // The favorite toggle is a sibling layered above the card button rather than nested inside
        // its label: a Button inside another Button's label does not reliably get its own hit test.
        ZStack(alignment: .topTrailing) {
            cardButton
            favoriteToggle
                .padding(.top, Spacing.xs)
                .padding(.trailing, Spacing.xs)
        }
        // Hover scale belongs to the whole row, not just the card: scaling the card alone slid it out
        // from under a stationary star.
        .scaleEffect(reduceMotion ? 1 : (isHovering ? 1.015 : 1))
    }

    private var favoriteToggle: some View {
        Button(action: toggleFavorite) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isFavorite ? accentTheme.primary : Color.secondary)
                // Glyph stays 12pt; only the hit target grows, keeping it clear of the send affordance.
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(favoriteLabel))
        .help(Text(favoriteLabel))
        // Normalized to match the favorites store's lowercase keys; the wire fingerprint may be uppercase.
        .accessibilityIdentifier("device-favorite-toggle-\(FavoriteDevice.normalizedFingerprint(device.id))")
    }

    private var favoriteLabel: LocalizedStringResource {
        isFavorite
            ? FeatureTransferLocalization.resource("device.removeFavorite")
            : FeatureTransferLocalization.resource("device.addFavorite")
    }

    private var cardButton: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle.continuous(Radius.xl)
                        .stroke(accentTheme.primary.opacity(0.26), lineWidth: 1.5)
                        .frame(width: 44, height: 44)
                        .scaleEffect(reduceMotion || showsAvailabilityPulse ? 1.32 : 1)
                        .opacity(reduceMotion || showsAvailabilityPulse ? 0 : 0.22)
                        .allowsHitTesting(false)

                    RoundedRectangle.continuous(Radius.xl)
                        .fill(accentTheme.primarySubtleFill)
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: device.kind.symbol)
                                .font(.system(size: 22, weight: .regular))
                                .foregroundStyle(accentTheme.primary)
                        }
                }

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(displayName)
                        .appFont(.headline)
                        .foregroundStyle(.primary)
                    Text(device.subtitle)
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)

                Spacer(minLength: 0)

                // Send affordance — fades/slides in only while hovering.
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accentTheme.primary)
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
                        isHovering ? accentTheme.primary.opacity(0.45) : Color(nsColor: .separatorColor),
                        lineWidth: isHovering ? 1 : 0.5
                    )
            }
            .shadow(
                color: .black.opacity((isHovering && !reduceMotion) ? 0.12 : 0),
                radius: (isHovering && !reduceMotion) ? 8 : 0,
                y: (isHovering && !reduceMotion) ? 3 : 0
            )
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
