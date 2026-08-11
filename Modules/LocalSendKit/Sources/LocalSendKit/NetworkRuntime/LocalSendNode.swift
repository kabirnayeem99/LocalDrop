import AppLogging
import Foundation

public struct LocalSendRuntimeConfiguration: Sendable {
    public var registerInfo: RegisterInfo
    public var protocolType: ProtocolType
    public var tcpPort: UInt16
    public var multicastPort: UInt16
    public var multicastHost: String
    public var storageDirectory: URL
    public var pin: String?
    public var uploadPolicy: PrepareUploadPolicy
    public var incomingRequestBridge: IncomingTransferRequestBridge?
    public var downloadInventoryProvider: @Sendable () async -> [String: LocalSharedFile]
    public var allowDownloads: Bool
    public var limits: LocalSendRuntimeLimits

    public init(
        registerInfo: RegisterInfo,
        protocolType: ProtocolType = .https,
        tcpPort: UInt16 = 0,
        multicastPort: UInt16 = 53317,
        multicastHost: String = "224.0.0.167",
        storageDirectory: URL,
        pin: String? = nil,
        uploadPolicy: PrepareUploadPolicy = .acceptAll,
        incomingRequestBridge: IncomingTransferRequestBridge? = nil,
        downloadInventoryProvider: @escaping @Sendable () async -> [String: LocalSharedFile] = { [:] },
        allowDownloads: Bool = true,
        limits: LocalSendRuntimeLimits = .init()
    ) {
        var registerInfo = registerInfo
        registerInfo.protocolType = protocolType
        self.registerInfo = registerInfo
        self.protocolType = protocolType
        self.tcpPort = tcpPort
        self.multicastPort = multicastPort
        self.multicastHost = multicastHost
        self.storageDirectory = storageDirectory
        self.pin = pin
        self.uploadPolicy = uploadPolicy
        self.incomingRequestBridge = incomingRequestBridge
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

    /// `apiVersion` defaults to `.v2` so existing call sites keep exactly today's behaviour; pass
    /// the discovered peer's version to get `ApiRoute.target`'s per-peer routing
    /// (`common/lib/api_route_builder.dart:28-36`).
    public func makeClient(
        host: String,
        port: Int,
        protocolType: ProtocolType,
        fingerprint: String,
        apiVersion: LocalSendKit.APIVersion = .v2
    ) -> LocalSendClient {
        LocalSendClient(
            peer: RemotePeer(host: host, port: port, protocolType: protocolType, apiVersion: apiVersion),
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
    private let runtimeStateStore: LocalSendRuntimeStateStore
    private let logger: AppLogger

    public init(
        runtimeConfiguration: LocalSendRuntimeConfiguration,
        certificateStore: any CertificateStore,
        clientFactory: LocalSendClientFactory = .init(),
        logger: AppLogger = .disabled()
    ) throws {
        self.runtimeConfiguration = runtimeConfiguration
        self.certificateAuthority = CertificateAuthority(store: certificateStore)
        self.clientFactory = clientFactory
        self.logger = logger
        self.localIdentity = try certificateAuthority.loadOrCreateIdentity()
        let runtimeStateStore = LocalSendRuntimeStateStore()
        self.runtimeStateStore = runtimeStateStore

        let inventory = runtimeConfiguration.downloadInventoryProvider
        // Created before the server because the server's `peerRegistrationObserver` has to reach
        // the discovery service, which does not exist yet. Same late-binding trick already used for
        // the multicast listener callback below.
        let callbackBox = DiscoveryCallbackBox()
        self.server = LocalSendServer(
            configuration: LocalSendServerConfiguration(
                registerInfo: runtimeConfiguration.registerInfo,
                pin: runtimeConfiguration.pin,
                uploadPolicy: runtimeConfiguration.uploadPolicy,
                incomingRequestBridge: runtimeConfiguration.incomingRequestBridge,
                sharedFiles: [:],
                sharedFilesProvider: inventory,
                allowDownloads: runtimeConfiguration.allowDownloads,
                storageDirectory: runtimeConfiguration.storageDirectory,
                stateObserver: { [incomingRequestBridge = runtimeConfiguration.incomingRequestBridge] snapshot in
                    let pendingRequest: IncomingTransferRequest?
                    if let incomingRequestBridge {
                        pendingRequest = await incomingRequestBridge.currentRequest()
                    } else {
                        pendingRequest = nil
                    }
                    await runtimeStateStore.update { state in
                        state.receiveSession = snapshot.receiveSession
                        state.sendSessions = snapshot.sendSessions
                        state.pendingIncomingRequest = pendingRequest
                    }
                },
                peerRegistrationObserver: { callerIP, info in
                    await callbackBox.service?.registerInboundPeer(host: callerIP, info: info)
                },
                logger: logger
            )
        )
        let serverRuntime = LocalSendServerRuntime(
            server: server,
            tlsConfiguration: LocalSendTLSConfiguration(identity: localIdentity),
            protocolType: runtimeConfiguration.protocolType,
            port: runtimeConfiguration.tcpPort,
            limits: runtimeConfiguration.limits,
            // NOT `storageDirectory` itself: staging must be a directory we exclusively own (so it
            // can be swept) that is still on the same volume as the destination (so the final move
            // is an atomic rename). A child rather than a sibling, because a sibling is not
            // guaranteed to be on the same volume — or writable — when the save directory is a
            // mount point or the user's home. `ReceiveSession.resolveDestination` is what keeps a
            // sender-supplied name from resolving into it. See `UploadStagingArea`.
            temporaryDirectory: UploadStagingArea.url(inside: runtimeConfiguration.storageDirectory),
            logger: logger
        )
        self.serverRuntime = serverRuntime

        let discoveryService = DiscoveryService(
            listener: try MulticastListenerRuntime(
                multicastHost: runtimeConfiguration.multicastHost,
                port: runtimeConfiguration.multicastPort,
                selfFingerprint: runtimeConfiguration.registerInfo.fingerprint,
                logger: logger
            ) { peer in
                Task { await callbackBox.service?.handle(peer: peer, localInfo: runtimeConfiguration.registerInfo) }
            },
            announcer: try MulticastAnnouncerRuntime(
                multicastHost: runtimeConfiguration.multicastHost,
                port: runtimeConfiguration.multicastPort,
                logger: logger
            ),
            // Answer an announcement over TCP `POST /register` first, exactly as
            // `multicast_discovery.dart:_answerAnnouncement` does. Returning `false` on any failure
            // hands off to `DiscoveryService`'s existing UDP fallback, so a peer on a network where
            // TCP back-connections are blocked is still answered.
            registerResponder: { [clientFactory] peer in
                // The announcement carried our advertised `registerInfo`, whose port is the
                // CONFIGURED one (often 0 = "any"). The peer has to be told the port we actually
                // bound, or it will call back to the wrong place.
                guard let endpoint = try? await serverRuntime.waitUntilReady() else {
                    return false
                }
                var localInfo = runtimeConfiguration.registerInfo
                localInfo.port = endpoint.port
                localInfo.protocolType = endpoint.protocolType

                // `RegisterInfo.port` is optional on the wire; `InfoRegisterDtoExt.toDevice`
                // resolves an absent port to the receiver's own, so the shared default port is the
                // faithful fallback.
                let peerPort = peer.info.port ?? Int(runtimeConfiguration.multicastPort)
                // The version goes onto the client's peer, not just onto the `register` call: the
                // same routing rule governs every later request to this device
                // (`common/lib/api_route_builder.dart:28-36`).
                let apiVersion = LocalSendKit.APIVersion(protocolVersion: peer.info.version)
                let client = clientFactory.makeClient(
                    host: peer.host,
                    port: peerPort,
                    protocolType: peer.info.protocolType ?? .https,
                    fingerprint: peer.info.fingerprint,
                    apiVersion: apiVersion
                )
                do {
                    _ = try await client.register(with: localInfo, apiVersion: apiVersion)
                    logger.emit(
                        level: .debug,
                        event: "discovery.register_reply.succeeded",
                        scope: "LocalSendNode",
                        attributes: [
                            .string("peer.alias", peer.info.alias),
                            .string("peer.host", peer.host),
                            .string("localsend.api_version", apiVersion.rawValue)
                        ]
                    )
                    return true
                } catch {
                    logger.emit(
                        level: .debug,
                        event: "discovery.register_reply.failed",
                        scope: "LocalSendNode",
                        attributes: [
                            .string("peer.alias", peer.info.alias),
                            .string("peer.host", peer.host),
                            .string("error.message", error.localizedDescription),
                            .string("error.type", String(describing: type(of: error)))
                        ]
                    )
                    return false
                }
            },
            peersObserver: { peers in
                await runtimeStateStore.update { state in
                    state.discoveredPeers = peers
                }
            },
            // Peers that launch after us never saw our start-up announcement. Re-announcing on a
            // timer is what makes us discoverable to them without requiring a restart.
            reannounce: {
                guard let endpoint = try? await serverRuntime.waitUntilReady() else {
                    return
                }
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
                try? await callbackBox.service?.announce(message)
            },
            logger: logger
        )
        callbackBox.service = discoveryService
        self.discoveryService = discoveryService
    }

    public func start() async throws {
        logger.emit(level: .info, event: "app.runtime.start.requested", scope: "LocalSendNode")
        await runtimeStateStore.update { $0.lifecycle = .starting }
        try await serverRuntime.start()
        let endpoint = try await serverRuntime.waitUntilReady()
        await runtimeStateStore.update {
            $0.lifecycle = .running(
                LocalSendServerRuntimeBoundEndpoint(
                    host: endpoint.host,
                    port: endpoint.port,
                    protocolType: endpoint.protocolType
                )
            )
        }
        discoveryService.start()
        logger.emit(
            level: .info,
            event: "app.runtime.start.succeeded",
            scope: "LocalSendNode",
            attributes: [
                .string("server.address", endpoint.host),
                .int("server.port", endpoint.port),
                .string("localsend.protocol_type", endpoint.protocolType.rawValue)
            ]
        )
    }

    public func stop() async {
        logger.emit(level: .info, event: "app.runtime.stop.requested", scope: "LocalSendNode")
        await runtimeStateStore.update { $0.lifecycle = .stopping }
        if let incomingRequestBridge = runtimeConfiguration.incomingRequestBridge {
            await incomingRequestBridge.finishPending()
        }
        discoveryService.stop()
        await serverRuntime.stop()
        await runtimeStateStore.update {
            $0.lifecycle = .stopped
            $0.pendingIncomingRequest = nil
        }
        logger.emit(level: .info, event: "app.runtime.stop.completed", scope: "LocalSendNode")
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
        logger.emit(
            level: .debug,
            event: "discovery.announce.started",
            scope: "LocalSendNode",
            attributes: [
                .int("server.port", endpoint.port),
                .string("localsend.protocol_type", endpoint.protocolType.rawValue)
            ]
        )
        try await discoveryService.announce(message)
        logger.emit(
            level: .debug,
            event: "discovery.announce.succeeded",
            scope: "LocalSendNode",
            attributes: [
                .int("server.port", endpoint.port),
                .string("localsend.protocol_type", endpoint.protocolType.rawValue)
            ]
        )
    }

    public func discoverPeers() -> AsyncStream<DiscoveredPeer> {
        discoveryService.stream()
    }

    public func observeRuntime() async -> AsyncStream<LocalSendRuntimeSnapshot> {
        await runtimeStateStore.stream()
    }

    public func runtimeSnapshot() async -> LocalSendRuntimeSnapshot {
        await runtimeStateStore.currentSnapshot()
    }

    /// Prompts and the network-side withdrawals of those prompts (sender-initiated `/cancel` during
    /// the accept/decline prompt), on ONE ordered stream.
    ///
    /// The single stream is the ordering guarantee: a `.withdrawal` can only ever follow the
    /// `.request` it refers to, and carrying both on the same continuation set is what preserves
    /// that for every consumer. See `IncomingTransferRequestBridge.events()`.
    public func incomingTransferRequestEvents() async -> AsyncStream<IncomingTransferRequestEvent> {
        if let incomingRequestBridge = runtimeConfiguration.incomingRequestBridge {
            return await incomingRequestBridge.events()
        }
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    public func respondToIncomingTransfer(
        requestID: String,
        decision: IncomingTransferDecision
    ) async throws {
        guard let incomingRequestBridge = runtimeConfiguration.incomingRequestBridge else {
            throw LocalSendRuntimeError.incomingTransferRequestNotPending
        }
        try await incomingRequestBridge.respond(to: requestID, decision: decision)
    }

    public func makeClient(
        host: String,
        port: Int,
        protocolType: ProtocolType,
        fingerprint: String,
        apiVersion: LocalSendKit.APIVersion = .v2
    ) -> LocalSendClient {
        clientFactory.makeClient(
            host: host,
            port: port,
            protocolType: protocolType,
            fingerprint: fingerprint,
            apiVersion: apiVersion
        )
    }

    /// Tears down the live receive session because the LOCAL user cancelled it, and publishes the
    /// resulting `.canceled` snapshot through `observeRuntime()`.
    ///
    /// Returns `false` when no live session matches `sessionId` (already finished, already
    /// cancelled, or never existed), which makes repeated calls harmless.
    public func cancelReceiveSession(sessionId: String) async -> Bool {
        await server.cancelReceiveSession(sessionId: sessionId)
    }
}

private final class DiscoveryCallbackBox: @unchecked Sendable {
    var service: DiscoveryService?
}

private actor LocalSendRuntimeStateStore {
    private var currentValue = LocalSendRuntimeSnapshot(lifecycle: .stopped)
    private var continuations: [UUID: AsyncStream<LocalSendRuntimeSnapshot>.Continuation] = [:]

    func update(_ mutate: (inout LocalSendRuntimeSnapshot) -> Void) {
        mutate(&currentValue)
        for continuation in continuations.values {
            continuation.yield(currentValue)
        }
    }

    func currentSnapshot() -> LocalSendRuntimeSnapshot {
        currentValue
    }

    func stream() -> AsyncStream<LocalSendRuntimeSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(currentValue)
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeContinuation(id: id)
                }
            }
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
