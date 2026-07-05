import SwiftUI

public enum Typography {
    public static let largeTitle = Font.system(.largeTitle, weight: .regular)
    public static let title1 = Font.system(.title, weight: .regular)
    public static let title2 = Font.system(.title2, weight: .bold)
    public static let title3 = Font.system(.title3, weight: .semibold)
    public static let headline = Font.system(.headline, weight: .semibold)
    public static let body = Font.system(.body, weight: .regular)
    public static let callout = Font.system(.callout, weight: .regular)
    public static let subheadline = Font.system(.subheadline, weight: .regular)
    public static let footnote = Font.system(.footnote, weight: .regular)
    public static let caption1 = Font.system(.caption, weight: .regular)
    public static let caption2 = Font.system(.caption2, weight: .regular)

    // IP addresses, fingerprints/hashes, protocol debug text.
    public static func mono(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }
}

extension View {
    // Frequently-updating numeric stats (speed, %, ETA) — stops digit-width
    // jitter from re-laying-out the surrounding text as values change.
    public func monospacedStat() -> some View {
        monospacedDigit()
    }
}
