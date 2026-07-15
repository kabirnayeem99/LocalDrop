import SwiftUI

public enum AppFontStyle {
    case text(Font.TextStyle, Font.Weight)
    case fixed(CGFloat, Font.Weight)

    public static let largeTitle = Self.text(.largeTitle, .regular)
    public static let title1 = Self.text(.title, .regular)
    public static let title2 = Self.text(.title2, .bold)
    public static let title3 = Self.text(.title3, .semibold)
    public static let headline = Self.text(.headline, .semibold)
    public static let body = Self.text(.body, .regular)
    public static let callout = Self.text(.callout, .regular)
    public static let subheadline = Self.text(.subheadline, .regular)
    public static let footnote = Self.text(.footnote, .regular)
    public static let caption1 = Self.text(.caption, .regular)
    public static let caption2 = Self.text(.caption2, .regular)
}

private struct AppFontModifier: ViewModifier {
    let style: AppFontStyle

    func body(content: Content) -> some View {
        content.font(resolvedFont)
    }

    private var resolvedFont: Font {
        switch style {
        case .text(let textStyle, let weight):
            return .system(textStyle, weight: weight)
        case .fixed(let size, let weight):
            return .system(size: size, weight: weight)
        }
    }
}

extension View {
    public func appFont(_ style: AppFontStyle) -> some View {
        modifier(AppFontModifier(style: style))
    }
}
