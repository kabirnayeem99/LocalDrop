import Foundation
import LocalSendKit

enum DeviceKind: Sendable {
    case macbook
    case desktop
    case phone
    case tablet
    case generic

    var symbol: String {
        switch self {
        case .macbook: "laptopcomputer"
        case .desktop: "desktopcomputer"
        case .phone: "iphone"
        case .tablet: "ipad"
        case .generic: "macwindow"
        }
    }

    init(deviceType: DeviceType?) {
        switch deviceType {
        case .mobile:
            self = .phone
        case .desktop, .server:
            self = .desktop
        case .web:
            self = .generic
        case .headless:
            self = .generic
        case nil:
            self = .generic
        }
    }
}

struct NearbyPeerItem: Identifiable, Hashable, Sendable {
    typealias ID = String

    let id: ID
    let host: String
    let name: String
    let subtitle: String
    let kind: DeviceKind
    let fingerprint: String
    let protocolType: ProtocolType?
    let port: Int?
    let supportsDownloads: Bool

    init(
        id: ID,
        host: String,
        name: String,
        subtitle: String,
        kind: DeviceKind,
        fingerprint: String,
        protocolType: ProtocolType?,
        port: Int?,
        supportsDownloads: Bool
    ) {
        self.id = id
        self.host = host
        self.name = name
        self.subtitle = subtitle
        self.kind = kind
        self.fingerprint = fingerprint
        self.protocolType = protocolType
        self.port = port
        self.supportsDownloads = supportsDownloads
    }

    init(peer: DiscoveredPeer) {
        let info = peer.info
        self.init(
            id: info.fingerprint,
            host: peer.host,
            name: info.alias,
            subtitle: Self.makeSubtitle(info: info),
            kind: DeviceKind(deviceType: info.deviceType),
            fingerprint: info.fingerprint,
            protocolType: info.protocolType,
            port: info.port,
            supportsDownloads: info.download
        )
    }

    private static func makeSubtitle(info: RegisterInfo) -> String {
        var parts: [String] = []
        if let deviceModel = info.deviceModel, deviceModel.isEmpty == false {
            parts.append(deviceModel)
        }
        if let port = info.port {
            parts.append("#\(port)")
        }
        if parts.isEmpty {
            return info.download ? "Ready to receive" : "Nearby"
        }
        return parts.joined(separator: " · ")
    }
}

struct IncomingTransferFile: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let size: String
    let symbol: String
}

struct IncomingTransferRequest: Identifiable, Equatable, Sendable {
    let id: String
    let deviceName: String
    let subtitle: String
    let sourceKind: DeviceKind
    let files: [IncomingTransferFile]
}

struct TransferFeedback: Identifiable, Equatable, Sendable {
    enum Tone: String, Codable, Sendable {
        case neutral
        case success
        case pending
        case destructive
    }

    let id: UUID
    let message: String
    let symbol: String
    let tone: Tone

    init(id: UUID = UUID(), message: String, symbol: String, tone: Tone = .neutral) {
        self.id = id
        self.message = message
        self.symbol = symbol
        self.tone = tone
    }
}

enum IncomingTransferDecision: Equatable, Sendable {
    case reject(requestID: String)
    case acceptAll(requestID: String)
    case acceptSubset(requestID: String, fileIDs: Set<String>)
    case noTransferNeeded(requestID: String)
}

struct StagedTransferItem: Identifiable, Equatable, Sendable {
    let id: String
    let fileURL: URL
    let name: String
    let subtitle: String
    let fileTypeSymbol: String
    let byteCount: Int64?
}

struct ActiveTransferProgress: Identifiable, Equatable, Sendable {
    enum Direction: Sendable {
        case sending
        case receiving
    }

    typealias ID = String

    let id: ID
    let direction: Direction
    let counterpartName: String
    let fileName: String
    let progress: Double
    let throughput: String
    let etaDescription: String
}

enum TransferDirection: Equatable, Sendable {
    case sent
    case received
}

enum TransferOutcome: Equatable, Sendable {
    case completed
    case declined

    var label: String {
        switch self {
        case .completed: "Completed"
        case .declined: "Declined"
        }
    }

    var symbol: String {
        switch self {
        case .completed: "checkmark.circle.fill"
        case .declined: "xmark.circle.fill"
        }
    }
}

struct HistoryEntry: Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let counterpart: String
    let size: String
    let timestamp: String
    let direction: TransferDirection
    let outcome: TransferOutcome

    init(
        id: UUID = UUID(),
        fileName: String,
        counterpart: String,
        size: String,
        timestamp: String,
        direction: TransferDirection,
        outcome: TransferOutcome
    ) {
        self.id = id
        self.fileName = fileName
        self.counterpart = counterpart
        self.size = size
        self.timestamp = timestamp
        self.direction = direction
        self.outcome = outcome
    }

    var subtitle: String {
        let verb = direction == .received ? "Received from" : "Sent to"
        return "\(verb) \(counterpart) · \(size)"
    }
}

