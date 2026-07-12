import SwiftUI

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}

public enum Primary {
    public static let p50 = Color(hex: 0xF0F6EE)
    public static let p100 = Color(hex: 0xE2EEDD)
    public static let p200 = Color(hex: 0xCAE0C2)
    public static let p300 = Color(hex: 0xA7CC99)
    public static let p400 = Color(hex: 0x6CAA55)
    public static let p500 = Color(hex: 0x426834)
    public static let p600 = Color(hex: 0x38592C)
    public static let p700 = Color(hex: 0x2A4521)
    public static let p800 = Color(hex: 0x1D3116)
    public static let p900 = Color(hex: 0x111D0C)
}

public struct AccentTheme {
    public let primary: Color
    public let primaryHover: Color
    public let primaryPressed: Color
    public let primaryDisabled: Color
    public let primarySubtleFill: Color

    public init(
        primary: Color,
        primaryHover: Color,
        primaryPressed: Color,
        primaryDisabled: Color,
        primarySubtleFill: Color
    ) {
        self.primary = primary
        self.primaryHover = primaryHover
        self.primaryPressed = primaryPressed
        self.primaryDisabled = primaryDisabled
        self.primarySubtleFill = primarySubtleFill
    }

    public static func palette(
        lightHex: UInt32,
        darkHex: UInt32
    ) -> AccentTheme {
        let primary = adaptive(light: Color(hex: lightHex), dark: Color(hex: darkHex))
        return AccentTheme(
            primary: primary,
            primaryHover: primary.opacity(0.88),
            primaryPressed: primary.opacity(0.76),
            primaryDisabled: primary.opacity(0.40),
            primarySubtleFill: primary.opacity(0.12)
        )
    }

    public static func systemAccent() -> AccentTheme {
        theme(for: .controlAccentColor)
    }

    private static func theme(for color: NSColor) -> AccentTheme {
        let c = Color(nsColor: color)
        return AccentTheme(
            primary: c,
            primaryHover: Color(nsColor: color.withSystemEffect(.pressed)),
            primaryPressed: Color(nsColor: color.withSystemEffect(.deepPressed)),
            primaryDisabled: c.opacity(0.4),
            primarySubtleFill: c.opacity(0.12)
        )
    }

    public static let systemBlue: AccentTheme = theme(for: .systemBlue)
    public static let systemGreen: AccentTheme = theme(for: .systemGreen)
    public static let systemPurple: AccentTheme = theme(for: .systemPurple)
    public static let systemOrange: AccentTheme = theme(for: .systemOrange)
    public static let systemPink: AccentTheme = theme(for: .systemPink)
    public static let systemTeal: AccentTheme = theme(for: .systemTeal)

    public static let medinaEmerald = palette(lightHex: 0x15803D, darkHex: 0x22C55E)
    public static let samarkandTeal = palette(lightHex: 0x0F766E, darkHex: 0x2DD4BF)
    public static let iznikBlue = palette(lightHex: 0x2563EB, darkHex: 0x60A5FA)
    public static let andalusianGold = palette(lightHex: 0xC58A12, darkHex: 0xF2B84B)
    public static let ottomanCrimson = palette(lightHex: 0xB42335, darkHex: 0xF05261)
    public static let cordobaBurgundy = palette(lightHex: 0x7F1D3A, darkHex: 0xD65A82)
    public static let umayyadPearl = palette(lightHex: 0xD6C7A1, darkHex: 0xE8DDBD)
    public static let abbasidObsidian = palette(lightHex: 0x27272A, darkHex: 0x71717A)
    public static let system = systemAccent()
}

public enum AccentThemeKey: EnvironmentKey {
    public static let defaultValue: AccentTheme = .medinaEmerald
}

public extension EnvironmentValues {
    var accentTheme: AccentTheme {
        get { self[AccentThemeKey.self] }
        set { self[AccentThemeKey.self] = newValue }
    }
}

private func adaptive(light: Color, dark: Color) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(isDark ? dark : light)
    })
}

public enum AccentColor {
    @available(*, deprecated, renamed: "AccentTheme.medinaEmerald.primary")
    public static let primary = AccentTheme.medinaEmerald.primary
    @available(*, deprecated, renamed: "AccentTheme.medinaEmerald.primaryHover")
    public static let primaryHover = AccentTheme.medinaEmerald.primaryHover
    @available(*, deprecated, renamed: "AccentTheme.medinaEmerald.primaryPressed")
    public static let primaryPressed = AccentTheme.medinaEmerald.primaryPressed
    @available(*, deprecated, renamed: "AccentTheme.medinaEmerald.primaryDisabled")
    public static let primaryDisabled = AccentTheme.medinaEmerald.primaryDisabled
    @available(*, deprecated, renamed: "AccentTheme.medinaEmerald.primarySubtleFill")
    public static let primarySubtleFill = AccentTheme.medinaEmerald.primarySubtleFill
}

public enum SemanticColor {
    public static let brand = AccentTheme.medinaEmerald.primary
    public static let brandSubtleFill = AccentTheme.medinaEmerald.primarySubtleFill

    public static let discovery = Color(nsColor: .systemCyan)
    public static let discoverySubtleFill = Color(nsColor: .systemCyan).opacity(0.12)

    public static let sending = Color(nsColor: .systemBlue)
    public static let sendingSubtleFill = Color(nsColor: .systemBlue).opacity(0.12)

    public static let receiving = Color(nsColor: .systemGreen)
    public static let receivingSubtleFill = Color(nsColor: .systemGreen).opacity(0.12)

    public static let pending = Color(nsColor: .systemOrange)
    public static let pendingSubtleFill = Color(nsColor: .systemOrange).opacity(0.13)

    public static let success = Color(nsColor: .systemGreen)
    public static let successSubtleFill = Color(nsColor: .systemGreen).opacity(0.12)

    public static let destructive = Color(nsColor: .systemRed)
    public static let destructiveSubtleFill = Color(nsColor: .systemRed).opacity(0.12)
}
