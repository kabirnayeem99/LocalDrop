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

    func testPersistSettingsFailureSurfacesErrorFeedback() async {
        let runtime = FakeTransferRuntime()
        await runtime.setUpdateSettingsError(TestFailure.runtimeApplyFailed)
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
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

        _ = SendView(store: store, actions: actions).body
        _ = RootView(store: store, sendEntryActions: actions).body
        _ = SendTextEntrySheet(initialText: "", onStage: { _ in }, onCancel: {}).body
        _ = SendTextEntrySheet(initialText: "hello", onStage: { _ in }, onCancel: {}).body
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

private enum TestFailure: LocalizedError {
    case nodeDidNotStart
    case runtimeApplyFailed

    var errorDescription: String? {
        switch self {
        case .nodeDidNotStart:
            "Node did not start"
        case .runtimeApplyFailed:
            "Runtime apply failed"
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
