import AppKit
import SwiftUI
import XCTest
@testable import FeatureTransfer
import AppLogging
import LocalSendKit

@MainActor
final class FeatureTransferTests: XCTestCase {
    func testDeviceModelReportsRealHardwareAndMacOSVersion() {
        let model = LocalDeviceIdentity.deviceModel()

        XCTAssertFalse(model.isEmpty)
        XCTAssertTrue(model.contains("macOS"), "Expected macOS version in device model, got \(model)")
        XCTAssertFalse(
            model.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) },
            "Device model must not contain NUL or other control characters"
        )
        XCTAssertEqual(model, LocalDeviceIdentity.deviceModel(), "Device model should be cached and stable")
    }

    func testStopCancelsObservationAndAutoAcceptTasks() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )

        // stop() before start() must be safe.
        await store.stop()
        XCTAssertFalse(store.hasActiveObservationTasks)
        XCTAssertFalse(store.hasPendingAutoAcceptTasks)

        await store.start()
        XCTAssertTrue(store.hasActiveObservationTasks, "start() should bind runtime stream observers")
        // Let every observer actually reach its `for await` before tearing them down, so the
        // post-stop assertion below tests cancellation rather than a late subscription.
        for _ in 0..<20 { await Task.yield() }

        await store.stop()

        XCTAssertFalse(store.hasActiveObservationTasks)
        XCTAssertFalse(store.hasPendingAutoAcceptTasks)

        // Behavioral proof the observers really are cancelled, not merely forgotten: an event
        // emitted after stop() must not reach the store.
        await runtime.emitIncomingRequest(Self.makeIncomingRequest(id: "after-stop", senderFingerprint: "PEER"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(store.incomingRequest, "stop() should cancel every observation task")

        // A second stop() must be idempotent.
        await store.stop()
        XCTAssertFalse(store.hasActiveObservationTasks)
        XCTAssertFalse(store.hasPendingAutoAcceptTasks)
    }

    /// A stop/start cycle must leave the store observing again. `stop()` cancels the observation
    /// tasks, so failing to reset `hasStarted` would make `start()` return early and never rebind
    /// the runtime streams — the store would be silently deaf from then on.
    func testRestartAfterStopRebindsRuntimeStreams() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )

        await store.start()
        await store.stop()
        XCTAssertFalse(store.hasActiveObservationTasks)

        await store.start()
        XCTAssertTrue(store.hasActiveObservationTasks, "restart should rebind the runtime streams")

        await runtime.emitIncomingRequest(Self.makeIncomingRequest(id: "after-restart", senderFingerprint: "PEER"))
        await waitUntil { store.incomingRequest?.id == "after-restart" }
        XCTAssertEqual(store.incomingRequest?.id, "after-restart")
    }

    func testActiveSheetPrefersIncomingRequestOverProgress() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
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

    func testProgressUpdateKeepsTransferActiveWithoutAppendingHistory() async {
        let runtime = FakeTransferRuntime()
        let historyPersistence = InMemoryHistoryPersistence(entries: [])
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

        await store.start()
        await runtime.emitProgress(
            ActiveTransferProgress(
                id: "progress-1",
                direction: .sending,
                counterpartName: "Peer",
                fileName: "movie.mov",
                progress: 0.42,
                throughput: "42 KB",
                etaDescription: "1 item left",
                totalBytes: 1_000,
                transferredBytes: 420,
                totalItemCount: 3,
                currentItemIndex: 2,
                currentFileTotalBytes: 1_000,
                currentFileTransferredBytes: 420
            )
        )

        await waitUntil { store.activeTransfer?.id == "progress-1" }

        XCTAssertEqual(store.activeTransfer?.status, .running)
        XCTAssertEqual(store.activeTransfer?.resolvedTotalItemCount, 3)
        XCTAssertEqual(store.activeTransfer?.resolvedCurrentItemIndex, 2)
        XCTAssertEqual(store.activeTransfer?.batchPositionLabel, "File 2 of 3")
        XCTAssertEqual(store.activeTransfer?.remainingItemCount, 1)
        XCTAssertTrue(store.historyEntries.isEmpty)
    }

    func testActiveTransferProgressDerivesOverallAndCurrentFileBatchState() {
        let progress = ActiveTransferProgress(
            id: "batch-1",
            direction: .sending,
            counterpartName: "Peer",
            fileName: "archive.zip",
            progress: 0.1,
            throughput: "42 KB",
            etaDescription: "Soon",
            totalBytes: 4_000,
            transferredBytes: 1_000,
            totalItemCount: 4,
            currentItemIndex: 2,
            currentFileTotalBytes: 500,
            currentFileTransferredBytes: 250
        )

        XCTAssertEqual(progress.resolvedTotalItemCount, 4)
        XCTAssertEqual(progress.resolvedCurrentItemIndex, 2)
        XCTAssertEqual(progress.batchPositionLabel, "File 2 of 4")
        XCTAssertEqual(progress.remainingItemCount, 2)
        XCTAssertEqual(progress.stablePercent, 25)
        XCTAssertEqual(progress.currentFileStablePercent, 50)
        XCTAssertEqual(progress.overallProgress, 0.25, accuracy: 0.0001)
        XCTAssertEqual(progress.currentFileProgress, 0.5, accuracy: 0.0001)
    }

    func testActiveTransferProgressFallbackFileRowUsesByteCountWhenRuntimeTotalIsZero() {
        let progress = ActiveTransferProgress(
            id: "batch-2",
            direction: .sending,
            counterpartName: "Peer",
            fileName: "archive.zip",
            progress: 0.1,
            throughput: "42 KB",
            etaDescription: "Soon",
            byteCount: 500,
            totalBytes: 4_000,
            transferredBytes: 1_000,
            currentFileTotalBytes: 0,
            currentFileTransferredBytes: 250
        )

        let row = try? XCTUnwrap(progress.resolvedFileProgress.first)
        XCTAssertEqual(row?.totalBytes, 500)
        XCTAssertEqual(row?.stablePercent, 50)
    }

    func testTransferProgressReducerClampsOutOfOrderLowerProgress() async {
        let reducer = TransferProgressReducer()
        let started = await reducer.reduce(
            makeRawProgressEvent(
                kind: .transferStarted,
                transferID: "t-1",
                files: [makeRawFile(id: "f-1", name: "archive.zip", state: .queued, totalBytes: 1_000, transferredBytes: 0)],
                totalBytesKnown: 1_000,
                actualTransferredBytes: 0,
                time: 1
            )
        )
        XCTAssertEqual(started.displayableTransferredBytes, 0)

        let progressed = await reducer.reduce(
            makeRawProgressEvent(
                kind: .snapshot,
                transferID: "t-1",
                files: [makeRawFile(id: "f-1", name: "archive.zip", state: .transferring, totalBytes: 1_000, transferredBytes: 600)],
                totalBytesKnown: 1_000,
                actualTransferredBytes: 600,
                time: 2
            )
        )
        XCTAssertEqual(progressed.displayableTransferredBytes, 600)
        XCTAssertEqual(progressed.files.first?.displayedTransferredBytes, 600)

        let regressed = await reducer.reduce(
            makeRawProgressEvent(
                kind: .snapshot,
                transferID: "t-1",
                files: [makeRawFile(id: "f-1", name: "archive.zip", state: .transferring, totalBytes: 500, transferredBytes: 200)],
                totalBytesKnown: 500,
                actualTransferredBytes: 200,
                time: 3
            )
        )
        XCTAssertEqual(regressed.displayableTransferredBytes, 600)
        XCTAssertEqual(regressed.files.first?.displayedTransferredBytes, 600)
        XCTAssertEqual(regressed.files.first?.effectiveTotalBytesForDisplay, 600)
    }

    func testTransferProgressReducerKeepsCompletedRowsVisibleAcrossSequentialBatch() async {
        let reducer = TransferProgressReducer()

        _ = await reducer.reduce(
            makeRawProgressEvent(
                kind: .transferStarted,
                transferID: "t-2",
                files: [
                    makeRawFile(id: "f-1", name: "one.txt", state: .queued, totalBytes: 100, transferredBytes: 0, order: 0),
                    makeRawFile(id: "f-2", name: "two.txt", state: .queued, totalBytes: 100, transferredBytes: 0, order: 1)
                ],
                totalBytesKnown: 200,
                actualTransferredBytes: 0,
                time: 1
            )
        )

        let firstComplete = await reducer.reduce(
            makeRawProgressEvent(
                kind: .snapshot,
                transferID: "t-2",
                files: [
                    makeRawFile(id: "f-1", name: "one.txt", state: .completed, totalBytes: 100, transferredBytes: 100, order: 0),
                    makeRawFile(id: "f-2", name: "two.txt", state: .transferring, totalBytes: 100, transferredBytes: 40, order: 1)
                ],
                totalBytesKnown: 200,
                actualTransferredBytes: 140,
                time: 2
            )
        )

        XCTAssertEqual(firstComplete.files.map(\.status), [.completed, .transferring])
        XCTAssertEqual(firstComplete.displayableTransferredBytes, 140)
    }

    func testStoreThrottlesBurstyProgressEventsAndEmitsLatestSnapshot() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            ),
            progressThrottleIntervalNanoseconds: 100_000_000
        )

        await store.start()
        await runtime.emitProgress(
            ActiveTransferProgress(
                id: "throttle-1",
                direction: .sending,
                counterpartName: "Peer",
                fileName: "a.bin",
                progress: 0.1,
                throughput: "10 KB/s",
                etaDescription: "Soon",
                totalBytes: 1_000,
                transferredBytes: 100
            )
        )
        await runtime.emitProgress(
            ActiveTransferProgress(
                id: "throttle-1",
                direction: .sending,
                counterpartName: "Peer",
                fileName: "a.bin",
                progress: 0.4,
                throughput: "40 KB/s",
                etaDescription: "Soon",
                totalBytes: 1_000,
                transferredBytes: 400
            )
        )

        XCTAssertNil(store.activeTransfer)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(store.activeTransfer?.displayableTransferredBytes, 400)
    }

    func testCompletedTerminalEventAppendsHistoryAndKeepsCompletedBatchVisible() async {
        let runtime = FakeTransferRuntime()
        let historyPersistence = InMemoryHistoryPersistence(entries: [])
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

        await store.start()
        let progress = ActiveTransferProgress(
            id: "done-1",
            direction: .sending,
            counterpartName: "Peer",
            fileName: "report.pdf",
            progress: 1,
            throughput: "Saved",
            etaDescription: "Complete",
            byteCount: 512,
            totalBytes: 512,
            transferredBytes: 512,
            totalItemCount: 3,
            currentItemIndex: 3,
            currentFileTotalBytes: 512,
            currentFileTransferredBytes: 512,
            status: .completed
        )

        await runtime.emitTerminalProgress(progress)
        await waitUntil { store.historyEntries.count == 3 }
        XCTAssertTrue(store.historyEntries.contains(where: { $0.fileName == "report.pdf" }))
        XCTAssertEqual(store.feedback?.tone, .success)
        XCTAssertEqual(store.activeTransfer?.batchPositionLabel, "File 3 of 3")
        XCTAssertEqual(store.activeTransfer?.remainingItemCount, 0)
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(store.activeTransfer?.id, "done-1")
    }

    func testCanceledAndFailedTerminalEventsPreserveTerminalStateBeforeDismissal() async {
        let runtime = FakeTransferRuntime()
        let historyPersistence = InMemoryHistoryPersistence(entries: [])
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

        await store.start()
        await runtime.emitProgress(
            ActiveTransferProgress(
                id: "cancel-1",
                direction: .sending,
                counterpartName: "Peer",
                fileName: "archive.zip",
                progress: 0.2,
                throughput: "20 KB",
                etaDescription: "Uploading",
                status: .running
            )
        )
        await waitUntil { store.activeTransfer?.id == "cancel-1" }

        await runtime.emitTerminalProgress(
            ActiveTransferProgress(
                id: "cancel-1",
                direction: .sending,
                counterpartName: "Peer",
                fileName: "archive.zip",
                progress: 0.2,
                throughput: "Canceled",
                etaDescription: "Canceled",
                status: .canceled
            )
        )
        await waitUntil { store.activeTransfer?.status == .canceled }
        XCTAssertEqual(store.feedback?.message, FeatureTransferLocalization.string(forKey: "feedback.transferCanceled"))
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertNil(store.activeTransfer)

        await runtime.emitProgress(
            ActiveTransferProgress(
                id: "fail-1",
                direction: .receiving,
                counterpartName: "Peer",
                fileName: "archive.zip",
                progress: 0.5,
                throughput: "50 KB",
                etaDescription: "Receiving",
                status: .running
            )
        )
        await waitUntil { store.activeTransfer?.id == "fail-1" }

        await runtime.emitTerminalProgress(
            ActiveTransferProgress(
                id: "fail-1",
                direction: .receiving,
                counterpartName: "Peer",
                fileName: "archive.zip",
                progress: 0.5,
                throughput: "Failed",
                etaDescription: "Failed",
                status: .failed
            )
        )
        await waitUntil { store.activeTransfer?.status == .failed }
        XCTAssertEqual(store.feedback?.message, "Transfer failed")
        XCTAssertTrue(store.historyEntries.isEmpty)
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertNil(store.activeTransfer)
    }

    func testPrepareUploadRefusalsSurfaceAsDistinctTerminalStatesWithOwnCopy() async {
        // backlog #22: 401/403/409/429 from /prepare-upload must not all read "Transfer failed".
        let expectations: [(ActiveTransferProgress.Status, String)] = [
            (.pinRequired, "feedback.transferPINRequired"),
            (.rejected, "feedback.transferDeclined"),
            (.blocked, "feedback.transferBlocked"),
            (.rateLimited, "feedback.transferRateLimited")
        ]

        var seenMessages: Set<String> = []
        for (status, messageKey) in expectations {
            let runtime = FakeTransferRuntime()
            let historyPersistence = InMemoryHistoryPersistence(entries: [])
            let store = TransferFeatureStore(
                runtime: runtime,
                settingsPersistence: InMemorySettingsPersistence(),
                historyPersistence: historyPersistence,
                loginItemManaging: FakeLoginItemManaging(),
                snapshot: .default(
                    deviceName: "LocalDrop Test Mac",
                    saveLocation: FileManager.default.temporaryDirectory
                )
            )
            await store.start()

            await runtime.emitTerminalProgress(
                ActiveTransferProgress(
                    id: "refusal-1",
                    direction: .sending,
                    counterpartName: "Peer",
                    fileName: "archive.zip",
                    progress: 0,
                    throughput: "",
                    etaDescription: "",
                    status: status
                )
            )
            await waitUntil { store.activeTransfer?.status == status }

            let expectedMessage = FeatureTransferLocalization.string(forKey: messageKey)
            XCTAssertEqual(store.feedback?.message, expectedMessage)
            XCTAssertTrue(status.isTerminal)
            XCTAssertTrue(status.isUnsuccessful)
            // A refusal delivers nothing, so it must never be recorded as a completed transfer.
            XCTAssertTrue(store.historyEntries.isEmpty)
            XCTAssertEqual(store.activeTransfer?.files.first?.status, .failed)
            seenMessages.insert(expectedMessage)
        }

        XCTAssertEqual(seenMessages.count, expectations.count, "each refusal needs its own copy")
        XCTAssertFalse(seenMessages.contains(FeatureTransferLocalization.string(forKey: "feedback.transferFailed")))
    }

    func testProgressResetClearsStaleActiveTransferState() async {
        let runtime = FakeTransferRuntime()
        let historyPersistence = InMemoryHistoryPersistence(entries: [])
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

        await store.start()
        await runtime.emitProgress(
            ActiveTransferProgress(
                id: "reset-1",
                direction: .sending,
                counterpartName: "Peer",
                fileName: "video.mp4",
                progress: 0.6,
                throughput: "60 KB",
                etaDescription: "Uploading",
                status: .running
            )
        )
        await waitUntil { store.activeTransfer?.id == "reset-1" }

        await runtime.emitProgressReset()
        await waitUntil { store.activeTransfer == nil }
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

    /// `encode(to:)` is a pure dump of stored state. It used to mint a fresh PIN whenever the
    /// stored one failed normalization, which made encoding side-effecting and non-idempotent.
    func testProtocolSettingsEncodeEmitsTheStoredIncomingPINVerbatim() throws {
        var settings = TransferProtocolSettings(
            deviceName: "LocalDrop Test Mac",
            tcpPort: 53_317,
            requirePIN: false,
            incomingPIN: "123456",
            allowDownloads: true,
            useHTTPS: false,
            saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
        )
        // Plain stored `var`, so an invalid value can land here from anywhere.
        settings.incomingPIN = "bad"

        let first = try JSONEncoder().encode(settings)
        let second = try JSONEncoder().encode(settings)

        XCTAssertEqual(first, second, "Encoding must not generate a new PIN as a side effect")
        let json = try XCTUnwrap(String(data: first, encoding: .utf8))
        XCTAssertTrue(json.contains("\"incomingPIN\":\"bad\""), "The stored value must pass through unchanged")
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

    func testGenerateIncomingPINUsesMemorable710PrefixWhenSelected() {
        let pin = TransferProtocolSettings.generateIncomingPIN(
            prefixRoll: 0,
            suffixValue: 42,
            fallbackValue: 999_999
        )

        XCTAssertEqual(pin, "710042")
    }

    func testGenerateIncomingPINFallsBackToSixDigitRandomValue() {
        let pin = TransferProtocolSettings.generateIncomingPIN(
            prefixRoll: 4,
            suffixValue: 42,
            fallbackValue: 321
        )

        XCTAssertEqual(pin, "000321")
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
        XCTAssertEqual(loaded.sendMode, .single)
        XCTAssertFalse(loaded.shareViaLinkAutoAccept)
    }

    func testTransferSettingsSnapshotDefaultsSendModeAndLinkAutoAccept() {
        let snapshot = TransferSettingsSnapshot.default(
            deviceName: "LocalDrop Test Mac",
            saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
        )

        XCTAssertEqual(snapshot.sendMode, .single)
        XCTAssertFalse(snapshot.shareViaLinkAutoAccept)
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

    /// `TransferProtocolSettings.incomingPIN` is a plain `var` with no `didSet`, so neither the
    /// initializer nor the decode normalizer is what keeps an empty PIN out of the server's
    /// `expectedPIN` — anything can assign `""` after the fact, and `testing(incomingPIN:)` does
    /// exactly that. The guard that actually holds is `resolvedIncomingPIN` on the way into
    /// `currentProtocolSettings`; this pins it.
    func testCurrentProtocolSettingsSubstitutesAPINForAnEmptyValueSetAfterInit() {
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

        store.requirePIN = true
        store.incomingPIN = ""

        // No `ensureIncomingPIN()` / `persistSettings()` repair in between — the read itself must
        // be safe, because this is the value `TransferFeatureContainer` hands to
        // `LocalSendRuntimeConfiguration.pin`.
        let resolved = store.currentProtocolSettings.incomingPIN
        XCTAssertFalse(resolved.isEmpty)
        XCTAssertEqual(resolved.count, TransferProtocolSettings.incomingPINLength)
        XCTAssertEqual(TransferProtocolSettings.normalizedIncomingPIN(from: resolved), resolved)
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

    func testUpdateDeviceNamePersistsTrimmedValueAndPushesRuntimeSettings() async {
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

        XCTAssertTrue(store.updateDeviceName("  Studio   Mac  "))

        XCTAssertEqual(store.deviceName, "Studio Mac")
        XCTAssertEqual(persistence.savedSnapshots.last?.protocolSettings.deviceName, "Studio Mac")

        let updated = await waitForRuntimeSettings(runtime)
        XCTAssertEqual(updated?.deviceName, "Studio Mac")
    }

    func testUpdateDeviceNameRejectsBlankValue() {
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

        XCTAssertFalse(store.updateDeviceName("   "))
        XCTAssertEqual(store.deviceName, "LocalDrop Test Mac")
        XCTAssertTrue(persistence.savedSnapshots.isEmpty)
    }

    func testRetroDeviceNameGeneratorProducesRetroNameAndThreeDigitNumber() {
        let name = RetroDeviceNameGenerator.generate()
        let parts = name.split(separator: " ")
        let suffix = String(parts.suffix(1).joined())
        let prefix = String(parts.dropLast().joined(separator: " "))

        XCTAssertEqual(suffix.count, 3)
        XCTAssertNotNil(Int(suffix))
        XCTAssertTrue([
            "Midnight Macintosh",
            "Signal Macintosh",
            "Blue Box Macintosh",
            "Wiretap Macintosh",
            "Carbon Terminal",
            "Phosphor Terminal",
            "Basement Terminal",
            "Amber Console",
            "Neon Mainframe",
            "Cipher System"
        ].contains(prefix))
    }

    func testRetroDeviceNameGeneratorSkipsExcludedDuplicate() {
        var generator = PredictableRandomNumberGenerator(values: [
            0, 0, 0, 0, 0,
            1, 51, 0, 1
        ])
        let excluded = "Midnight Macintosh 232"

        let name = RetroDeviceNameGenerator.generate(
            excluding: [excluded],
            using: &generator
        )

        XCTAssertNotEqual(name, excluded)
        XCTAssertEqual(name.split(separator: " ").last?.count, 3)
    }

    func testUseSystemDeviceNamePersistsResolvedName() async {
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

        let applied = store.useSystemDeviceName { "Studio Display" }

        XCTAssertEqual(applied, "Studio Display")
        XCTAssertEqual(store.deviceName, "Studio Display")
        XCTAssertEqual(persistence.savedSnapshots.last?.protocolSettings.deviceName, "Studio Display")

        let updated = await waitForRuntimeSettings(runtime)
        XCTAssertEqual(updated?.deviceName, "Studio Display")
    }

    func testGenerateRandomDeviceNameAliasPersistsGeneratedAlias() async {
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

        let applied = store.generateRandomDeviceNameAlias { "Copper Summit" }

        XCTAssertEqual(applied, "Copper Summit")
        XCTAssertEqual(store.deviceName, "Copper Summit")
        XCTAssertEqual(persistence.savedSnapshots.last?.protocolSettings.deviceName, "Copper Summit")

        let updated = await waitForRuntimeSettings(runtime)
        XCTAssertEqual(updated?.deviceName, "Copper Summit")
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
            snapshot: Self.promptingSnapshot()
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
                etaDescription: "Soon",
                totalItemCount: 3,
                currentItemIndex: 2
            )
        )
        await store.start()
        await waitUntil { store.activeTransfer != nil }

        XCTAssertEqual(store.menuSummary.statusSymbol, "paperplane.fill")
        XCTAssertEqual(store.menuSummary.activeTransferTitle, "Sending · 1 of 3 completed")

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
            snapshot: Self.promptingSnapshot()
        )

        await store.start()
        store.refreshNearbyPeers()
        await waitUntil { await runtime.refreshDiscoveryCallCount == 1 }

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

    /// A sender-initiated cancel arriving while the accept/decline prompt is up must dismiss the
    /// sheet, and must NOT be routed through `declineIncomingRequest()` — that would write a
    /// `.declined` history entry per file and claim the user declined something they never saw a
    /// decision on.
    func testNetworkWithdrawalDismissesThePromptWithoutADeclineHistoryEntry() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(entries: []),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )
        await store.start()

        let request = IncomingTransferRequest(
            id: "withdrawn-id",
            deviceName: "Peer Mac",
            subtitle: "Peer Mac \u{00B7} 1 item",
            sourceKind: .macbook,
            files: [IncomingTransferFile(id: "file", name: "notes.txt", size: "1 KB", symbol: "doc")]
        )
        await runtime.emitIncomingRequest(request)
        await waitUntil { store.incomingRequest?.id == "withdrawn-id" }
        XCTAssertEqual(store.activeSheet, .incoming)

        await runtime.emitWithdrawal("withdrawn-id")
        await waitUntil { store.incomingRequest == nil }

        XCTAssertNil(store.activeSheet)
        XCTAssertTrue(store.historyEntries.isEmpty)
        XCTAssertEqual(store.feedback?.tone, .neutral)
        // No decision is sent back: the bridge already resolved the awaiting `prepare`.
        let responses = await runtime.responses
        XCTAssertTrue(responses.isEmpty)
    }

    /// A withdrawal for a prompt that is no longer displayed must not clear a newer one.
    func testWithdrawalForAStalePromptIsIgnored() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(entries: []),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )
        await store.start()

        await runtime.emitIncomingRequest(
            IncomingTransferRequest(
                id: "current-id",
                deviceName: "Peer Mac",
                subtitle: "Peer Mac",
                sourceKind: .macbook,
                files: []
            )
        )
        await waitUntil { store.incomingRequest?.id == "current-id" }

        store.withdrawIncomingRequest(id: "some-older-id")
        XCTAssertEqual(store.incomingRequest?.id, "current-id")
    }

    func testDeclineAndSubsetAcceptSendExpectedResponses() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
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

    /// Item #15: the desired-name map has to survive the store -> runtime hop, and entries for files
    /// that are not being accepted must not ride along.
    func testSubsetAcceptCarriesDesiredNamesForAcceptedFilesOnly() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
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

        store.acceptIncomingRequest(
            fileIDs: ["a"],
            desiredNames: ["a": "renamed.txt", "b": "not-accepted.txt"]
        )

        let expected: FeatureTransfer.IncomingTransferDecision = .acceptSubset(
            requestID: "request-id",
            fileIDs: ["a"],
            desiredNames: ["a": "renamed.txt"]
        )
        await waitUntil { await runtime.responses == [expected] }
    }

    /// Omitting the map keeps the payload byte-identical to what shipped before the feature.
    func testSubsetAcceptWithoutDesiredNamesIsUnchanged() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )
        let request = IncomingTransferRequest(
            id: "request-id",
            deviceName: "Peer Mac",
            subtitle: "Peer Mac · 1 item",
            sourceKind: .macbook,
            files: [IncomingTransferFile(id: "a", name: "a.txt", size: "1 KB", symbol: "doc")]
        )

        await runtime.emitIncomingRequest(request)
        await store.start()
        await waitUntil { store.incomingRequest?.id == "request-id" }

        store.acceptIncomingRequest(fileIDs: ["a"])
        let expected: FeatureTransfer.IncomingTransferDecision = .acceptSubset(requestID: "request-id", fileIDs: ["a"])
        await waitUntil { await runtime.responses == [expected] }
        XCTAssertEqual(expected, .acceptSubset(requestID: "request-id", fileIDs: ["a"], desiredNames: [:]))
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

    func testSecurityLocalizationUsesHTTPAndHTTPSTerminology() {
        let useHTTPS = FeatureTransferLocalization.string(forKey: "settings.useHTTPS")
        let useHTTPSHelp = FeatureTransferLocalization.string(forKey: "settings.useHTTPSHelp")
        let disabledMessage = FeatureTransferLocalization.string(forKey: SecurityDialog.httpsDisabled.messageKey)

        XCTAssertEqual(useHTTPS, "Use HTTPS for transfers")
        XCTAssertTrue(useHTTPSHelp.contains("HTTPS"))
        XCTAssertTrue(useHTTPSHelp.contains("plain HTTP"))
        XCTAssertTrue(disabledMessage.contains("plain HTTP"))
        XCTAssertFalse(disabledMessage.localizedCaseInsensitiveContains("end-to-end"))
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
        store.shareViaLinkAutoAccept = true
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

    // MARK: - Sender-side PIN entry + retry (backlog #11)

    func testPINRequiredEmitsNoTerminalEventAndKeepsStagedItemsForTheRetry() async throws {
        let adapter = try makeLiveRuntimeAdapter(settings: makePINTestSettings(), recorder: RuntimeComponentRecorder())
        let staged = Self.makePINTestStagedItems()
        await adapter.stage(staged)
        let events = await ProgressEventCollector.attached(to: adapter)
        let script = PrepareUploadScript(results: [
            .failure(LocalSendClientError.pinRequired),
            .success(PrepareUploadResponse(sessionId: "session-retry", files: ["a": "token-a"]))
        ])
        let prompts = PINPromptRecorder(responses: ["246810"])

        let outcome = try await adapter.runPrepareUploadPhase(
            peer: Self.makePINTestPeer(),
            context: AppLogContext(attributes: []),
            initialPIN: nil,
            requestPIN: { await prompts.respond(to: $0) },
            attempt: { try await script.next(pin: $0) }
        )

        guard case .prepared(let response) = outcome else {
            return XCTFail("Expected the retry to prepare an upload, got \(outcome)")
        }
        XCTAssertEqual(response?.sessionId, "session-retry")
        let observedPINs = await script.observedPINs
        XCTAssertEqual(observedPINs, [nil, "246810"], "The retry must re-issue prepare-upload with the submitted PIN")
        let heldItemIDs = await adapter.stagedItemsSnapshot().map(\.id)
        XCTAssertEqual(
            heldItemIDs,
            staged.map(\.id),
            "A prepare-upload throw must leave the staged batch intact — the retry re-sends it"
        )
        let emitted = await events.drain()
        XCTAssertEqual(
            emitted,
            [],
            "A 401 is a prompt, not a terminal state: emitting one would strand a failed card under a fresh transfer ID"
        )
    }

    func testPINRetryStaysOneLogicalTransferWithNoOrphanFailedCard() async throws {
        // The event sequence a PIN retry actually produces: nothing at all for the 401, then the
        // ordinary start/complete pair keyed on the one accepted session ID.
        let reducer = TransferProgressReducer()
        let started = Self.makePINTestRawEvent(kind: .transferStarted, sessionID: "session-retry", sequence: 1)
        let completed = Self.makePINTestRawEvent(kind: .transferCompleted, sessionID: "session-retry", sequence: 2)

        let first = await reducer.reduce(started)
        let second = await reducer.reduce(completed)

        XCTAssertEqual(first.id, second.id, "The retry must reduce into one card, not two")
        XCTAssertEqual(first.attemptID, second.attemptID)
        XCTAssertEqual(first.startedAtMonotonic, second.startedAtMonotonic, "Continuity is keyed on the transfer ID")
        XCTAssertEqual(second.status, .completed)
    }

    func testFirstPINPromptIsNotAnErrorAndTheSecondReportsAnIncorrectPIN() async throws {
        let adapter = try makeLiveRuntimeAdapter(settings: makePINTestSettings(), recorder: RuntimeComponentRecorder())
        await adapter.stage(Self.makePINTestStagedItems())
        let script = PrepareUploadScript(results: [
            .failure(LocalSendClientError.pinRequired),
            .failure(LocalSendClientError.pinRequired),
            .success(PrepareUploadResponse(sessionId: "session-second-try", files: ["a": "token-a"]))
        ])
        let prompts = PINPromptRecorder(responses: ["111111", "246810"])

        _ = try await adapter.runPrepareUploadPhase(
            peer: Self.makePINTestPeer(),
            context: AppLogContext(attributes: []),
            initialPIN: nil,
            requestPIN: { await prompts.respond(to: $0) },
            attempt: { try await script.next(pin: $0) }
        )

        // The wire answers 401 for both "PIN required" and "wrong PIN"; only this client-side flag
        // separates the plain prompt from the error state.
        let firstAttemptFlags = await prompts.observedFirstAttemptFlags
        XCTAssertEqual(firstAttemptFlags, [true, false])
    }

    func testStorePINPromptCarriesFirstAttemptStateThroughToTheSheet() async throws {
        let runtime = FakeTransferRuntime()
        await runtime.scriptPINPrompts([true, false])
        let store = makePINTestStore(runtime: runtime)
        store.stageDroppedItems([URL(fileURLWithPath: "/tmp/LocalDropTests/pin.txt")])

        store.send(to: "peer-pin")

        await waitUntil { store.pinPrompt != nil }
        XCTAssertEqual(store.activeSheet, .pinEntry)
        let firstPrompt = try XCTUnwrap(store.pinPrompt)
        XCTAssertTrue(firstPrompt.isFirstAttempt, "The first 401 must render with no error styling")
        _ = SendPINEntrySheet(prompt: firstPrompt, onSubmit: { _ in }, onCancel: {}).body

        store.submitSendPIN("111111")

        await waitUntil { store.pinPrompt?.isFirstAttempt == false }
        let secondPrompt = try XCTUnwrap(store.pinPrompt)
        XCTAssertFalse(secondPrompt.isFirstAttempt, "A refused PIN must escalate the sheet to its error state")
        _ = SendPINEntrySheet(prompt: secondPrompt, onSubmit: { _ in }, onCancel: {}).body

        store.submitSendPIN("246810")
        await waitUntil { await runtime.submittedPINs.count == 2 }
        let submitted = await runtime.submittedPINs
        XCTAssertEqual(submitted, ["111111", "246810"])
        XCTAssertNil(store.pinPrompt)
    }

    func testCancelingThePINPromptDiscardsTheSendAndClearsStagedItems() async throws {
        let adapter = try makeLiveRuntimeAdapter(settings: makePINTestSettings(), recorder: RuntimeComponentRecorder())
        await adapter.stage(Self.makePINTestStagedItems())
        let script = PrepareUploadScript(results: [.failure(LocalSendClientError.pinRequired)])
        let prompts = PINPromptRecorder(responses: [nil])

        let outcome = try await adapter.runPrepareUploadPhase(
            peer: Self.makePINTestPeer(),
            context: AppLogContext(attributes: []),
            initialPIN: nil,
            requestPIN: { await prompts.respond(to: $0) },
            attempt: { try await script.next(pin: $0) }
        )

        guard case .canceledByPINPrompt = outcome else {
            return XCTFail("Dismissing the prompt must discard the send, got \(outcome)")
        }
        let heldAfterCancel = await adapter.stagedItemsSnapshot()
        XCTAssertEqual(heldAfterCancel, [], "The held batch is dropped when the prompt is dismissed")
        let attemptedPINs = await script.observedPINs
        XCTAssertEqual(attemptedPINs, [nil], "No further prepare-upload may be issued after a cancel")
    }

    func testStoreCancelingPINPromptClearsStagedItemsAndReportsNoFailure() async throws {
        let runtime = FakeTransferRuntime()
        await runtime.scriptPINPrompts([true])
        let store = makePINTestStore(runtime: runtime)
        store.stageDroppedItems([URL(fileURLWithPath: "/tmp/LocalDropTests/pin.txt")])

        store.send(to: "peer-pin")
        await waitUntil { store.pinPrompt != nil }
        store.cancelSendPIN()

        await waitUntil { await runtime.pinPromptWasCanceled }
        XCTAssertNil(store.pinPrompt)
        XCTAssertNil(store.activeSheet)
        XCTAssertEqual(store.stagedItems, [])
        let submittedAfterCancel = await runtime.submittedPINs
        XCTAssertEqual(submittedAfterCancel, [])
        XCTAssertNil(store.lastErrorMessage, "A dismissed prompt is not a failure")
    }

    /// `activeSheet` prioritises `.incoming`, so an inbound request arriving while the sender-side
    /// PIN sheet is up preempts it on screen. Dismissing that incoming sheet must resolve the
    /// incoming request and *nothing else* — resolving every non-nil state would also cancel the
    /// live PIN prompt and silently discard the user's whole staged outbound batch.
    func testDismissingTheIncomingSheetLeavesALiveOutboundPINPromptAndItsStagedBatchIntact() async throws {
        let runtime = FakeTransferRuntime()
        await runtime.scriptPINPrompts([true])
        let store = makePINTestStore(runtime: runtime)
        store.stageDroppedItems([URL(fileURLWithPath: "/tmp/LocalDropTests/pin.txt")])
        await store.start()

        store.send(to: "peer-pin")
        await waitUntil { store.pinPrompt != nil }
        let stagedBeforeDismissal = store.stagedItems
        XCTAssertFalse(stagedBeforeDismissal.isEmpty)

        await runtime.emitIncomingRequest(
            IncomingTransferRequest(
                id: "incoming-during-pin",
                deviceName: "Peer",
                subtitle: "Peer · 1 item",
                sourceKind: .phone,
                files: []
            )
        )
        await waitUntil { store.incomingRequest != nil }
        XCTAssertEqual(store.activeSheet, .incoming, "The incoming request preempts the PIN sheet")

        store.dismissActiveSheet()

        XCTAssertNil(store.incomingRequest, "The dismissed sheet is the one that gets resolved")
        XCTAssertNotNil(store.pinPrompt, "The outbound PIN prompt was never on screen — it must stay live")
        XCTAssertEqual(store.stagedItems, stagedBeforeDismissal, "The outbound batch must survive untouched")
        let canceled = await runtime.pinPromptWasCanceled
        XCTAssertFalse(canceled, "The PIN continuation must not be resolved by an unrelated dismissal")
        let responses = await runtime.responses
        XCTAssertEqual(responses.count, 1, "Exactly one decision — the decline — leaves the store")
    }

    /// Dismissing the PIN prompt on one send must drop only that send's own items. A blanket
    /// `stagedItems.removeAll()` on the shared actor field would empty an overlapping send's batch,
    /// which then uploads nothing yet still reports success.
    func testDismissingOnePINPromptLeavesAnOverlappingSendsStagedBatchIntact() async throws {
        let adapter = try makeLiveRuntimeAdapter(settings: makePINTestSettings(), recorder: RuntimeComponentRecorder())
        let firstBatch = Self.makePINTestStagedItems()
        let secondBatch = Self.makeSecondSendStagedItems()
        // Both sends' items are live on the one shared actor field, exactly as they are mid-overlap.
        await adapter.stage(firstBatch + secondBatch)
        let script = PrepareUploadScript(results: [.failure(LocalSendClientError.pinRequired)])
        let prompts = PINPromptRecorder(responses: [nil])

        let outcome = try await adapter.runPrepareUploadPhase(
            peer: Self.makePINTestPeer(),
            context: AppLogContext(attributes: []),
            batch: firstBatch,
            initialPIN: nil,
            requestPIN: { await prompts.respond(to: $0) },
            attempt: { try await script.next(pin: $0) }
        )

        guard case .canceledByPINPrompt = outcome else {
            return XCTFail("Dismissing the prompt must discard the first send, got \(outcome)")
        }
        let surviving = await adapter.stagedItemsSnapshot().map(\.id)
        XCTAssertEqual(
            surviving,
            secondBatch.map(\.id),
            "The second send's batch must survive so it still has files to upload"
        )
    }

    /// The terminal prepare-upload event must describe the caller's own batch. Reading the shared
    /// staged field here would attribute one send's failure to another send's files.
    func testPrepareUploadFailureEventDescribesTheCallersOwnBatchNotTheSharedStagedField() async throws {
        let adapter = try makeLiveRuntimeAdapter(settings: makePINTestSettings(), recorder: RuntimeComponentRecorder())
        let firstBatch = Self.makePINTestStagedItems()
        await adapter.stage(firstBatch + Self.makeSecondSendStagedItems())
        let events = await ProgressEventCollector.attached(to: adapter)
        let script = PrepareUploadScript(results: [.failure(LocalSendClientError.rejected)])

        do {
            _ = try await adapter.runPrepareUploadPhase(
                peer: Self.makePINTestPeer(),
                context: AppLogContext(attributes: []),
                batch: firstBatch,
                initialPIN: nil,
                requestPIN: nil,
                attempt: { try await script.next(pin: $0) }
            )
            XCTFail("A rejection must propagate")
        } catch {}

        let emitted = await events.drain()
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(
            emitted.first?.files.map(\.fileID),
            firstBatch.map(\.id),
            "The failure card must list this send's files only"
        )
        XCTAssertEqual(
            emitted.first?.totalBytesKnown,
            firstBatch.compactMap(\.byteCount).reduce(0, +),
            "The declared total must come from this send's batch"
        )
    }

    // MARK: - Receiver-typed rename validation

    /// A typed name containing a separator or a leading dot makes the Kit's traversal guard drop
    /// the file from the batch entirely — accepted, then never arriving, with no error anywhere.
    /// The sheet has to refuse it before Accept, not after.
    func testTypedRenameRejectsTraversalShapedNames() {
        for rejected in ["..", "../escape.txt", "a/b.txt", "a\\b.txt", ".hidden", "/etc/passwd"] {
            XCTAssertFalse(
                IncomingRequestSheet.isAcceptableDesiredName(rejected),
                "\(rejected) resolves to nothing or escapes the save location"
            )
        }
    }

    func testTypedRenameAcceptsOrdinaryNamesAndTheUnchangedCase() {
        // A blank field means "keep the sender's name" and must never block Accept.
        for accepted in ["", "   ", "report.pdf", "holiday photo.heic", "a..b.txt", "notes.tar.gz"] {
            XCTAssertTrue(
                IncomingRequestSheet.isAcceptableDesiredName(accepted),
                "\(accepted) is a perfectly ordinary file name"
            )
        }
    }

    // MARK: - Bootstrap failure copy

    /// A keychain read failure leaves the app with no TLS identity, so discovery and every transfer
    /// are dead. What surfaces must say so, not "OSStatus -25293".
    @MainActor
    func testKeychainBootstrapFailureSurfacesActionableLocalizedCopy() {
        let message = TransferFeatureContainer.bootstrapFailureMessage(
            for: KeychainCertificateStoreError.keychainOperationFailed(operation: "read", status: -25_293)
        )
        XCTAssertEqual(message, FeatureTransferLocalization.string(forKey: "error.deviceIdentityUnavailable"))
        XCTAssertFalse(message.contains("OSStatus"), "The raw diagnostic belongs in the logs, not on screen")
        XCTAssertFalse(message.contains("KeychainCertificateStore"), "No type names in user-facing copy")

        for keychainError: KeychainCertificateStoreError in [
            .corruptKeychainPayload,
            .corruptLegacyIdentityFile,
            .migrationVerificationFailed
        ] {
            XCTAssertEqual(
                TransferFeatureContainer.bootstrapFailureMessage(for: keychainError),
                message,
                "Every keychain identity failure is the same dead-runtime situation for the user"
            )
        }
    }

    @MainActor
    func testNonKeychainBootstrapFailureKeepsItsOwnDescription() {
        let message = TransferFeatureContainer.bootstrapFailureMessage(
            for: TransferFeatureError.peerNotFound("peer-1")
        )
        XCTAssertEqual(message, TransferFeatureError.peerNotFound("peer-1").localizedDescription)
    }

    func testTooManyRequestsTerminatesWithoutEverPromptingForAPIN() async throws {
        // The receiver locks out after three wrong non-empty PINs; re-prompting into that lockout
        // would burn the user's remaining attempts.
        let adapter = try makeLiveRuntimeAdapter(settings: makePINTestSettings(), recorder: RuntimeComponentRecorder())
        await adapter.stage(Self.makePINTestStagedItems())
        let events = await ProgressEventCollector.attached(to: adapter)
        let script = PrepareUploadScript(results: [.failure(LocalSendClientError.tooManyRequests)])
        let prompts = PINPromptRecorder(responses: ["246810"])

        do {
            _ = try await adapter.runPrepareUploadPhase(
                peer: Self.makePINTestPeer(),
                context: AppLogContext(attributes: []),
                initialPIN: nil,
                requestPIN: { await prompts.respond(to: $0) },
                attempt: { try await script.next(pin: $0) }
            )
            XCTFail("429 must terminate the send")
        } catch {
            XCTAssertEqual(error as? LocalSendClientError, .tooManyRequests)
        }

        let rateLimitedPrompts = await prompts.observedFirstAttemptFlags
        XCTAssertEqual(rateLimitedPrompts, [], "429 must not re-prompt")
        let rateLimitedAttempts = await script.observedPINs
        XCTAssertEqual(rateLimitedAttempts, [nil], "429 must not retry")
        let rateLimitedKinds = await events.drain().map(\.kind)
        XCTAssertEqual(rateLimitedKinds, [.transferRateLimited])
    }

    func testRejectedAndBlockedOutcomesNeverPromptForAPIN() async throws {
        let expectations: [(LocalSendClientError, TransferProgressRawEvent.Kind)] = [
            (.rejected, .transferRejected),
            (.blockedByAnotherSession, .transferBlocked)
        ]

        for (clientError, expectedKind) in expectations {
            let adapter = try makeLiveRuntimeAdapter(settings: makePINTestSettings(), recorder: RuntimeComponentRecorder())
            await adapter.stage(Self.makePINTestStagedItems())
            let events = await ProgressEventCollector.attached(to: adapter)
            let script = PrepareUploadScript(results: [.failure(clientError)])
            let prompts = PINPromptRecorder(responses: ["246810"])

            do {
                _ = try await adapter.runPrepareUploadPhase(
                    peer: Self.makePINTestPeer(),
                    context: AppLogContext(attributes: []),
                    initialPIN: nil,
                    requestPIN: { await prompts.respond(to: $0) },
                    attempt: { try await script.next(pin: $0) }
                )
                XCTFail("\(clientError) must terminate the send")
            } catch {
                XCTAssertEqual(error as? LocalSendClientError, clientError)
            }

            let raisedPrompts = await prompts.observedFirstAttemptFlags
            XCTAssertEqual(raisedPrompts, [], "\(clientError) is not a PIN problem")
            let emittedKinds = await events.drain().map(\.kind)
            XCTAssertEqual(emittedKinds, [expectedKind])
        }
    }

    func testPINRequiredStaysTerminalWhenNoPromptIsWiredUp() async throws {
        // The pre-#11 behaviour, still reachable for any caller without a prompt.
        let adapter = try makeLiveRuntimeAdapter(settings: makePINTestSettings(), recorder: RuntimeComponentRecorder())
        let staged = Self.makePINTestStagedItems()
        await adapter.stage(staged)
        let events = await ProgressEventCollector.attached(to: adapter)
        let script = PrepareUploadScript(results: [.failure(LocalSendClientError.pinRequired)])

        do {
            _ = try await adapter.runPrepareUploadPhase(
                peer: Self.makePINTestPeer(),
                context: AppLogContext(attributes: []),
                initialPIN: nil,
                requestPIN: nil,
                attempt: { try await script.next(pin: $0) }
            )
            XCTFail("Without a prompt, 401 must stay terminal")
        } catch {
            XCTAssertEqual(error as? LocalSendClientError, .pinRequired)
        }

        let terminalKinds = await events.drain().map(\.kind)
        XCTAssertEqual(terminalKinds, [.transferPINRequired])
        let survivingItemIDs = await adapter.stagedItemsSnapshot().map(\.id)
        XCTAssertEqual(
            survivingItemIDs,
            staged.map(\.id),
            "stagedItems.removeAll() must remain confined to the success path"
        )
    }

    func testSubmittedPINNeverReachesALogRecordOrAnErrorSummary() async throws {
        let submittedPIN = "246810"
        let sink = RecordingLogSink()
        let logger = AppLogger(
            configuration: AppLoggerConfiguration(minimumLevel: .debug, redactSensitiveValues: true),
            resource: [.string("service.name", "LocalDrop")],
            sinks: [sink]
        )
        let adapter = try makeLiveRuntimeAdapter(
            settings: makePINTestSettings(),
            recorder: RuntimeComponentRecorder(),
            logger: logger
        )
        await adapter.stage(Self.makePINTestStagedItems())
        let events = await ProgressEventCollector.attached(to: adapter)
        // A transport error that wraps the request URL — the one path by which a PIN could reach
        // the logs and the on-screen transfer card.
        let leakyError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Could not connect to https://192.168.1.5:53317/api/localsend/v2/prepare-upload?pin=\(submittedPIN)"
            ]
        )
        let script = PrepareUploadScript(results: [.failure(LocalSendClientError.pinRequired), .failure(leakyError)])
        let prompts = PINPromptRecorder(responses: [submittedPIN])

        do {
            _ = try await adapter.runPrepareUploadPhase(
                peer: Self.makePINTestPeer(),
                context: AppLogContext(attributes: []),
                initialPIN: nil,
                requestPIN: { await prompts.respond(to: $0) },
                attempt: { try await script.next(pin: $0) }
            )
            XCTFail("The transport failure must propagate")
        } catch {}

        let wirePINs = await script.observedPINs
        XCTAssertEqual(wirePINs, [nil, submittedPIN], "The PIN did reach the wire — the leak is real if unredacted")

        await logger.flush()
        let capturedRecords = await sink.records()
        let renderedRecords = try capturedRecords.map { record in
            String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        }
        XCTAssertFalse(renderedRecords.isEmpty, "Expected the failure to be logged at all")
        for rendered in renderedRecords {
            XCTAssertFalse(rendered.contains(submittedPIN), "A submitted PIN must never reach a log record: \(rendered)")
        }

        let summaries = await events.drain().flatMap(\.files).compactMap(\.errorSummary)
        XCTAssertFalse(summaries.isEmpty, "Expected a per-file failure summary")
        for summary in summaries {
            XCTAssertFalse(summary.contains(submittedPIN), "A submitted PIN must never reach errorSummary: \(summary)")
            XCTAssertTrue(summary.contains(SensitiveTextRedaction.placeholder))
        }
    }

    func testSensitiveTextRedactionLeavesUnrelatedTextAlone() {
        XCTAssertEqual(SensitiveTextRedaction.redactingPINs(in: "no secrets here"), "no secrets here")
        XCTAssertEqual(
            SensitiveTextRedaction.redactingPINs(in: "https://host/x?pin=123456&y=1"),
            "https://host/x?pin=<redacted>&y=1"
        )
        XCTAssertEqual(
            SensitiveTextRedaction.redactingPINs(in: "PIN=987654"),
            "pin=<redacted>"
        )
        // "pin" as an ordinary word must survive.
        XCTAssertEqual(SensitiveTextRedaction.redactingPINs(in: "spinning pinwheel"), "spinning pinwheel")
    }

    // MARK: - Receiver-initiated cancel (backlog #23)

    func testUserCancelOfAnInboundTransferTearsDownTheSessionEmitsCanceledAndNotifiesTheSenderOnce() async throws {
        let fixture = try await makeLiveReceiveFixture()

        try await fixture.adapter.cancelActiveTransfer(fixture.sessionID)

        // 1. the local session is actually cancelled — before this fix the receive branch was a no-op
        let receiveStatus = await fixture.node.runtimeSnapshot().receiveSession?.status
        XCTAssertEqual(receiveStatus, .canceled)

        // 2. the UI is told
        let canceledEvent = await waitForCanceledEvent(fixture.events, transferID: fixture.sessionID)
        XCTAssertNotNil(canceledEvent, "A user-initiated receive cancel must emit .transferCanceled")
        XCTAssertEqual(canceledEvent?.direction, .receiving)

        // 3. the sender is told, exactly once, addressed from the register info it announced
        let sent = await fixture.notifications.sent()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.sessionID, fixture.sessionID)
        XCTAssertEqual(sent.first?.peer.port, Self.receiveCancelTestSenderPort)
        XCTAssertEqual(sent.first?.peer.protocolType, .http)
        XCTAssertEqual(sent.first?.fingerprint, Self.receiveCancelTestSenderFingerprint)

        await fixture.tearDown()
    }

    func testPeerInitiatedCancelSendsNoOutboundCancelBack() async throws {
        let fixture = try await makeLiveReceiveFixture()

        // The peer cancels US. This lands as an observed `.canceled` transition — the same
        // observation the UI is driven from — and must NOT bounce a /cancel back at the peer.
        try await fixture.senderClient.cancel(sessionId: fixture.sessionID)

        let canceledEvent = await waitForCanceledEvent(fixture.events, transferID: fixture.sessionID)
        XCTAssertNotNil(canceledEvent, "A peer-initiated cancel still has to reach the UI")
        let sent = await fixture.notifications.sent()
        XCTAssertEqual(sent, [], "A peer-initiated cancel must never trigger an outbound /cancel")

        await fixture.tearDown()
    }

    func testFailingCancelNotificationStillCancelsLocallyAndUpdatesTheUI() async throws {
        let fixture = try await makeLiveReceiveFixture(notifierError: URLError(.timedOut))

        try await fixture.adapter.cancelActiveTransfer(fixture.sessionID)

        let receiveStatus = await fixture.node.runtimeSnapshot().receiveSession?.status
        XCTAssertEqual(receiveStatus, .canceled, "An unreachable sender must not block the local teardown")
        let canceledEvent = await waitForCanceledEvent(fixture.events, transferID: fixture.sessionID)
        XCTAssertNotNil(canceledEvent)
        let sent = await fixture.notifications.sent()
        XCTAssertEqual(sent.count, 1, "The POST is attempted once and its failure swallowed")

        await fixture.tearDown()
    }

    func testCancelingTheSameInboundTransferTwiceSendsOnlyOneOutboundCancel() async throws {
        let fixture = try await makeLiveReceiveFixture()

        // Concurrently first: `cancelActiveTransfer` suspends between reading the snapshot and
        // tearing the session down, so the actor is reentrant across exactly the window the
        // idempotence guard exists to close.
        async let first: Void = fixture.adapter.cancelActiveTransfer(fixture.sessionID)
        async let second: Void = fixture.adapter.cancelActiveTransfer(fixture.sessionID)
        _ = try await (first, second)
        // …and then again, long after the session reached its terminal state.
        try await fixture.adapter.cancelActiveTransfer(fixture.sessionID)

        let sent = await fixture.notifications.sent()
        XCTAssertEqual(sent.count, 1)

        await fixture.tearDown()
    }

    func testSendDirectionCancelIsUnaffectedByTheReceiveCancelPath() async throws {
        // Regression guard: the send branch still cancels through the session's own client and
        // never reaches the receive-side notifier.
        let notifications = ReceiveCancelNotificationRecorder()
        let runtime = FakeTransferRuntime()
        let store = makePINTestStore(runtime: runtime)
        store.activeTransfer = Self.makeActiveSendProgress(id: "send-session")

        store.cancelActiveTransfer()
        for _ in 0..<50 where await runtime.canceledTransferIDs.isEmpty {
            await Task.yield()
        }

        let canceled = await runtime.canceledTransferIDs
        XCTAssertEqual(canceled, ["send-session"])
        let sent = await notifications.sent()
        XCTAssertEqual(sent, [])
    }

    // MARK: - Client-side v1 route targeting (backlog #59)

    /// A peer that omits `version` on the wire is a v1-era peer
    /// (`common/lib/constants.dart:18`, `register_dto.dart:38`) — it must NOT inherit our own
    /// `protocolVersion`, or the legacy peers this change exists to reach get mislabeled as v2 and
    /// keep receiving v2 paths they do not serve.
    func testNearbyPeerItemResolvesAMissingAnnouncedVersionToTheV1Fallback() throws {
        // Decoded from the wire rather than built in memory, because the absent-`version` rule
        // lives in `RegisterInfo`'s decoder and this test is about it surviving the trip.
        let peer = try Self.makeDiscoveredPeerItem(
            json: #"{"alias":"Legacy","fingerprint":"OLD","port":53317,"protocol":"http"}"#
        )

        XCTAssertEqual(peer.protocolVersion, LocalSendKit.fallbackProtocolVersion)
        XCTAssertEqual(peer.apiVersion, .v1)
    }

    func testNearbyPeerItemResolvesAnAnnouncedV2VersionToV2() throws {
        let peer = try Self.makeDiscoveredPeerItem(
            json: #"{"alias":"Modern","version":"2.1","fingerprint":"NEW","port":53317,"protocol":"https"}"#
        )

        XCTAssertEqual(peer.protocolVersion, "2.1")
        XCTAssertEqual(peer.apiVersion, .v2)
    }

    private static func makeDiscoveredPeerItem(json: String) throws -> NearbyPeerItem {
        let info = try JSONDecoder().decode(RegisterInfo.self, from: Data(json.utf8))
        return NearbyPeerItem(
            peer: DiscoveredPeer(host: "192.168.1.44", info: info, shouldReplyViaRegister: false)
        )
    }

    /// The memberwise initializer's new parameter has to be defaulted — every existing call site
    /// omits it — and the default is the v1 fallback, not our own version.
    func testNearbyPeerItemMemberwiseInitDefaultsToTheV1Fallback() {
        XCTAssertEqual(Self.makePINTestPeer().protocolVersion, LocalSendKit.fallbackProtocolVersion)
    }

    /// The remote `/cancel` is a courtesy, not a precondition. It used to be the FIRST statement of
    /// the send branch, so a non-2xx threw before any local teardown: statuses stayed
    /// `.transferring`, no `.transferCanceled` was emitted, and the session entry leaked — the
    /// cancel button did nothing.
    ///
    /// v1 routing makes that reachable by design: the reference 403s a `/v1/cancel` whose session's
    /// sender announced a non-`1.0` version (`receive_controller.dart:646-653`), and our
    /// prepare-upload always announces `2.1`.
    func testSendCancelCompletesLocalTeardownWhenTheRemoteCancelFails() async throws {
        let recorder = RuntimeComponentRecorder()
        var settings = makePINTestSettings()
        settings.useHTTPS = false
        let adapter = try makeLiveRuntimeAdapter(settings: settings, recorder: recorder)
        let events = await ProgressEventCollector.attached(to: adapter)
        defer { Task { await adapter.stop() } }

        let sessionID = "send-session-v1"
        await adapter.installSendSessionForTesting(
            id: sessionID,
            peer: Self.makePINTestPeer(),
            // Every request this client makes fails, standing in for the 403 a v1-routed cancel
            // draws from a receiver whose session recorded a v2 sender.
            client: LocalSendClient(transport: AlwaysFailingTransport()),
            fileIDs: ["file-1"]
        )

        try await adapter.cancelActiveTransfer(sessionID)

        let canceledEvent = await waitForCanceledEvent(events, transferID: sessionID)
        XCTAssertNotNil(canceledEvent, "A failed remote /cancel must not swallow the terminal event")
        XCTAssertEqual(canceledEvent?.direction, .sending)
        XCTAssertEqual(canceledEvent?.files.first?.state, .canceled)
        let leaked = await adapter.hasSendSessionForTesting(id: sessionID)
        XCTAssertFalse(leaked, "The session entry must drain even when the remote /cancel fails")
    }

    private static let receiveCancelTestSenderPort = 53318
    private static let receiveCancelTestSenderFingerprint = "receive-cancel-test-sender-fingerprint"

    /// A real receive session: a live adapter over loopback HTTP, a real `/prepare-upload` from a
    /// real `LocalSendClient`, auto-accepted through the adapter's own inbound-request stream.
    /// Nothing here is stubbed except the outbound cancel POST itself.
    private struct LiveReceiveFixture {
        let adapter: LocalSendRuntimeAdapter
        let node: LocalSendNode
        let sessionID: String
        let senderClient: LocalSendClient
        let events: ProgressEventCollector
        let notifications: ReceiveCancelNotificationRecorder
        let acceptTask: Task<Void, Never>

        /// Deterministic: the next fixture must not start while this one's runtime is still
        /// shutting down, so both the accept loop and the adapter stop are awaited.
        func tearDown() async {
            acceptTask.cancel()
            _ = await acceptTask.value
            await adapter.stop()
        }
    }

    private func makeLiveReceiveFixture(
        notifierError: Error? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> LiveReceiveFixture {
        let recorder = RuntimeComponentRecorder()
        let notifications = ReceiveCancelNotificationRecorder(error: notifierError)
        var settings = makePINTestSettings()
        // Plain HTTP so the loopback sender needs no certificate fingerprint to talk to us.
        settings.useHTTPS = false
        let adapter = try makeLiveRuntimeAdapter(
            settings: settings,
            recorder: recorder,
            receiveCancelNotifier: { sessionID, peer, fingerprint in
                try await notifications.record(sessionID: sessionID, peer: peer, fingerprint: fingerprint)
            }
        )
        let events = await ProgressEventCollector.attached(to: adapter)
        try await adapter.start()

        let recordedNode = await recorder.lastNode()
        let node = try XCTUnwrap(recordedNode, file: file, line: line)
        let endpoint = try await waitForRunningEndpoint(node: node, file: file, line: line)

        let acceptTask = Task {
            let events = await adapter.inboundRequestEvents()
            for await event in events {
                // Only `.request`. Accepting on `.withdrawal` would call `.acceptAll` with the ID of
                // a request the sender already canceled, silently corrupting these fixtures.
                guard case .request(let request) = event else { continue }
                try? await adapter.respondToIncomingRequest(.acceptAll(requestID: request.id))
            }
        }

        let senderClient = LocalSendClient(
            peer: RemotePeer(host: endpoint.host, port: endpoint.port, protocolType: endpoint.protocolType),
            expectedFingerprint: ""
        )
        let senderInfo = RegisterInfo(
            alias: "LocalDrop Test Sender",
            deviceModel: "LocalDrop Test Runtime",
            deviceType: .desktop,
            fingerprint: Self.receiveCancelTestSenderFingerprint,
            port: Self.receiveCancelTestSenderPort,
            protocolType: .http,
            download: false
        )
        let prepared = try await senderClient.prepareUpload(
            PrepareUploadRequest(
                info: senderInfo,
                files: [
                    "file-1": FileDto(id: "file-1", fileName: "cancel-me.txt", size: 4096, fileType: "text/plain")
                ]
            )
        )
        let response = try XCTUnwrap(prepared, "The fixture needs an accepted session", file: file, line: line)

        return LiveReceiveFixture(
            adapter: adapter,
            node: node,
            sessionID: response.sessionId,
            senderClient: senderClient,
            events: events,
            notifications: notifications,
            acceptTask: acceptTask
        )
    }

    private func waitForCanceledEvent(
        _ events: ProgressEventCollector,
        transferID: String
    ) async -> TransferProgressRawEvent? {
        for _ in 0..<100 {
            let observed = await events.drain()
            if let match = observed.last(where: { $0.transferID == transferID && $0.kind == .transferCanceled }) {
                return match
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    private static func makeActiveSendProgress(id: String) -> ActiveTransferProgress {
        ActiveTransferProgress(
            id: id,
            attemptID: id,
            direction: .sending,
            counterpartName: "Peer",
            counterpartKind: .desktop,
            status: .running,
            files: []
        )
    }

    private func makePINTestSettings() -> TransferProtocolSettings {
        TransferProtocolSettings(
            deviceName: "LocalDrop Test Mac",
            tcpPort: 0,
            requirePIN: false,
            incomingPIN: "123456",
            allowDownloads: true,
            useHTTPS: true,
            saveLocation: makeTempDirectory()
        )
    }

    private func makePINTestStore(runtime: FakeTransferRuntime) -> TransferFeatureStore {
        TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )
    }

    private static func makePINTestPeer() -> NearbyPeerItem {
        NearbyPeerItem(
            id: "peer-pin",
            host: "192.168.1.5",
            name: "Locked Laptop",
            subtitle: "",
            kind: .macbook,
            fingerprint: "fingerprint-locked",
            protocolType: .https,
            port: 53_317,
            supportsDownloads: true
        )
    }

    private static func makePINTestStagedItems() -> [StagedTransferItem] {
        [
            StagedTransferItem(
                id: "a",
                fileURL: URL(fileURLWithPath: "/tmp/LocalDropTests/a.txt"),
                name: "a.txt",
                subtitle: "",
                fileTypeSymbol: "doc.fill",
                byteCount: 10
            ),
            StagedTransferItem(
                id: "b",
                fileURL: URL(fileURLWithPath: "/tmp/LocalDropTests/b.txt"),
                name: "b.txt",
                subtitle: "",
                fileTypeSymbol: "doc.fill",
                byteCount: 20
            )
        ]
    }

    /// A second, disjoint batch standing in for an overlapping send's staged items.
    private static func makeSecondSendStagedItems() -> [StagedTransferItem] {
        [
            StagedTransferItem(
                id: "c",
                fileURL: URL(fileURLWithPath: "/tmp/LocalDropTests/c.txt"),
                name: "c.txt",
                subtitle: "",
                fileTypeSymbol: "doc.fill",
                byteCount: 30
            ),
            StagedTransferItem(
                id: "d",
                fileURL: URL(fileURLWithPath: "/tmp/LocalDropTests/d.txt"),
                name: "d.txt",
                subtitle: "",
                fileTypeSymbol: "doc.fill",
                byteCount: 40
            )
        ]
    }

    private static func makePINTestRawEvent(
        kind: TransferProgressRawEvent.Kind,
        sessionID: String,
        sequence: Int64
    ) -> TransferProgressRawEvent {
        TransferProgressRawEvent(
            kind: kind,
            transferID: sessionID,
            attemptID: sessionID,
            direction: .sending,
            counterpartName: "Locked Laptop",
            counterpartKind: .macbook,
            sequenceNumber: sequence,
            eventMonotonicTime: Double(sequence),
            files: [
                TransferProgressRawFile(
                    fileID: "a",
                    displayName: "a.txt",
                    fileURL: nil,
                    order: 0,
                    attemptIndex: 0,
                    state: kind == .transferCompleted ? .completed : .transferring,
                    declaredTotalBytes: 10,
                    actualTransferredBytes: kind == .transferCompleted ? 10 : 0,
                    errorSummary: nil
                )
            ],
            totalBytesKnown: 10,
            actualTransferredBytes: kind == .transferCompleted ? 10 : 0
        )
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
        store.sendMode = .multiple
        _ = SendView(store: store, actions: actions).body
        store.sendMode = .link
        _ = SendView(store: store, actions: actions).body
        _ = NSApplication.shared
        _ = RootView(store: store, sendEntryActions: actions).body
        _ = SendTextEntrySheet(initialText: "", onStage: { _ in }, onCancel: {}).body
        _ = SendTextEntrySheet(initialText: "hello", onStage: { _ in }, onCancel: {}).body
    }

    func testSelectingLinkModeWithoutStagedItemsKeepsPersistedMode() {
        let persistence = InMemorySettingsPersistence()
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: persistence,
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: .default(
                deviceName: "LocalDrop Test Mac",
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )

        store.selectSendMode(.link)

        XCTAssertEqual(store.sendMode, .single)
        XCTAssertEqual(persistence.savedSnapshots.count, 0)
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
                && eventNames.contains("app.runtime.discoverable")
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
        XCTAssertTrue(eventNames.contains("app.runtime.discoverable"))
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

    // MARK: - Favorites

    func testFavoritesPersistenceAdapterRoundTripsFavoritesAcrossInstances() throws {
        let suiteName = "FeatureTransferTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let adapter = FavoritesPersistenceAdapter(userDefaults: defaults)
        XCTAssertTrue(adapter.load().isEmpty)

        adapter.save([
            FavoriteDevice(fingerprint: "AABBCCDD", aliasOverride: "Studio Mac", lastKnownAlias: "Peer Mac"),
            FavoriteDevice(fingerprint: "11223344", lastKnownAlias: "Phone")
        ])

        let reloaded = FavoritesPersistenceAdapter(userDefaults: defaults).load()
        XCTAssertEqual(reloaded.map(\.fingerprint), ["aabbccdd", "11223344"])
        XCTAssertEqual(reloaded.first?.aliasOverride, "Studio Mac")
        XCTAssertEqual(reloaded.first?.lastKnownAlias, "Peer Mac")
        XCTAssertEqual(reloaded.first?.displayName(fallback: "Fallback"), "Studio Mac")
        XCTAssertEqual(reloaded.last?.displayName(fallback: "Fallback"), "Fallback")
        XCTAssertEqual(reloaded.last?.displayName(fallback: ""), "Phone")
    }

    func testFavoritesPersistenceAdapterNormalizesAndDeduplicatesFingerprintCasing() throws {
        let suiteName = "FeatureTransferTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A payload written before fingerprints became lowercase, with the same device twice.
        let payload = """
        [
          {"fingerprint":"AABBCCDD","lastKnownAlias":"Legacy Mac"},
          {"fingerprint":"aabbccdd","lastKnownAlias":"Current Mac"}
        ]
        """
        defaults.set(Data(payload.utf8), forKey: "FeatureTransfer.favorites")

        let loaded = FavoritesPersistenceAdapter(userDefaults: defaults).load()
        XCTAssertEqual(loaded.map(\.fingerprint), ["aabbccdd"])
        XCTAssertEqual(loaded.first?.lastKnownAlias, "Legacy Mac")
    }

    func testFavoritesPersistenceAdapterFailsSafeOnCorruptPayload() throws {
        let suiteName = "FeatureTransferTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data("not json".utf8), forKey: "FeatureTransfer.favorites")

        XCTAssertTrue(FavoritesPersistenceAdapter(userDefaults: defaults).load().isEmpty)
    }

    func testToggleFavoritePersistsAndMatchesFingerprintCaseInsensitively() {
        let favoritesPersistence = InMemoryFavoritesPersistence()
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            favoritesPersistence: favoritesPersistence,
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )
        let peer = Self.makePeer(fingerprint: "AABBCCDD", name: "Peer Mac")

        XCTAssertFalse(store.isFavorite(peer))
        XCTAssertTrue(store.toggleFavorite(for: peer))

        XCTAssertEqual(store.favorites.map(\.fingerprint), ["aabbccdd"])
        XCTAssertEqual(favoritesPersistence.load().map(\.fingerprint), ["aabbccdd"])
        XCTAssertTrue(store.isFavorite(peer))
        // The same device announcing the other casing is still the same favorite.
        XCTAssertTrue(store.isFavorite(fingerprint: "aabbccdd"))
        XCTAssertTrue(store.isFavorite(fingerprint: "AaBbCcDd"))
        XCTAssertFalse(store.isFavorite(fingerprint: "deadbeef"))
        XCTAssertFalse(store.isFavorite(fingerprint: ""))

        XCTAssertFalse(store.toggleFavorite(fingerprint: "AABBCCDD"))
        XCTAssertTrue(store.favorites.isEmpty)
        XCTAssertTrue(favoritesPersistence.load().isEmpty)
    }

    func testStoreLoadsPersistedFavoritesAndPrefersAliasOverrideForDisplayName() {
        let favoritesPersistence = InMemoryFavoritesPersistence(favorites: [
            FavoriteDevice(fingerprint: "AABBCCDD", aliasOverride: "Studio Mac", lastKnownAlias: "Peer Mac")
        ])
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            favoritesPersistence: favoritesPersistence,
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )

        let favorited = Self.makePeer(fingerprint: "aabbccdd", name: "Peer Mac")
        let other = Self.makePeer(fingerprint: "deadbeef", name: "Other Mac")

        XCTAssertEqual(store.displayName(for: favorited), "Studio Mac")
        XCTAssertEqual(store.displayName(for: other), "Other Mac")
    }

    func testFavoriteWithoutAliasOverrideKeepsTheAnnouncedAlias() {
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            favoritesPersistence: InMemoryFavoritesPersistence(favorites: [
                FavoriteDevice(fingerprint: "aabbccdd", lastKnownAlias: "Stale Name")
            ]),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )

        let peer = Self.makePeer(fingerprint: "aabbccdd", name: "Renamed Mac")
        XCTAssertEqual(store.displayName(for: peer), "Renamed Mac")
    }

    // MARK: - Favorites revocation

    /// Revoking has to survive a relaunch, so this drives the real UserDefaults-backed adapter rather
    /// than the in-memory double: a favorite that came back on the next launch would keep its
    /// auto-accept grant alive forever.
    func testRevokeFavoriteRemovesItFromTheListAndFromPersistenceAcrossAReload() throws {
        let suiteName = "FeatureTransferTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistence = FavoritesPersistenceAdapter(userDefaults: defaults)
        persistence.save([
            FavoriteDevice(fingerprint: "aabbccdd", lastKnownAlias: "Studio Mac"),
            FavoriteDevice(fingerprint: "11223344", lastKnownAlias: "Phone")
        ])

        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            favoritesPersistence: persistence,
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )

        XCTAssertEqual(store.sortedFavorites.map(\.fingerprint), ["11223344", "aabbccdd"])

        XCTAssertTrue(store.revokeFavorite(fingerprint: "AABBCCDD"))

        XCTAssertEqual(store.sortedFavorites.map(\.fingerprint), ["11223344"])
        XCTAssertEqual(store.favorites.map(\.fingerprint), ["11223344"])
        XCTAssertFalse(store.isFavorite(fingerprint: "aabbccdd"))

        // A fresh adapter reads what a relaunch would read.
        let reloaded = FavoritesPersistenceAdapter(userDefaults: defaults).load()
        XCTAssertEqual(reloaded.map(\.fingerprint), ["11223344"])

        // And a store rebuilt from that storage never sees the revoked device again.
        let relaunched = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            favoritesPersistence: FavoritesPersistenceAdapter(userDefaults: defaults),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )
        XCTAssertEqual(relaunched.sortedFavorites.map(\.fingerprint), ["11223344"])

        // Revoking is not a toggle: repeating it cannot resurrect the grant.
        XCTAssertFalse(store.revokeFavorite(fingerprint: "aabbccdd"))
        XCTAssertFalse(store.revokeFavorite(fingerprint: ""))
        XCTAssertEqual(store.favorites.map(\.fingerprint), ["11223344"])
    }

    /// The whole point of the surface: the device is gone from the network for good, so it never
    /// reappears in `nearbyPeers` and the star in the device list is unreachable.
    func testRevokeFavoriteWorksForADeviceThatIsNotNearby() {
        let persistence = InMemoryFavoritesPersistence(favorites: [
            FavoriteDevice(fingerprint: "aabbccdd", lastKnownAlias: "Sold Laptop")
        ])
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            favoritesPersistence: persistence,
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )

        XCTAssertTrue(store.nearbyPeers.isEmpty)
        // It still renders, using the cached alias, with a short fingerprint to tell it apart.
        XCTAssertEqual(store.sortedFavorites.map(\.displayName), ["Sold Laptop"])
        XCTAssertEqual(store.sortedFavorites.map(\.shortFingerprint), ["aabbccdd"])

        XCTAssertTrue(store.revokeFavorite(fingerprint: "aabbccdd"))

        XCTAssertTrue(store.sortedFavorites.isEmpty)
        XCTAssertTrue(persistence.load().isEmpty)
    }

    /// The assertion that closes the item: revocation actually withdraws the persisted auto-accept
    /// grant, so a later request from that fingerprint prompts instead of silently landing on disk.
    func testRevokedFavoriteNoLongerAutoAcceptsUnderAutoAcceptFavorites() {
        var snapshot = Self.promptingSnapshot()
        snapshot.autoAcceptFavorites = true
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            favoritesPersistence: InMemoryFavoritesPersistence(favorites: [
                FavoriteDevice(fingerprint: "aabbccdd", lastKnownAlias: "Sold Laptop")
            ]),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: snapshot
        )

        let request = Self.makeIncomingRequest(id: "revoked", senderFingerprint: "AABBCCDD")
        XCTAssertEqual(store.disposition(for: request), .autoAccept(reason: .favorite))

        XCTAssertTrue(store.revokeFavorite(fingerprint: "aabbccdd"))

        XCTAssertTrue(store.autoAcceptFavorites, "Revocation must not silently disable the setting")
        XCTAssertEqual(store.disposition(for: request), .prompt)
    }

    func testSortedFavoritesIsStableAndDeterministic() {
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            favoritesPersistence: InMemoryFavoritesPersistence(favorites: [
                FavoriteDevice(fingerprint: "ffff0000", lastKnownAlias: "zulu"),
                // Two devices sharing an alias: fingerprint is the tie-break, ascending.
                FavoriteDevice(fingerprint: "bbbb1111", lastKnownAlias: "Shared Alias"),
                FavoriteDevice(fingerprint: "aaaa2222", lastKnownAlias: "Shared Alias"),
                FavoriteDevice(fingerprint: "cccc3333", lastKnownAlias: "alpha")
            ]),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )

        let expected = ["cccc3333", "aaaa2222", "bbbb1111", "ffff0000"]
        XCTAssertEqual(store.sortedFavorites.map(\.fingerprint), expected)
        // Sorting by display name is case-insensitive, so "alpha" precedes "Shared Alias".
        XCTAssertEqual(
            store.sortedFavorites.map(\.displayName),
            ["alpha", "Shared Alias", "Shared Alias", "zulu"]
        )
        // Repeated reads never reorder.
        XCTAssertEqual(store.sortedFavorites.map(\.fingerprint), expected)
        XCTAssertEqual(store.sortedFavorites, store.sortedFavorites)

        // Removing one row leaves the rest in the same relative order.
        XCTAssertTrue(store.revokeFavorite(fingerprint: "aaaa2222"))
        XCTAssertEqual(store.sortedFavorites.map(\.fingerprint), ["cccc3333", "bbbb1111", "ffff0000"])
    }

    /// A favorite with no override, no cached alias and no live peer still renders a readable row.
    func testSortedFavoritesFallsBackToALocalizedNameWhenNoAliasIsKnown() {
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            favoritesPersistence: InMemoryFavoritesPersistence(favorites: [
                FavoriteDevice(fingerprint: "aabbccdd", lastKnownAlias: "")
            ]),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )

        XCTAssertEqual(
            store.sortedFavorites.map(\.displayName),
            [FeatureTransferLocalization.string(forKey: "settings.favorites.unknownDevice")]
        )
        XCTAssertNotEqual(store.sortedFavorites.first?.displayName, "")
    }

    /// A favorite that *is* nearby uses the alias it is announcing right now, through the same render
    /// path as the device list rather than a second formatting rule.
    func testSortedFavoritesUsesTheLiveAnnouncedAliasWhenThePeerIsNearby() {
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            favoritesPersistence: InMemoryFavoritesPersistence(favorites: [
                FavoriteDevice(fingerprint: "aabbccdd", lastKnownAlias: "Stale Name")
            ]),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )

        let peer = Self.makePeer(fingerprint: "AABBCCDD", name: "Renamed Mac")
        store.nearbyPeers = [peer]

        XCTAssertEqual(store.sortedFavorites.map(\.displayName), ["Renamed Mac"])
        XCTAssertEqual(store.displayName(for: peer), "Renamed Mac")
    }

    func testSettingsViewRendersTheFavoritesEmptyStateWithNoFavorites() {
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            favoritesPersistence: InMemoryFavoritesPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )

        XCTAssertTrue(store.sortedFavorites.isEmpty)
        _ = SettingsView(store: store).body

        let emptyState = FeatureTransferLocalization.string(forKey: "settings.favorites.empty")
        XCTAssertNotEqual(emptyState, "settings.favorites.empty")
        XCTAssertFalse(emptyState.isEmpty)

        // And the section still builds once a favorite exists.
        store.toggleFavorite(fingerprint: "aabbccdd", lastKnownAlias: "Studio Mac")
        XCTAssertEqual(store.sortedFavorites.map(\.displayName), ["Studio Mac"])
        _ = SettingsView(store: store).body
    }

    // MARK: - Incoming request auto-accept

    func testQuickSaveOnAutoAcceptsWithoutShowingThePrompt() async {
        let runtime = FakeTransferRuntime()
        var snapshot = Self.promptingSnapshot()
        snapshot.quickSave = .on
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(entries: []),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: snapshot
        )
        await store.start()

        let request = Self.makeIncomingRequest(id: "quick-save", senderFingerprint: "deadbeef")
        XCTAssertEqual(store.disposition(for: request), .autoAccept(reason: .quickSave))

        await runtime.emitIncomingRequest(request)
        let expected: [FeatureTransfer.IncomingTransferDecision] = [.acceptAll(requestID: "quick-save")]
        await waitUntil { await runtime.responses == expected }
        XCTAssertNil(store.incomingRequest)
        XCTAssertNil(store.activeSheet)
    }

    // MARK: - Messages are never quick-saved

    /// A message — one text file whose body travels in `preview` — must always reach the user, even
    /// with quick save fully on. Mirrors the reference gate
    /// `settings.quickSave && session?.message == null` (`receive_controller.dart:262-263`).
    func testQuickSaveOnStillPromptsForAMessagePayload() async {
        let runtime = FakeTransferRuntime()
        var snapshot = Self.promptingSnapshot()
        snapshot.quickSave = .on
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(entries: []),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: snapshot
        )
        await store.start()

        let request = Self.makeIncomingRequest(
            id: "message",
            senderFingerprint: "deadbeef",
            wireFiles: [
                FileDto(id: "f1", fileName: "message.txt", size: 12, fileType: "text", preview: "hello there")
            ]
        )
        XCTAssertTrue(request.isMessagePayload)
        XCTAssertEqual(store.disposition(for: request), .prompt)

        await runtime.emitIncomingRequest(request)
        await waitUntil { store.incomingRequest?.id == "message" }
        XCTAssertEqual(store.activeSheet, .incoming)
        let responses = await runtime.responses
        XCTAssertTrue(responses.isEmpty)
    }

    /// The reference decoder accepts both the bare enum name `text` and any `text/…` MIME
    /// (`file_dto.dart:66-73`); both wire forms must be recognised as a message.
    func testQuickSaveOnStillPromptsForATextMimeMessagePayload() {
        var snapshot = Self.promptingSnapshot()
        snapshot.quickSave = .on
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(entries: []),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: snapshot
        )

        let request = Self.makeIncomingRequest(
            id: "mime-message",
            senderFingerprint: "deadbeef",
            wireFiles: [
                FileDto(id: "f1", fileName: "message.txt", size: 12, fileType: "text/plain", preview: "hello there")
            ]
        )
        XCTAssertTrue(request.isMessagePayload)
        XCTAssertEqual(store.disposition(for: request), .prompt)
    }

    /// A lone `.txt` *document* has no preview at all, so the reference does not treat it as a
    /// message and does quick-save it. Over-matching here would break plain text-file transfers.
    ///
    /// Presence of `preview` is the whole test in the reference (`receive_session_state.dart:63-68`),
    /// so an *empty-string* preview is still a message and must prompt — that case is asserted here
    /// alongside the document case it is easily confused with.
    func testQuickSaveOnAutoAcceptsTextFilesWithNoPreviewButPromptsForAnEmptyMessage() async {
        let runtime = FakeTransferRuntime()
        var snapshot = Self.promptingSnapshot()
        snapshot.quickSave = .on
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(entries: []),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: snapshot
        )
        await store.start()

        // No preview at all.
        let noPreview = Self.makeIncomingRequest(
            id: "no-preview",
            senderFingerprint: "deadbeef",
            wireFiles: [FileDto(id: "f1", fileName: "notes.txt", size: 12, fileType: "text", preview: nil)]
        )
        XCTAssertFalse(noPreview.isMessagePayload)
        XCTAssertEqual(store.disposition(for: noPreview), .autoAccept(reason: .quickSave))

        // Present but empty preview: `preview != null` in the reference, so this *is* a message and
        // must reach the user rather than being written silently to disk.
        let emptyPreview = Self.makeIncomingRequest(
            id: "empty-preview",
            senderFingerprint: "deadbeef",
            wireFiles: [FileDto(id: "f1", fileName: "notes.txt", size: 12, fileType: "text", preview: "")]
        )
        XCTAssertTrue(emptyPreview.isMessagePayload)
        XCTAssertEqual(store.disposition(for: emptyPreview), .prompt)

        // Non-text file whose preview is a thumbnail, not a body.
        let image = Self.makeIncomingRequest(
            id: "image",
            senderFingerprint: "deadbeef",
            wireFiles: [
                FileDto(id: "f1", fileName: "photo.jpg", size: 4096, fileType: "image/jpeg", preview: "thumb")
            ]
        )
        XCTAssertFalse(image.isMessagePayload)
        XCTAssertEqual(store.disposition(for: image), .autoAccept(reason: .quickSave))

        await runtime.emitIncomingRequest(noPreview)
        let expected: [FeatureTransfer.IncomingTransferDecision] = [.acceptAll(requestID: "no-preview")]
        await waitUntil { await runtime.responses == expected }
        XCTAssertNil(store.incomingRequest)
    }

    /// The reference's `message` getter requires `files.length == 1`; a batch that merely contains a
    /// text file is a normal transfer and stays quick-savable.
    func testQuickSaveOnAutoAcceptsAMultiFileBatchContainingAMessageLikeFile() {
        var snapshot = Self.promptingSnapshot()
        snapshot.quickSave = .on
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(entries: []),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: snapshot
        )

        let request = Self.makeIncomingRequest(
            id: "batch",
            senderFingerprint: "deadbeef",
            wireFiles: [
                FileDto(id: "f1", fileName: "message.txt", size: 12, fileType: "text", preview: "hello there"),
                FileDto(id: "f2", fileName: "photo.jpg", size: 4096, fileType: "image/jpeg")
            ]
        )
        XCTAssertFalse(request.isMessagePayload)
        XCTAssertEqual(store.disposition(for: request), .autoAccept(reason: .quickSave))
    }

    /// A favorited device is still not authorised to write unseen text to disk, so the
    /// quick-save-from-favorites branch gets the same exemption.
    func testQuickSaveFavoritesStillPromptsForAMessagePayloadFromAFavorite() {
        var snapshot = Self.promptingSnapshot()
        snapshot.quickSave = .favorites
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(entries: []),
            favoritesPersistence: InMemoryFavoritesPersistence(favorites: [
                FavoriteDevice(fingerprint: "aabbccdd", lastKnownAlias: "Peer Mac")
            ]),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: snapshot
        )

        let message = Self.makeIncomingRequest(
            id: "fav-message",
            senderFingerprint: "AABBCCDD",
            wireFiles: [
                FileDto(id: "f1", fileName: "message.txt", size: 12, fileType: "text", preview: "hello there")
            ]
        )
        XCTAssertEqual(store.disposition(for: message), .prompt)

        // The same favorite sending a plain document is unaffected.
        let document = Self.makeIncomingRequest(
            id: "fav-document",
            senderFingerprint: "AABBCCDD",
            wireFiles: [FileDto(id: "f1", fileName: "notes.txt", size: 12, fileType: "text")]
        )
        XCTAssertEqual(store.disposition(for: document), .autoAccept(reason: .quickSaveFavorites))
    }

    func testAutoAcceptFavoritesAutoAcceptsAFavoritedSenderRegardlessOfCasing() async {
        let runtime = FakeTransferRuntime()
        var snapshot = Self.promptingSnapshot()
        snapshot.autoAcceptFavorites = true
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(entries: []),
            favoritesPersistence: InMemoryFavoritesPersistence(favorites: [
                FavoriteDevice(fingerprint: "aabbccdd", lastKnownAlias: "Peer Mac")
            ]),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: snapshot
        )
        await store.start()

        // Sender announces uppercase hex; it must still match the stored lowercase favorite.
        let request = Self.makeIncomingRequest(id: "favorite", senderFingerprint: "AABBCCDD")
        XCTAssertEqual(store.disposition(for: request), .autoAccept(reason: .favorite))

        await runtime.emitIncomingRequest(request)
        let expected: [FeatureTransfer.IncomingTransferDecision] = [.acceptAll(requestID: "favorite")]
        await waitUntil { await runtime.responses == expected }
        XCTAssertNil(store.incomingRequest)
    }

    /// Auto-accept-from-favorites gets the same message exemption as the two quick-save branches: a
    /// favorited device is still not authorised to write unseen text to disk.
    func testAutoAcceptFavoritesStillPromptsForAMessagePayloadFromAFavorite() {
        var snapshot = Self.promptingSnapshot()
        snapshot.autoAcceptFavorites = true
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(entries: []),
            favoritesPersistence: InMemoryFavoritesPersistence(favorites: [
                FavoriteDevice(fingerprint: "aabbccdd", lastKnownAlias: "Peer Mac")
            ]),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: snapshot
        )

        let message = Self.makeIncomingRequest(
            id: "fav-auto-message",
            senderFingerprint: "AABBCCDD",
            wireFiles: [
                FileDto(id: "f1", fileName: "message.txt", size: 12, fileType: "text", preview: "hello there")
            ]
        )
        XCTAssertTrue(message.isMessagePayload)
        XCTAssertEqual(store.disposition(for: message), .prompt)

        // The same favorite sending a plain document is unaffected.
        let document = Self.makeIncomingRequest(
            id: "fav-auto-document",
            senderFingerprint: "AABBCCDD",
            wireFiles: [FileDto(id: "f1", fileName: "notes.txt", size: 12, fileType: "text")]
        )
        XCTAssertFalse(document.isMessagePayload)
        XCTAssertEqual(store.disposition(for: document), .autoAccept(reason: .favorite))
    }

    func testUnknownSenderWithAutoAcceptDisabledStillShowsThePrompt() async {
        let runtime = FakeTransferRuntime()
        var snapshot = Self.promptingSnapshot()
        snapshot.autoAcceptFavorites = true
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(entries: []),
            favoritesPersistence: InMemoryFavoritesPersistence(favorites: [
                FavoriteDevice(fingerprint: "aabbccdd", lastKnownAlias: "Peer Mac")
            ]),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: snapshot
        )
        await store.start()

        let request = Self.makeIncomingRequest(id: "stranger", senderFingerprint: "deadbeef")
        XCTAssertEqual(store.disposition(for: request), .prompt)

        await runtime.emitIncomingRequest(request)
        await waitUntil { store.incomingRequest?.id == "stranger" }
        XCTAssertEqual(store.activeSheet, .incoming)
        let responses = await runtime.responses
        XCTAssertTrue(responses.isEmpty)
    }

    func testQuickSaveFavoritesOnlyAutoAcceptsFavoritedSenders() {
        var snapshot = Self.promptingSnapshot()
        snapshot.quickSave = .favorites
        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(entries: []),
            favoritesPersistence: InMemoryFavoritesPersistence(favorites: [
                FavoriteDevice(fingerprint: "aabbccdd", lastKnownAlias: "Peer Mac")
            ]),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: snapshot
        )

        XCTAssertEqual(
            store.disposition(for: Self.makeIncomingRequest(id: "fav", senderFingerprint: "AABBCCDD")),
            .autoAccept(reason: .quickSaveFavorites)
        )
        XCTAssertEqual(
            store.disposition(for: Self.makeIncomingRequest(id: "other", senderFingerprint: "deadbeef")),
            .prompt
        )
        XCTAssertEqual(
            store.disposition(for: Self.makeIncomingRequest(id: "unknown", senderFingerprint: "")),
            .prompt
        )
    }

    func testShipDefaultsDoNotAutoAcceptAnything() {
        let snapshot = TransferSettingsSnapshot.default(
            deviceName: "LocalDrop Test Mac",
            saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
        )

        XCTAssertEqual(snapshot.quickSave, .off)
        XCTAssertFalse(snapshot.autoAcceptFavorites)

        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(entries: []),
            favoritesPersistence: InMemoryFavoritesPersistence(favorites: [
                FavoriteDevice(fingerprint: "aabbccdd", lastKnownAlias: "Peer Mac")
            ]),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: snapshot
        )

        XCTAssertEqual(
            store.disposition(for: Self.makeIncomingRequest(id: "stranger", senderFingerprint: "deadbeef")),
            .prompt
        )
        XCTAssertEqual(
            store.disposition(for: Self.makeIncomingRequest(id: "favorite", senderFingerprint: "AABBCCDD")),
            .prompt
        )
    }

    func testPreSchemaVersionSettingsPayloadMigratesToPromptingConfiguration() throws {
        let suiteName = "FeatureTransferTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Written by a build in which quickSave/autoAcceptFavorites were decorative: no "schemaVersion"
        // key, and an "on" quick save that never actually suppressed the prompt.
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
          "sendMode":"single",
          "shareViaLinkAutoAccept":false,
          "protocolSettings":{
            "deviceName":"LocalDrop Test Mac",
            "tcpPort":53317,
            "requirePIN":false,
            "incomingPIN":"710042",
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

        XCTAssertEqual(loaded.quickSave, .off)
        XCTAssertFalse(loaded.autoAcceptFavorites)
        XCTAssertEqual(loaded.schemaVersion, TransferSettingsSnapshot.currentSchemaVersion)

        let store = TransferFeatureStore(
            runtime: FakeTransferRuntime(),
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(entries: []),
            favoritesPersistence: InMemoryFavoritesPersistence(favorites: [
                FavoriteDevice(fingerprint: "aabbccdd", lastKnownAlias: "Peer Mac")
            ]),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: loaded
        )

        XCTAssertEqual(
            store.disposition(for: Self.makeIncomingRequest(id: "migrated", senderFingerprint: "AABBCCDD")),
            .prompt
        )
    }

    func testSettingsPayloadWithCurrentSchemaVersionKeepsExplicitQuickSaveChoice() throws {
        let snapshot = TransferSettingsSnapshot(
            quickSave: .on,
            appearance: .system,
            language: .system,
            minimizeToMenuBar: false,
            launchAtLogin: true,
            reduceMotion: false,
            autoAcceptFavorites: true,
            protocolSettings: TransferProtocolSettings(
                deviceName: "LocalDrop Test Mac",
                tcpPort: 53317,
                requirePIN: false,
                incomingPIN: "710042",
                allowDownloads: true,
                useHTTPS: true,
                saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
            )
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(TransferSettingsSnapshot.self, from: data)

        XCTAssertEqual(decoded.quickSave, .on)
        XCTAssertTrue(decoded.autoAcceptFavorites)
        XCTAssertEqual(decoded.schemaVersion, TransferSettingsSnapshot.currentSchemaVersion)
    }

    /// The positive-intermediate version of the old "withdrawal arrives first" test, which asserted
    /// a sequence the merged stream makes unrepresentable. Both halves are load-bearing: the middle
    /// `waitUntil` proves the request really was delivered, so the final "prompt is gone" assertion
    /// cannot pass vacuously by the request never having arrived.
    func testInboundRequestThenWithdrawalDismissesThePromptInOrder() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(entries: []),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )
        await store.start()
        // Attach barrier, not an ordering hack: `start()` only creates the observation tasks, each
        // of which subscribes asynchronously inside its own body.
        for _ in 0..<20 { await Task.yield() }

        await runtime.emitIncomingRequest(Self.makeIncomingRequest(id: "racy", senderFingerprint: "deadbeef"))
        await waitUntil { store.incomingRequest?.id == "racy" }

        await runtime.emitWithdrawal("racy")
        await waitUntil { store.incomingRequest == nil }

        XCTAssertNil(store.activeSheet)
        let responses = await runtime.responses
        XCTAssertTrue(responses.isEmpty)
    }

    /// Asserts the ordering directly rather than inferring it from end state. This is the test that
    /// fails if anyone reintroduces a second consumer for withdrawals.
    ///
    /// Recording via the store's own structured logs (rather than at the runtime's stream hand-out
    /// point) is deliberate: `handleIncomingRequest`/`withdrawIncomingRequest` only emit
    /// `prompt_displayed`/`withdrawn` when they actually act on an event, so this proves what the
    /// store *processed*, in the order it processed it — not merely what order the runtime handed
    /// events to whichever task(s) happen to be consuming the stream.
    func testInboundRequestEventsAreObservedInEmissionOrder() async {
        let sink = RecordingLogSink()
        let logger = AppLogger(
            configuration: AppLoggerConfiguration(minimumLevel: .info, redactSensitiveValues: true),
            resource: [.string("service.name", "LocalDrop")],
            sinks: [sink]
        )
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(entries: []),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot(),
            logger: logger
        )
        await store.start()
        for _ in 0..<20 { await Task.yield() }

        let first = Self.makeIncomingRequest(id: "x", senderFingerprint: "deadbeef")
        let second = Self.makeIncomingRequest(id: "y", senderFingerprint: "deadbeef")
        // Emitted back to back with no yields in between: one ordered stream must still hand them
        // to the single consumer in exactly this order.
        await runtime.emitIncomingRequest(first)
        await runtime.emitWithdrawal("x")
        await runtime.emitIncomingRequest(second)

        await waitUntil { store.incomingRequest?.id == "y" }
        await waitUntil {
            let names = await sink.records().compactMap { $0.attributes["event.name"] }
            return names.count >= 3
        }

        let observed = await sink.records().compactMap { record -> (String, String)? in
            guard case .string(let name) = record.attributes["event.name"],
                  case .string(let requestID)? = record.attributes["transfer.request_id"]
            else { return nil }
            return (name, requestID)
        }

        XCTAssertEqual(
            observed.map(\.0),
            ["transfer.incoming.prompt_displayed", "transfer.incoming.withdrawn", "transfer.incoming.prompt_displayed"]
        )
        XCTAssertEqual(observed.map(\.1), ["x", "x", "y"])
    }

    /// Quick save auto-accepts without ever displaying a prompt, so a withdrawal that follows finds
    /// nothing displayed and is ignored: no prompt, no `.declined` history entry. The auto-accept's
    /// own response still goes out and is answered by the fake — the live bridge would reject it
    /// with `incomingTransferRequestNotPending`, logged as `transfer.incoming.auto_accept_failed`.
    /// Pre-existing behaviour, unchanged by the merge, but this is now its only coverage.
    func testWithdrawalAfterAutoAcceptIsIgnored() async {
        let runtime = FakeTransferRuntime()
        var snapshot = Self.promptingSnapshot()
        snapshot.quickSave = .on
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(entries: []),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: snapshot
        )
        await store.start()
        for _ in 0..<20 { await Task.yield() }

        await runtime.emitIncomingRequest(Self.makeIncomingRequest(id: "racy", senderFingerprint: "deadbeef"))
        await waitUntil { await runtime.responses.isEmpty == false }
        XCTAssertNil(store.incomingRequest, "quick save must auto-accept without displaying a prompt")

        await runtime.emitWithdrawal("racy")
        for _ in 0..<20 { await Task.yield() }

        XCTAssertNil(store.incomingRequest)
        XCTAssertNil(store.activeSheet)
        XCTAssertTrue(
            store.historyEntries.contains { $0.outcome == .declined } == false,
            "A withdrawal must never be recorded as a decline"
        )
        let responses = await runtime.responses
        XCTAssertEqual(responses, [.acceptAll(requestID: "racy")])
    }

    func testWithdrawalDoesNotSuppressALaterDistinctRequest() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(entries: []),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )
        await store.start()
        // Attach barrier BEFORE the withdrawal. Without it the `cache: false` withdrawal would be
        // yielded to zero subscribers and never delivered at all, and the test would stop proving
        // that a stale withdrawal is inert.
        for _ in 0..<20 { await Task.yield() }

        await runtime.emitWithdrawal("gone")
        await runtime.emitIncomingRequest(Self.makeIncomingRequest(id: "fresh", senderFingerprint: "deadbeef"))

        await waitUntil { store.incomingRequest?.id == "fresh" }
        XCTAssertEqual(store.activeSheet, .incoming)
    }

    private static func makeIncomingRequest(
        id: String,
        senderFingerprint: String
    ) -> FeatureTransfer.IncomingTransferRequest {
        FeatureTransfer.IncomingTransferRequest(
            id: id,
            deviceName: "Peer Mac",
            subtitle: "Peer Mac \u{00B7} 1 item",
            sourceKind: .macbook,
            files: [IncomingTransferFile(id: "file", name: "notes.txt", size: "1 KB", symbol: "doc")],
            senderFingerprint: senderFingerprint
        )
    }

    /// Builds a request straight from wire `FileDto`s, so the message classification is exercised
    /// through the same mapping the runtime adapter uses rather than a hand-set flag.
    private static func makeIncomingRequest(
        id: String,
        senderFingerprint: String,
        wireFiles: [FileDto]
    ) -> FeatureTransfer.IncomingTransferRequest {
        FeatureTransfer.IncomingTransferRequest(
            id: id,
            deviceName: "Peer Mac",
            subtitle: "Peer Mac \u{00B7} 1 item",
            sourceKind: .macbook,
            files: wireFiles.map { IncomingTransferFile(file: $0, symbol: "doc") },
            senderFingerprint: senderFingerprint
        )
    }

    private static func makePeer(fingerprint: String, name: String) -> NearbyPeerItem {
        NearbyPeerItem(
            id: fingerprint,
            host: "192.168.1.20",
            name: name,
            subtitle: "Ready",
            kind: .macbook,
            fingerprint: fingerprint,
            protocolType: nil,
            port: 53317,
            supportsDownloads: true
        )
    }

    private static func promptingSnapshot() -> TransferSettingsSnapshot {
        var snapshot = TransferSettingsSnapshot.default(
            deviceName: "LocalDrop Test Mac",
            saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
        )
        // Ship defaults already prompt (see `testShipDefaultsDoNotAutoAcceptAnything`); pinned here so
        // these tests keep exercising the prompt path even if the defaults are revisited.
        snapshot.quickSave = .off
        snapshot.autoAcceptFavorites = false
        return snapshot
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

    private func makeRawProgressEvent(
        kind: TransferProgressRawEvent.Kind,
        transferID: String,
        files: [TransferProgressRawFile],
        totalBytesKnown: Int64?,
        actualTransferredBytes: Int64,
        time: TimeInterval
    ) -> TransferProgressRawEvent {
        TransferProgressRawEvent(
            kind: kind,
            transferID: transferID,
            attemptID: transferID,
            direction: .sending,
            counterpartName: "Peer",
            counterpartKind: .generic,
            sequenceNumber: Int64(time),
            eventMonotonicTime: time,
            files: files,
            totalBytesKnown: totalBytesKnown,
            actualTransferredBytes: actualTransferredBytes
        )
    }

    private func makeRawFile(
        id: String,
        name: String,
        state: TransferFileProgress.Status,
        totalBytes: Int64?,
        transferredBytes: Int64,
        order: Int = 0
    ) -> TransferProgressRawFile {
        TransferProgressRawFile(
            fileID: id,
            displayName: name,
            fileURL: nil,
            order: order,
            attemptIndex: 0,
            state: state,
            declaredTotalBytes: totalBytes,
            actualTransferredBytes: transferredBytes,
            errorSummary: nil
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
        receiveCancelNotifier: ReceiveCancelNotifier? = nil,
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

        if let receiveCancelNotifier {
            return LocalSendRuntimeAdapter(
                components: try makeComponents(settings),
                settings: settings,
                makeComponents: makeComponents,
                receiveCancelNotifier: receiveCancelNotifier,
                logger: logger
            )
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

    func testLanguageSettingLocalizationsMatchInfoPlist() throws {
        let infoPlist = try loadInfoPlist()
        let bundleLocalizations = try XCTUnwrap(infoPlist["CFBundleLocalizations"] as? [String])
        XCTAssertEqual(bundleLocalizations, LanguageSetting.supportedLocalizationIdentifiers)
    }

    func testLocalizationCatalogHasEverySupportedLocaleForEveryKey() throws {
        let catalog = try loadStringCatalog()
        let requiredLocales = try requiredLocalizationIdentifiers()
        var missing: [String] = []

        for key in catalog.strings.keys.sorted() {
            for locale in requiredLocales {
                guard
                    let stringUnit = catalog.strings[key]?.localizations?[locale]?.stringUnit,
                    stringUnit.state == "translated",
                    let value = stringUnit.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                    value.isEmpty == false
                else {
                    missing.append("\(key) [\(locale)]")
                    continue
                }
            }
        }

        XCTAssertEqual(missing, [])
    }

    func testLocalizedFormatKeysPreservePlaceholdersAcrossSupportedLocales() throws {
        let catalog = try loadStringCatalog()
        let requiredLocales = try requiredLocalizationIdentifiers()
        let keys = [
            "device.subtitleFormat",
            "history.subtitleFormat",
            "incomingRequest.itemCount",
            "incomingRequest.menuTitleFormat",
            "incomingRequest.selectionAll",
            "incomingRequest.selectionPartial",
            "incomingRequest.subtitleFormat",
            "incomingRequest.titleFormat",
            "feedback.fileReceived",
            "feedback.fileSent",
            "feedback.filesAccepted",
            "feedback.itemsStaged",
            "menubar.receivingTitle",
            "pinEntry.description",
            "send.removeItem",
            "send.stagedSubtitleFormat",
            "transfer.completedItemFormat",
            "transfer.progress.byteFormat",
            "transfer.progress.etaFormat",
            "transfer.progress.filePositionFormat",
            "transfer.progress.menuBatchTitleFormat",
            "transfer.progress.menuSummaryFormat",
            "transfer.progress.menuTitleFormat",
            "transfer.progress.percentComplete",
            "transfer.progress.speedEtaFormat",
            "transfer.progress.speedFormat",
            "transfer.queuedItemFormat",
            "transfer.stagedItems",
            "transfer.stagedSummary"
        ]

        for key in keys {
            let englishValue = try XCTUnwrap(catalog.strings[key]?.localizations?["en"]?.stringUnit?.value)
            let englishPlaceholders = placeholderTokens(in: englishValue)
            for locale in requiredLocales {
                let localizedValue = try XCTUnwrap(catalog.strings[key]?.localizations?[locale]?.stringUnit?.value)
                XCTAssertEqual(
                    placeholderTokens(in: localizedValue),
                    englishPlaceholders,
                    "Placeholder mismatch for \(key) [\(locale)]"
                )
            }
        }
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
            stringCatalogURL.path,
            infoPlistURL.path
        ]

        let stderr = Pipe()
        result.standardError = stderr
        try result.run()
        result.waitUntilExit()

        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        XCTAssertEqual(result.terminationStatus, 0, errorOutput ?? "verification script failed")
    }

    func testFeatureTransferLocalizationFormatsUpdatedTransferKeys() {
        XCTAssertEqual(
            FeatureTransferLocalization.format("transfer.progress.byteFormat", "1 MB", "2 MB"),
            "1 MB / 2 MB"
        )
        XCTAssertEqual(
            FeatureTransferLocalization.format("transfer.progress.speedFormat", "2 MB"),
            "2 MB/s"
        )
        XCTAssertEqual(
            FeatureTransferLocalization.format("transfer.progress.speedEtaFormat", "2 MB/s", "5s"),
            "2 MB/s • ETA 5s"
        )
        XCTAssertEqual(
            FeatureTransferLocalization.format("history.subtitleFormat", "Sent to", "Peer", "24 MB"),
            "Sent to Peer · 24 MB"
        )
    }

    func testTransferFileProgressStatusLabelUsesLocalizedKeys() {
        XCTAssertEqual(TransferFileProgress(id: "queued", fileName: "queued.txt", status: .queued).statusLabel, "Queued")
        XCTAssertEqual(TransferFileProgress(id: "failed", fileName: "failed.txt", status: .failed).statusLabel, "Failed")
        XCTAssertEqual(TransferFileProgress(id: "retrying", fileName: "retrying.txt", status: .retrying).statusLabel, "Retrying")
    }

    func testTransferETADescriptionTextUsesLocalizedStrings() {
        XCTAssertEqual(TransferETA.calculating.descriptionText, "Calculating…")
        XCTAssertEqual(TransferETA.stalled.descriptionText, "Stalled")
    }

    func testActiveTransferProgressMenuTitleUsesLocalizedBatchFormat() {
        let progress = ActiveTransferProgress(
            id: "menu-1",
            attemptID: "menu-1",
            direction: .sending,
            counterpartName: "Peer",
            files: [
                TransferFileProgress(id: "1", fileName: "one.txt", status: .completed, totalBytes: 100, effectiveTotalBytesForDisplay: 100, actualTransferredBytes: 100, displayedTransferredBytes: 100, completedBytesContribution: 100, order: 0),
                TransferFileProgress(id: "2", fileName: "two.txt", status: .transferring, totalBytes: 100, effectiveTotalBytesForDisplay: 100, actualTransferredBytes: 50, displayedTransferredBytes: 50, order: 1),
                TransferFileProgress(id: "3", fileName: "three.txt", status: .queued, order: 2)
            ],
            totalBytesKnown: 300,
            displayableTransferredBytes: 150,
            actualTransferredBytes: 150
        )

        XCTAssertEqual(progress.menuTitle, "Sending 1 of 3 completed 50%")
    }

    func testArabicOverrideResolvesDeviceNameAndSecurityDialogCopy() {
        FeatureTransferLocalization.setLanguage(.arabic)
        defer { FeatureTransferLocalization.setLocaleIdentifier(nil) }

        XCTAssertEqual(
            FeatureTransferLocalization.string(forKey: "settings.deviceNameHint"),
            "اختر الاسم الذي ستشاهده أجهزة LocalSend الأخرى."
        )
        XCTAssertEqual(
            FeatureTransferLocalization.string(forKey: SecurityDialog.requirePIN.messageKey),
            "ستتطلب عمليات النقل الواردة رمز PIN قبل قبول الملفات."
        )
    }

    func testSendViewResolvesDropZoneLabelText() {
        let view = SendView(
            store: TransferFeatureStore(
                runtime: FakeTransferRuntime(),
                settingsPersistence: InMemorySettingsPersistence(),
                historyPersistence: InMemoryHistoryPersistence(),
                loginItemManaging: FakeLoginItemManaging(),
                snapshot: .default(
                    deviceName: "LocalDrop Test Mac",
                    saveLocation: URL(fileURLWithPath: "/tmp/LocalDropTests")
                )
            )
        )

        XCTAssertEqual(view.resolvedDropZoneLabel, "Drag files or folders anywhere to send")
        XCTAssertNotEqual(view.resolvedDropZoneLabel, "send.dropZoneLabel")
    }

    func testAuditedFilesDoNotReintroduceKnownHardCodedLocalizationLiterals() throws {
        let forbiddenByFile: [String: [String]] = [
            "Sources/FeatureTransfer/SettingsView.swift": [
                "\"Choose the name other LocalSend devices will see.\"",
                "\"Enter a device name to apply.\"",
                "\"Use system name\"",
                "\"Generate random alias\""
            ],
            "Sources/FeatureTransfer/SendView.swift": [
                "label: \"send.dropZoneLabel\""
            ],
            "Sources/FeatureTransfer/Sheets/TransferProgressSheet.swift": [
                "\"Complete\"",
                "\"In Progress\""
            ],
            "Sources/FeatureTransfer/Models/FeatureTransferModels.swift": [
                "\"Calculating…\"",
                "\"Stalled\"",
                "\"Queued\"",
                "\"Failed\"",
                "\"Retrying\"",
                "\"Completed Item \\(",
                "\"Queued Item \\(",
                "\" / \"",
                "\"/s\"",
                "\" • ETA \"",
                "\"ETA \\(",
                "\" · \""
            ],
            "Sources/FeatureTransfer/Application/TransferFeatureStore.swift": [
                "\"Transfer failed\""
            ],
            "Sources/FeatureTransfer/Infrastructure/LocalSendRuntimeAdapter.swift": [
                "\"Transfer failed\""
            ],
            "Sources/FeatureTransfer/MenuBarExtraView.swift": [
                "\" completed\"",
                "\"\\(action) · \\(itemTitle)\""
            ]
        ]

        for (relativePath, forbiddenLiterals) in forbiddenByFile {
            let fileURL = featureTransferRootURL.appendingPathComponent(relativePath)
            let contents = try String(contentsOf: fileURL)
            for literal in forbiddenLiterals {
                XCTAssertFalse(contents.contains(literal), "Found forbidden literal \(literal) in \(relativePath)")
            }
        }
    }

    private var stringCatalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FeatureTransfer/Resources/Localizable.xcstrings")
    }

    private var featureTransferRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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

    private var infoPlistURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/LocalDropApp/Info.plist")
    }

    private func loadStringCatalog() throws -> StringCatalog {
        let data = try Data(contentsOf: stringCatalogURL)
        return try JSONDecoder().decode(StringCatalog.self, from: data)
    }

    private func loadInfoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: infoPlistURL)
        return try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    // MARK: - Backlog item 21: concurrent send sessions

    /// Two sends in flight at once must BOTH stay visible. The old single `activeTransfer` meant
    /// starting a send to device B silently hid the one still running to device A.
    func testConcurrentTransfersAreAllListedInFlight() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )
        await store.start()

        await runtime.emitProgress(
            ActiveTransferProgress(
                id: "session-A",
                direction: .sending,
                counterpartName: "Device A",
                fileName: "a.txt",
                progress: 0.25,
                throughput: "1 MB/s",
                etaDescription: "Soon"
            )
        )
        await waitUntil { store.activeTransfersByID["session-A"] != nil }

        await runtime.emitProgress(
            ActiveTransferProgress(
                id: "session-B",
                direction: .sending,
                counterpartName: "Device B",
                fileName: "b.txt",
                progress: 0.5,
                throughput: "2 MB/s",
                etaDescription: "Soon"
            )
        )
        await waitUntil { store.activeTransfersByID["session-B"] != nil }

        XCTAssertEqual(store.inFlightTransfers.count, 2, "both concurrent sends must remain listed")
        XCTAssertTrue(store.hasConcurrentTransfers)
        XCTAssertEqual(Set(store.inFlightTransfers.map(\.id)), ["session-A", "session-B"])
        await store.stop()
    }

    /// Cancelling one concurrent send must cancel ONLY that session.
    func testCancellingOneTransferLeavesTheOtherRunning() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )
        await store.start()

        for (id, name) in [("session-A", "Device A"), ("session-B", "Device B")] {
            await runtime.emitProgress(
                ActiveTransferProgress(
                    id: id,
                    direction: .sending,
                    counterpartName: name,
                    fileName: "f.txt",
                    progress: 0.25,
                    throughput: "1 MB/s",
                    etaDescription: "Soon"
                )
            )
            await waitUntil { store.activeTransfersByID[id] != nil }
        }

        store.cancelTransfer(id: "session-A")
        await waitUntil { await runtime.canceledTransferIDs.isEmpty == false }

        let canceled = await runtime.canceledTransferIDs
        XCTAssertEqual(canceled, ["session-A"], "only the targeted session may be cancelled")
        XCTAssertNotNil(store.activeTransfersByID["session-B"], "the other send must keep running")
        await store.stop()
    }

    /// A terminal transfer leaves the in-flight list even though the detail sheet lingers briefly.
    func testTerminalTransferLeavesTheInFlightList() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )
        await store.start()

        let running = ActiveTransferProgress(
            id: "session-A",
            direction: .sending,
            counterpartName: "Device A",
            fileName: "a.txt",
            progress: 0.5,
            throughput: "1 MB/s",
            etaDescription: "Soon"
        )
        await runtime.emitProgress(running)
        await waitUntil { store.activeTransfersByID["session-A"] != nil }

        // `status` must be terminal for `emitTerminalProgress` to send a terminal event kind — the
        // convenience initializer defaults to `.running`, which would emit a plain snapshot.
        let completed = ActiveTransferProgress(
            id: "session-A",
            direction: .sending,
            counterpartName: "Device A",
            fileName: "a.txt",
            progress: 1,
            throughput: "1 MB/s",
            etaDescription: "Done",
            status: .completed
        )
        await runtime.emitTerminalProgress(completed)
        await waitUntil { store.activeTransfersByID["session-A"] == nil }

        XCTAssertTrue(store.inFlightTransfers.isEmpty)
        XCTAssertFalse(store.hasConcurrentTransfers)
        await store.stop()
    }

    /// The reducer keeps per-transfer state. Interleaved events from two concurrent sends used to
    /// share one slot, so each reset the other's byte high-water mark and speed sample.
    func testProgressReducerKeepsPerTransferStateWhenEventsInterleave() async {
        let reducer = TransferProgressReducer()

        let a1 = await reducer.reduce(
            makeRawProgressEvent(
                kind: .snapshot,
                transferID: "A",
                files: [makeRawFile(id: "a", name: "a.txt", state: .transferring, totalBytes: 1000, transferredBytes: 400)],
                totalBytesKnown: 1000,
                actualTransferredBytes: 400,
                time: 1
            )
        )
        XCTAssertEqual(a1.displayableTransferredBytes, 400)

        // B interleaves. Under the old shared slot this wiped A's state.
        _ = await reducer.reduce(
            makeRawProgressEvent(
                kind: .snapshot,
                transferID: "B",
                files: [makeRawFile(id: "b", name: "b.txt", state: .transferring, totalBytes: 1000, transferredBytes: 100)],
                totalBytesKnown: 1000,
                actualTransferredBytes: 100,
                time: 2
            )
        )

        // A continues. Its high-water mark must have survived B's event.
        let a2 = await reducer.reduce(
            makeRawProgressEvent(
                kind: .snapshot,
                transferID: "A",
                files: [makeRawFile(id: "a", name: "a.txt", state: .transferring, totalBytes: 1000, transferredBytes: 600)],
                totalBytesKnown: 1000,
                actualTransferredBytes: 600,
                time: 3
            )
        )
        XCTAssertEqual(a2.id, "A")
        XCTAssertEqual(a2.displayableTransferredBytes, 600)
        XCTAssertEqual(a2.startedAtMonotonic, a1.startedAtMonotonic, "A's start time must not be reset by B's events")
    }

    // MARK: - Backlog item 16: received messages go to history, not disk

    /// Accepting a message writes a history entry carrying the text, with no file URL.
    func testAcceptingAMessageRecordsItInHistory() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )
        await store.start()

        let message = IncomingTransferRequest(
            id: "msg-1",
            deviceName: "Peer",
            subtitle: "Peer · message",
            sourceKind: .phone,
            files: [
                IncomingTransferFile(
                    id: "m1",
                    name: "message.txt",
                    size: "11 bytes",
                    symbol: "text.bubble",
                    isMessagePayload: true,
                    messageText: "hello there"
                )
            ]
        )
        await runtime.emitIncomingRequest(message)
        await waitUntil { store.incomingRequest?.id == "msg-1" }

        store.acceptIncomingRequest()

        let entry = try? XCTUnwrap(store.historyEntries.first)
        XCTAssertEqual(entry?.fileName, "hello there", "the message body is the history entry")
        XCTAssertTrue(entry?.isMessage == true)
        XCTAssertNil(entry?.fileURL, "a message was never written to disk")
        await store.stop()
    }

    /// A plain file transfer must NOT produce a message history entry on accept — those are written
    /// by the progress pipeline on completion.
    func testAcceptingAFileDoesNotRecordAMessageEntry() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )
        await store.start()

        await runtime.emitIncomingRequest(Self.makeIncomingRequest(id: "file-1", senderFingerprint: "PEER"))
        await waitUntil { store.incomingRequest?.id == "file-1" }

        store.acceptIncomingRequest()
        XCTAssertTrue(store.historyEntries.allSatisfy { $0.isMessage == false })
        await store.stop()
    }

    /// A `history.json` written before `isMessage` existed must still decode. The persistence
    /// adapter fails safe to `[]` on ANY decode error, so a synthesized decoder here would wipe the
    /// user's entire history on first launch after upgrading.
    func testLegacyHistoryEntryWithoutIsMessageStillDecodes() throws {
        let json = """
        [{
          "id": "\(UUID().uuidString)",
          "fileName": "old.txt",
          "counterpart": "Peer",
          "size": "1 KB",
          "timestamp": 760000000,
          "direction": "received",
          "outcome": "completed"
        }]
        """
        let entries = try JSONDecoder().decode([HistoryEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].fileName, "old.txt")
        XCTAssertFalse(entries[0].isMessage, "a missing isMessage must default to false, not fail the decode")
    }

    // MARK: - Backlog item 50: favorite rename reaches `aliasOverride`

    /// `aliasOverride` had a model, persistence and a render path but no setter — nothing in the
    /// app could ever populate it.
    func testRenamingAFavoriteSetsAliasOverrideAndPersists() async {
        let runtime = FakeTransferRuntime()
        let favorites = InMemoryFavoritesPersistence()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            favoritesPersistence: favorites,
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )

        store.toggleFavorite(fingerprint: "ABCDEF0123", lastKnownAlias: "Broadcast Name")
        XCTAssertTrue(store.renameFavorite(fingerprint: "ABCDEF0123", alias: "Kitchen Mac"))

        XCTAssertEqual(store.aliasOverride(forFingerprint: "ABCDEF0123"), "Kitchen Mac")
        XCTAssertEqual(store.sortedFavorites.first?.displayName, "Kitchen Mac")
        XCTAssertEqual(favorites.load().first?.aliasOverride, "Kitchen Mac", "the rename must be persisted")
    }

    /// Clearing the override is the only route back to the broadcast name, so empty/whitespace
    /// input must clear rather than be rejected.
    func testRenamingAFavoriteToEmptyClearsTheOverride() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            favoritesPersistence: InMemoryFavoritesPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )

        store.toggleFavorite(fingerprint: "ABCDEF0123", lastKnownAlias: "Broadcast Name")
        store.renameFavorite(fingerprint: "ABCDEF0123", alias: "Kitchen Mac")
        XCTAssertEqual(store.aliasOverride(forFingerprint: "ABCDEF0123"), "Kitchen Mac")

        store.renameFavorite(fingerprint: "ABCDEF0123", alias: "   ")
        XCTAssertNil(store.aliasOverride(forFingerprint: "ABCDEF0123"))
        XCTAssertEqual(store.sortedFavorites.first?.displayName, "Broadcast Name", "clearing falls back to the broadcast name")
    }

    /// Renaming something that is not a favorite must not silently create one.
    func testRenamingAnUnknownFingerprintDoesNothing() async {
        let runtime = FakeTransferRuntime()
        let store = TransferFeatureStore(
            runtime: runtime,
            settingsPersistence: InMemorySettingsPersistence(),
            historyPersistence: InMemoryHistoryPersistence(),
            favoritesPersistence: InMemoryFavoritesPersistence(),
            loginItemManaging: FakeLoginItemManaging(),
            snapshot: Self.promptingSnapshot()
        )

        XCTAssertFalse(store.renameFavorite(fingerprint: "NOTAFAVORITE", alias: "Nope"))
        XCTAssertTrue(store.sortedFavorites.isEmpty)
    }

    private func requiredLocalizationIdentifiers() throws -> [String] {
        let bundleLocalizations = try XCTUnwrap((try loadInfoPlist())["CFBundleLocalizations"] as? [String])
        var locales: [String] = []
        for locale in [try loadStringCatalog().sourceLanguage] + bundleLocalizations where locales.contains(locale) == false {
            locales.append(locale)
        }
        return locales
    }

    private func placeholderTokens(in value: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:\d+\$)?[@dDfFuUxXoOcCsSpaAeEgG]"#)
        let nsValue = value as NSString
        return regex.matches(in: value, range: NSRange(location: 0, length: nsValue.length)).map {
            nsValue.substring(with: $0.range)
        }
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

    let sourceLanguage: String
    let strings: [String: Entry]
}

