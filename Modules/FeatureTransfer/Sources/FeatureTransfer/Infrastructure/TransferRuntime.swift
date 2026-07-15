import Foundation

struct TransferProgressRawFile: Equatable, Sendable {
    let fileID: String
    let displayName: String
    let fileURL: URL?
    let order: Int
    let attemptIndex: Int
    let state: TransferFileProgress.Status
    let declaredTotalBytes: Int64?
    let actualTransferredBytes: Int64
    let errorSummary: String?
}

struct TransferProgressRawEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case transferStarted
        case snapshot
        case transferCompleted
        case transferFailed
        case transferCanceled
    }

    let kind: Kind
    let transferID: String
    let attemptID: String
    let direction: ActiveTransferProgress.Direction
    let counterpartName: String
    let counterpartKind: DeviceKind
    let sequenceNumber: Int64
    let eventMonotonicTime: TimeInterval
    let files: [TransferProgressRawFile]
    let totalBytesKnown: Int64?
    let actualTransferredBytes: Int64
}

enum TransferProgressEvent: Equatable, Sendable {
    case event(TransferProgressRawEvent)
    case reset
}

protocol TransferRuntime: Sendable {
    func start() async throws
    func stop() async
    func refreshDiscovery() async
    func discoveredPeers() async -> AsyncStream<[NearbyPeerItem]>
    func inboundRequests() async -> AsyncStream<IncomingTransferRequest>
    func progressEvents() async -> AsyncStream<TransferProgressEvent>
    func updateSettings(_ settings: TransferProtocolSettings) async throws
    func stage(_ items: [StagedTransferItem]) async
    func sendStagedItems(to peerID: NearbyPeerItem.ID, pin: String?) async throws
    func respondToIncomingRequest(_ response: IncomingTransferDecision) async throws
    func cancelActiveTransfer(_ id: ActiveTransferProgress.ID) async throws
}

protocol TransferSettingsPersisting {
    func load() -> TransferSettingsSnapshot
    func save(_ snapshot: TransferSettingsSnapshot)
}

protocol HistoryPersisting {
    func load() -> [HistoryEntry]
    func save(_ entries: [HistoryEntry])
}
