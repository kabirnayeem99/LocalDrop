import AppLogging
import Foundation
import Observation

@MainActor
@Observable
final class TransferFeatureStore {
    var screen: Screen = .receive
    var quickSave: QuickSaveMode
    var appearance: AppearanceSetting
    var accentColor: AccentColorChoice
    var language: LanguageSetting
    var minimizeToMenuBar: Bool
    var launchAtLogin: Bool
    var reduceMotion: Bool
    var autoAcceptFavorites: Bool
    var deviceName: String
    var port: String
    var saveLocation: String
    var requirePIN: Bool
    var incomingPIN: String
    var allowDownloads: Bool
    var useHTTPS: Bool
    var isRuntimeAvailable = false
    var runtimeStatusText = "Starting LocalDrop runtime…"
    var nearbyPeers: [NearbyPeerItem] = []
    var stagedItems: [StagedTransferItem] = []
    var historyEntries: [HistoryEntry]
    var incomingRequest: IncomingTransferRequest?
    var activeTransfer: ActiveTransferProgress?
    var feedback: TransferFeedback?
    var isRefreshingDiscovery = false
    var isScanningDiscovery = false
    var lastErrorMessage: String?
    private let runtime: any TransferRuntime
    private let settingsPersistence: any TransferSettingsPersisting
    private let logger: AppLogger
    private var hasStarted = false
    @ObservationIgnored
    nonisolated(unsafe) private var observationTasks: [Task<Void, Never>] = []
    @ObservationIgnored
    nonisolated(unsafe) private var progressCompletionTask: Task<Void, Never>?
    @ObservationIgnored
    nonisolated(unsafe) private var feedbackDismissTask: Task<Void, Never>?

    init(
        runtime: any TransferRuntime,
        settingsPersistence: any TransferSettingsPersisting,
        snapshot: TransferSettingsSnapshot,
        logger: AppLogger = .disabled(),
        historyEntries: [HistoryEntry] = HistoryEntry.samples
    ) {
        self.runtime = runtime
        self.settingsPersistence = settingsPersistence
        self.logger = logger
        self.quickSave = snapshot.quickSave
        self.appearance = snapshot.appearance
        self.accentColor = snapshot.accentColor
        self.language = snapshot.language
        self.minimizeToMenuBar = snapshot.minimizeToMenuBar
        self.launchAtLogin = snapshot.launchAtLogin
        self.reduceMotion = snapshot.reduceMotion
        self.autoAcceptFavorites = snapshot.autoAcceptFavorites
        self.deviceName = snapshot.protocolSettings.deviceName
        self.port = String(snapshot.protocolSettings.tcpPort)
        self.saveLocation = snapshot.protocolSettings.saveLocation.path
        self.requirePIN = snapshot.protocolSettings.requirePIN
        self.incomingPIN = snapshot.protocolSettings.incomingPIN
        self.allowDownloads = snapshot.protocolSettings.allowDownloads
        self.useHTTPS = snapshot.protocolSettings.useHTTPS
        self.historyEntries = historyEntries
    }

    deinit {
        observationTasks.forEach { $0.cancel() }
        progressCompletionTask?.cancel()
        feedbackDismissTask?.cancel()
    }

    var activeSheet: ActiveSheet? {
        if incomingRequest != nil {
            return .incoming
        }
        if activeTransfer != nil {
            return .progress
        }
        return nil
    }

    var waitingIdentifier: String {
        let source = currentProtocolSettings.deviceName.isEmpty ? "LD" : currentProtocolSettings.deviceName
        return String(source.prefix(2)).uppercased()
    }

    var currentProtocolSettings: TransferProtocolSettings {
        TransferProtocolSettings(
            deviceName: deviceName,
            tcpPort: Int(port) ?? 53317,
            requirePIN: requirePIN,
            incomingPIN: resolvedIncomingPIN,
            allowDownloads: allowDownloads,
            useHTTPS: useHTTPS,
            saveLocation: URL(fileURLWithPath: saveLocation)
        )
    }

