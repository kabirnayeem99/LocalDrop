import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case receive
    case send
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .receive: return "Receive"
        case .send: return "Send"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .receive: return "dot.radiowaves.up.forward"
        case .send: return "paperplane"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

enum QuickSaveMode: String, CaseIterable, Identifiable {
    case off
    case favorites
    case on

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .favorites: return "Favorites"
        case .on: return "On"
        }
    }
}

enum ActiveSheet: Identifiable {
    case incoming
    case progress

    var id: Int {
        switch self {
        case .incoming: return 0
        case .progress: return 1
        }
    }
}

enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum LanguageSetting: String, CaseIterable, Identifiable {
    case system
    case english
    case german

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .english: return "English"
        case .german: return "Deutsch"
        }
    }
}

@Observable
final class TransferViewState {
    var screen: Screen = .receive
    var quickSave: QuickSaveMode = .on
    var activeSheet: ActiveSheet?

    let deviceName = "MacBook M4 Air"
    let waitingIdentifier = 9
    let port = "53317"
    let saveLocation = "~/Downloads/LocalDrop"

    var appearance: AppearanceSetting = .system
    var language: LanguageSetting = .system

    var minimizeToMenuBar = false
    var launchAtLogin = true
    var reduceMotion = false
    var requirePIN = false
    var autoAcceptFavorites = true
    var endToEndEncryption = true

    var stagedFile: StagedFile? = StagedFile(name: "Design-Assets.zip", subtitle: "3 files · 24.6 MB ready to send")
    var isDropTargeted = false

    var transferProgress = 0.62
    let transferTarget = "iPhone 15 Pro"
    let transferFileName = "Design-Assets.zip"
    let transferSpeed = "8.4 MB/s"
    let transferETA = "~4s remaining"
}
