import AppKit
import DesignSystem
import Foundation
import LocalSendKit
import SwiftUI

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
            return info.download
                ? FeatureTransferLocalization.string(forKey: "device.readyToReceive")
                : FeatureTransferLocalization.string(forKey: "device.nearby")
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

enum IncomingRequestSelectionState: Equatable, Sendable {
    case none(totalCount: Int)
    case partial(selectedCount: Int, totalCount: Int)
    case all(totalCount: Int)

    init(selectedCount: Int, totalCount: Int) {
        if totalCount == 0 || selectedCount <= 0 {
            self = .none(totalCount: totalCount)
        } else if selectedCount >= totalCount {
            self = .all(totalCount: totalCount)
        } else {
            self = .partial(selectedCount: selectedCount, totalCount: totalCount)
        }
    }

    var acceptsAll: Bool {
        if case .all = self {
            return true
        }
        return false
    }
}

enum NearbyDevicesPresentationState: Equatable, Sendable {
    case results
    case emptyIdle
    case emptyRefreshing
    case emptyScanning

    init(peerCount: Int, isRefreshing: Bool, isScanning: Bool) {
        if peerCount > 0 {
            self = .results
        } else if isScanning {
            self = .emptyScanning
        } else if isRefreshing {
            self = .emptyRefreshing
        } else {
            self = .emptyIdle
        }
    }

    var isShowingActivity: Bool {
        switch self {
        case .emptyRefreshing, .emptyScanning:
            return true
        case .results, .emptyIdle:
            return false
        }
    }
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

extension Collection where Element == StagedTransferItem {
    var stagedItemCountLabel: String {
        count == 1
            ? FeatureTransferLocalization.string(forKey: "transfer.stagedItem")
            : FeatureTransferLocalization.format("transfer.stagedItems", count)
    }

    var stagedTotalByteCount: Int64? {
        let byteCounts = compactMap(\.byteCount)
        guard byteCounts.isEmpty == false else { return nil }
        return byteCounts.reduce(0, +)
    }

    var stagedTotalSizeLabel: String? {
        guard let stagedTotalByteCount else { return nil }
        return ByteCountFormatter.string(fromByteCount: stagedTotalByteCount, countStyle: .file)
    }

    var stagedBatchSummaryLabel: String {
        guard let stagedTotalSizeLabel else { return stagedItemCountLabel }
        return FeatureTransferLocalization.format("transfer.stagedSummary", stagedItemCountLabel, stagedTotalSizeLabel)
    }
}

struct TransferFileProgress: Identifiable, Equatable, Sendable {
    enum Status: Sendable {
        case pending
        case running
        case completed
        case failed
        case canceled
    }

    let id: String
    let fileName: String
    let totalBytes: Int64?
    let transferredBytes: Int64?
    let status: Status

    var progress: Double {
        if status == .completed {
            return 1
        }
        guard let totalBytes, totalBytes > 0 else { return 0 }
        let transferred = min(max(transferredBytes ?? 0, 0), totalBytes)
        return min(max(Double(transferred) / Double(totalBytes), 0), 1)
    }

    var stablePercent: Int {
        if status == .completed {
            return 100
        }
        return min(max(Int((progress * 100).rounded(.down)), 0), 99)
    }
}

struct ActiveTransferProgress: Identifiable, Equatable, Sendable {
    enum Direction: Sendable {
        case sending
        case receiving
    }

    enum Status: Sendable {
        case running
        case completed
        case failed
        case canceled
    }

    typealias ID = String

    let id: ID
    let direction: Direction
    let counterpartName: String
    let counterpartKind: DeviceKind
    let fileName: String
    let progress: Double
    let throughput: String
    let etaDescription: String
    let byteCount: Int64?
    let fileURL: URL?
    let totalBytes: Int64?
    let transferredBytes: Int64?
    let fileProgress: [TransferFileProgress]
    let totalItemCount: Int?
    let currentItemIndex: Int?
    let currentFileTotalBytes: Int64?
    let currentFileTransferredBytes: Int64?
    let status: Status