    func start() async {
        guard hasStarted == false else { return }
        hasStarted = true
        bindRuntimeStreamsIfNeeded()
        runtimeStatusText = "Starting LocalDrop runtime…"
        logger.emit(
            level: .info,
            event: "app.runtime.start.requested",
            scope: "TransferFeatureStore",
            attributes: [
                .string("app.screen", screen.rawValue),
                .bool("settings.use_https", useHTTPS)
            ]
        )

        do {
            try await runtime.start()
            isRuntimeAvailable = true
            runtimeStatusText = "Discoverable"
            logger.emit(
                level: .info,
                event: "app.runtime.start.succeeded",
                scope: "TransferFeatureStore",
                attributes: [
                    .string("result", "success"),
                    .string("runtime.status", runtimeStatusText)
                ]
            )
            await runtime.refreshDiscovery()
        } catch {
            isRuntimeAvailable = false
            runtimeStatusText = "Unavailable"
            recordError(event: "app.runtime.start.failed", error: error)
        }
    }

    func stop() async {
        cancelProgressCompletionTask()
        logger.emit(level: .info, event: "app.runtime.stop.requested", scope: "TransferFeatureStore")
        await runtime.stop()
        logger.emit(level: .info, event: "app.runtime.stop.completed", scope: "TransferFeatureStore")
        await logger.flush()
    }

    func refreshNearbyPeers() {
        refreshDiscovery(shouldShowFeedback: true, scan: false)
    }

    func scanNearbyPeers() {
        refreshDiscovery(shouldShowFeedback: true, scan: true)
    }

    private func refreshDiscovery(shouldShowFeedback: Bool, scan: Bool) {
        logger.emit(
            level: .info,
            event: scan ? "discovery.scan.requested" : "discovery.refresh.requested",
            scope: "TransferFeatureStore",
            attributes: [
                .string("event.domain", "discovery"),
                .string("event.action", scan ? "scan" : "refresh")
            ]
        )
        if scan {
            isScanningDiscovery = true
        } else {
            isRefreshingDiscovery = true
        }
        Task {
            await runtime.refreshDiscovery()
            if scan {
                isScanningDiscovery = false
            } else {
                isRefreshingDiscovery = false
            }
            if shouldShowFeedback {
                showFeedback(
                    TransferFeedback(
                        message: scan ? "Discovery scan started" : "Discovery refreshed",
                        symbol: scan ? "dot.radiowaves.left.and.right" : "arrow.clockwise",
                        tone: .neutral
                    )
                )
            }
        }
    }

    func stageDroppedItems(_ urls: [URL]) {
        let staged = urls.map(Self.makeStagedItem(url:))
        stagedItems = staged
        logger.emit(
            level: .info,
            event: "transfer.stage.completed",
            scope: "TransferFeatureStore",
            attributes: [
                .int("transfer.file_count", staged.count),
                .string("transfer.direction", "sending")
            ]
        )
        Task {
            await runtime.stage(staged)
        }
        showFeedback(
            TransferFeedback(
                message: staged.count == 1 ? "File staged" : "\(staged.count) items staged",
                symbol: "checkmark.circle.fill",
                tone: .success
            )
        )
    }

    func removeStagedItem(id: StagedTransferItem.ID) {
        stagedItems.removeAll { $0.id == id }
        logger.emit(
            level: .info,
            event: "transfer.stage.item_removed",
            scope: "TransferFeatureStore",
            attributes: [
                .string("transfer.file_id", id),
                .int("transfer.file_count", stagedItems.count)
            ]
        )
        Task {
            await runtime.stage(stagedItems)
        }
    }

    func send(to peerID: NearbyPeerItem.ID) {
        logger.emit(
            level: .info,
            event: "transfer.send.requested",
            scope: "TransferFeatureStore",
            attributes: [
                .string("peer.id", peerID),
                .int("transfer.file_count", stagedItems.count)
            ]
        )
        Task {
            do {
                await runtime.stage(stagedItems)
                try await runtime.sendStagedItems(to: peerID, pin: nil)
            } catch {
                recordError(event: "transfer.send.failed", error: error)
            }
        }
    }

    func declineIncomingRequest() {
        guard let request = incomingRequest else { return }
        incomingRequest = nil
        logger.emit(
            level: .notice,
            event: "transfer.incoming.rejected",
            scope: "TransferFeatureStore",
            attributes: [.string("transfer.request_id", request.id)]
        )
        showFeedback(
            TransferFeedback(message: "Transfer declined", symbol: "xmark.circle.fill", tone: .destructive)
        )
        Task {
            try? await runtime.respondToIncomingRequest(.reject(requestID: request.id))
        }
    }

    func acceptIncomingRequest() {
        guard let request = incomingRequest else { return }
        incomingRequest = nil
        logger.emit(
            level: .info,
            event: "transfer.incoming.accepted",
            scope: "TransferFeatureStore",
            attributes: [.string("transfer.request_id", request.id)]
        )
        showFeedback(
            TransferFeedback(message: "Transfer accepted", symbol: "checkmark.circle.fill", tone: .success)
        )
        Task {
            try? await runtime.respondToIncomingRequest(.acceptAll(requestID: request.id))
        }
    }

