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
        store.endToEndEncryption = false
        store.persistSettings()

        let persisted = persistence.savedSnapshots.last
        XCTAssertEqual(persisted?.protocolSettings.requirePIN, true)
        XCTAssertEqual(persisted?.protocolSettings.allowDownloads, false)
        XCTAssertEqual(persisted?.protocolSettings.endToEndEncryption, false)

        let updated = await waitForRuntimeSettings(runtime)
        XCTAssertEqual(updated?.requirePIN, true)
        XCTAssertEqual(updated?.incomingPIN, store.incomingPIN)
        XCTAssertEqual(updated?.allowDownloads, false)
        XCTAssertEqual(updated?.protocolType, .http)
    }

    func testProtocolSettingsMapEncryptionToggleToProtocolType() {
        var settings = TransferProtocolSettings(
            deviceName: "LocalDrop Test Mac",
            tcpPort: 53_317,
            requirePIN: false,
            incomingPIN: "123456",
            allowDownloads: true,
            endToEndEncryption: true,
            saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
        )

        XCTAssertEqual(settings.protocolType, .https)

        settings.endToEndEncryption = false

        XCTAssertEqual(settings.protocolType, .http)
    }

    func testDefaultSnapshotGeneratesValidIncomingPIN() {
        let snapshot = TransferSettingsSnapshot.default(
            deviceName: "LocalDrop Test Mac",
            saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
        )

        XCTAssertEqual(snapshot.protocolSettings.incomingPIN.count, TransferProtocolSettings.incomingPINLength)
        XCTAssertEqual(
            TransferProtocolSettings.normalizedIncomingPIN(from: snapshot.protocolSettings.incomingPIN),
            snapshot.protocolSettings.incomingPIN
        )
    }

    func testSettingsPersistenceLoadsLegacySnapshotWithoutIncomingPIN() throws {
        let suiteName = "FeatureTransferTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let payload = """
        {
          "quickSave":"on",
          "appearance":"system",
          "accentColor":"green",
          "language":"system",
          "minimizeToMenuBar":false,
          "launchAtLogin":true,
          "reduceMotion":false,
          "autoAcceptFavorites":true,
          "protocolSettings":{
            "deviceName":"LocalDrop Test Mac",
            "tcpPort":53317,
            "requirePIN":true,
            "allowDownloads":true,
            "endToEndEncryption":true,
            "saveLocation":"file:///tmp/LocalDropTests"
          }
        }
        """
        defaults.set(Data(payload.utf8), forKey: "FeatureTransfer.settings")

        let adapter = SettingsPersistenceAdapter(
            userDefaults: defaults,
            fallback: .default(
                deviceName: "Fallback Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/Fallback")
            )
        )
        let loaded = adapter.load()

        XCTAssertTrue(loaded.protocolSettings.requirePIN)
        XCTAssertEqual(loaded.protocolSettings.incomingPIN.count, TransferProtocolSettings.incomingPINLength)
        XCTAssertEqual(
            TransferProtocolSettings.normalizedIncomingPIN(from: loaded.protocolSettings.incomingPIN),
            loaded.protocolSettings.incomingPIN
        )
    }

    func testEnsureIncomingPINGeneratesValidPINWhenMissing() {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )

        store.incomingPIN = ""
        store.ensureIncomingPIN()

        XCTAssertEqual(store.incomingPIN.count, TransferProtocolSettings.incomingPINLength)
        XCTAssertEqual(
            TransferProtocolSettings.normalizedIncomingPIN(from: store.incomingPIN),
            store.incomingPIN
        )
    }

    func testUpdateIncomingPINPersistsAndPushesRuntimeSettings() async {
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

        XCTAssertTrue(store.updateIncomingPIN("12-34 56"))

        XCTAssertEqual(store.incomingPIN, "123456")
        XCTAssertEqual(persistence.savedSnapshots.last?.protocolSettings.incomingPIN, "123456")
        XCTAssertEqual(persistence.savedSnapshots.last?.protocolSettings.requirePIN, true)

        let updated = await waitForRuntimeSettings(runtime)
        XCTAssertEqual(updated?.incomingPIN, "123456")
        XCTAssertEqual(updated?.requirePIN, true)
    }

    func testUpdateIncomingPINRejectsInvalidValue() {
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
        let existingPIN = store.incomingPIN

        XCTAssertFalse(store.updateIncomingPIN("123"))
        XCTAssertEqual(store.incomingPIN, existingPIN)
        XCTAssertTrue(persistence.savedSnapshots.isEmpty)
    }

    func testMenuSummaryReflectsRuntimeIncomingAndTransferStates() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            ),
            historyEntries: [
                makeHistoryEntry(fileName: "one.txt"),
                makeHistoryEntry(fileName: "two.txt"),
                makeHistoryEntry(fileName: "three.txt"),
                makeHistoryEntry(fileName: "four.txt"),
                makeHistoryEntry(fileName: "five.txt"),
                makeHistoryEntry(fileName: "six.txt")
            ]
        )

        XCTAssertEqual(store.menuSummary.statusSymbol, "paperplane.circle")
        XCTAssertEqual(store.menuSummary.recentHistoryEntries.map(\.fileName), [
            "one.txt",
            "two.txt",
            "three.txt",
            "four.txt",
            "five.txt"
        ])

        store.isRuntimeAvailable = true
        store.runtimeStatusText = "Discoverable"
        XCTAssertEqual(store.menuSummary.statusSymbol, "paperplane")
        XCTAssertEqual(store.menuSummary.statusText, "Discoverable")

        await runtime.emitProgress(
            ActiveTransferProgress(
                id: "progress",
                direction: .sending,
                counterpartName: "Peer",
                fileName: "report.pdf",
                progress: 0.42,
                throughput: "1 MB/s",
                etaDescription: "Soon"
            )
        )
        await store.start()
        await waitUntil { store.activeTransfer != nil }

        XCTAssertEqual(store.menuSummary.statusSymbol, "paperplane.fill")
        XCTAssertEqual(store.menuSummary.activeTransferTitle, "Sending report.pdf 42%")

        await runtime.emitIncomingRequest(
            IncomingTransferRequest(
                id: "incoming",
                deviceName: "Peer Mac",
                subtitle: "Peer Mac · 1 item",
                sourceKind: .macbook,
                files: [IncomingTransferFile(id: "file", name: "notes.txt", size: "1 KB", symbol: "doc")]
            )
        )
        await waitUntil { store.incomingRequest != nil }

        XCTAssertEqual(store.menuSummary.statusSymbol, "paperplane.badge.clock")
        XCTAssertEqual(store.menuSummary.incomingRequestTitle, "Peer Mac wants to send 1 file")
        XCTAssertEqual(store.menuSummary.statusText, "Incoming request from Peer Mac")
    }

    func testMenuActionsDriveRuntimeAndStoreIntegration() async {
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

        await store.start()
        store.refreshNearbyPeers()
        await waitUntil { await runtime.refreshDiscoveryCallCount >= 2 }

        let fileURL = URL(fileURLWithPath: "/tmp/LocalDropTests/report.pdf")
        store.stageDroppedItems([fileURL])
        await waitUntil { await runtime.stagedItems.map(\.fileURL) == [fileURL] }

        store.nearbyPeers = [
            NearbyPeerItem(
                id: "peer-id",
                host: "192.168.1.20",
                name: "Peer Mac",
                subtitle: "Ready",
                kind: .macbook,
                fingerprint: "peer-id",
                protocolType: nil,
                port: 53317,
                supportsDownloads: true
            )
        ]
        XCTAssertTrue(store.menuSummary.canSendToPeers)

        store.send(to: "peer-id")
        await waitUntil { await runtime.sentPeerIDs == ["peer-id"] }

        let request = IncomingTransferRequest(
            id: "request-id",
            deviceName: "Peer Mac",
            subtitle: "Peer Mac · 1 item",
            sourceKind: .macbook,
            files: [IncomingTransferFile(id: "file", name: "notes.txt", size: "1 KB", symbol: "doc")]
        )
        await runtime.emitIncomingRequest(request)
        await waitUntil { store.incomingRequest?.id == "request-id" }
        store.acceptIncomingRequest()
        await waitUntil { await runtime.responses == [.acceptAll(requestID: "request-id")] }

        store.activeTransfer = ActiveTransferProgress(
            id: "transfer-id",
            direction: .receiving,
            counterpartName: "Peer Mac",
            fileName: "notes.txt",
            progress: 0.2,
            throughput: "1 MB/s",
            etaDescription: "Soon"
        )
        store.cancelActiveTransfer()
        await waitUntil { await runtime.canceledTransferIDs == ["transfer-id"] }

        store.updateQuickSave(.off)
        XCTAssertEqual(persistence.savedSnapshots.last?.quickSave, .off)

        store.clearHistory()
        XCTAssertTrue(store.historyEntries.isEmpty)
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<20 where !(await predicate()) {
            await Task.yield()
        }
        let result = await predicate()
        XCTAssertTrue(result, file: file, line: line)
    }

    private func makeHistoryEntry(fileName: String) -> HistoryEntry {
        HistoryEntry(
            fileName: fileName,
            counterpart: "Peer",
            size: "1 KB",
            timestamp: "Today",
            direction: .received,
            outcome: .completed
        )
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
    private(set) var refreshDiscoveryCallCount = 0
    private(set) var stagedItems: [StagedTransferItem] = []
    private(set) var sentPeerIDs: [NearbyPeerItem.ID] = []
    private(set) var responses: [IncomingTransferDecision] = []
    private(set) var canceledTransferIDs: [ActiveTransferProgress.ID] = []

    func start() async throws {}
    func stop() async {}
    func refreshDiscovery() async { refreshDiscoveryCallCount += 1 }
    func discoveredPeers() async -> AsyncStream<[NearbyPeerItem]> { await peersBroadcaster.stream() }
    func inboundRequests() async -> AsyncStream<IncomingTransferRequest> { await incomingBroadcaster.stream() }
    func progressEvents() async -> AsyncStream<ActiveTransferProgress> { await progressBroadcaster.stream() }
    func updateSettings(_ settings: TransferProtocolSettings) async throws { lastUpdatedSettings = settings }
    func stage(_ items: [StagedTransferItem]) async { stagedItems = items }
    func sendStagedItems(to peerID: NearbyPeerItem.ID, pin: String?) async throws { sentPeerIDs.append(peerID) }
    func respondToIncomingRequest(_ response: IncomingTransferDecision) async throws { responses.append(response) }
    func cancelActiveTransfer(_ id: ActiveTransferProgress.ID) async throws { canceledTransferIDs.append(id) }

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
