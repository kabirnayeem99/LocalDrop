import SwiftUI

public struct PulseRingView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    @Environment(\.accentTheme) private var accentTheme
    @State private var animating = false

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    private let ringCount: Int
    private let color: Color?
    private let lineWidth: CGFloat
    private let duration: Double

    private var resolvedColor: Color { color ?? accentTheme.primary }

    public init(
        ringCount: Int = 2,
        color: Color? = nil,
        lineWidth: CGFloat = 1.5,
        duration: Double = 2.4
    ) {
        self.ringCount = ringCount
        self.color = color
        self.lineWidth = lineWidth
        self.duration = duration
    }

    public var body: some View {
        ZStack {
            if reduceMotion {
                // Resting visible state, not the expand/fade end-state (fully transparent).
                Circle()
                    .stroke(resolvedColor, lineWidth: lineWidth)
                    .scaleEffect(0.7)
                    .opacity(0.6)
            } else {
                ForEach(0..<ringCount, id: \.self) { index in
                    Circle()
                        .stroke(resolvedColor, lineWidth: lineWidth)
                        .scaleEffect(animating ? 1.0 : 0.4)
                        .opacity(animating ? 0 : 0.6)
                        .animation(ringAnimation(delay: staggerDelay(for: index)), value: animating)
                }
                .onAppear { animating = true }
            }
        }
    }

    private func staggerDelay(for index: Int) -> Double {
        guard ringCount > 0 else { return 0 }
        return duration / Double(ringCount) * Double(index)
    }

    private func ringAnimation(delay: Double) -> Animation? {
        .easeOut(duration: duration).repeatForever(autoreverses: false).delay(delay)
    }
}
