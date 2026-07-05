import SwiftUI

public struct BrandMark: View {
    public enum Variant {
        case color
        case monoLight
        case template
    }

    private let variant: Variant

    public init(variant: Variant = .color) {
        self.variant = variant
    }

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            // 1.5pt stroke authored against a 25-unit viewBox; keep that ratio
            // but never render below 1pt or the glyph disappears at small sizes.
            let stroke = max(1, side * (1.5 / 25))
            MarkGlyph()
                .stroke(
                    strokeColor,
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round)
                )
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var strokeColor: Color {
        switch variant {
        case .color: return Primary.p500
        case .monoLight: return .white
        case .template: return .black
        }
    }
}

private struct MarkGlyph: Shape {
    // Authored viewBox is "-0.5 0 25 25": origin x = -0.5, width/height = 25.
    private static let originX: CGFloat = -0.5
    private static let originY: CGFloat = 0
    private static let extent: CGFloat = 25

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / Self.extent

        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + (x - Self.originX) * scale,
                y: rect.minY + (y - Self.originY) * scale
            )
        }

        var path = Path()

        // Plane body (closed): the three cubic curves from path 1's `d` data.
        path.move(to: p(2.33045, 8.38999))
        path.addCurve(
            to: p(9.42048, 14.9),
            control1: p(0.250452, 11.82),
            control2: p(9.42048, 14.9)
        )
        path.addCurve(
            to: p(15.9305, 21.99),
            control1: p(9.42048, 14.9),
            control2: p(12.5005, 24.07)
        )
        path.addCurve(
            to: p(21.0505, 3.27),
            control1: p(19.5705, 19.77),
            control2: p(23.9305, 6.13)
        )
        path.addCurve(
            to: p(2.33045, 8.38999),
            control1: p(18.1705, 0.409998),
            control2: p(4.55045, 4.74999)
        )
        path.closeSubpath()

        // Wing fold (path 2): straight line.
        path.move(to: p(15.1999, 9.12))
        path.addLine(to: p(9.41992, 14.9))

        return path
    }
}
