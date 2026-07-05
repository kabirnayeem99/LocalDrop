import SwiftUI
import DesignSystem

struct DeviceCardView: View {
    let device: Device
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle.continuous(Radius.xl)
                        .fill(AccentColor.primarySubtleFill)
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: device.kind.symbol)
                                .font(.system(size: 22, weight: .regular))
                                .foregroundStyle(AccentColor.primary)
                        }

                    if device.unreadCount > 0 {
                        StatusBadge(count: device.unreadCount)
                            .offset(x: 6, y: -6)
                    }
                }

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(device.name)
                        .font(Typography.headline)
                        .foregroundStyle(.primary)

                    if device.isFavorite {
                        Label("Favorite", systemImage: "heart.fill")
                            .font(Typography.callout)
                            .foregroundStyle(Color(nsColor: .systemPink))
                            .labelStyle(.titleAndIcon)
                    } else {
                        Text(device.subtitle)
                            .font(Typography.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle.continuous(Radius.xl))
            .overlay {
                RoundedRectangle.continuous(Radius.xl)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }
}