private struct PredictableRandomNumberGenerator: RandomNumberGenerator {
    private var values: [UInt64]
    private var index = 0

    init(values: [UInt64]) {
        self.values = values
    }

    mutating func next() -> UInt64 {
        guard values.isEmpty == false else { return 0 }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}

/// A scripted sequence of `/prepare-upload` results, recording the PIN each attempt carried.
private actor PrepareUploadScript {
    enum Result {
        case success(PrepareUploadResponse)
        case failure(any Error)
    }

    private var results: [Result]
    private(set) var observedPINs: [String?] = []

    init(results: [Result]) {
        self.results = results
    }

    func next(pin: String?) async throws -> PrepareUploadResponse? {
        observedPINs.append(pin)
        guard results.isEmpty == false else {
            throw TestFailure.unexpectedPrepareUploadAttempt
        }
        switch results.removeFirst() {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }
}

/// Stands in for the PIN sheet: hands back a scripted answer per prompt (`nil` = user dismissed)
/// and records the `isFirstAttempt` flag each prompt was raised with.
private actor PINPromptRecorder {
    private var responses: [String?]
    private(set) var observedFirstAttemptFlags: [Bool] = []

    init(responses: [String?]) {
        self.responses = responses
    }

    func respond(to context: TransferPINPromptContext) async -> String? {
        observedFirstAttemptFlags.append(context.isFirstAttempt)
        guard responses.isEmpty == false else { return nil }
        return responses.removeFirst()
    }
}

/// Fails every request, standing in for a peer that refuses (or cannot answer) the send-side
/// `/cancel` — e.g. the 403 a v1-routed cancel draws from a receiver whose session recorded a v2
/// sender (`receive_controller.dart:646-653`).
private struct AlwaysFailingTransport: LocalSendTransport {
    func send(
        _ request: HTTPRequest,
        to peer: RemotePeer,
        progress: (@Sendable (FileTransferProgress) -> Void)?
    ) async throws -> HTTPResponse {
        throw LocalSendClientError.invalidStatusCode(403)
    }
}

/// Stands in for the outbound `POST /cancel` the receiver fires at the sender, so a test can count
/// them — including the load-bearing case of zero, when the peer is the one who cancelled.
private actor ReceiveCancelNotificationRecorder {
    struct Sent: Equatable {
        let sessionID: String
        let peer: RemotePeer
        let fingerprint: String
    }

    private var recorded: [Sent] = []
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func record(sessionID: String, peer: RemotePeer, fingerprint: String) async throws {
        recorded.append(Sent(sessionID: sessionID, peer: peer, fingerprint: fingerprint))
        if let error {
            throw error
        }
    }

    func sent() -> [Sent] {
        recorded
    }
}

/// Drains the adapter's progress stream so a test can assert on exactly which events were emitted
/// — including the load-bearing case of none at all.
private actor ProgressEventCollector {
    private var events: [TransferProgressRawEvent] = []
    private var task: Task<Void, Never>?

    static func attached(to adapter: LocalSendRuntimeAdapter) async -> ProgressEventCollector {
        let collector = ProgressEventCollector()
        let stream = await adapter.progressEvents()
        await collector.consume(stream)
        return collector
    }

    private func consume(_ stream: AsyncStream<TransferProgressEvent>) {
        task = Task { [weak self] in
            for await event in stream {
                if case .event(let raw) = event {
                    await self?.append(raw)
                }
            }
        }
    }

    private func append(_ event: TransferProgressRawEvent) {
        events.append(event)
    }

    /// Yields a few times first so an in-flight broadcast has landed before the assertion.
    func drain() async -> [TransferProgressRawEvent] {
        for _ in 0..<20 {
            await Task.yield()
        }
        return events
    }
}

private actor FakeTransferRuntime: TransferRuntime {
    private let peersBroadcaster = TestBroadcaster<[NearbyPeerItem]>(initialValue: [])
    private let inboundEventBroadcaster = TestBroadcaster<InboundRequestEvent>()
    private let progressBroadcaster = TestBroadcaster<TransferProgressEvent>()
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
    func inboundRequestEvents() async -> AsyncStream<InboundRequestEvent> { await inboundEventBroadcaster.stream() }
    /// `cache: false`, exactly as production yields withdrawals. A cached withdrawal would become
    /// the replayed last value for a late or re-subscribing store, which is a hazard the single
    /// merged stream would otherwise introduce.
    func emitWithdrawal(_ requestID: String) async {
        await inboundEventBroadcaster.yield(.withdrawal(requestID: requestID), cache: false)
    }
    func progressEvents() async -> AsyncStream<TransferProgressEvent> { await progressBroadcaster.stream() }
    func updateSettings(_ settings: TransferProtocolSettings) async throws {
        if let updateSettingsError {
            throw updateSettingsError
        }
        lastUpdatedSettings = settings
    }
    func stage(_ items: [StagedTransferItem]) async { stagedItems = items }
    func sendStagedItems(
        to peerID: NearbyPeerItem.ID,
        pin: String?,
        requestPIN: TransferPINProvider?
    ) async throws {
        sentPeerIDs.append(peerID)
        guard let scriptedPINPrompts, let requestPIN else { return }
        // Replays a scripted sequence of 401s through the caller's prompt, exactly as the live
        // adapter's retry loop does, so store-level flows can be driven without a live peer.
        for isFirstAttempt in scriptedPINPrompts {
            guard let submitted = await requestPIN(
                TransferPINPromptContext(peerID: peerID, peerName: "Scripted Peer", isFirstAttempt: isFirstAttempt)
            ) else {
                pinPromptWasCanceled = true
                stagedItems.removeAll()
                return
            }
            submittedPINs.append(submitted)
        }
    }

    private var scriptedPINPrompts: [Bool]?
    private(set) var submittedPINs: [String] = []
    private(set) var pinPromptWasCanceled = false

    /// `attempts` holds the `isFirstAttempt` flag for each 401 the peer should answer with.
    func scriptPINPrompts(_ attempts: [Bool]) {
        scriptedPINPrompts = attempts
    }
    func respondToIncomingRequest(_ response: FeatureTransfer.IncomingTransferDecision) async throws { responses.append(response) }
    func cancelActiveTransfer(_ id: ActiveTransferProgress.ID) async throws { canceledTransferIDs.append(id) }

    func setUpdateSettingsError(_ error: Error?) {
        updateSettingsError = error
    }

    /// Keeps `cache: true` (production uses `cache: false`) because several tests deliberately emit
    /// before `start()` and rely on the replay — `testActiveSheetPrefersIncomingRequestOverProgress`
    /// and `testRestartAfterStopRebindsRuntimeStreams`. Pre-existing test-fixture convenience.
    func emitIncomingRequest(_ request: FeatureTransfer.IncomingTransferRequest) async {
        await inboundEventBroadcaster.yield(.request(request))
    }

    func emitProgress(_ progress: ActiveTransferProgress) async {
        await progressBroadcaster.yield(.event(Self.makeRawEvent(from: progress, kind: .snapshot)))
    }

    func emitTerminalProgress(_ progress: ActiveTransferProgress) async {
        let kind: TransferProgressRawEvent.Kind
        switch progress.status {
        case .running:
            kind = .snapshot
        case .completed:
            kind = .transferCompleted
        case .failed:
            kind = .transferFailed
        case .canceled:
            kind = .transferCanceled
        case .pinRequired:
            kind = .transferPINRequired
        case .rejected:
            kind = .transferRejected
        case .blocked:
            kind = .transferBlocked
        case .rateLimited:
            kind = .transferRateLimited
        }
        await progressBroadcaster.yield(.event(Self.makeRawEvent(from: progress, kind: kind)))
    }

    func emitProgressReset() async {
        await progressBroadcaster.yield(.reset)
    }

    private static func makeRawEvent(
        from progress: ActiveTransferProgress,
        kind: TransferProgressRawEvent.Kind
    ) -> TransferProgressRawEvent {
        TransferProgressRawEvent(
            kind: kind,
            transferID: progress.id,
            attemptID: progress.attemptID,
            direction: progress.direction,
            counterpartName: progress.counterpartName,
            counterpartKind: progress.counterpartKind,
            sequenceNumber: 1,
            eventMonotonicTime: ProcessInfo.processInfo.systemUptime,
            files: progress.files.enumerated().map { index, file in
                TransferProgressRawFile(
                    fileID: file.id,
                    displayName: file.fileName,
                    fileURL: file.fileURL,
                    order: index,
                    attemptIndex: file.attemptIndex,
                    state: file.status,
                    declaredTotalBytes: file.totalBytes,
                    actualTransferredBytes: file.actualTransferredBytes,
                    errorSummary: file.errorSummary
                )
            },
            totalBytesKnown: progress.totalBytesKnown,
            actualTransferredBytes: progress.actualTransferredBytes
        )
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
    case unexpectedPrepareUploadAttempt

    var errorDescription: String? {
        switch self {
        case .unexpectedPrepareUploadAttempt:
            "Unexpected prepare-upload attempt"
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

    /// `cache` mirrors the production `StreamBroadcaster` signature. It defaults to `true` — which
    /// production does NOT do — because a number of existing tests deliberately emit before
    /// `start()` and rely on the replay; see the note on `FakeTransferRuntime.emitIncomingRequest`.
    func yield(_ value: Value, cache: Bool = true) {
        if cache {
            currentValue = value
        }
        for continuation in continuations.values {
            continuation.yield(value)
        }
    }

    private func remove(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
