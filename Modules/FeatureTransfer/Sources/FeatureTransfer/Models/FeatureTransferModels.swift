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
        if parts.count == 1 {
            return parts[0]
        }
        return FeatureTransferLocalization.format("device.subtitleFormat", parts[0], parts[1])
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

enum SendMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case single
    case multiple
    case link

    var id: String { rawValue }
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

enum TransferETA: Equatable, Sendable {
    case none
    case calculating
    case stalled
    case estimated(seconds: TimeInterval)

    var descriptionText: String? {
        switch self {
        case .none:
            return nil
        case .calculating:
            return FeatureTransferLocalization.string(forKey: "transfer.eta.calculating")
        case .stalled:
            return FeatureTransferLocalization.string(forKey: "transfer.eta.stalled")
        case .estimated(let seconds):
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
            formatter.unitsStyle = .abbreviated
            formatter.maximumUnitCount = 2
            formatter.zeroFormattingBehavior = [.dropLeading, .dropMiddle]
            return formatter.string(from: max(seconds, 1))
        }
    }
}

struct TransferFileProgress: Identifiable, Equatable, Sendable {
    enum Status: Sendable {
        case queued
        case transferring
        case completed
        case failed
        case canceled
        case retrying

        static var pending: Self { .queued }
        static var running: Self { .transferring }

        var isTerminal: Bool {
            switch self {
            case .completed, .failed, .canceled:
                return true
            case .queued, .transferring, .retrying:
                return false
            }
        }
    }

    let id: String
    let fileName: String
    let attemptIndex: Int
    let status: Status
    let totalBytes: Int64?
    let effectiveTotalBytesForDisplay: Int64?
    let actualTransferredBytes: Int64
    let displayedTransferredBytes: Int64
    let completedBytesContribution: Int64
    let failedBytesContribution: Int64
    let lastEventSequence: Int64
    let lastProgressAtMonotonic: TimeInterval
    let errorSummary: String?
    let fileURL: URL?
    let order: Int

    init(
        id: String,
        fileName: String,
        attemptIndex: Int = 0,
        status: Status,
        totalBytes: Int64? = nil,
        effectiveTotalBytesForDisplay: Int64? = nil,
        actualTransferredBytes: Int64 = 0,
        displayedTransferredBytes: Int64 = 0,
        completedBytesContribution: Int64 = 0,
        failedBytesContribution: Int64 = 0,
        lastEventSequence: Int64 = 0,
        lastProgressAtMonotonic: TimeInterval = 0,
        errorSummary: String? = nil,
        fileURL: URL? = nil,
        order: Int = 0
    ) {
        self.id = id
        self.fileName = fileName
        self.attemptIndex = attemptIndex
        self.status = status
        self.totalBytes = totalBytes
        self.effectiveTotalBytesForDisplay = effectiveTotalBytesForDisplay ?? totalBytes
        self.actualTransferredBytes = max(actualTransferredBytes, 0)
        self.displayedTransferredBytes = max(displayedTransferredBytes, 0)
        self.completedBytesContribution = max(completedBytesContribution, 0)
        self.failedBytesContribution = max(failedBytesContribution, 0)
        self.lastEventSequence = lastEventSequence
        self.lastProgressAtMonotonic = lastProgressAtMonotonic
        self.errorSummary = errorSummary
        self.fileURL = fileURL
        self.order = order
    }

    var transferredBytes: Int64? {
        status == .queued ? 0 : displayedTransferredBytes
    }

    var hasKnownTotal: Bool {
        if let effectiveTotalBytesForDisplay {
            return effectiveTotalBytesForDisplay > 0
        }
        return false
    }

    var determinateProgress: Double? {
        guard let total = effectiveTotalBytesForDisplay, total > 0 else {
            return status == .completed ? 1 : nil
        }
        let transferred = min(max(displayedTransferredBytes, 0), total)
        return min(max(Double(transferred) / Double(total), 0), 1)
    }

    var progress: Double {
        determinateProgress ?? (status == .completed ? 1 : 0)
    }

    var stablePercent: Int {
        if status == .completed {
            return 100
        }
        guard let determinateProgress else { return 0 }
        return min(max(Int((determinateProgress * 100).rounded(.down)), 0), 99)
    }

