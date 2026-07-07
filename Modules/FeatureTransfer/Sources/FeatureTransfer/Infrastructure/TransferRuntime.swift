import Foundation

protocol TransferRuntime: Sendable {
    func start() async throws
    func stop() async
    func refreshDiscovery() async
    func discoveredPeers() async -> AsyncStream<[NearbyPeerItem]>
    func inboundRequests() async -> AsyncStream<IncomingTransferRequest>
    func progressEvents() async -> AsyncStream<ActiveTransferProgress>
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