    init(
        id: ID,
        direction: Direction,
        counterpartName: String,
        counterpartKind: DeviceKind = .generic,
        fileName: String,
        progress: Double,
        throughput: String,
        etaDescription: String,
        byteCount: Int64? = nil,
        fileURL: URL? = nil,
        totalBytes: Int64? = nil,
        transferredBytes: Int64? = nil,
        fileProgress: [TransferFileProgress] = [],
        totalItemCount: Int? = nil,
        currentItemIndex: Int? = nil,
        currentFileTotalBytes: Int64? = nil,
        currentFileTransferredBytes: Int64? = nil,
        status: Status = .running
    ) {
        self.id = id
        self.direction = direction
        self.counterpartName = counterpartName
        self.counterpartKind = counterpartKind
        self.fileName = fileName
        self.progress = progress
        self.throughput = throughput
        self.etaDescription = etaDescription
        self.byteCount = byteCount
        self.fileURL = fileURL
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.fileProgress = fileProgress
        self.totalItemCount = totalItemCount
        self.currentItemIndex = currentItemIndex
        self.currentFileTotalBytes = currentFileTotalBytes
        self.currentFileTransferredBytes = currentFileTransferredBytes
        self.status = status
    }
}

extension ActiveTransferProgress {
    var resolvedFileProgress: [TransferFileProgress] {
        if fileProgress.isEmpty == false {
            return fileProgress
        }
        let fallbackStatus: TransferFileProgress.Status
        switch status {
        case .running:
            fallbackStatus = .running
        case .completed:
            fallbackStatus = .completed
        case .failed:
            fallbackStatus = .failed
        case .canceled:
            fallbackStatus = .canceled
        }
        return [
            TransferFileProgress(
                id: fileName,
                fileName: fileName,
                totalBytes: {
                    if let currentFileTotalBytes, currentFileTotalBytes > 0 {
                        return currentFileTotalBytes
                    }
                    return byteCount
                }(),
                transferredBytes: currentFileTransferredBytes ?? transferredBytes,
                status: fallbackStatus
            )
        ]
    }

    var resolvedTotalItemCount: Int {
        max(totalItemCount ?? 1, 1)
    }

    var resolvedCurrentItemIndex: Int {
        min(max(currentItemIndex ?? 1, 1), resolvedTotalItemCount)
    }

    var overallProgress: Double {
        if status == .completed {
            return 1
        }
        if let totalBytes, totalBytes > 0 {
            let transferred = min(max(transferredBytes ?? 0, 0), totalBytes)
            return min(max(Double(transferred) / Double(totalBytes), 0), 1)
        }
        return min(max(progress, 0), 1)
    }

    var currentFileProgress: Double {
        if status == .completed {
            return 1
        }
        if let currentFileTotalBytes, currentFileTotalBytes > 0 {
            let transferred = min(max(currentFileTransferredBytes ?? 0, 0), currentFileTotalBytes)
            return min(max(Double(transferred) / Double(currentFileTotalBytes), 0), 1)
        }
        return overallProgress
    }

    var currentFileStablePercent: Int {
        if status == .completed {
            return 100
        }
        return min(max(Int((currentFileProgress * 100).rounded(.down)), 0), 99)
    }

    var remainingItemCount: Int {
        max(resolvedTotalItemCount - resolvedCurrentItemIndex, 0)
    }

    var batchPositionLabel: String? {
        guard resolvedTotalItemCount > 1 else { return nil }
        return FeatureTransferLocalization.format(
            "transfer.progress.filePositionFormat",
            resolvedCurrentItemIndex,
            resolvedTotalItemCount
        )
    }

    var stablePercent: Int {
        if status == .completed {
            return 100
        }
        return min(max(Int((overallProgress * 100).rounded(.down)), 0), 99)
    }
}

enum TransferDirection: String, Equatable, Codable, Sendable {
    case sent
    case received
}

enum TransferOutcome: String, Equatable, Codable, Sendable {
    case completed
    case declined

    var label: LocalizedStringResource {
        switch self {
        case .completed: FeatureTransferLocalization.resource("transfer.outcome.completed")
        case .declined: FeatureTransferLocalization.resource("transfer.outcome.declined")
        }
    }

    var symbol: String {
        switch self {
        case .completed: "checkmark.circle.fill"
        case .declined: "xmark.circle.fill"
        }
    }
}

struct HistoryEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let fileName: String
    let counterpart: String
    let size: String
    let timestamp: Date
    let direction: TransferDirection
    let outcome: TransferOutcome
    let fileURL: URL?

    init(
        id: UUID = UUID(),
        fileName: String,
        counterpart: String,
        size: String,
        timestamp: Date,
        direction: TransferDirection,
        outcome: TransferOutcome,
        fileURL: URL? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.counterpart = counterpart
        self.size = size
        self.timestamp = timestamp
        self.direction = direction
        self.outcome = outcome
        self.fileURL = fileURL
    }

