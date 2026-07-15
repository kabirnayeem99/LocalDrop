import AppKit
import SwiftUI
import XCTest
@testable import FeatureTransfer
import AppLogging
import LocalSendKit

@MainActor
final class FeatureTransferTests: XCTestCase {
    func testActiveSheetPrefersIncomingRequestOverProgress() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
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
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )

        store.requirePIN = true
        store.allowDownloads = false
        store.useHTTPS = false
        store.persistSettings()

        let persisted = persistence.savedSnapshots.last
        XCTAssertEqual(persisted?.protocolSettings.requirePIN, true)
        XCTAssertEqual(persisted?.protocolSettings.allowDownloads, false)
        XCTAssertEqual(persisted?.protocolSettings.useHTTPS, false)

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
            useHTTPS: true,
            saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
        )

        XCTAssertEqual(settings.protocolType, .https)

        settings.useHTTPS = false

        XCTAssertEqual(settings.protocolType, .http)
    }

    func testProtocolSettingsDecodeLegacyAndCanonicalHTTPSKeys() throws {
        let legacyPayload = """
        {
          "deviceName":"LocalDrop Test Mac",
          "tcpPort":53317,
          "requirePIN":false,
          "incomingPIN":"123456",
          "allowDownloads":true,
          "endToEndEncryption":false,
          "saveLocation":"file:///tmp/LocalDropTests"
        }
        """
        let canonicalPayload = """
        {
          "deviceName":"LocalDrop Test Mac",
          "tcpPort":53317,
          "requirePIN":false,
          "incomingPIN":"123456",
          "allowDownloads":true,
          "useHTTPS":true,
          "saveLocation":"file:///tmp/LocalDropTests"
        }
        """

        let legacy = try JSONDecoder().decode(TransferProtocolSettings.self, from: Data(legacyPayload.utf8))
        let canonical = try JSONDecoder().decode(TransferProtocolSettings.self, from: Data(canonicalPayload.utf8))

        XCTAssertFalse(legacy.useHTTPS)
        XCTAssertTrue(canonical.useHTTPS)
    }

    func testProtocolSettingsEncodePreservesLegacyPersistenceKey() throws {
        let settings = TransferProtocolSettings(
            deviceName: "LocalDrop Test Mac",
            tcpPort: 53_317,
            requirePIN: false,
            incomingPIN: "123456",
            allowDownloads: true,
            useHTTPS: false,
            saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
        )

        let json = try XCTUnwrap(String(data: JSONEncoder().encode(settings), encoding: .utf8))

        XCTAssertTrue(json.contains("\"endToEndEncryption\":false"))
        XCTAssertFalse(json.contains("\"useHTTPS\""))
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
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
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

    func testPersistSettingsRepairsMissingPINWhenRequirementEnabled() {
        let runtime = FakeTransferRuntime()
        let persistence = InMemorySettingsPersistence()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: persistence,
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )

        store.requirePIN = true
        store.incomingPIN = ""
        store.persistSettings()

        XCTAssertEqual(store.incomingPIN.count, TransferProtocolSettings.incomingPINLength)
        XCTAssertEqual(persistence.savedSnapshots.last?.protocolSettings.incomingPIN, store.incomingPIN)
    }

    func testUpdateIncomingPINPersistsAndPushesRuntimeSettings() async {
        let runtime = FakeTransferRuntime()
        let persistence = InMemorySettingsPersistence()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: persistence,
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
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
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
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

    func testPersistSettingsFailureSurfacesErrorFeedback() async {
        let runtime = FakeTransferRuntime()
        await runtime.setUpdateSettingsError(TestFailure.runtimeApplyFailed)
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )

        store.useHTTPS = false
        store.persistSettings()

        await waitUntil { store.lastErrorMessage == TestFailure.runtimeApplyFailed.localizedDescription }
        XCTAssertEqual(store.feedback?.tone, .destructive)
        XCTAssertEqual(store.feedback?.message, "Settings could not be applied")
    }

    func testMenuSummaryReflectsRuntimeIncomingAndTransferStates() async {
        let runtime = FakeTransferRuntime()
        let historyPersistence = InMemoryHistoryPersistence(entries: [
            makeHistoryEntry(fileName: "one.txt"),
            makeHistoryEntry(fileName: "two.txt"),
            makeHistoryEntry(fileName: "three.txt"),
            makeHistoryEntry(fileName: "four.txt"),
            makeHistoryEntry(fileName: "five.txt"),
            makeHistoryEntry(fileName: "six.txt")
        ])
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: historyPersistence,
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )

        XCTAssertEqual(store.menuSummary.statusSymbol, "paperplane.circle")
        XCTAssertNil(store.menuSummary.stagedItemsText)
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

    func testStageDroppedItemsTracksEntireBatchAndRemoveRestagesRemainder() async throws {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )
        let alpha = URL(fileURLWithPath: "/tmp/LocalDropTests/alpha.txt")
        let bravo = URL(fileURLWithPath: "/tmp/LocalDropTests/bravo.txt")
        let charlie = URL(fileURLWithPath: "/tmp/LocalDropTests/charlie.txt")

        store.stageDroppedItems([alpha, bravo, charlie])

        XCTAssertEqual(store.stagedItems.map(\.name), ["alpha.txt", "bravo.txt", "charlie.txt"])
        XCTAssertEqual(store.feedback?.message, "3 items staged")
        await waitUntil { await runtime.stagedItems.map(\.fileURL) == [alpha, bravo, charlie] }
        XCTAssertEqual(store.menuSummary.stagedItemCount, 3)
        XCTAssertEqual(store.menuSummary.stagedItemsText, store.stagedItems.stagedBatchSummaryLabel)

        let removedID = try XCTUnwrap(store.stagedItems.dropFirst().first?.id)
        store.removeStagedItem(id: removedID)

        XCTAssertEqual(store.stagedItems.map(\.name), ["alpha.txt", "charlie.txt"])
        await waitUntil { await runtime.stagedItems.map(\.fileURL) == [alpha, charlie] }
        XCTAssertEqual(store.menuSummary.stagedItemCount, 2)
        XCTAssertEqual(store.menuSummary.stagedItemsText, store.stagedItems.stagedBatchSummaryLabel)
    }

    func testRefreshNearbyPeersShowsRefreshFeedbackAndResetsFlag() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )

        store.refreshNearbyPeers()

        XCTAssertTrue(store.isRefreshingDiscovery)
        await waitUntil { await runtime.refreshDiscoveryCallCount == 1 }
        await waitUntil { store.isRefreshingDiscovery == false }
        XCTAssertEqual(store.feedback?.message, "Discovery refreshed")
        XCTAssertEqual(store.feedback?.tone, .neutral)
    }

    func testScanNearbyPeersShowsScanFeedbackAndResetsFlag() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )

        store.scanNearbyPeers()

        XCTAssertTrue(store.isScanningDiscovery)
        await waitUntil { await runtime.refreshDiscoveryCallCount == 1 }
        await waitUntil { store.isScanningDiscovery == false }
        XCTAssertEqual(store.feedback?.message, "Discovery scan started")
        XCTAssertEqual(store.feedback?.tone, .neutral)
    }

    func testMenuActionsDriveRuntimeAndStoreIntegration() async {
        let runtime = FakeTransferRuntime()
        let persistence = InMemorySettingsPersistence()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: persistence,
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
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
        let acceptAllResponse: FeatureTransfer.IncomingTransferDecision = .acceptAll(requestID: "request-id")
        await waitUntil { await runtime.responses == [acceptAllResponse] }

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

    func testDeclineAndSubsetAcceptSendExpectedResponses() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )
        let request = IncomingTransferRequest(
            id: "request-id",
            deviceName: "Peer Mac",
            subtitle: "Peer Mac · 2 items",
            sourceKind: .macbook,
            files: [
                IncomingTransferFile(id: "a", name: "a.txt", size: "1 KB", symbol: "doc"),
                IncomingTransferFile(id: "b", name: "b.txt", size: "1 KB", symbol: "doc")
            ]
        )

        await runtime.emitIncomingRequest(request)
        await store.start()
        await waitUntil { store.incomingRequest?.id == "request-id" }

        let subsetResponse: FeatureTransfer.IncomingTransferDecision = .acceptSubset(
            requestID: "request-id",
            fileIDs: ["a"]
        )
        store.acceptIncomingRequest(fileIDs: ["a"])
        await waitUntil { await runtime.responses == [subsetResponse] }
        XCTAssertEqual(store.feedback?.message, "1 files accepted")
        XCTAssertEqual(store.feedback?.tone, .success)

        await runtime.emitIncomingRequest(request)
        await waitUntil { store.incomingRequest?.id == "request-id" }

        let rejectResponse: FeatureTransfer.IncomingTransferDecision = .reject(requestID: "request-id")
        store.declineIncomingRequest()
        await waitUntil { await runtime.responses == [subsetResponse, rejectResponse] }
    }

    func testDismissProgressClearsActiveTransferImmediately() {
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )

        store.activeTransfer = ActiveTransferProgress(
            id: "progress",
            direction: .receiving,
            counterpartName: "Peer",
            fileName: "demo.txt",
            progress: 0.5,
            throughput: "1 MB/s",
            etaDescription: "Soon"
        )

        store.dismissProgress()

        XCTAssertNil(store.activeTransfer)
    }

    func testNearbyDevicesPresentationStateReflectsDiscoveryActivity() {
        XCTAssertEqual(
            NearbyDevicesPresentationState(peerCount: 0, isRefreshing: false, isScanning: false),
            .emptyIdle
        )
        XCTAssertEqual(
            NearbyDevicesPresentationState(peerCount: 0, isRefreshing: true, isScanning: false),
            .emptyRefreshing
        )
        XCTAssertEqual(
            NearbyDevicesPresentationState(peerCount: 0, isRefreshing: false, isScanning: true),
            .emptyScanning
        )
        XCTAssertEqual(
            NearbyDevicesPresentationState(peerCount: 2, isRefreshing: true, isScanning: true),
            .results
        )
    }

    func testIncomingRequestSelectionStateTracksAllPartialAndNone() {
        XCTAssertEqual(
            IncomingRequestSelectionState(selectedCount: 0, totalCount: 3),
            .none(totalCount: 3)
        )
        XCTAssertEqual(
            IncomingRequestSelectionState(selectedCount: 2, totalCount: 3),
            .partial(selectedCount: 2, totalCount: 3)
        )
        XCTAssertEqual(
            IncomingRequestSelectionState(selectedCount: 3, totalCount: 3),
            .all(totalCount: 3)
        )
        XCTAssertTrue(IncomingRequestSelectionState(selectedCount: 3, totalCount: 3).acceptsAll)
        XCTAssertFalse(IncomingRequestSelectionState(selectedCount: 1, totalCount: 3).acceptsAll)
    }

    func testTransferSecurityCopyUsesHTTPAndHTTPSTerminology() {
        XCTAssertEqual(TransferSecurityCopy.httpsToggleTitle, "Use HTTPS for transfers")
        XCTAssertTrue(TransferSecurityCopy.httpsToggleHelp.contains("HTTPS"))
        XCTAssertTrue(TransferSecurityCopy.httpsToggleHelp.contains("plain HTTP"))
        XCTAssertTrue(TransferSecurityCopy.httpsDisabledMessage.contains("plain HTTP"))
        XCTAssertFalse(TransferSecurityCopy.httpsDisabledMessage.localizedCaseInsensitiveContains("end-to-end"))
    }

    func testSettingsViewBodyBuildsWithHTTPSSetting() {
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )

        _ = SettingsView(store: store).body
        store.useHTTPS = false
        _ = SettingsView(store: store).body
    }

    func testLocalSendRuntimeAdapterRestartSwitchesBetweenHTTPSAndHTTP() async throws {
        let recorder = RuntimeComponentRecorder()
        let initialSettings = TransferProtocolSettings(
            deviceName: "LocalDrop Test Mac",
            tcpPort: 0,
            requirePIN: false,
            incomingPIN: "123456",
            allowDownloads: true,
            useHTTPS: true,
            saveLocation: makeTempDirectory()
        )
        let adapter = try makeLiveRuntimeAdapter(settings: initialSettings, recorder: recorder)

        try await adapter.start()
        defer { Task { await adapter.stop() } }

        let initialRecordedNode = await recorder.lastNode()
        let initialNode = try XCTUnwrap(initialRecordedNode)
        let initialEndpoint = try await waitForRunningEndpoint(node: initialNode)
        XCTAssertEqual(initialEndpoint.protocolType, .https)

        var updatedSettings = initialSettings
        updatedSettings.useHTTPS = false
        updatedSettings.saveLocation = makeTempDirectory()
        try await adapter.updateSettings(updatedSettings)

        let restartedRecordedNode = await recorder.lastNode()
        let restartedNode = try XCTUnwrap(restartedRecordedNode)
        let restartedEndpoint = try await waitForRunningEndpoint(node: restartedNode)
        XCTAssertEqual(restartedEndpoint.protocolType, .http)
        let protocolHistory = await recorder.protocolHistory()
        XCTAssertEqual(protocolHistory, [.https, .http])
    }

    func testLocalSendRuntimeAdapterSkipsRebuildWhenSettingsAreUnchanged() async throws {
        let recorder = RuntimeComponentRecorder()
        let settings = TransferProtocolSettings(
            deviceName: "LocalDrop Test Mac",
            tcpPort: 0,
            requirePIN: false,
            incomingPIN: "123456",
            allowDownloads: true,
            useHTTPS: true,
            saveLocation: makeTempDirectory()
        )
        let adapter = try makeLiveRuntimeAdapter(settings: settings, recorder: recorder)
        defer { Task { await adapter.stop() } }

        try await adapter.updateSettings(settings)

        let protocolHistory = await recorder.protocolHistory()
        XCTAssertEqual(protocolHistory, [.https])
    }

    func testSendEntryKindDispatchesExpectedActions() {
        var invoked: [String] = []
        let actions = SendEntryActions(
            sendFiles: { invoked.append("file") },
            sendFolders: { invoked.append("folder") },
            sendText: { invoked.append("text") },
            sendClipboard: { invoked.append("clipboard") }
        )

        for kind in SendEntryKind.allCases {
            kind.perform(using: actions)
        }

        XCTAssertEqual(invoked, ["file", "folder", "text", "clipboard"])
    }

    func testContainerStagesGeneratedTextFileAndShowsSendScreen() async throws {
        let runtime = FakeTransferRuntime()
        let container = TransferFeatureContainer(
            store: TransferFeatureStore(
                runtime: runtime,
                settingsPersistence: InMemorySettingsPersistence(),
                historyPersistence: InMemoryHistoryPersistence(),
                loginItemManaging: FakeLoginItemManaging(),
                snapshot: .default(
                    deviceName: "LocalDrop Test Mac",
                    saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
                )
            ),
            logger: .disabled()
        )
        let directory = makeTempDirectory()

        XCTAssertTrue(container.stagePastedText("  hello localdrop  ", in: directory))

        await waitUntil { await runtime.stagedItems.count == 1 }
        let stagedItems = await runtime.stagedItems
        let stagedFile = try XCTUnwrap(stagedItems.first)
        let text = try String(contentsOf: stagedFile.fileURL)
        XCTAssertEqual(text, "hello localdrop")
        XCTAssertEqual(stagedFile.fileURL.pathExtension, "txt")
        XCTAssertEqual(container.store.screen, .send)
    }

    func testContainerRejectsEmptyTextInputWithVisibleFailure() {
        let container = TransferFeatureContainer.testing()

        XCTAssertFalse(container.stagePastedText("   \n\t"))
        XCTAssertEqual(container.store.lastErrorMessage, "Text cannot be empty.")
        XCTAssertEqual(container.store.feedback?.tone, .destructive)
        XCTAssertEqual(container.store.screen, .send)
    }

    func testClipboardFallbackReturnsRequiresTextEntryWhenStringMissing() {
        let container = TransferFeatureContainer.testing()

        let result = container.stageClipboardTextIfAvailable(stringProvider: { nil })

        XCTAssertEqual(result, .requiresTextEntry)
    }

    func testClipboardTextStagesWhenAvailable() async throws {
        let runtime = FakeTransferRuntime()
        let container = TransferFeatureContainer(
            store: TransferFeatureStore(
                runtime: runtime,
                settingsPersistence: InMemorySettingsPersistence(),
                historyPersistence: InMemoryHistoryPersistence(),
                loginItemManaging: FakeLoginItemManaging(),
                snapshot: .default(
                    deviceName: "LocalDrop Test Mac",
                    saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
                )
            ),
            logger: .disabled()
        )
        let directory = makeTempDirectory()

        let result = container.stageClipboardTextIfAvailable(
            stringProvider: { "from clipboard" },
            in: directory
        )

        XCTAssertEqual(result, .staged)
        await waitUntil { await runtime.stagedItems.count == 1 }
        let stagedItems = await runtime.stagedItems
        let stagedFile = try XCTUnwrap(stagedItems.first?.fileURL)
        XCTAssertEqual(try String(contentsOf: stagedFile), "from clipboard")
    }

    func testSendTextAndSendViewsBuildWithEntryActions() {
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )
        let actions = SendEntryActions(
            sendFiles: {},
            sendFolders: {},
            sendText: {},
            sendClipboard: {}
        )

        store.stageDroppedItems([
            URL(fileURLWithPath: "/tmp/LocalDropTests/alpha.txt"),
            URL(fileURLWithPath: "/tmp/LocalDropTests/bravo.txt")
        ])
        _ = SendView(store: store, actions: actions).body
        _ = RootView(store: store, sendEntryActions: actions).body
        _ = SendTextEntrySheet(initialText: "", onStage: { _ in }, onCancel: {}).body
        _ = SendTextEntrySheet(initialText: "hello", onStage: { _ in }, onCancel: {}).body
    }

    func testStageImportedItemsStagesFilesAndSwitchesToSendScreen() async {
        let runtime = FakeTransferRuntime()
        let container = TransferFeatureContainer(
            store: TransferFeatureStore(
                runtime: runtime,
                settingsPersistence: InMemorySettingsPersistence(),
                historyPersistence: InMemoryHistoryPersistence(),
                loginItemManaging: FakeLoginItemManaging(),
                snapshot: .default(
                    deviceName: "LocalDrop Test Mac",
                    saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
                )
            ),
            logger: .disabled()
        )
        // Default screen is .receive; staging imports must switch to .send.
        XCTAssertEqual(container.store.screen, .receive)

        let urls = [
            URL(fileURLWithPath: "/tmp/LocalDropTests/one.pdf"),
            URL(fileURLWithPath: "/tmp/LocalDropTests/two.jpg")
        ]
        container.stageImportedItems(urls)

        XCTAssertEqual(container.store.screen, .send)
        XCTAssertEqual(container.store.stagedItems.map(\.fileURL), urls)
        await waitUntil { await runtime.stagedItems.map(\.fileURL) == urls }
    }

    func testStagePastedTextReportsFailureWhenFileCannotBeWritten() throws {
        let container = TransferFeatureContainer.testing()
        // Use an existing regular file as the target "directory" so createDirectory throws.
        let blockingFile = makeTempDirectory().appendingPathComponent("not-a-directory", isDirectory: false)
        try "blocker".write(to: blockingFile, atomically: true, encoding: .utf8)

        XCTAssertFalse(container.stagePastedText("payload", in: blockingFile))
        XCTAssertEqual(container.store.feedback?.tone, .destructive)
        XCTAssertNotNil(container.store.lastErrorMessage)
        XCTAssertEqual(container.store.screen, .send)
        XCTAssertTrue(container.store.stagedItems.isEmpty)
    }

    func testStagePastedTextUsesDefaultOutboundDirectoryWhenUnspecified() throws {
        let container = TransferFeatureContainer.testing()

        XCTAssertTrue(container.stagePastedText("default directory payload"))

        let stagedURL = try XCTUnwrap(container.store.stagedItems.first?.fileURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: stagedURL) }
        XCTAssertEqual(stagedURL.pathExtension, "txt")
        XCTAssertEqual(stagedURL.deletingLastPathComponent().lastPathComponent, "OutgoingText")
        XCTAssertEqual(try String(contentsOf: stagedURL), "default directory payload")
    }

    func testSendEntryKindExposesSymbolsAndNoopActionsAreInert() {
        for kind in SendEntryKind.allCases {
            XCTAssertFalse(kind.symbol.isEmpty)
            XCTAssertEqual(kind.id, kind.rawValue)
            // .noop closures must be safe to invoke and do nothing.
            kind.perform(using: .noop)
        }
    }

    func testTextStagingEmitsStructuredLogsForImportSuccessAndFailure() async throws {
        let sink = RecordingLogSink()
        let logger = AppLogger(
            configuration: AppLoggerConfiguration(minimumLevel: .debug, redactSensitiveValues: true),
            resource: [.string("service.name", "LocalDrop")],
            sinks: [sink]
        )
        let runtime = FakeTransferRuntime()
        let container = TransferFeatureContainer(
            store: TransferFeatureStore(
                runtime: runtime,
                settingsPersistence: InMemorySettingsPersistence(),
                historyPersistence: InMemoryHistoryPersistence(),
                loginItemManaging: FakeLoginItemManaging(),
                snapshot: .default(
                    deviceName: "LocalDrop Test Mac",
                    saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
                ),
                logger: logger
            ),
            logger: logger
        )

        container.stageImportedItems([URL(fileURLWithPath: "/tmp/LocalDropTests/report.pdf")])

        let textDirectory = makeTempDirectory()
        XCTAssertTrue(container.stagePastedText("logged text", in: textDirectory))

        let blockingFile = makeTempDirectory().appendingPathComponent("blocker", isDirectory: false)
        try "x".write(to: blockingFile, atomically: true, encoding: .utf8)
        XCTAssertFalse(container.stagePastedText("cannot write", in: blockingFile))

        // Empty input drives the same failure logging with a nil error, covering
        // the message fallback branch inside the enabled-logger autoclosure.
        XCTAssertFalse(container.stagePastedText("   "))

        await waitUntil {
            let eventNames = await sink.records().compactMap { record -> String? in
                if case .string(let value) = record.attributes["event.name"] {
                    return value
                }
                return nil
            }
            return eventNames.contains("app.import.files.selected")
                && eventNames.contains("app.import.text.staged")
                && eventNames.contains("app.import.text.failed")
                && eventNames.contains("app.import.text.empty")
        }
    }

    func testClipboardStagingReadsDefaultSystemPasteboard() throws {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)
        addTeardownBlock {
            pasteboard.clearContents()
            if let previousContents {
                pasteboard.setString(previousContents, forType: .string)
            }
        }

        pasteboard.clearContents()
        pasteboard.setString("system pasteboard text", forType: .string)

        let container = TransferFeatureContainer.testing()
        // Exercises the default stringProvider that reads NSPasteboard.general.
        let result = container.stageClipboardTextIfAvailable(in: makeTempDirectory())

        XCTAssertEqual(result, .staged)
        let stagedURL = try XCTUnwrap(container.store.stagedItems.first?.fileURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: stagedURL) }
        XCTAssertEqual(try String(contentsOf: stagedURL), "system pasteboard text")
    }

    func testStoreEmitsStructuredLogsForStartStageSendAndSettingsFailure() async {
        let sink = RecordingLogSink()
        let logger = AppLogger(
            configuration: AppLoggerConfiguration(minimumLevel: .info, redactSensitiveValues: true),
            resource: [.string("service.name", "LocalDrop")],
            sinks: [sink],
            clock: AppLogClock(now: { 42 })
        )
        let runtime = FakeTransferRuntime()
        await runtime.setUpdateSettingsError(TestFailure.runtimeApplyFailed)
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            ),
            logger: logger
        )

        await store.start()
        store.stageDroppedItems([URL(fileURLWithPath: "/tmp/LocalDropTests/report.pdf")])
        store.send(to: "peer-id")
        store.useHTTPS = false
        store.persistSettings()

        await waitUntil {
            let eventNames = await sink.records().compactMap { record -> String? in
                if case .string(let value) = record.attributes["event.name"] {
                    return value
                }
                return nil
            }
            return eventNames.contains("app.runtime.start.requested")
                && eventNames.contains("app.runtime.start.succeeded")
                && eventNames.contains("transfer.stage.completed")
                && eventNames.contains("transfer.send.requested")
                && eventNames.contains("settings.runtime_update.failed")
        }

        let eventNames = await sink.records().compactMap { record -> String? in
            if case .string(let value) = record.attributes["event.name"] {
                return value
            }
            return nil
        }
        XCTAssertTrue(eventNames.contains("app.runtime.start.requested"))
        XCTAssertTrue(eventNames.contains("app.runtime.start.succeeded"))
        XCTAssertTrue(eventNames.contains("transfer.stage.completed"))
        XCTAssertTrue(eventNames.contains("transfer.send.requested"))
        XCTAssertTrue(eventNames.contains("settings.runtime_update.failed"))
    }

    func testLaunchAtLoginRegistersAndUnregistersLoginItem() {
        let manager = FakeLoginItemManaging()
        let persistence = InMemorySettingsPersistence()
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: persistence,
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: manager,
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )

        store.launchAtLogin = true
        store.applyLaunchAtLogin()

        XCTAssertTrue(manager.isRegistered)
        XCTAssertTrue(persistence.savedSnapshots.contains { $0.launchAtLogin == true })

        store.launchAtLogin = false
        store.applyLaunchAtLogin()

        XCTAssertFalse(manager.isRegistered)
        XCTAssertTrue(persistence.savedSnapshots.contains { $0.launchAtLogin == false })
    }

    func testLaunchAtLoginFailureRevertsSettingAndSurfacesFeedback() {
        let manager = ThrowingLoginItemManager()
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: manager,
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )

        store.launchAtLogin = true
        store.applyLaunchAtLogin()

        XCTAssertFalse(store.launchAtLogin)
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertEqual(store.feedback?.message, "Couldn't update Launch at Login")
    }

    func testUpdateSaveLocationPersistsNewLocation() {
        let runtime = FakeTransferRuntime()
        let persistence = InMemorySettingsPersistence()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: persistence,
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )

        let newLocation = URL(fileURLWithPath: "/tmp/LocalDropTests/Downloads")
        store.updateSaveLocation(newLocation)

        XCTAssertEqual(store.saveLocation, newLocation.path)
        XCTAssertEqual(persistence.savedSnapshots.last?.protocolSettings.saveLocation, newLocation)
    }

    func testHistoryPersistenceAdapterRoundTripsEntries() throws {
        let directory = makeTempDirectory()
        let adapter = HistoryPersistenceAdapter(directory: directory)
        XCTAssertTrue(adapter.load().isEmpty)

        let entries = [
            makeHistoryEntry(fileName: "a.txt"),
            makeHistoryEntry(fileName: "b.txt")
        ]
        adapter.save(entries)

        let loaded = adapter.load()
        XCTAssertEqual(loaded.map(\.fileName), ["a.txt", "b.txt"])
    }

    func testRevealInFinderShowsFeedbackWhenFileIsMissing() {
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )

        let entry = makeHistoryEntry(
            fileName: "missing.txt",
            fileURL: URL(fileURLWithPath: "/tmp/LocalDropTests/missing.txt")
        )
        store.revealInFinder(entry)

        XCTAssertEqual(store.feedback?.message, "File no longer available")
        XCTAssertEqual(store.feedback?.tone, .destructive)
    }

    func testOpenHistoryItemNoOpsWhenFileURLIsAbsent() {
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )

        let entry = makeHistoryEntry(fileName: "no-url.txt", fileURL: nil)
        store.openHistoryItem(entry)

        XCTAssertNil(store.feedback)
    }

    func testRuntimeAdapterEmitsRestartAndSkipLogs() async throws {
        let sink = RecordingLogSink()
        let logger = AppLogger(
            configuration: AppLoggerConfiguration(minimumLevel: .debug, redactSensitiveValues: true),
            resource: [.string("service.name", "LocalDrop")],
            sinks: [sink]
        )
        let recorder = RuntimeComponentRecorder()
        let settings = TransferProtocolSettings(
            deviceName: "LocalDrop Test Mac",
            tcpPort: 0,
            requirePIN: false,
            incomingPIN: "123456",
            allowDownloads: true,
            useHTTPS: true,
            saveLocation: makeTempDirectory()
        )
        let adapter = try makeLiveRuntimeAdapter(settings: settings, recorder: recorder, logger: logger)
        defer { Task { await adapter.stop() } }

        try await adapter.updateSettings(settings)
        var updatedSettings = settings
        updatedSettings.useHTTPS = false
        updatedSettings.saveLocation = makeTempDirectory()
        try await adapter.updateSettings(updatedSettings)

        await waitUntil {
            let eventNames = await sink.records().compactMap { record -> String? in
                if case .string(let value) = record.attributes["event.name"] {
                    return value
                }
                return nil
            }
            return eventNames.contains("settings.runtime_restart.skipped_unchanged")
                && eventNames.contains("settings.runtime_restart.started")
                && eventNames.contains("settings.runtime_restart.completed")
        }

        let eventNames = await sink.records().compactMap { record -> String? in
            if case .string(let value) = record.attributes["event.name"] {
                return value
            }
            return nil
        }
        XCTAssertTrue(eventNames.contains("settings.runtime_restart.skipped_unchanged"))
        XCTAssertTrue(eventNames.contains("settings.runtime_restart.started"))
        XCTAssertTrue(eventNames.contains("settings.runtime_restart.completed"))
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

    private func makeHistoryEntry(
        fileName: String,
        timestamp: Date = Date(),
        direction: TransferDirection = .received,
        outcome: TransferOutcome = .completed,
        fileURL: URL? = nil
    ) -> HistoryEntry {
        HistoryEntry(
            fileName: fileName,
            counterpart: "Peer",
            size: "1 KB",
            timestamp: timestamp,
            direction: direction,
            outcome: outcome,
            fileURL: fileURL
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

    private func makeLiveRuntimeAdapter(
        settings: TransferProtocolSettings,
        recorder: RuntimeComponentRecorder,
        logger: AppLogger = .disabled()
    ) throws -> LocalSendRuntimeAdapter {
        let certificateStore = FileCertificateStore(
            identityURL: makeTempDirectory().appendingPathComponent("identity.json")
        )
        let makeComponents: @Sendable (TransferProtocolSettings) throws -> LiveRuntimeComponents = { settings in
            let identity = try CertificateAuthority(store: certificateStore).loadOrCreateIdentity()
            let registerInfo = RegisterInfo(
                alias: settings.deviceName,
                deviceModel: "LocalDrop Test Runtime",
                deviceType: .desktop,
                fingerprint: identity.fingerprint,
                port: settings.tcpPort == 0 ? nil : settings.tcpPort,
                protocolType: settings.protocolType,
                download: settings.allowDownloads
            )
            let runtimeConfiguration = LocalSendRuntimeConfiguration(
                registerInfo: registerInfo,
                protocolType: settings.protocolType,
                tcpPort: UInt16(clamping: settings.tcpPort),
                storageDirectory: settings.saveLocation,
                pin: settings.requirePIN ? settings.incomingPIN : nil,
                incomingRequestBridge: IncomingTransferRequestBridge(),
                allowDownloads: settings.allowDownloads
            )
            let node = try LocalSendNode(
                runtimeConfiguration: runtimeConfiguration,
                certificateStore: certificateStore
            )
            let components = LiveRuntimeComponents(node: node, registerInfo: registerInfo)
            Task {
                await recorder.record(protocolType: settings.protocolType, node: node)
            }
            return components
        }

        return LocalSendRuntimeAdapter(
            components: try makeComponents(settings),
            settings: settings,
            makeComponents: makeComponents,
            logger: logger
        )
    }

    private func waitForRunningEndpoint(
        node: LocalSendNode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> LocalSendServerRuntimeBoundEndpoint {
        for _ in 0..<100 {
            let snapshot = await node.runtimeSnapshot()
            switch snapshot.lifecycle {
            case .running(let endpoint):
                return endpoint
            default:
                await Task.yield()
            }
        }

        XCTFail("Node did not reach running state", file: file, line: line)
        throw TestFailure.nodeDidNotStart
    }

    private func makeTempDirectory() -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testAccentColorChoiceDefaultIsMedinaEmerald() {
        let snapshot = TransferSettingsSnapshot.default(
            deviceName: "LocalDrop Test Mac",
            saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
        )
        XCTAssertEqual(snapshot.accentColor, .medinaEmerald)
    }

    func testAccentColorChoiceThemeResolvesForEveryCase() {
        for choice in AccentColorChoice.allCases {
            XCTAssertNotEqual(choice.theme.primary, Color.clear, "Primary color should be resolved for \(choice)")
        }
    }

    func testLegacyGreenAccentColorMigratesToMedinaEmerald() throws {
        let payload = """
        "green"
        """
        let choice = try JSONDecoder().decode(AccentColorChoice.self, from: Data(payload.utf8))
        XCTAssertEqual(choice, .medinaEmerald)
    }

    func testLegacyBlueAccentColorMigratesToSystemBlue() throws {
        let payload = """
        "blue"
        """
        let choice = try JSONDecoder().decode(AccentColorChoice.self, from: Data(payload.utf8))
        XCTAssertEqual(choice, .systemBlue)
    }

    func testLegacyOrangeAccentColorMigratesToSystemOrange() throws {
        let payload = """
        "orange"
        """
        let choice = try JSONDecoder().decode(AccentColorChoice.self, from: Data(payload.utf8))
        XCTAssertEqual(choice, .systemOrange)
    }

    func testLegacyPurpleAccentColorMigratesToSystemPurple() throws {
        let payload = """
        "purple"
        """
        let choice = try JSONDecoder().decode(AccentColorChoice.self, from: Data(payload.utf8))
        XCTAssertEqual(choice, .systemPurple)
    }

    func testUnknownLegacyAccentColorFallsBackToMedinaEmerald() throws {
        let payload = """
        "chartreuse"
        """
        let choice = try JSONDecoder().decode(AccentColorChoice.self, from: Data(payload.utf8))
        XCTAssertEqual(choice, .medinaEmerald)
    }

    func testLanguageSettingLocaleForEverySupportedLanguage() {
        let expectations: [(LanguageSetting, String)] = [
            (.arabic, "ar"),
            (.indonesian, "id"),
            (.urdu, "ur"),
            (.bengali, "bn"),
            (.hindi, "hi"),
            (.turkish, "tr"),
            (.english, "en-US"),
            (.french, "fr"),
            (.russian, "ru"),
            (.uyghur, "ug"),
            (.simplifiedChinese, "zh-Hans"),
            (.spanish, "es"),
            (.brazilianPortuguese, "pt-BR"),
            (.german, "de"),
            (.vietnamese, "vi"),
            (.korean, "ko"),
            (.japanese, "ja"),
            (.system, "__system__")
        ]

        for (language, expectedIdentifier) in expectations {
            if expectedIdentifier == "__system__" {
                XCTAssertNil(language.locale)
            } else {
                XCTAssertEqual(language.locale?.identifier, expectedIdentifier)
            }
        }
    }

    func testApplyingLanguageOverrideInjectsLocaleIntoEnvironment() {
        struct LocaleReader: View {
            @Environment(\.locale) var locale
            var body: some View { EmptyView() }
        }

        let reader = LocaleReader().applyingLanguageOverride(.french)
        XCTAssertNotNil(reader)
    }

    func testAllLanguageEndonymsAreNonEmpty() {
        for language in LanguageSetting.allCases {
            XCTAssertFalse(language.label.isEmpty, "Endonym should not be empty for \(language)")
        }
    }

    func testLanguageSettingCaseIterableOrderMatchesProductPriority() {
        let expected: [LanguageSetting] = [
            .system, .english, .arabic, .indonesian, .urdu, .bengali,
            .hindi, .turkish, .french, .russian, .uyghur,
            .simplifiedChinese, .spanish, .brazilianPortuguese,
            .german, .vietnamese, .korean, .japanese
        ]
        XCTAssertEqual(LanguageSetting.allCases, expected)
    }

    func testLocalizationCatalogHasEnglishTranslationForEveryKey() throws {
        let catalog = try loadStringCatalog()
        let missingKeys = catalog.strings.keys.sorted().filter { key in
            guard
                let stringUnit = catalog.strings[key]?.localizations?["en"]?.stringUnit,
                stringUnit.state == "translated",
                let value = stringUnit.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                value.isEmpty == false
            else {
                return true
            }
            return false
        }

        XCTAssertEqual(missingKeys, [])
    }

    func testLocalizationCatalogResolvesEveryKeyInEnglish() throws {
        let catalog = try loadStringCatalog()

        for key in catalog.strings.keys.sorted() {
            let resolved = FeatureTransferLocalization.string(forKey: key)
            XCTAssertNotEqual(resolved, key, "Expected resolved English string for key \(key)")
        }
    }

    func testLocalizationVerificationScriptPassesCurrentCatalog() throws {
        let result = Process()
        result.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        result.arguments = [
            scriptURL.path,
            stringCatalogURL.path
        ]

        let stderr = Pipe()
        result.standardError = stderr
        try result.run()
        result.waitUntilExit()

        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        XCTAssertEqual(result.terminationStatus, 0, errorOutput ?? "verification script failed")
    }

    private var stringCatalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FeatureTransfer/Resources/Localizable.xcstrings")
    }

    private var scriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/verify-featuretransfer-localizations.swift")
    }

    private func loadStringCatalog() throws -> StringCatalog {
        let data = try Data(contentsOf: stringCatalogURL)
        return try JSONDecoder().decode(StringCatalog.self, from: data)
    }
}

private struct StringCatalog: Decodable {
    struct Entry: Decodable {
        struct Localization: Decodable {
            struct StringUnit: Decodable {
                let state: String?
                let value: String?
            }

            let stringUnit: StringUnit?
        }

        let localizations: [String: Localization]?
    }

    let strings: [String: Entry]
}

private actor FakeTransferRuntime: TransferRuntime {
    private let peersBroadcaster = TestBroadcaster<[NearbyPeerItem]>(initialValue: [])
    private let incomingBroadcaster = TestBroadcaster<FeatureTransfer.IncomingTransferRequest>()
    private let progressBroadcaster = TestBroadcaster<ActiveTransferProgress>()
    private(set) var lastUpdatedSettings: TransferProtocolSettings?
    private(set) var refreshDiscoveryCallCount = 0
    private(set) var stagedItems: [StagedTransferItem] = []
    private(set) var sentPeerIDs: [NearbyPeerItem.ID] = []
    private(set) var responses: [FeatureTransfer.IncomingTransferDecision] = []
    private(set) var canceledTransferIDs: [ActiveTransferProgress.ID] = []
    private var updateSettingsError: Error?

    func start() async throws {}
    func stop() async {}
    func refreshDiscovery() async { refreshDiscoveryCallCount += 1 }
    func discoveredPeers() async -> AsyncStream<[NearbyPeerItem]> { await peersBroadcaster.stream() }
    func inboundRequests() async -> AsyncStream<FeatureTransfer.IncomingTransferRequest> { await incomingBroadcaster.stream() }
    func progressEvents() async -> AsyncStream<ActiveTransferProgress> { await progressBroadcaster.stream() }
    func updateSettings(_ settings: TransferProtocolSettings) async throws {
        if let updateSettingsError {
            throw updateSettingsError
        }
        lastUpdatedSettings = settings
    }
    func stage(_ items: [StagedTransferItem]) async { stagedItems = items }
    func sendStagedItems(to peerID: NearbyPeerItem.ID, pin: String?) async throws { sentPeerIDs.append(peerID) }
    func respondToIncomingRequest(_ response: FeatureTransfer.IncomingTransferDecision) async throws { responses.append(response) }
    func cancelActiveTransfer(_ id: ActiveTransferProgress.ID) async throws { canceledTransferIDs.append(id) }

    func setUpdateSettingsError(_ error: Error?) {
        updateSettingsError = error
    }

    func emitIncomingRequest(_ request: FeatureTransfer.IncomingTransferRequest) async {
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

private actor RuntimeComponentRecorder {
    private var recordedProtocolHistory: [ProtocolType] = []
    private var latestNode: LocalSendNode?

    func record(protocolType: ProtocolType, node: LocalSendNode) {
        recordedProtocolHistory.append(protocolType)
        latestNode = node
    }

    func lastNode() -> LocalSendNode? {
        latestNode
    }

    func protocolHistory() -> [ProtocolType] {
        recordedProtocolHistory
    }
}

private final class FakeLoginItemManaging: LoginItemManaging, @unchecked Sendable {
    var isRegistered = false

    func register() throws {
        isRegistered = true
    }

    func unregister() throws {
        isRegistered = false
    }
}

private final class ThrowingLoginItemManager: LoginItemManaging, @unchecked Sendable {
    var isRegistered = false

    func register() throws {
        throw TestFailure.loginItemRegistrationFailed
    }

    func unregister() throws {
        throw TestFailure.loginItemRegistrationFailed
    }
}

private enum TestFailure: LocalizedError {
    case nodeDidNotStart
    case runtimeApplyFailed
    case loginItemRegistrationFailed

    var errorDescription: String? {
        switch self {
        case .nodeDidNotStart:
            "Node did not start"
        case .runtimeApplyFailed:
            "Runtime apply failed"
        case .loginItemRegistrationFailed:
            "Login item registration failed"
        }
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
