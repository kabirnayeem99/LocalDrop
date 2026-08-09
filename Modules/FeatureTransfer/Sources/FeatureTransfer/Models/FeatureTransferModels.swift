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
    /// Whether the wire `FileDto` was a message payload — a text file whose content travels in
    /// `preview` (see `FileDto.isMessagePayload`).
    ///
    /// The raw `fileType` is still not carried — the disposition rule needs nothing else and the UI
    /// renders it nowhere. Defaults to `false` (a plain document) so a caller that never saw a
    /// `FileDto` keeps the quick-save behaviour.
    let isMessagePayload: Bool

    /// The message body, carried ONLY for a message payload.
    ///
    /// Previously dropped on the floor deliberately ("the feature layer has no reason to hold onto
    /// it"). That stopped being true once messages started going to receive history instead of to
    /// disk: the text IS the history entry, and the kit answers 204 without ever handing the bytes
    /// over, so this is the only path the body can travel. `nil` for every non-message file.
    let messageText: String?

    init(
        id: String,
        name: String,
        size: String,
        symbol: String,
        isMessagePayload: Bool = false,
        messageText: String? = nil
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.symbol = symbol
        self.isMessagePayload = isMessagePayload
        self.messageText = messageText
    }

    /// Maps a wire `FileDto` onto the row the feature layer works with. Lives here rather than in
    /// the runtime adapter so the message classification is exercised by feature-level tests.
    init(file: FileDto, symbol: String) {
        self.init(
            id: file.id,
            name: file.fileName,
            size: ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file),
            symbol: symbol,
            isMessagePayload: file.isMessagePayload,
            messageText: file.isMessagePayload ? file.preview : nil
        )
    }
}

struct IncomingTransferRequest: Identifiable, Equatable, Sendable {
    let id: String
    let deviceName: String
    let subtitle: String
    let sourceKind: DeviceKind
    let files: [IncomingTransferFile]
    /// Sender certificate fingerprint, normalized to lowercase. Carried so the feature layer can
    /// match the sender against the favorites store without reaching back into LocalSendKit.
    /// Empty when the sender is unknown, which never matches a favorite.
    let senderFingerprint: String

    init(
        id: String,
        deviceName: String,
        subtitle: String,
        sourceKind: DeviceKind,
        files: [IncomingTransferFile],
        senderFingerprint: String = ""
    ) {
        self.id = id
        self.deviceName = deviceName
        self.subtitle = subtitle
        self.sourceKind = sourceKind
        self.files = files
        self.senderFingerprint = FavoriteDevice.normalizedFingerprint(senderFingerprint)
    }

    /// Whether this request is a *message* rather than a file transfer.
    ///
    /// Mirrors the reference `ReceiveSessionState.message`
    /// (`app/lib/model/state/server/receive_session_state.dart:63-68`): a request is a message only
    /// when it carries exactly one file, that file is text, and its `preview` — the message body —
    /// is present and non-empty. A lone `.txt` document with no preview is not a message and stays
    /// eligible for quick save, matching the reference.
    var isMessagePayload: Bool {
        files.count == 1 && files[0].isMessagePayload
    }

    /// The message body when this request is a message, for the receive-history entry that stands
    /// in for the file that is never written.
    var messageText: String? {
        guard isMessagePayload else { return nil }
        return files[0].messageText
    }
}

/// A device the user pinned, keyed by certificate fingerprint.
///
/// Fingerprints are lowercase hex on the wire (see `Fingerprint.make(from:)`), but peers — and
/// LocalDrop identities persisted before that change — may still send uppercase. Every fingerprint
/// entering this type is normalized with ``normalizedFingerprint(_:)`` so lookups are exact string
/// comparisons on already-normalized keys, matching `Fingerprint.matches(_:_:)` semantics.
struct FavoriteDevice: Codable, Equatable, Sendable, Identifiable {
    /// Lowercased, whitespace-trimmed fingerprint. Also the identity of the favorite.
    let fingerprint: String
    /// User-chosen display name that wins over whatever the peer announces.
    var aliasOverride: String?
    /// Last alias seen from this peer, so a favorite still renders while it is offline.
    var lastKnownAlias: String

    var id: String { fingerprint }

