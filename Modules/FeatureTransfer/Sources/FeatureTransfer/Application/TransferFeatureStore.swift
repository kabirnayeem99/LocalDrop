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
        historyEntries: [HistoryEntry] = HistoryEntry.samples
    ) {
        self.runtime = runtime
        self.settingsPersistence = settingsPersistence
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

        do {
            try await runtime.start()
            isRuntimeAvailable = true
            runtimeStatusText = "Discoverable"
            await runtime.refreshDiscovery()
        } catch {
            isRuntimeAvailable = false
            runtimeStatusText = "Unavailable"
            lastErrorMessage = error.localizedDescription
        }
    }

    func stop() async {
        cancelProgressCompletionTask()
        await runtime.stop()
    }

    func refreshNearbyPeers() {
        refreshDiscovery(shouldShowFeedback: true, scan: false)
    }

    func scanNearbyPeers() {
        refreshDiscovery(shouldShowFeedback: true, scan: true)
    }

    private func refreshDiscovery(shouldShowFeedback: Bool, scan: Bool) {
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
        Task {
            await runtime.stage(stagedItems)
        }
    }

    func send(to peerID: NearbyPeerItem.ID) {
        Task {
            do {
                await runtime.stage(stagedItems)
                try await runtime.sendStagedItems(to: peerID, pin: nil)
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func declineIncomingRequest() {
        guard let request = incomingRequest else { return }
        incomingRequest = nil
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
        settingsPersistence.save(makeSnapshot())
        showFeedback(
            TransferFeedback(message: "Settings saved", symbol: "checkmark.circle.fill", tone: .success)
        )
        Task {
            do {
                try await runtime.updateSettings(currentProtocolSettings)
            } catch {
                lastErrorMessage = error.localizedDescription
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
        persistSettings()
        showFeedback(
            TransferFeedback(message: "Incoming PIN regenerated", symbol: "number.circle.fill", tone: .success)
        )
    }

    func updateIncomingPIN(_ candidate: String) -> Bool {
        guard let normalized = TransferProtocolSettings.normalizedIncomingPIN(from: candidate) else {
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
                }
            },
            Task { [weak self] in
                guard let self else { return }
                let stream = await self.runtime.progressEvents()
                for await progress in stream {
                    self.cancelProgressCompletionTask()
                    self.activeTransfer = progress
                    if progress.progress >= 1 {
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