    var subtitle: String {
        let verb = direction == .received
            ? FeatureTransferLocalization.string(forKey: "transfer.receivedFrom")
            : FeatureTransferLocalization.string(forKey: "transfer.sentTo")
        return "\(verb) \(counterpart) · \(size)"
    }

    /// Human-readable rendering of `timestamp` for row display, e.g.
    /// "Today, 2:14 PM", "Yesterday", "Mon", or "Jul 4, 2026".
    var timestampDisplay: String {
        Self.displayString(for: timestamp)
    }

    static func displayString(
        for date: Date,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> String {
        if calendar.isDateInToday(date) {
            let today = FeatureTransferLocalization.string(forKey: "transfer.today")
            return "\(today), \(date.formatted(date: .omitted, time: .shortened))"
        }
        if calendar.isDateInYesterday(date) {
            return FeatureTransferLocalization.string(forKey: "transfer.yesterday")
        }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day
        if let days, days >= 0, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

struct TransferProtocolSettings: Codable, Equatable, Sendable {
    var deviceName: String
    var tcpPort: Int
    var requirePIN: Bool
    var incomingPIN: String
    var allowDownloads: Bool
    var useHTTPS: Bool
    var saveLocation: URL

    enum CodingKeys: String, CodingKey {
        case deviceName
        case tcpPort
        case requirePIN
        case incomingPIN
        case allowDownloads
        case useHTTPS = "endToEndEncryption"
        case saveLocation
    }

    enum AlternateCodingKeys: String, CodingKey {
        case useHTTPS
    }

    init(
        deviceName: String,
        tcpPort: Int,
        requirePIN: Bool,
        incomingPIN: String,
        allowDownloads: Bool,
        useHTTPS: Bool,
        saveLocation: URL
    ) {
        self.deviceName = deviceName
        self.tcpPort = tcpPort
        self.requirePIN = requirePIN
        self.incomingPIN = Self.normalizedIncomingPIN(from: incomingPIN) ?? Self.generateIncomingPIN()
        self.allowDownloads = allowDownloads
        self.useHTTPS = useHTTPS
        self.saveLocation = saveLocation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let alternateContainer = try decoder.container(keyedBy: AlternateCodingKeys.self)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        tcpPort = try container.decode(Int.self, forKey: .tcpPort)
        requirePIN = try container.decode(Bool.self, forKey: .requirePIN)
        incomingPIN = Self.normalizedIncomingPIN(
            from: try container.decodeIfPresent(String.self, forKey: .incomingPIN)
        ) ?? Self.generateIncomingPIN()
        allowDownloads = try container.decode(Bool.self, forKey: .allowDownloads)
        useHTTPS =
            try container.decodeIfPresent(Bool.self, forKey: .useHTTPS)
            ?? alternateContainer.decodeIfPresent(Bool.self, forKey: .useHTTPS)
            ?? true
        saveLocation = try container.decode(URL.self, forKey: .saveLocation)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode(tcpPort, forKey: .tcpPort)
        try container.encode(requirePIN, forKey: .requirePIN)
        try container.encode(Self.normalizedIncomingPIN(from: incomingPIN) ?? Self.generateIncomingPIN(), forKey: .incomingPIN)
        try container.encode(allowDownloads, forKey: .allowDownloads)
        try container.encode(useHTTPS, forKey: .useHTTPS)
        try container.encode(saveLocation, forKey: .saveLocation)
    }

    static let incomingPINLength = 6

    static func generateIncomingPIN() -> String {
        String(format: "%0\(incomingPINLength)d", Int.random(in: 0..<1_000_000))
    }

    static func normalizedIncomingPIN(from candidate: String?) -> String? {
        guard let candidate else { return nil }
        let digits = candidate.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.map(String.init).joined()
        guard digits.count == incomingPINLength else { return nil }
        return digits
    }

    var protocolType: ProtocolType {
        useHTTPS ? .https : .http
    }
}

enum AccentColorChoice: String, CaseIterable, Codable, Identifiable, Sendable {
    case systemBlue
    case systemGreen
    case systemPurple
    case systemOrange
    case systemPink
    case systemTeal
    case medinaEmerald
    case samarkandTeal
    case iznikBlue
    case andalusianGold
    case ottomanCrimson
    case cordobaBurgundy
    case umayyadPearl
    case abbasidObsidian
    case system

    var id: String { rawValue }

    static let selectableCases: [AccentColorChoice] = [
        .medinaEmerald,
        .samarkandTeal,
        .iznikBlue,
        .andalusianGold,
        .ottomanCrimson,
        .cordobaBurgundy,
        .umayyadPearl,
        .abbasidObsidian
    ]

    var label: LocalizedStringResource {
        switch self {
        case .systemBlue: FeatureTransferLocalization.resource("accent.blue")
        case .systemGreen: FeatureTransferLocalization.resource("accent.green")
        case .systemPurple: FeatureTransferLocalization.resource("accent.purple")
        case .systemOrange: FeatureTransferLocalization.resource("accent.orange")
        case .systemPink: FeatureTransferLocalization.resource("accent.pink")
        case .systemTeal: FeatureTransferLocalization.resource("accent.teal")
        case .system: FeatureTransferLocalization.resource("accent.system")
        case .medinaEmerald: FeatureTransferLocalization.resource("accent.medinaEmerald")
        case .samarkandTeal: FeatureTransferLocalization.resource("accent.samarkandTeal")
        case .iznikBlue: FeatureTransferLocalization.resource("accent.iznikBlue")
        case .andalusianGold: FeatureTransferLocalization.resource("accent.andalusianGold")
        case .ottomanCrimson: FeatureTransferLocalization.resource("accent.ottomanCrimson")
        case .cordobaBurgundy: FeatureTransferLocalization.resource("accent.cordobaBurgundy")
        case .umayyadPearl: FeatureTransferLocalization.resource("accent.umayyadPearl")
        case .abbasidObsidian: FeatureTransferLocalization.resource("accent.abbasidObsidian")
        }
    }

    var theme: AccentTheme {
        switch self {
        case .systemBlue: return AccentTheme.systemBlue
        case .systemGreen: return AccentTheme.systemGreen
        case .systemPurple: return AccentTheme.systemPurple
        case .systemOrange: return AccentTheme.systemOrange
        case .systemPink: return AccentTheme.systemPink
        case .systemTeal: return AccentTheme.systemTeal
        case .system: return AccentTheme.system
        case .medinaEmerald: return AccentTheme.medinaEmerald
        case .samarkandTeal: return AccentTheme.samarkandTeal
        case .iznikBlue: return AccentTheme.iznikBlue
        case .andalusianGold: return AccentTheme.andalusianGold
        case .ottomanCrimson: return AccentTheme.ottomanCrimson
        case .cordobaBurgundy: return AccentTheme.cordobaBurgundy
        case .umayyadPearl: return AccentTheme.umayyadPearl
        case .abbasidObsidian: return AccentTheme.abbasidObsidian
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if let value = Self(rawValue: rawValue) {
            self = value
        } else {
            // Migration from legacy accent colors; old "green" was the brand green now called Medina Emerald.
            switch rawValue {
            case "green": self = .medinaEmerald
            case "blue": self = .systemBlue
            case "orange": self = .systemOrange
            case "purple": self = .systemPurple
            default: self = .medinaEmerald
            }
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
        accentColor: AccentColorChoice = .medinaEmerald,
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
        accentColor = try container.decodeIfPresent(AccentColorChoice.self, forKey: .accentColor) ?? .medinaEmerald
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
            accentColor: .medinaEmerald,
            language: .system,
            minimizeToMenuBar: false,
            launchAtLogin: true,
            reduceMotion: false,
            autoAcceptFavorites: true,
            protocolSettings: TransferProtocolSettings(
                deviceName: deviceName,
                tcpPort: 53317,
                requirePIN: false,
                incomingPIN: TransferProtocolSettings.generateIncomingPIN(),
                allowDownloads: true,
                useHTTPS: true,
                saveLocation: saveLocation
            )
        )
    }
}

extension HistoryEntry {
    static let samples: [HistoryEntry] = {
        let now = Date()
        return [
            HistoryEntry(
                fileName: "Design-Assets.zip",
                counterpart: "iPhone 15 Pro",
                size: "24.6 MB",
                timestamp: now,
                direction: .received,
                outcome: .completed
            ),
            HistoryEntry(
                fileName: "Q3-Report.pdf",
                counterpart: "iMac Studio",
                size: "4.2 MB",
                timestamp: now.addingTimeInterval(-3 * 3600),
                direction: .sent,
                outcome: .completed
            ),
            HistoryEntry(
                fileName: "IMG_4021.HEIC",
                counterpart: "iPad Air",
                size: "3.1 MB",
                timestamp: now.addingTimeInterval(-24 * 3600),
                direction: .received,
                outcome: .completed
            ),
            HistoryEntry(
                fileName: "presentation.key",
                counterpart: "Galaxy S24",
                size: "18.9 MB",
                timestamp: now.addingTimeInterval(-4 * 24 * 3600),
                direction: .sent,
                outcome: .declined
            )
        ]
    }()
}
