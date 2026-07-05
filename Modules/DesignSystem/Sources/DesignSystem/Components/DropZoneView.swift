import SwiftUI

public struct DropZoneView<Content: View>: View {
    private let isTargeted: Bool
    private let content: Content

    // isTargeted is rendered but not owned here — the Send screen wires the
    // real `.dropDestination(for:)` in a later pass and passes its state in.
    public init(isTargeted: Bool, @ViewBuilder content: () -> Content) {
        self.isTargeted = isTargeted
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                AccentColor.primarySubtleFill.opacity(isTargeted ? 0.5 : 0.15),
                in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .strokeBorder(
                        AccentColor.primary.opacity(isTargeted ? 1.0 : 0.5),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            }
            .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }

    public init(isTargeted: Bool, systemImage: String, label: String) where Content == DropZoneLabel {
        self.isTargeted = isTargeted
        self.content = DropZoneLabel(systemImage: systemImage, label: label)
    }
}

public struct DropZoneLabel: View {
    private let systemImage: String
    private let label: String

    public init(systemImage: String, label: String) {
        self.systemImage = systemImage
        self.label = label
    }

    public var body: some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(AccentColor.primary)
            Text(label)
                .font(Typography.callout)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.xl)
    }
}
