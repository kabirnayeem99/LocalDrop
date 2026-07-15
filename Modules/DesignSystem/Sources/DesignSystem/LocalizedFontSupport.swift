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

private enum ScriptFontFamily {
    case system
    case cairo
    case tiroBangla
    case notoNastaliqUrdu

    init(locale: Locale) {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        let languageCode = identifier.split(separator: "-").first.map(String.init) ?? identifier

        switch languageCode {
        case "ar", "ug":
            self = .cairo
        case "bn":
            self = .tiroBangla
        case "ur":
            self = .notoNastaliqUrdu
        default:
            self = .system
        }
    }

    func fontName(for weight: Font.Weight) -> String? {
        switch self {
        case .system:
            return nil
        case .cairo:
            switch weight {
            case .bold, .heavy, .black:
                return "Cairo-Bold"
            case .medium:
                return "Cairo-Medium"
            case .semibold:
                return "Cairo-SemiBold"
            default:
                return "Cairo-Regular"
            }
        case .tiroBangla:
            return "TiroBangla-Regular"
        case .notoNastaliqUrdu:
            switch weight {
            case .bold, .heavy, .black:
                return "NotoNastaliqUrdu-Bold"
            case .medium:
                return "NotoNastaliqUrdu-Medium"
            case .semibold:
                return "NotoNastaliqUrdu-SemiBold"
            default:
                return "NotoNastaliqUrdu-Regular"
            }
        }
    }
}

private struct AppFontModifier: ViewModifier {
    @Environment(\.locale) private var locale

    let style: AppFontStyle

    func body(content: Content) -> some View {
        content.font(resolvedFont)
    }

    private var resolvedFont: Font {
        let family = ScriptFontFamily(locale: locale)

        switch style {
        case .text(let textStyle, let weight):
            guard let customName = family.fontName(for: weight) else {
                return .system(textStyle, weight: weight)
            }
            return .custom(customName, size: baseSize(for: textStyle), relativeTo: textStyle)
        case .fixed(let size, let weight):
            guard let customName = family.fontName(for: weight) else {
                return .system(size: size, weight: weight)
            }
            return .custom(customName, size: size)
        }
    }

    private func baseSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle:
            return 34
        case .title:
            return 28
        case .title2:
            return 22
        case .title3:
            return 20
        case .headline, .body:
            return 17
        case .callout:
            return 16
        case .subheadline:
            return 15
        case .footnote:
            return 13
        case .caption:
            return 12
        case .caption2:
            return 11
        @unknown default:
            return 17
        }
    }
}

extension View {
    public func appFont(_ style: AppFontStyle) -> some View {
        modifier(AppFontModifier(style: style))
    }
}
