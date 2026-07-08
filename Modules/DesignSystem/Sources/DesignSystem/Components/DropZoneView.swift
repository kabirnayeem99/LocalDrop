import SwiftUI

public enum DropZoneInteractionState: Equatable {
    case idle
    case targeted
    case accepted
}

public struct DropZoneView<Content: View>: View {
    private let state: DropZoneInteractionState
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    // isTargeted is rendered but not owned here — the Send screen wires the
    // real `.dropDestination(for:)` in a later pass and passes its state in.
    public init(isTargeted: Bool, @ViewBuilder content: () -> Content) {
        self.state = isTargeted ? .targeted : .idle
        self.content = content()
    }

    public init(state: DropZoneInteractionState, @ViewBuilder content: () -> Content) {
        self.state = state
        self.content = content()
    }

    public var body: some View {
        content
            .environment(\.dropZoneInteractionState, state)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(reduceMotion ? 1 : scale)
            .background {
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .fill(.regularMaterial)
                    .opacity(materialOpacity)
            }
            .background {
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .fill(AccentColor.primarySubtleFill.opacity(fillOpacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .strokeBorder(
                        borderColor,
                        style: StrokeStyle(lineWidth: borderWidth, dash: [6, 4])
                    )
            }
            .shadow(color: glowColor, radius: reduceMotion ? 0 : glowRadius, y: reduceMotion ? 0 : 3)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: state)
    }

    public init(isTargeted: Bool, systemImage: String, label: String) where Content == DropZoneLabel {
        self.state = isTargeted ? .targeted : .idle
        self.content = DropZoneLabel(systemImage: systemImage, label: label)
    }

    public init(state: DropZoneInteractionState, systemImage: String, label: String) where Content == DropZoneLabel {
        self.state = state
        self.content = DropZoneLabel(systemImage: systemImage, label: label)
    }

    private var scale: CGFloat {
        switch state {
        case .idle:
            return 1
        case .targeted:
            return 1.012
        case .accepted:
            return 1.018
        }
    }

    private var fillOpacity: Double {
        switch state {
        case .idle:
            return 0.15
        case .targeted:
            return 0.42
        case .accepted:
            return 0.55
        }
    }

    private var materialOpacity: Double {
        switch state {
        case .idle:
            return 0
        case .targeted:
            return 0.26
        case .accepted:
            return 0.34
        }
    }

    private var borderColor: Color {
        switch state {
        case .idle:
            return AccentColor.primary.opacity(0.5)
        case .targeted:
            return AccentColor.primary.opacity(0.9)
        case .accepted:
            return AccentColor.primary
        }
    }

    private var borderWidth: CGFloat {
        switch state {
        case .idle:
            return 1.5
        case .targeted:
            return 2
        case .accepted:
            return 2.5
        }
    }

    private var glowColor: Color {
        switch state {
        case .idle:
            return .clear
        case .targeted:
            return AccentColor.primary.opacity(0.16)
        case .accepted:
            return AccentColor.primary.opacity(0.22)
        }
    }

    private var glowRadius: CGFloat {
        switch state {
        case .idle:
            return 0
        case .targeted:
            return 10
        case .accepted:
            return 14
        }
    }
}

public struct DropZoneLabel: View {
    private let systemImage: String
    private let label: String
    @Environment(\.dropZoneInteractionState) private var state
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    public init(systemImage: String, label: String) {
        self.systemImage = systemImage
        self.label = label
    }

    public var body: some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(AccentColor.primary)
                .symbolEffect(.bounce, value: !reduceMotion && state == .accepted)
                .offset(y: reduceMotion ? 0 : iconOffset)
            Text(label)
                .font(Typography.callout)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.xl)
    }

    private var iconOffset: CGFloat {
        switch state {
        case .idle:
            return 0
        case .targeted:
            return -3
        case .accepted:
            return -5
        }
    }
}

private struct DropZoneInteractionStateKey: EnvironmentKey {
    static let defaultValue: DropZoneInteractionState = .idle
}

private extension EnvironmentValues {
    var dropZoneInteractionState: DropZoneInteractionState {
        get { self[DropZoneInteractionStateKey.self] }
        set { self[DropZoneInteractionStateKey.self] = newValue }
    }
}
