import SwiftUI
import DesignSystem

struct IncomingRequestSheet: View {
    let request: IncomingRequest
    let onDecline: () -> Void
    let onAccept: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Spacing.xxs) {
                RoundedRectangle.continuous(Radius.xxl)
                    .fill(AccentColor.primarySubtleFill)
                    .frame(width: 60, height: 60)
                    .overlay {
                        Image(systemName: "iphone")
                            .font(.system(size: 28, weight: .regular))
                            .foregroundStyle(AccentColor.primary)
                    }
                    .padding(.bottom, Spacing.sm - Spacing.xxs)

                Text("\(request.deviceName) wants to send")
                    .font(Typography.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text(request.subtitle)
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(request.files.enumerated()), id: \.element.id) { index, file in
                    HStack(spacing: Spacing.xs + Spacing.xxs) {
                        Image(systemName: file.symbol)
                            .font(.system(size: 15))
                            .foregroundStyle(AccentColor.primary)
                            .frame(width: 20)
                        Text(file.name)
                            .font(Typography.body)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(file.size)
                            .font(Typography.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs + 2)

                    if index < request.files.count - 1 {
                        Divider()
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle.continuous(Radius.lg))
            .overlay {
                RoundedRectangle.continuous(Radius.lg)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .padding(.top, Spacing.md + 2)

            HStack(spacing: Spacing.xs + Spacing.xxs) {
                Button(action: onDecline) {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)

                Button(action: onAccept) {
                    Text("Accept").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(AccentColor.primary)
            }
            .padding(.top, Spacing.md + 2)
        }
        .padding(Spacing.xl)
        .frame(width: 400)
    }
}
