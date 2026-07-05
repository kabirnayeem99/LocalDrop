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

public enum AccentColor {
    public static let primary = adaptive(light: Primary.p500, dark: Primary.p400)
    public static let primaryHover = adaptive(light: Primary.p600, dark: Primary.p300)
    public static let primaryPressed = adaptive(light: Primary.p700, dark: Primary.p500)
    public static let primaryDisabled = adaptive(
        light: Primary.p200.opacity(0.4),
        dark: Primary.p700.opacity(0.4)
    )
    public static let primarySubtleFill = adaptive(light: Primary.p50, dark: Primary.p900)

    // Resolves per-appearance rather than reusing the light base, so accent
    // usage keeps contrast against dark backgrounds the way system accents do.
    private static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}
