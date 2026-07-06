import Foundation

public struct LocalSendRuntimeConfiguration: Sendable {
    public var registerInfo: RegisterInfo
    public var tcpPort: UInt16
    public var multicastPort: UInt16
    public var multicastHost: String
    public var storageDirectory: URL
    public var pin: String?
    public var uploadPolicy: PrepareUploadPolicy
    public var downloadInventoryProvider: @Sendable () async -> [String: LocalSharedFile]
    public var allowDownloads: Bool
    public var limits: LocalSendRuntimeLimits

    public init(
        registerInfo: RegisterInfo,
        tcpPort: UInt16 = 0,
        multicastPort: UInt16 = 53317,
        multicastHost: String = "224.0.0.167",
        storageDirectory: URL,
        pin: String? = nil,
        uploadPolicy: PrepareUploadPolicy = .acceptAll,
        downloadInventoryProvider: @escaping @Sendable () async -> [String: LocalSharedFile] = { [:] },
        allowDownloads: Bool = true,
        limits: LocalSendRuntimeLimits = .init()
    ) {
        self.registerInfo = registerInfo
        self.tcpPort = tcpPort
        self.multicastPort = multicastPort
        self.multicastHost = multicastHost
        self.storageDirectory = storageDirectory
        self.pin = pin
        self.uploadPolicy = uploadPolicy
        self.downloadInventoryProvider = downloadInventoryProvider
        self.allowDownloads = allowDownloads
        self.limits = limits
    }
}

public struct LocalSendClientFactory: Sendable {
    private let timeoutConfiguration: LocalSendClientTimeoutConfiguration

    public init(timeoutConfiguration: LocalSendClientTimeoutConfiguration = .init()) {
        self.timeoutConfiguration = timeoutConfiguration
    }

    public func makeClient(host: String, port: Int, protocolType: ProtocolType, fingerprint: String) -> LocalSendClient {
        LocalSendClient(
            peer: RemotePeer(host: host, port: port, protocolType: protocolType),
            expectedFingerprint: fingerprint,
            timeoutConfiguration: timeoutConfiguration
        )
    }
}

public final class LocalSendNode: @unchecked Sendable {
    private let runtimeConfiguration: LocalSendRuntimeConfiguration
    private let certificateAuthority: CertificateAuthority
    private let clientFactory: LocalSendClientFactory
    private let localIdentity: LocalIdentity
    private let server: LocalSendServer
    private let serverRuntime: LocalSendServerRuntime
    private let discoveryService: DiscoveryService

    public init(
        runtimeConfiguration: LocalSendRuntimeConfiguration,
        certificateStore: any CertificateStore,
        clientFactory: LocalSendClientFactory = .init()
    ) throws {
        self.runtimeConfiguration = runtimeConfiguration
        self.certificateAuthority = CertificateAuthority(store: certificateStore)
        self.clientFactory = clientFactory
        self.localIdentity = try certificateAuthority.loadOrCreateIdentity()

        let inventory = runtimeConfiguration.downloadInventoryProvider
        self.server = LocalSendServer(
            configuration: LocalSendServerConfiguration(
                registerInfo: runtimeConfiguration.registerInfo,
                pin: runtimeConfiguration.pin,
                uploadPolicy: runtimeConfiguration.uploadPolicy,
                sharedFiles: [:],
                sharedFilesProvider: inventory,
                allowDownloads: runtimeConfiguration.allowDownloads,
                storageDirectory: runtimeConfiguration.storageDirectory
            )
        )
        self.serverRuntime = LocalSendServerRuntime(
            server: server,
            tlsConfiguration: LocalSendTLSConfiguration(identity: localIdentity),
            port: runtimeConfiguration.tcpPort,
            limits: runtimeConfiguration.limits,
            temporaryDirectory: runtimeConfiguration.storageDirectory
        )

        let callbackBox = DiscoveryCallbackBox()
        let discoveryService = DiscoveryService(
            listener: try MulticastListenerRuntime(
            multicastHost: runtimeConfiguration.multicastHost,
            port: runtimeConfiguration.multicastPort,
            selfFingerprint: runtimeConfiguration.registerInfo.fingerprint
        ) { peer in
            Task { await callbackBox.service?.handle(peer: peer, localInfo: runtimeConfiguration.registerInfo) }
        },
            announcer: try MulticastAnnouncerRuntime(
                multicastHost: runtimeConfiguration.multicastHost,
                port: runtimeConfiguration.multicastPort
            )
        ) { _ in
            false
        }
        callbackBox.service = discoveryService
        self.discoveryService = discoveryService
    }

    public func start() async throws {
        try await serverRuntime.start()
        _ = try await serverRuntime.waitUntilReady()
        discoveryService.start()
    }

    public func stop() async {
        discoveryService.stop()
        await serverRuntime.stop()
    }

    public func announce() async throws {
        let endpoint = try await serverRuntime.waitUntilReady()
        let info = runtimeConfiguration.registerInfo
        let message = MulticastMessage(
            alias: info.alias,
            version: info.version,
            deviceModel: info.deviceModel,
            deviceType: info.deviceType,
            fingerprint: info.fingerprint,
            port: endpoint.port,
            protocolType: endpoint.protocolType,
            download: info.download,
            announce: true
        )
        try await discoveryService.announce(message)
    }

    public func discoverPeers() -> AsyncStream<DiscoveredPeer> {
        discoveryService.stream()
    }

    public func makeClient(host: String, port: Int, protocolType: ProtocolType, fingerprint: String) -> LocalSendClient {
        clientFactory.makeClient(host: host, port: port, protocolType: protocolType, fingerprint: fingerprint)
    }
}

private final class DiscoveryCallbackBox: @unchecked Sendable {
    var service: DiscoveryService?
}
