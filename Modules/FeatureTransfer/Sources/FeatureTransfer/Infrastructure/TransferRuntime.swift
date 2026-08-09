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
        /// The `/prepare-upload` outcomes from protocol section 4.1 that deserve their own copy,
        /// rather than collapsing into a generic `.transferFailed`.
        case transferPINRequired
        case transferRejected
        case transferBlocked
        case transferRateLimited
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

/// What the sender-side PIN prompt needs to render one attempt.
///
/// Carries no PIN itself: a submitted PIN travels back through `TransferPINProvider`'s return
/// value straight into the in-flight `/prepare-upload` retry and is never stored.
struct TransferPINPromptContext: Equatable, Sendable {
    let peerID: NearbyPeerItem.ID
    let peerName: String
    /// `true` until a PIN has been submitted and refused.
    ///
    /// The wire cannot distinguish "a PIN is required" from "that PIN was wrong" — `/prepare-upload`
    /// answers 401 for both — so this is purely client-side state, mirroring the reference
    /// implementation's `pinFirstAttempt`.
    let isFirstAttempt: Bool
}

/// Asks the user for a PIN. Returning `nil` means the user dismissed the prompt, which discards
/// the send rather than reporting a failure.
typealias TransferPINProvider = @Sendable (TransferPINPromptContext) async -> String?

protocol TransferRuntime: Sendable {
    func start() async throws
    func stop() async
    func refreshDiscovery() async
    func discoveredPeers() async -> AsyncStream<[NearbyPeerItem]>
    func inboundRequests() async -> AsyncStream<IncomingTransferRequest>
    /// Ids of inbound prompts withdrawn by the network side (the sender canceled while the
    /// accept/decline prompt was still on screen) rather than answered by the user. Additive to
    /// `inboundRequests()` so that stream's element type is untouched.
    func inboundRequestWithdrawals() async -> AsyncStream<String>
    func progressEvents() async -> AsyncStream<TransferProgressEvent>
    func updateSettings(_ settings: TransferProtocolSettings) async throws
    func stage(_ items: [StagedTransferItem]) async
    /// Sends the staged batch.
    ///
    /// `requestPIN` is consulted only when `/prepare-upload` answers 401, and the retry happens
    /// inside this single invocation so the batch stays ONE logical transfer: `TransferProgressReducer`
    /// keys continuity on the transfer ID, and re-entering this method for a retry would mint a new
    /// one and leave a stale card behind. Passing `nil` keeps the pre-existing behaviour of
    /// surfacing 401 as a terminal `.pinRequired` state.
    func sendStagedItems(
        to peerID: NearbyPeerItem.ID,
        pin: String?,
        requestPIN: TransferPINProvider?
    ) async throws
    func respondToIncomingRequest(_ response: IncomingTransferDecision) async throws
    func cancelActiveTransfer(_ id: ActiveTransferProgress.ID) async throws
}

extension TransferRuntime {
    /// Send with no PIN prompt attached. 401 stays terminal, exactly as before.
    func sendStagedItems(to peerID: NearbyPeerItem.ID, pin: String?) async throws {
        try await sendStagedItems(to: peerID, pin: pin, requestPIN: nil)
    }
}

protocol TransferSettingsPersisting {
    func load() -> TransferSettingsSnapshot
    func save(_ snapshot: TransferSettingsSnapshot)
}

protocol HistoryPersisting {
    func load() -> [HistoryEntry]
    func save(_ entries: [HistoryEntry])
}

protocol FavoritesPersisting {
    func load() -> [FavoriteDevice]
    func save(_ favorites: [FavoriteDevice])
}
