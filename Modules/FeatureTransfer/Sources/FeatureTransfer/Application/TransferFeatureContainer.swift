import Foundation
import LocalSendKit
import SwiftUI

@MainActor
public final class TransferFeatureContainer {
    let store: TransferFeatureStore

    init(store: TransferFeatureStore) {
        self.store = store
    }

    public var rootView: some View {
        RootView(store: store)
    }

    public func startIfNeeded() async {
        await store.start()
    }

    public func stop() async {
        await store.stop()
    }

    public static func live(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> TransferFeatureContainer {
        let baseDirectory = applicationSupportDirectory(fileManager: fileManager)
        let saveLocation = defaultSaveLocation(fileManager: fileManager)
        let deviceName = Host.current().localizedName ?? "LocalDrop Mac"
        let defaultSnapshot = TransferSettingsSnapshot.default(deviceName: deviceName, saveLocation: saveLocation)
        let settingsPersistence = SettingsPersistenceAdapter(
            userDefaults: userDefaults,
            fallback: defaultSnapshot
        )
        let snapshot = settingsPersistence.load()

        do {
            let identityURL = baseDirectory.appendingPathComponent("identity.json")
            let certificateStore = FileCertificateStore(identityURL: identityURL)
            let makeComponents: @Sendable (TransferProtocolSettings) throws -> LiveRuntimeComponents = { settings in
                let identity = try CertificateAuthority(store: certificateStore).loadOrCreateIdentity()
                let bridge = IncomingTransferRequestBridge()
                let registerInfo = RegisterInfo(
                    alias: settings.deviceName,
                    deviceModel: "LocalDrop for macOS",
                    deviceType: .desktop,
                    fingerprint: identity.fingerprint,
                    port: settings.tcpPort,
                    protocolType: .https,
                    download: settings.allowDownloads
                )
                let runtimeConfiguration = LocalSendRuntimeConfiguration(
                    registerInfo: registerInfo,
                    tcpPort: UInt16(clamping: settings.tcpPort),
                    storageDirectory: settings.saveLocation,
                    pin: settings.requirePIN ? "000000" : nil,
                    incomingRequestBridge: bridge,
                    allowDownloads: settings.allowDownloads
                )
                let node = try LocalSendNode(
                    runtimeConfiguration: runtimeConfiguration,
                    certificateStore: certificateStore
                )
                return LiveRuntimeComponents(node: node, registerInfo: registerInfo)
            }
            let runtime = LocalSendRuntimeAdapter(
                components: try makeComponents(snapshot.protocolSettings),
                settings: snapshot.protocolSettings,
                makeComponents: makeComponents
            )
            let store = TransferFeatureStore(
                runtime: runtime,
                settingsPersistence: settingsPersistence,
                snapshot: snapshot
            )
            return TransferFeatureContainer(store: store)
        } catch {
            let runtime = NoopTransferRuntime()
            let store = TransferFeatureStore(
                runtime: runtime,
                settingsPersistence: settingsPersistence,
                snapshot: snapshot
            )
            store.lastErrorMessage = error.localizedDescription
            store.runtimeStatusText = "Unavailable"
            return TransferFeatureContainer(store: store)
        }
    }

    private static func applicationSupportDirectory(fileManager: FileManager) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return root.appendingPathComponent("LocalDrop", isDirectory: true)
    }

    private static func defaultSaveLocation(fileManager: FileManager) -> URL {
        fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
    }
}

actor NoopTransferRuntime: TransferRuntime {
    func start() async throws {}
    func stop() async {}
    func refreshDiscovery() async {}
    func discoveredPeers() async -> AsyncStream<[NearbyPeerItem]> { AsyncStream { $0.yield([]) } }
    func inboundRequests() async -> AsyncStream<IncomingTransferRequest> { AsyncStream { _ in } }
    func progressEvents() async -> AsyncStream<ActiveTransferProgress> { AsyncStream { _ in } }
    func updateSettings(_ settings: TransferProtocolSettings) async throws {}
    func stage(_ items: [StagedTransferItem]) async {}
    func sendStagedItems(to peerID: NearbyPeerItem.ID, pin: String?) async throws {}
    func respondToIncomingRequest(_ response: IncomingTransferDecision) async throws {}
    func cancelActiveTransfer(_ id: ActiveTransferProgress.ID) async throws {}
}