    var byteProgressLabel: String {
        let transferredLabel = ByteCountFormatter.string(
            fromByteCount: displayedTransferredBytes,
            countStyle: .file
        )
        guard let total = effectiveTotalBytesForDisplay, total > 0 else {
            return transferredLabel
        }
        let totalLabel = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return FeatureTransferLocalization.format("transfer.progress.byteFormat", transferredLabel, totalLabel)
    }

    var statusLabel: String {
        switch status {
        case .queued:
            return FeatureTransferLocalization.string(forKey: "transfer.status.queued")
        case .transferring:
            return FeatureTransferLocalization.string(forKey: "transfer.progress.sending")
        case .completed:
            return FeatureTransferLocalization.string(forKey: "transfer.progress.done")
        case .failed:
            return FeatureTransferLocalization.string(forKey: "transfer.status.failed")
        case .canceled:
            return FeatureTransferLocalization.string(forKey: "transfer.status.canceled")
        case .retrying:
            return FeatureTransferLocalization.string(forKey: "transfer.status.retrying")
        }
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

        var isTerminal: Bool {
            switch self {
            case .completed, .failed, .canceled:
                return true
            case .running:
                return false
            }
        }
    }

    typealias ID = String

    let id: ID
    let attemptID: String
    let direction: Direction
    let counterpartName: String
    let counterpartKind: DeviceKind
    let status: Status
    let files: [TransferFileProgress]
    let totalBytesKnown: Int64?
    let displayableTransferredBytes: Int64
    let actualTransferredBytes: Int64
    let smoothedBytesPerSecond: Double?
    let eta: TransferETA
    let startedAtMonotonic: TimeInterval
    let lastProgressAtMonotonic: TimeInterval

    init(
        id: ID,
        attemptID: String,
        direction: Direction,
        counterpartName: String,
        counterpartKind: DeviceKind = .generic,
        status: Status = .running,
        files: [TransferFileProgress],
        totalBytesKnown: Int64? = nil,
        displayableTransferredBytes: Int64 = 0,
        actualTransferredBytes: Int64 = 0,
        smoothedBytesPerSecond: Double? = nil,
        eta: TransferETA = .none,
        startedAtMonotonic: TimeInterval = 0,
        lastProgressAtMonotonic: TimeInterval = 0
    ) {
        self.id = id
        self.attemptID = attemptID
        self.direction = direction
        self.counterpartName = counterpartName
        self.counterpartKind = counterpartKind
        self.status = status
        self.files = files.sorted { $0.order < $1.order }
        self.totalBytesKnown = totalBytesKnown
        self.displayableTransferredBytes = max(displayableTransferredBytes, 0)
        self.actualTransferredBytes = max(actualTransferredBytes, 0)
        self.smoothedBytesPerSecond = smoothedBytesPerSecond
        self.eta = eta
        self.startedAtMonotonic = startedAtMonotonic
        self.lastProgressAtMonotonic = lastProgressAtMonotonic
    }

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
        let resolvedFiles: [TransferFileProgress]
        if fileProgress.isEmpty == false {
            resolvedFiles = fileProgress.enumerated().map { index, item in
                TransferFileProgress(
                    id: item.id,
                    fileName: item.fileName,
                    attemptIndex: item.attemptIndex,
                    status: item.status,
                    totalBytes: item.totalBytes,
                    effectiveTotalBytesForDisplay: item.effectiveTotalBytesForDisplay,
                    actualTransferredBytes: item.actualTransferredBytes,
                    displayedTransferredBytes: item.displayedTransferredBytes,
                    completedBytesContribution: item.completedBytesContribution,
                    failedBytesContribution: item.failedBytesContribution,
                    lastEventSequence: item.lastEventSequence,
                    lastProgressAtMonotonic: item.lastProgressAtMonotonic,
                    errorSummary: item.errorSummary,
                    fileURL: item.fileURL,
                    order: item.order == 0 ? index : item.order
                )
            }
        } else {
            let fallbackStatus: TransferFileProgress.Status
            switch status {
            case .running:
                fallbackStatus = .transferring
            case .completed:
                fallbackStatus = .completed
            case .failed:
                fallbackStatus = .failed
            case .canceled:
                fallbackStatus = .canceled
            }
            let resolvedTransferred = currentFileTransferredBytes ?? transferredBytes ?? {
                guard let totalBytes else { return 0 }
                return Int64(Double(totalBytes) * min(max(progress, 0), 1))
            }()
            let resolvedTotalItemCount = max(totalItemCount ?? 1, 1)
            let resolvedCurrentItemIndex = min(max(currentItemIndex ?? 1, 1), resolvedTotalItemCount)
            resolvedFiles = (0..<resolvedTotalItemCount).map { index in
                let itemIndex = index + 1
                let itemStatus: TransferFileProgress.Status
                let itemName: String
                let itemTransferredBytes: Int64
                let itemTotalBytes: Int64?

                if itemIndex < resolvedCurrentItemIndex {
                    itemStatus = .completed
                    itemName = FeatureTransferLocalization.format("transfer.completedItemFormat", itemIndex)
                    itemTotalBytes = byteCount
                    itemTransferredBytes = byteCount ?? 0
                } else if itemIndex == resolvedCurrentItemIndex {
                    itemStatus = fallbackStatus
                    itemName = fileName
                    let fallbackTotal = ((currentFileTotalBytes ?? 0) > 0 ? currentFileTotalBytes : byteCount)
                    itemTotalBytes = fallbackTotal
                    itemTransferredBytes = max(resolvedTransferred, 0)
                } else {
                    itemStatus = .queued
                    itemName = FeatureTransferLocalization.format("transfer.queuedItemFormat", itemIndex)
                    itemTotalBytes = nil
                    itemTransferredBytes = 0
                }

                return TransferFileProgress(
                    id: itemIndex == resolvedCurrentItemIndex ? fileName : "\(fileName)-\(itemIndex)",
                    fileName: itemName,
                    status: itemStatus,
                    totalBytes: itemTotalBytes,
                    effectiveTotalBytesForDisplay: itemTotalBytes.flatMap { $0 > 0 ? max($0, itemTransferredBytes) : nil },
                    actualTransferredBytes: itemTransferredBytes,
                    displayedTransferredBytes: itemTransferredBytes,
                    completedBytesContribution: itemStatus == .completed ? max(itemTransferredBytes, itemTotalBytes ?? 0) : 0,
                    failedBytesContribution: (itemStatus == .failed || itemStatus == .canceled) ? itemTransferredBytes : 0,
                    fileURL: itemIndex == resolvedCurrentItemIndex ? fileURL : nil,
                    order: index
                )
            }
        }

