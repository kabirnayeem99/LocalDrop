import SwiftUI

enum Screen: String, CaseIterable, Identifiable, Codable, Sendable {
    case receive
    case send
    case history
    case settings

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .receive: "screen.receive.title"
        case .send: "screen.send.title"
        case .history: "screen.history.title"
        case .settings: "screen.settings.title"
        }
    }

    var symbol: String {
        switch self {
        case .receive: "dot.radiowaves.up.forward"
        case .send: "paperplane"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

enum QuickSaveMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case favorites
    case on

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .off: "quicksave.mode.off"
        case .favorites: "quicksave.mode.favorites"
        case .on: "quicksave.mode.on"
        }
    }
}

enum ActiveSheet: Identifiable, Equatable {
    case incoming
    case progress

    var id: Int {
        switch self {
        case .incoming: 0
        case .progress: 1
        }
    }
}

enum AppearanceSetting: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .system: "appearance.system"
        case .light: "appearance.light"
        case .dark: "appearance.dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum LanguageSetting: String, CaseIterable, Identifiable, Codable, Sendable {
    case arabic
    case indonesian
    case urdu
    case bengali
    case hindi
    case turkish
    case english
    case french
    case russian
    case uyghur
    case simplifiedChinese
    case spanish
    case brazilianPortuguese
    case german
    case vietnamese
    case korean
    case japanese
    case system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .arabic: "العربية"
        case .indonesian: "Bahasa Indonesia"
        case .urdu: "اردو"
        case .bengali: "বাংলা"
        case .hindi: "हिन्दी"
        case .turkish: "Türkçe"
        case .english: "English"
        case .french: "Français"
        case .russian: "Русский"
        case .uyghur: "ئۇيغۇرچە"
        case .simplifiedChinese: "简体中文"
        case .spanish: "Español"
        case .brazilianPortuguese: "Português (Brasil)"
        case .german: "Deutsch"
        case .vietnamese: "Tiếng Việt"
        case .korean: "한국어"
        case .japanese: "日本語"
        case .system: FeatureTransferLocalization.string(forKey: "language.system")
        }
    }

    var locale: Locale? {
        switch self {
        case .arabic: Locale(identifier: "ar")
        case .indonesian: Locale(identifier: "id")
        case .urdu: Locale(identifier: "ur")
        case .bengali: Locale(identifier: "bn")
        case .hindi: Locale(identifier: "hi")
        case .turkish: Locale(identifier: "tr")
        case .english: Locale(identifier: "en-US")
        case .french: Locale(identifier: "fr")
        case .russian: Locale(identifier: "ru")
        case .uyghur: Locale(identifier: "ug")
        case .simplifiedChinese: Locale(identifier: "zh-Hans")
        case .spanish: Locale(identifier: "es")
        case .brazilianPortuguese: Locale(identifier: "pt-BR")
        case .german: Locale(identifier: "de")
        case .vietnamese: Locale(identifier: "vi")
        case .korean: Locale(identifier: "ko")
        case .japanese: Locale(identifier: "ja")
        case .system: nil
        }
    }
}

extension View {
    // `.system` must leave the environment untouched rather than force an
    // explicit `Locale` value, so it behaves identically to today's no-override default.
    @ViewBuilder
    func applyingLanguageOverride(_ language: LanguageSetting) -> some View {
        if let locale = language.locale {
            self.environment(\.locale, locale)
        } else {
            self
        }
    }
}