struct TransferProtocolSettings: Codable, Equatable, Sendable {
    var deviceName: String
    var tcpPort: Int
    var requirePIN: Bool
    var allowDownloads: Bool
    var endToEndEncryption: Bool
    var saveLocation: URL
}

enum AccentColorChoice: String, CaseIterable, Codable, Identifiable, Sendable {
    case green
    case blue
    case orange
    case purple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .green: "Green"
        case .blue: "Blue"
        case .orange: "Orange"
        case .purple: "Purple"
        }
    }
}

struct TransferSettingsSnapshot: Codable, Equatable, Sendable {
    var quickSave: QuickSaveMode
    var appearance: AppearanceSetting
    var accentColor: AccentColorChoice
    var language: LanguageSetting
    var minimizeToMenuBar: Bool
    var launchAtLogin: Bool
    var reduceMotion: Bool
    var autoAcceptFavorites: Bool
    var protocolSettings: TransferProtocolSettings

    enum CodingKeys: String, CodingKey {
        case quickSave
        case appearance
        case accentColor
        case language
        case minimizeToMenuBar
        case launchAtLogin
        case reduceMotion
        case autoAcceptFavorites
        case protocolSettings
    }

    init(
        quickSave: QuickSaveMode,
        appearance: AppearanceSetting,
        accentColor: AccentColorChoice = .green,
        language: LanguageSetting,
        minimizeToMenuBar: Bool,
        launchAtLogin: Bool,
        reduceMotion: Bool,
        autoAcceptFavorites: Bool,
        protocolSettings: TransferProtocolSettings
    ) {
        self.quickSave = quickSave
        self.appearance = appearance
        self.accentColor = accentColor
        self.language = language
        self.minimizeToMenuBar = minimizeToMenuBar
        self.launchAtLogin = launchAtLogin
        self.reduceMotion = reduceMotion
        self.autoAcceptFavorites = autoAcceptFavorites
        self.protocolSettings = protocolSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quickSave = try container.decode(QuickSaveMode.self, forKey: .quickSave)
        appearance = try container.decode(AppearanceSetting.self, forKey: .appearance)
        accentColor = try container.decodeIfPresent(AccentColorChoice.self, forKey: .accentColor) ?? .green
        language = try container.decode(LanguageSetting.self, forKey: .language)
        minimizeToMenuBar = try container.decode(Bool.self, forKey: .minimizeToMenuBar)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        reduceMotion = try container.decode(Bool.self, forKey: .reduceMotion)
        autoAcceptFavorites = try container.decode(Bool.self, forKey: .autoAcceptFavorites)
        protocolSettings = try container.decode(TransferProtocolSettings.self, forKey: .protocolSettings)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(quickSave, forKey: .quickSave)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(accentColor, forKey: .accentColor)
        try container.encode(language, forKey: .language)
        try container.encode(minimizeToMenuBar, forKey: .minimizeToMenuBar)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(reduceMotion, forKey: .reduceMotion)
        try container.encode(autoAcceptFavorites, forKey: .autoAcceptFavorites)
        try container.encode(protocolSettings, forKey: .protocolSettings)
    }

    static func `default`(deviceName: String, saveLocation: URL) -> Self {
        Self(
            quickSave: .on,
            appearance: .system,
            accentColor: .green,
            language: .system,
            minimizeToMenuBar: false,
            launchAtLogin: true,
            reduceMotion: false,
            autoAcceptFavorites: true,
            protocolSettings: TransferProtocolSettings(
                deviceName: deviceName,
                tcpPort: 53317,
                requirePIN: false,
                allowDownloads: true,
                endToEndEncryption: true,
                saveLocation: saveLocation
            )
        )
    }
}

extension HistoryEntry {
    static let samples: [HistoryEntry] = [
        HistoryEntry(
            fileName: "Design-Assets.zip",
            counterpart: "iPhone 15 Pro",
            size: "24.6 MB",
            timestamp: "Today, 2:14 PM",
            direction: .received,
            outcome: .completed
        ),
        HistoryEntry(
            fileName: "Q3-Report.pdf",
            counterpart: "iMac Studio",
            size: "4.2 MB",
            timestamp: "Today, 11:02 AM",
            direction: .sent,
            outcome: .completed
        ),
        HistoryEntry(
            fileName: "IMG_4021.HEIC",
            counterpart: "iPad Air",
            size: "3.1 MB",
            timestamp: "Yesterday",
            direction: .received,
            outcome: .completed
        ),
        HistoryEntry(
            fileName: "presentation.key",
            counterpart: "Galaxy S24",
            size: "18.9 MB",
            timestamp: "Mon",
            direction: .sent,
            outcome: .declined
        )
    ]
}
