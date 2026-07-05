import SwiftUI

public struct StatusBadge: View {
    public enum Content {
        case count(Int)
        case dot
    }

    private let content: Content
    private let tint: Color

    public init(count: Int, tint: Color = .red) {
        self.content = .count(count)
        self.tint = tint
    }

    public init(tint: Color = .red) {
        self.content = .dot
        self.tint = tint
    }

    public var body: some View {
        switch content {
        case .count(let value):
            Text(value > 99 ? "99+" : "\(value)")
                .font(Typography.caption2)
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, value > 9 ? Spacing.xxs : 0)
                .frame(minWidth: 16, minHeight: 16)
                .background(tint, in: Capsule())
        case .dot:
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
        }
    }
}
