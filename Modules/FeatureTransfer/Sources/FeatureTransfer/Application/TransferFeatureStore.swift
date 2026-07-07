import Foundation
import Observation

@MainActor
@Observable
final class TransferFeatureStore {
    var screen: Screen = .receive
    var quickSave: QuickSaveMode
    var appearance: AppearanceSetting
    var language: LanguageSetting
    var minimizeToMenuBar: Bool
    var launchAtLogin: Bool
    var reduceMotion: Bool
    var autoAcceptFavorites: Bool
    var deviceName: String
    var port: String
    var saveLocation: String
    var requirePIN: Bool
    var allowDownloads: Bool
    var endToEndEncryption: Bool
    var isRuntimeAvailable = false
    var runtimeStatusText = "Starting LocalDrop runtime…"
    var nearbyPeers: [NearbyPeerItem] = []
    var stagedItems: [StagedTransferItem] = []
    var historyEntries: [HistoryEntry]
    var incomingRequest: IncomingTransferRequest?
    var activeTransfer: ActiveTransferProgress?
    var lastErrorMessage: String?
    private let runtime: any TransferRuntime
    private let settingsPersistence: any TransferSettingsPersisting
    private var hasStarted = false
    private var observationTasks: [Task<Void, Never>] = []

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
        self.language = snapshot.language
        self.minimizeToMenuBar = snapshot.minimizeToMenuBar
        self.launchAtLogin = snapshot.launchAtLogin
        self.reduceMotion = snapshot.reduceMotion
        self.autoAcceptFavorites = snapshot.autoAcceptFavorites
        self.deviceName = snapshot.protocolSettings.deviceName
        self.port = String(snapshot.protocolSettings.tcpPort)
        self.saveLocation = snapshot.protocolSettings.saveLocation.path
        self.requirePIN = snapshot.protocolSettings.requirePIN
        self.allowDownloads = snapshot.protocolSettings.allowDownloads
        self.endToEndEncryption = snapshot.protocolSettings.endToEndEncryption
        self.historyEntries = historyEntries
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
            allowDownloads: allowDownloads,
            endToEndEncryption: endToEndEncryption,
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
        await runtime.stop()
    }

    func refreshNearbyPeers() {
        Task {
            await runtime.refreshDiscovery()
        }
    }

    func stageDroppedItems(_ urls: [URL]) {
        let staged = urls.map(Self.makeStagedItem(url:))
        stagedItems = staged
        Task {
            await runtime.stage(staged)
        }
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
        Task {
            try? await runtime.respondToIncomingRequest(.reject(requestID: request.id))
        }
    }

    func acceptIncomingRequest() {
        guard let request = incomingRequest else { return }
        incomingRequest = nil
        Task {
            try? await runtime.respondToIncomingRequest(.acceptAll(requestID: request.id))
        }
    }

    func dismissProgress() {
        activeTransfer = nil
    }

    func cancelActiveTransfer() {
        guard let activeTransfer else { return }
        Task {
            try? await runtime.cancelActiveTransfer(activeTransfer.id)
            self.activeTransfer = nil
        }
    }

    func clearHistory() {
        historyEntries.removeAll()
    }

    func persistSettings() {
        settingsPersistence.save(makeSnapshot())
        Task {
            try? await runtime.updateSettings(currentProtocolSettings)
        }
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
                    self.activeTransfer = progress
                }
            }
        ]
    }

    private func makeSnapshot() -> TransferSettingsSnapshot {
        TransferSettingsSnapshot(
            quickSave: quickSave,
            appearance: appearance,
            language: language,
            minimizeToMenuBar: minimizeToMenuBar,
            launchAtLogin: launchAtLogin,
            reduceMotion: reduceMotion,
            autoAcceptFavorites: autoAcceptFavorites,
            protocolSettings: currentProtocolSettings
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