    func acceptIncomingRequest(fileIDs: Set<String>) {
        guard let request = incomingRequest else { return }
        incomingRequest = nil
        let acceptedCount = fileIDs.count
        logger.emit(
            level: .info,
            event: acceptedCount == request.files.count ? "transfer.incoming.accepted" : "transfer.incoming.accepted_subset",
            scope: "TransferFeatureStore",
            attributes: [
                .string("transfer.request_id", request.id),
                .int("transfer.accepted_file_count", acceptedCount)
            ]
        )
        showFeedback(
            TransferFeedback(
                message: acceptedCount == request.files.count ? "Transfer accepted" : "\(acceptedCount) files accepted",
                symbol: "checkmark.circle.fill",
                tone: .success
            )
        )
        Task {
            try? await runtime.respondToIncomingRequest(.acceptSubset(requestID: request.id, fileIDs: fileIDs))
        }
    }

    func dismissProgress() {
        cancelProgressCompletionTask()
        activeTransfer = nil
    }

    func cancelActiveTransfer() {
        guard let activeTransfer else { return }
        cancelProgressCompletionTask()
        logger.emit(
            level: .notice,
            event: "transfer.send.canceled",
            scope: "TransferFeatureStore",
            attributes: [.string("transfer.session_id", activeTransfer.id)]
        )
        showFeedback(
            TransferFeedback(message: "Transfer canceled", symbol: "xmark.circle.fill", tone: .destructive)
        )
        Task {
            try? await runtime.cancelActiveTransfer(activeTransfer.id)
            self.activeTransfer = nil
        }
    }

    func clearHistory() {
        historyEntries.removeAll()
    }

    func persistSettings() {
        if requirePIN {
            ensureIncomingPIN()
        }
        logger.emit(
            level: .info,
            event: "settings.persist.requested",
            scope: "TransferFeatureStore",
            attributes: settingsAttributes()
        )
        settingsPersistence.save(makeSnapshot())
        logger.emit(
            level: .info,
            event: "settings.persist.succeeded",
            scope: "TransferFeatureStore",
            attributes: settingsAttributes()
        )
        showFeedback(
            TransferFeedback(message: "Settings saved", symbol: "checkmark.circle.fill", tone: .success)
        )
        Task {
            do {
                try await runtime.updateSettings(currentProtocolSettings)
                logger.emit(
                    level: .info,
                    event: "settings.runtime_update.succeeded",
                    scope: "TransferFeatureStore",
                    attributes: settingsAttributes()
                )
            } catch {
                recordError(event: "settings.runtime_update.failed", error: error)
                showFeedback(
                    TransferFeedback(message: "Settings could not be applied", symbol: "exclamationmark.triangle.fill", tone: .destructive)
                )
            }
        }
    }

    func updateSaveLocation(_ url: URL) {
        saveLocation = url.path
        persistSettings()
        showFeedback(
            TransferFeedback(message: "Save location changed", symbol: "folder.fill", tone: .success)
        )
    }

    func ensureIncomingPIN() {
        incomingPIN = resolvedIncomingPIN
    }

    func regenerateIncomingPIN() {
        incomingPIN = TransferProtocolSettings.generateIncomingPIN()
        logger.emit(level: .notice, event: "settings.persist.requested", scope: "TransferFeatureStore", attributes: settingsAttributes())
        persistSettings()
        showFeedback(
            TransferFeedback(message: "Incoming PIN regenerated", symbol: "number.circle.fill", tone: .success)
        )
    }

    func updateIncomingPIN(_ candidate: String) -> Bool {
        guard let normalized = TransferProtocolSettings.normalizedIncomingPIN(from: candidate) else {
            logger.emit(
                level: .warning,
                event: "settings.runtime_update.failed",
                scope: "TransferFeatureStore",
                attributes: [
                    .string("error.message", "Incoming PIN must be exactly \(TransferProtocolSettings.incomingPINLength) digits"),
                    .string("error.type", "validation")
                ]
            )
            showFeedback(
                TransferFeedback(
                    message: "Incoming PIN must be exactly \(TransferProtocolSettings.incomingPINLength) digits",
                    symbol: "exclamationmark.triangle.fill",
                    tone: .destructive
                )
            )
            return false
        }

        incomingPIN = normalized
        persistSettings()
        showFeedback(
            TransferFeedback(message: "Incoming PIN updated", symbol: "number.circle.fill", tone: .success)
        )
        return true
    }