    init(fingerprint: String, aliasOverride: String? = nil, lastKnownAlias: String = "") {
        self.fingerprint = Self.normalizedFingerprint(fingerprint)
        self.aliasOverride = Self.normalizedAlias(aliasOverride)
        self.lastKnownAlias = lastKnownAlias
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            fingerprint: try container.decode(String.self, forKey: .fingerprint),
            aliasOverride: try container.decodeIfPresent(String.self, forKey: .aliasOverride),
            lastKnownAlias: try container.decodeIfPresent(String.self, forKey: .lastKnownAlias) ?? ""
        )
    }

    /// Name to render for this favorite. The user's override always wins; otherwise the caller's
    /// live value (the alias the peer is announcing right now) wins over the cached
    /// `lastKnownAlias`, which is only a fallback for a favorite with nothing live to show.
    func displayName(fallback: String) -> String {
        if let aliasOverride, aliasOverride.isEmpty == false {
            return aliasOverride
        }
        if fallback.isEmpty == false {
            return fallback
        }
        return lastKnownAlias
    }

    static func normalizedFingerprint(_ candidate: String) -> String {
        candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Number of leading fingerprint characters shown as secondary text in the favorites list.
    static let shortFingerprintLength = 8

    /// Short, human-comparable prefix of a fingerprint. Two devices sharing an alias are told apart
    /// by this, so it is rendered rather than the full 64-character hex string.
    static func shortFingerprint(_ candidate: String) -> String {
        String(normalizedFingerprint(candidate).prefix(shortFingerprintLength))
    }

    private static func normalizedAlias(_ candidate: String?) -> String? {
        guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

/// A favorited device as rendered in the settings favorites list.
///
/// Deliberately carries no online/offline or last-seen state: the list exists to manage devices that
/// are *absent* — sold, reimaged, or a one-off guest — so a presence badge on every row would be
/// noise on exactly the rows that matter most.
struct FavoriteListItem: Identifiable, Equatable, Sendable {
    /// Normalized fingerprint, and the identity of the row.
    let fingerprint: String
    /// Already-resolved name, produced by the same render path as the device list.
    let displayName: String
    /// Truncated fingerprint shown as secondary text so two devices sharing an alias are distinct.
    let shortFingerprint: String

    var id: String { fingerprint }
}

/// Why an incoming request was accepted without showing the prompt. Emitted as a log attribute so
/// an auto-accept is distinguishable from a user accept after the fact.
enum AutoAcceptReason: String, Equatable, Sendable {
    case quickSave = "quick_save"
    case quickSaveFavorites = "quick_save_favorites"
    case favorite = "favorite"
}

/// What the feature layer decided to do with an inbound request before any UI is involved.
enum IncomingRequestDisposition: Equatable, Sendable {
    case prompt
    case autoAccept(reason: AutoAcceptReason)
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
    /// `desiredNames` maps fileID -> the name the user typed into the incoming-request sheet, for
    /// the files they renamed. Only this case carries it: the rename affordance lives on the
    /// per-file rows, and the sheet routes an all-selected accept through `acceptSubset` as soon as
    /// any rename is present, so `acceptAll` (also the auto-accept and quick-save paths, where
    /// nobody is at the keyboard) never has renames to carry.
    ///
    /// The names are untrusted user input and are sanitized in `LocalSendKit`, by the same code
    /// path as a sender-supplied filename — not here.
    case acceptSubset(requestID: String, fileIDs: Set<String>, desiredNames: [String: String] = [:])
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
            ? FeatureTransferLocalization.format("transfer.stagedItem", count)
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

/// A sender-side PIN prompt waiting on the user.
///
/// Holds no PIN, by design. The submitted value is handed straight to the in-flight
/// `/prepare-upload` retry and dropped — it is never cached in memory across sends, never written
/// to `UserDefaults`, and never put in the keychain.
struct SendPINPrompt: Identifiable, Equatable, Sendable {
    let id: UUID
    let peerName: String
    /// `false` once a PIN has been submitted and refused — the only way to tell "PIN required"
    /// from "incorrect PIN", since the wire answers 401 for both.
    let isFirstAttempt: Bool

    init(id: UUID = UUID(), peerName: String, isFirstAttempt: Bool) {
        self.id = id
        self.peerName = peerName
        self.isFirstAttempt = isFirstAttempt
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
        /// `/prepare-upload` answered 401 — the recipient wants a PIN, or the one sent was wrong.
        case pinRequired
        /// `/prepare-upload` answered 403 — the recipient declined the transfer.
        case rejected
        /// `/prepare-upload` answered 409 — the recipient is busy with another session.
        case blocked
        /// `/prepare-upload` answered 429 — too many requests.
        case rateLimited

        var isTerminal: Bool {
            switch self {
            case .completed, .failed, .canceled, .pinRequired, .rejected, .blocked, .rateLimited:
                return true
            case .running:
                return false
            }
        }

        /// Whether this status means the batch ended without delivering the files. The per-file
        /// rollup treats these exactly like `.failed`; only the user-facing copy differs.
        var isUnsuccessful: Bool {
            switch self {
            case .failed, .pinRequired, .rejected, .blocked, .rateLimited:
                return true
            case .running, .completed, .canceled:
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
            case .failed, .pinRequired, .rejected, .blocked, .rateLimited:
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
    /// A received text message rather than a file. `fileName` carries the message body itself
    /// (matching the reference's `AddHistoryEntryAction(fileName: message, isMessage: true)`), and
    /// `fileURL` is always nil because nothing was written to disk.
    let isMessage: Bool

    init(
        id: UUID = UUID(),
        fileName: String,
        counterpart: String,
        size: String,
        timestamp: Date,
        direction: TransferDirection,
        outcome: TransferOutcome,
        fileURL: URL? = nil,
        isMessage: Bool = false
    ) {
        self.id = id
        self.fileName = fileName
        self.counterpart = counterpart
        self.size = size
        self.timestamp = timestamp
        self.direction = direction
        self.outcome = outcome
        self.fileURL = fileURL
        self.isMessage = isMessage
    }

    /// Hand-written so a `history.json` produced before `isMessage` existed still decodes.
    /// `HistoryPersistenceAdapter.load()` fails safe to `[]` on ANY decode error, so a synthesized
    /// decoder here would silently erase the user's entire transfer history on first launch after
    /// upgrading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        counterpart = try container.decode(String.self, forKey: .counterpart)
        size = try container.decode(String.self, forKey: .size)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        direction = try container.decode(TransferDirection.self, forKey: .direction)
        outcome = try container.decode(TransferOutcome.self, forKey: .outcome)
        fileURL = try container.decodeIfPresent(URL.self, forKey: .fileURL)
        isMessage = try container.decodeIfPresent(Bool.self, forKey: .isMessage) ?? false
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
    /// Schema version of the persisted settings payload.
    ///
    /// Version 1 is the first build in which `quickSave`/`autoAcceptFavorites` actually suppress the
    /// incoming-request prompt. Payloads written before that carry no `schemaVersion` key and may hold
    /// a decorative `"quickSave":"on"` that was inert at the time it was written — accepting it verbatim
    /// would silently upgrade those installs to always-auto-accept. See ``init(from:)``.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
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
        case schemaVersion
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
        protocolSettings: TransferProtocolSettings,
        schemaVersion: Int = TransferSettingsSnapshot.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
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
        let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        schemaVersion = Self.currentSchemaVersion
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

        // One-time migration: a payload written before schema 1 cannot be trusted to express intent
        // about auto-accept, because neither flag suppressed the prompt when it was written. Force the
        // prompting configuration regardless of what the ship defaults happen to be today.
        if decodedSchemaVersion < Self.currentSchemaVersion {
            quickSave = .off
            autoAcceptFavorites = false
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
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

    /// Ship defaults. Auto-accept is off in both forms, matching the LocalSend reference
    /// (`persistence_provider.dart`: `isQuickSave()` and `isQuickSaveFromFavorites()` both fall back to
    /// false). Files from an arbitrary LAN peer must never land on disk without a prompt.
    static func `default`(deviceName: String, saveLocation: URL) -> Self {
        Self(
            quickSave: .off,
            appearance: .system,
            accentColor: .medinaEmerald,
            language: .system,
            minimizeToMenuBar: false,
            launchAtLogin: true,
            reduceMotion: false,
            autoAcceptFavorites: false,
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
