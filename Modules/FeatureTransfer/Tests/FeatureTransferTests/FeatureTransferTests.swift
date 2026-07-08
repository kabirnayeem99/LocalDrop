import XCTest
@testable import FeatureTransfer

@MainActor
final class FeatureTransferTests: XCTestCase {
    func testActiveSheetPrefersIncomingRequestOverProgress() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )

        await runtime.emitProgress(
            ActiveTransferProgress(
                id: "progress",
                direction: .sending,
                counterpartName: "Peer",
                fileName: "a.txt",
                progress: 0.3,
                throughput: "1 MB/s",
                etaDescription: "Soon"
            )
        )
        await runtime.emitIncomingRequest(
            IncomingTransferRequest(
                id: "incoming",
                deviceName: "Peer",
                subtitle: "Peer · 1 item",
                sourceKind: .phone,
                files: []
            )
        )

        await store.start()

        await waitUntil { store.activeSheet == .incoming }

        XCTAssertEqual(store.activeSheet, .incoming)
        XCTAssertEqual(store.incomingRequest?.id, "incoming")
    }

    func testPersistSettingsPushesRuntimeUpdate() async {
        let runtime = FakeTransferRuntime()
        let persistence = InMemorySettingsPersistence()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: persistence,
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )

        store.requirePIN = true
        store.allowDownloads = false
        store.persistSettings()

        let persisted = persistence.savedSnapshots.last
        XCTAssertEqual(persisted?.protocolSettings.requirePIN, true)
        XCTAssertEqual(persisted?.protocolSettings.allowDownloads, false)

        let updated = await waitForRuntimeSettings(runtime)
        XCTAssertEqual(updated?.requirePIN, true)
        XCTAssertEqual(updated?.allowDownloads, false)
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<20 where !predicate() {
            await Task.yield()
        }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    private func waitForRuntimeSettings(_ runtime: FakeTransferRuntime) async -> TransferProtocolSettings? {
        for _ in 0..<20 {
            if let settings = await runtime.lastUpdatedSettings {
                return settings
            }
            await Task.yield()
        }
        return await runtime.lastUpdatedSettings
    }
}

private actor FakeTransferRuntime: TransferRuntime {
    private let peersBroadcaster = TestBroadcaster<[NearbyPeerItem]>(initialValue: [])
    private let incomingBroadcaster = TestBroadcaster<IncomingTransferRequest>()
    private let progressBroadcaster = TestBroadcaster<ActiveTransferProgress>()
    private(set) var lastUpdatedSettings: TransferProtocolSettings?

    func start() async throws {}
    func stop() async {}
    func refreshDiscovery() async {}
    func discoveredPeers() async -> AsyncStream<[NearbyPeerItem]> { await peersBroadcaster.stream() }
    func inboundRequests() async -> AsyncStream<IncomingTransferRequest> { await incomingBroadcaster.stream() }
    func progressEvents() async -> AsyncStream<ActiveTransferProgress> { await progressBroadcaster.stream() }
    func updateSettings(_ settings: TransferProtocolSettings) async throws { lastUpdatedSettings = settings }
    func stage(_ items: [StagedTransferItem]) async {}
    func sendStagedItems(to peerID: NearbyPeerItem.ID, pin: String?) async throws {}
    func respondToIncomingRequest(_ response: IncomingTransferDecision) async throws {}
    func cancelActiveTransfer(_ id: ActiveTransferProgress.ID) async throws {}

    func emitIncomingRequest(_ request: IncomingTransferRequest) async {
        await incomingBroadcaster.yield(request)
    }

    func emitProgress(_ progress: ActiveTransferProgress) async {
        await progressBroadcaster.yield(progress)
    }
}

private final class InMemorySettingsPersistence: TransferSettingsPersisting {
    private(set) var savedSnapshots: [TransferSettingsSnapshot] = []

    func load() -> TransferSettingsSnapshot {
        .default(
            deviceName: "LocalDrop Test Mac",
            saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
        )
    }

    func save(_ snapshot: TransferSettingsSnapshot) {
        savedSnapshots.append(snapshot)
    }
}

private actor TestBroadcaster<Value: Sendable> {
    private var currentValue: Value?
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

    init(initialValue: Value? = nil) {
        currentValue = initialValue
    }

    func stream() -> AsyncStream<Value> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            if let currentValue {
                continuation.yield(currentValue)
            }
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.remove(id: id)
                }
            }
        }
    }

    func yield(_ value: Value) {
        currentValue = value
        for continuation in continuations.values {
            continuation.yield(value)
        }
    }

    private func remove(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