        self.init(
            id: id,
            attemptID: id,
            direction: direction,
            counterpartName: counterpartName,
            counterpartKind: counterpartKind,
            status: status,
            files: resolvedFiles,
            totalBytesKnown: totalBytes,
            displayableTransferredBytes: transferredBytes ?? 0,
            actualTransferredBytes: transferredBytes ?? 0,
            smoothedBytesPerSecond: nil,
            eta: etaDescription.isEmpty ? .none : .calculating,
            startedAtMonotonic: 0,
            lastProgressAtMonotonic: 0
        )
    }
}

extension ActiveTransferProgress {
    var resolvedFileProgress: [TransferFileProgress] { files }

    var totalItemCount: Int? { files.count }

    var resolvedTotalItemCount: Int {
        max(files.count, 1)
    }

    var currentFile: TransferFileProgress? {
        files.first { $0.status == .transferring || $0.status == .retrying }
            ?? files.first { $0.status == .queued }
            ?? files.last
    }

    var currentItemIndex: Int? {
        guard let currentFile else { return nil }
        return (files.firstIndex(where: { $0.id == currentFile.id }) ?? 0) + 1
    }

    var resolvedCurrentItemIndex: Int {
        min(max(currentItemIndex ?? resolvedTotalItemCount, 1), resolvedTotalItemCount)
    }

    var remainingItemCount: Int {
        max(resolvedTotalItemCount - resolvedCurrentItemIndex, 0)
    }

    var fileName: String {
        currentFile?.fileName ?? counterpartName
    }

    var byteCount: Int64? {
        currentFile?.totalBytes
    }

    var fileURL: URL? {
        currentFile?.fileURL
    }

    var totalBytes: Int64? { totalBytesKnown }

    var transferredBytes: Int64? { displayableTransferredBytes }

    var currentFileTotalBytes: Int64? {
        currentFile?.effectiveTotalBytesForDisplay
    }

    var currentFileTransferredBytes: Int64? {
        currentFile?.displayedTransferredBytes
    }

    var overallProgressValue: Double? {
        guard let totalBytesKnown, totalBytesKnown > 0 else {
            return status == .completed ? 1 : nil
        }
        let transferred = min(max(displayableTransferredBytes, 0), totalBytesKnown)
        return min(max(Double(transferred) / Double(totalBytesKnown), 0), 1)
    }

