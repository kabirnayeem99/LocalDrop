import SwiftUI

enum Screen: String, CaseIterable, Identifiable, Codable, Sendable {
    case receive
    case send
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .receive: "Receive"
        case .send: "Send"
        case .history: "History"
        case .settings: "Settings"
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

    var label: String {
        switch self {
        case .off: "Off"
        case .favorites: "Favorites"
        case .on: "On"
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

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
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
    case system
    case english
    case german

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .english: "English"
        case .german: "Deutsch"
        }
    }
}