    private func bindRuntimeStreamsIfNeeded() {
        guard observationTasks.isEmpty else { return }

        observationTasks = [
            Task { [weak self] in
                guard let self else { return }
                let stream = await self.runtime.discoveredPeers()
                for await peers in stream {
                    self.nearbyPeers = peers
                }
            },
            Task { [weak self] in
                guard let self else { return }
                let stream = await self.runtime.inboundRequests()
                for await request in stream {
                    self.incomingRequest = request
                    self.logger.emit(
                        level: .info,
                        event: "transfer.incoming.prompt_displayed",
                        scope: "TransferFeatureStore",
                        attributes: [
                            .string("transfer.request_id", request.id),
                            .int("transfer.file_count", request.files.count)
                        ]
                    )
                }
            },
            Task { [weak self] in
                guard let self else { return }
                let stream = await self.runtime.progressEvents()
                for await progress in stream {
                    self.cancelProgressCompletionTask()
                    self.activeTransfer = progress
                    if progress.progress >= 1 {
                        self.logger.emit(
                            level: .info,
                            event: "transfer.send.completed",
                            scope: "TransferFeatureStore",
                            attributes: [
                                .string("transfer.session_id", progress.id),
                                .string("transfer.file_name", progress.fileName)
                            ]
                        )
                        self.showFeedback(
                            TransferFeedback(
                                message: "Transfer completed",
                                symbol: "checkmark.circle.fill",
                                tone: .success
                            )
                        )
                        self.scheduleProgressCompletionDismiss(for: progress)
                    }
                }
            }
        ]
    }

    private func scheduleProgressCompletionDismiss(for progress: ActiveTransferProgress) {
        progressCompletionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 850_000_000)
            guard !Task.isCancelled else { return }
            if self?.activeTransfer?.id == progress.id {
                self?.activeTransfer = nil
                self?.progressCompletionTask = nil
            }
        }
    }

    private func cancelProgressCompletionTask() {
        progressCompletionTask?.cancel()
        progressCompletionTask = nil
    }

    private func showFeedback(_ newFeedback: TransferFeedback) {
        feedbackDismissTask?.cancel()
        feedback = newFeedback
        feedbackDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            if self?.feedback?.id == newFeedback.id {
                self?.feedback = nil
                self?.feedbackDismissTask = nil
            }
        }
    }

    private func makeSnapshot() -> TransferSettingsSnapshot {
        TransferSettingsSnapshot(
            quickSave: quickSave,
            appearance: appearance,
            accentColor: accentColor,
            language: language,
            minimizeToMenuBar: minimizeToMenuBar,
            launchAtLogin: launchAtLogin,
            reduceMotion: reduceMotion,
            autoAcceptFavorites: autoAcceptFavorites,
            protocolSettings: currentProtocolSettings
        )
    }

    private var resolvedIncomingPIN: String {
        TransferProtocolSettings.normalizedIncomingPIN(from: incomingPIN) ?? TransferProtocolSettings.generateIncomingPIN()
    }

    private func settingsAttributes() -> [AppLogAttribute] {
        [
            .bool("settings.require_pin", requirePIN),
            .bool("settings.allow_downloads", allowDownloads),
            .bool("settings.use_https", useHTTPS),
            .string("settings.quick_save_mode", quickSave.rawValue)
        ]
    }

    private func recordError(event: String, error: any Error) {
        lastErrorMessage = error.localizedDescription
        logger.emit(
            level: .error,
            event: event,
            scope: "TransferFeatureStore",
            attributes: [
                .string("result", "failure"),
                .string("error.message", error.localizedDescription),
                .string("error.type", String(describing: type(of: error)))
            ]
        )
    }

    private static func makeStagedItem(url: URL) -> StagedTransferItem {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        let byteCount = values?.fileSize.map(Int64.init)
        let itemCountLabel = (values?.isDirectory == true) ? "folder ready to send" : "ready to send"
        let subtitle: String
        if let byteCount {
            subtitle = "\(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)) · \(itemCountLabel)"
        } else {
            subtitle = itemCountLabel
        }
        return StagedTransferItem(
            id: url.absoluteString,
            fileURL: url,
            name: url.lastPathComponent,
            subtitle: subtitle,
            fileTypeSymbol: values?.isDirectory == true ? "folder.fill" : "doc.fill",
            byteCount: byteCount
        )
    }
}