    var overallProgress: Double {
        overallProgressValue ?? (status == .completed ? 1 : 0)
    }

    var currentFileProgressValue: Double? {
        currentFile?.determinateProgress
    }

    var currentFileProgress: Double {
        currentFileProgressValue ?? overallProgress
    }

    var stablePercent: Int {
        if status == .completed {
            return 100
        }
        guard let overallProgressValue else { return 0 }
        return min(max(Int((overallProgressValue * 100).rounded(.down)), 0), 99)
    }

    var currentFileStablePercent: Int {
        currentFile?.stablePercent ?? stablePercent
    }

    var batchPositionLabel: String? {
        guard resolvedTotalItemCount > 1 else { return nil }
        return FeatureTransferLocalization.format(
            "transfer.progress.filePositionFormat",
            resolvedCurrentItemIndex,
            resolvedTotalItemCount
        )
    }

    var activeFileCount: Int {
        files.filter { $0.status == .transferring || $0.status == .retrying }.count
    }

    var hasKnownTotal: Bool {
        if let totalBytesKnown {
            return totalBytesKnown > 0
        }
        return false
    }

    var aggregateByteProgressLabel: String {
        let transferredLabel = ByteCountFormatter.string(
            fromByteCount: displayableTransferredBytes,
            countStyle: .file
        )
        guard let totalBytesKnown, totalBytesKnown > 0 else {
            return transferredLabel
        }
        let totalLabel = ByteCountFormatter.string(fromByteCount: totalBytesKnown, countStyle: .file)
        return FeatureTransferLocalization.format("transfer.progress.byteFormat", transferredLabel, totalLabel)
    }

    var speedLabel: String? {
        guard let smoothedBytesPerSecond, smoothedBytesPerSecond >= 1 else { return nil }
        let unitsPerSecond = ByteCountFormatter.string(
            fromByteCount: Int64(smoothedBytesPerSecond.rounded()),
            countStyle: .file
        )
        return FeatureTransferLocalization.format("transfer.progress.speedFormat", unitsPerSecond)
    }

    var etaLabel: String? {
        eta.descriptionText
    }

    var secondaryStatusLine: String? {
        switch (speedLabel, etaLabel) {
        case let (.some(speed), .some(eta)):
            return FeatureTransferLocalization.format("transfer.progress.speedEtaFormat", speed, eta)
        case let (.some(speed), nil):
            return speed
        case let (nil, .some(eta)):
            return FeatureTransferLocalization.format("transfer.progress.etaFormat", eta)
        case (nil, nil):
            return nil
        }
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
        return FeatureTransferLocalization.format("history.subtitleFormat", verb, counterpart, size)
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
        let locale = FeatureTransferLocalization.currentLocale()
        if calendar.isDateInToday(date) {
            let today = FeatureTransferLocalization.string(forKey: "transfer.today")
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return "\(today), \(formatter.string(from: date))"
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
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate("EEE")
            return formatter.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
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

    static let incomingPINLength = MemorableIncomingPINGenerator.pinLength

    static func generateIncomingPIN() -> String {
        MemorableIncomingPINGenerator.generate()
    }

    static func generateIncomingPIN(
        prefixRoll: Int,
        suffixValue: Int,
        fallbackValue: Int
    ) -> String {
        MemorableIncomingPINGenerator.generate(
            prefixRoll: prefixRoll,
            suffixValue: suffixValue,
            fallbackValue: fallbackValue
        )
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
    var sendMode: SendMode
    var shareViaLinkAutoAccept: Bool
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
        case sendMode
        case shareViaLinkAutoAccept
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
        sendMode: SendMode = .single,
        shareViaLinkAutoAccept: Bool = false,
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
        self.sendMode = sendMode
        self.shareViaLinkAutoAccept = shareViaLinkAutoAccept
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
        sendMode = try container.decodeIfPresent(SendMode.self, forKey: .sendMode) ?? .single
        shareViaLinkAutoAccept = try container.decodeIfPresent(Bool.self, forKey: .shareViaLinkAutoAccept) ?? false
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
        try container.encode(sendMode, forKey: .sendMode)
        try container.encode(shareViaLinkAutoAccept, forKey: .shareViaLinkAutoAccept)
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
            sendMode: .single,
            shareViaLinkAutoAccept: false,
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
