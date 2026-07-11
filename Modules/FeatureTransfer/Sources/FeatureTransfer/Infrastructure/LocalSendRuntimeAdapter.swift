import AppLogging
import Foundation
import LocalSendKit
import UniformTypeIdentifiers

struct LiveRuntimeComponents {
    let node: LocalSendNode
    let registerInfo: RegisterInfo
}

actor LocalSendRuntimeAdapter: TransferRuntime {
    private var components: LiveRuntimeComponents
    private let makeComponents: @Sendable (TransferProtocolSettings) throws -> LiveRuntimeComponents
    private var currentSettings: TransferProtocolSettings
    private var stagedItems: [StagedTransferItem] = []
    private var stateObservationTask: Task<Void, Never>?
    private var incomingObservationTask: Task<Void, Never>?
    private let peersBroadcaster = StreamBroadcaster<[NearbyPeerItem]>(initialValue: [])
    private let incomingBroadcaster = StreamBroadcaster<IncomingTransferRequest>()
    private let progressBroadcaster = StreamBroadcaster<ActiveTransferProgress>()
    private let logger: AppLogger
    private let runtimeInstanceID = UUID().uuidString.lowercased()
    private var restartGeneration = 0
    private var activeSendSession: ActiveSendSession?
    private var lastReceiveStatusKey: String?

    init(
        components: LiveRuntimeComponents,
        settings: TransferProtocolSettings,
        makeComponents: @escaping @Sendable (TransferProtocolSettings) throws -> LiveRuntimeComponents,
        logger: AppLogger = .disabled()
    ) {
        self.components = components
        self.currentSettings = settings
        self.makeComponents = makeComponents
        self.logger = logger
    }

    func start() async throws {
        logger.emit(
            level: .info,
            event: "app.runtime.start.requested",
            scope: "LocalSendRuntimeAdapter",
            context: runtimeContext(),
            attributes: [.bool("settings.use_https", currentSettings.useHTTPS)]
        )
        try await components.node.start()
        bindNodeObservers()
        try await components.node.announce()
        logger.emit(
            level: .info,
            event: "app.runtime.start.succeeded",
            scope: "LocalSendRuntimeAdapter",
            context: runtimeContext(),
            attributes: [.string("result", "success")]
        )
    }

    func stop() async {
        stateObservationTask?.cancel()
        incomingObservationTask?.cancel()
        stateObservationTask = nil
        incomingObservationTask = nil
        activeSendSession = nil
        await components.node.stop()
        await peersBroadcaster.yield([])
        await progressBroadcaster.finishCurrentValue()
        logger.emit(
            level: .info,
            event: "app.runtime.stop.completed",
            scope: "LocalSendRuntimeAdapter",
            context: runtimeContext()
        )
    }

    func refreshDiscovery() async {
        try? await components.node.announce()
        logger.emit(
            level: .info,
            event: "discovery.announce.succeeded",
            scope: "LocalSendRuntimeAdapter",
            context: runtimeContext()
        )
    }

    func discoveredPeers() async -> AsyncStream<[NearbyPeerItem]> {
        await peersBroadcaster.stream()
    }

    func inboundRequests() async -> AsyncStream<IncomingTransferRequest> {
        await incomingBroadcaster.stream()
    }

    func progressEvents() async -> AsyncStream<ActiveTransferProgress> {
        await progressBroadcaster.stream()
    }

    func updateSettings(_ settings: TransferProtocolSettings) async throws {
        guard settings != currentSettings else {
            logger.emit(
                level: .notice,
                event: "settings.runtime_restart.skipped_unchanged",
                scope: "LocalSendRuntimeAdapter",
                context: runtimeContext()
            )
            return
        }

        restartGeneration += 1
        logger.emit(
            level: .notice,
            event: "settings.runtime_restart.started",
            scope: "LocalSendRuntimeAdapter",
            context: runtimeContext(),
            attributes: [
                .int("runtime.restart_generation", restartGeneration),
                .bool("settings.use_https", settings.useHTTPS)
            ]
        )
        await stop()
        let newComponents = try makeComponents(settings)
        components = newComponents
        currentSettings = settings
        try await start()
        logger.emit(
            level: .notice,
            event: "settings.runtime_restart.completed",
            scope: "LocalSendRuntimeAdapter",
            context: runtimeContext(),
            attributes: [.int("runtime.restart_generation", restartGeneration)]
        )
    }

    func stage(_ items: [StagedTransferItem]) async {
        stagedItems = items
        logger.emit(
            level: .debug,
            event: "transfer.stage.completed",
            scope: "LocalSendRuntimeAdapter",
            context: runtimeContext(),
            attributes: [.int("transfer.file_count", items.count)]
        )
    }

    func sendStagedItems(to peerID: NearbyPeerItem.ID, pin: String?) async throws {
        guard stagedItems.isEmpty == false else {
            return
        }

        let peer = try await resolvePeer(id: peerID)
        guard let port = peer.port, let protocolType = peer.protocolType else {
            throw TransferFeatureError.unreachablePeer(peer.name)
        }
        let traceID = Self.makeTraceID()
        let context = sendContext(sessionID: nil, peer: peer, traceID: traceID)
        logger.emit(
            level: .info,
            event: "transfer.send.peer_resolved",
            scope: "LocalSendRuntimeAdapter",
            context: context,
            attributes: [
                .string("peer.host", peer.host),
                .int("peer.port", port),
                .string("peer.protocol_type", protocolType.rawValue)
            ]
        )

        let files = makeFileMap(from: stagedItems)
        let request = PrepareUploadRequest(info: components.registerInfo, files: files)
        let client = components.node.makeClient(
            host: peer.host,
            port: port,
            protocolType: protocolType,
            fingerprint: peer.fingerprint
        )
        logger.emit(
            level: .info,
            event: "transfer.send.prepare_upload.started",
            scope: "LocalSendRuntimeAdapter",
            context: context,
            attributes: [.int("transfer.file_count", files.count)]
        )

        guard let prepareResponse = try await client.prepareUpload(request, pin: pin) else {
            await progressBroadcaster.finishCurrentValue()
            logger.emit(
                level: .warning,
                event: "transfer.send.prepare_upload.rejected",
                scope: "LocalSendRuntimeAdapter",
                context: context,
                attributes: [.string("result", "rejected")]
            )
            return
        }

        activeSendSession = ActiveSendSession(
            id: prepareResponse.sessionId,
            peer: peer,
            client: client,
            traceID: traceID
        )
        logger.emit(
            level: .info,
            event: "transfer.send.prepare_upload.succeeded",
            scope: "LocalSendRuntimeAdapter",
            context: sendContext(sessionID: prepareResponse.sessionId, peer: peer, traceID: traceID),
            attributes: [.int("transfer.accepted_file_count", prepareResponse.files.count)]
        )

        let acceptedItems = stagedItems.filter { prepareResponse.files[$0.id] != nil }
        let totalCount = max(acceptedItems.count, 1)

        for (index, item) in acceptedItems.enumerated() {
            guard let token = prepareResponse.files[item.id] else {
                continue
            }

            await progressBroadcaster.yield(
                ActiveTransferProgress(
                    id: prepareResponse.sessionId,
                    direction: .sending,
                    counterpartName: peer.name,
                    fileName: item.name,
                    progress: Double(index) / Double(totalCount),
                    throughput: "Preparing…",
                    etaDescription: "\(totalCount - index) item(s) remaining"
                )
            )

            let byteCount = item.byteCount ?? Int64((try? Data(contentsOf: item.fileURL).count) ?? 0)
            logger.emit(
                level: .info,
                event: "transfer.send.file_upload.started",
                scope: "LocalSendRuntimeAdapter",
                context: sendContext(sessionID: prepareResponse.sessionId, peer: peer, traceID: traceID),
                attributes: [
                    .string("transfer.file_id", item.id),
                    .string("transfer.file_name", item.name),
                    .int64("transfer.byte_count", byteCount)
                ]
            )
            try await client.upload(
                fileAt: item.fileURL,
                byteCount: byteCount,
                sessionId: prepareResponse.sessionId,
                fileId: item.id,
                token: token
            )
            logger.emit(
                level: .info,
                event: "transfer.send.file_upload.completed",
                scope: "LocalSendRuntimeAdapter",
                context: sendContext(sessionID: prepareResponse.sessionId, peer: peer, traceID: traceID),
                attributes: [
                    .string("transfer.file_id", item.id),
                    .string("transfer.file_name", item.name),
                    .int64("transfer.byte_count", byteCount)
                ]
            )

            await progressBroadcaster.yield(
                ActiveTransferProgress(
                    id: prepareResponse.sessionId,
                    direction: .sending,
                    counterpartName: peer.name,
                    fileName: item.name,
                    progress: Double(index + 1) / Double(totalCount),
                    throughput: byteCount > 0 ? ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file) : "Uploaded",
                    etaDescription: index + 1 == totalCount ? "Complete" : "\(totalCount - index - 1) item(s) remaining"
                )
            )
        }

        stagedItems.removeAll()
        activeSendSession = nil
        await progressBroadcaster.finishCurrentValue()
        logger.emit(
            level: .info,
            event: "transfer.send.completed",
            scope: "LocalSendRuntimeAdapter",
            context: sendContext(sessionID: prepareResponse.sessionId, peer: peer, traceID: traceID),
            attributes: [.int("transfer.file_count", acceptedItems.count)]
        )
    }

    func respondToIncomingRequest(_ response: IncomingTransferDecision) async throws {
        logger.emit(
            level: .info,
            event: incomingDecisionEvent(response),
            scope: "LocalSendRuntimeAdapter",
            context: runtimeContext(),
            attributes: incomingDecisionAttributes(response)
        )
        switch response {
        case .reject(let requestID):
            try await components.node.respondToIncomingTransfer(requestID: requestID, decision: .reject)
        case .acceptAll(let requestID):
            try await components.node.respondToIncomingTransfer(requestID: requestID, decision: .acceptAll)
        case .acceptSubset(let requestID, let fileIDs):
            try await components.node.respondToIncomingTransfer(requestID: requestID, decision: .acceptOnly(fileIDs))
        case .noTransferNeeded(let requestID):
            try await components.node.respondToIncomingTransfer(requestID: requestID, decision: .noTransferNeeded)
        }
    }

    func cancelActiveTransfer(_ id: ActiveTransferProgress.ID) async throws {
        if let activeSendSession, activeSendSession.id == id {
            try await activeSendSession.client.cancel(sessionId: activeSendSession.id)
            self.activeSendSession = nil
            await progressBroadcaster.finishCurrentValue()
            logger.emit(
                level: .notice,
                event: "transfer.send.canceled",
                scope: "LocalSendRuntimeAdapter",
                context: sendContext(sessionID: activeSendSession.id, peer: activeSendSession.peer, traceID: activeSendSession.traceID)
            )
        }
    }

    private func bindNodeObservers() {
        stateObservationTask?.cancel()
        incomingObservationTask?.cancel()

        stateObservationTask = Task {
            let runtimeStream = await components.node.observeRuntime()
            for await snapshot in runtimeStream {
                let peerItems = snapshot.discoveredPeers.map(NearbyPeerItem.init(peer:))
                await peersBroadcaster.yield(peerItems)
                logger.emit(
                    level: .debug,
                    event: "discovery.peer.snapshot",
                    scope: "LocalSendRuntimeAdapter",
                    context: runtimeContext(),
                    attributes: [.int("peer.count", peerItems.count)]
                )

                if let receiveSession = snapshot.receiveSession {
                    let statusProgress: Double
                    let etaDescription: String
                    switch receiveSession.status {
                    case .waiting:
                        statusProgress = 0.05
                        etaDescription = "Waiting for sender"
                    case .transferring:
                        statusProgress = 0.6
                        etaDescription = "Receiving…"
                    case .finished:
                        statusProgress = 1.0
                        etaDescription = "Complete"
                    case .canceled:
                        statusProgress = 0
                        etaDescription = "Canceled"
                    }

                    let leadFile = receiveSession.files.values.first?.file
                    if let leadFile {
                        let statusKey = "\(receiveSession.sessionId):\(receiveSession.status)"
                        if lastReceiveStatusKey != statusKey {
                            lastReceiveStatusKey = statusKey
                            logger.emit(
                                level: .info,
                                event: receiveStatusEvent(receiveSession.status),
                                scope: "LocalSendRuntimeAdapter",
                                context: AppLogContext(
                                    attributes: runtimeContext().attributes + [
                                        .string("transfer.session_id", receiveSession.sessionId),
                                        .string("transfer.direction", "receiving")
                                    ]
                                ),
                                attributes: [.string("transfer.file_name", leadFile.fileName)]
                            )
                        }
                        await progressBroadcaster.yield(
                            ActiveTransferProgress(
                                id: receiveSession.sessionId,
                                direction: .receiving,
                                counterpartName: receiveSession.senderInfo.alias,
                                fileName: leadFile.fileName,
                                progress: statusProgress,
                                throughput: receiveSession.status == .finished ? "Saved" : "Receiving",
                                etaDescription: etaDescription
                            )
                        )
                    }
                }
            }
        }

        incomingObservationTask = Task {
            let requestStream = await components.node.incomingTransferRequests()
            for await request in requestStream {
                let mappedFiles = request.files.values.sorted { $0.fileName < $1.fileName }.map { file in
                    IncomingTransferFile(
                        id: file.id,
                        name: file.fileName,
                        size: ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file),
                        symbol: Self.symbol(for: file)
                    )
                }
                let totalBytes = request.files.values.reduce(Int64.zero) { $0 + $1.size }
                let subtitle = "\(request.info.alias) · \(mappedFiles.count) item(s) · \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
                await incomingBroadcaster.yield(
                    IncomingTransferRequest(
                        id: request.id,
                        deviceName: request.info.alias,
                        subtitle: subtitle,
                        sourceKind: DeviceKind(deviceType: request.info.deviceType),
                        files: mappedFiles
                    )
                )
                logger.emit(
                    level: .info,
                    event: "transfer.incoming.request_received",
                    scope: "LocalSendRuntimeAdapter",
                    context: AppLogContext(
                        attributes: runtimeContext().attributes + [.string("transfer.request_id", request.id)]
                    ),
                    attributes: [
                        .string("peer.alias", request.info.alias),
                        .int("transfer.file_count", request.files.count),
                        .int64("transfer.byte_count", totalBytes)
                    ]
                )
            }
        }
    }

    private func resolvePeer(id: NearbyPeerItem.ID) async throws -> NearbyPeerItem {
        let snapshot = await components.node.runtimeSnapshot()
        guard let peer = snapshot.discoveredPeers.map(NearbyPeerItem.init(peer:)).first(where: { $0.id == id }) else {
            throw TransferFeatureError.peerNotFound(id)
        }
        return peer
    }

    private func makeFileMap(from items: [StagedTransferItem]) -> [String: FileDto] {
        Dictionary(uniqueKeysWithValues: items.map { item in
            let byteCount = item.byteCount ?? Int64((try? Data(contentsOf: item.fileURL).count) ?? 0)
            let fileType = Self.mimeType(for: item.fileURL)
            let dto = FileDto(
                id: item.id,
                fileName: item.name,
                size: byteCount,
                fileType: fileType
            )
            return (item.id, dto)
        })
    }

    private static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType {
            return type
        }
        return "application/octet-stream"
    }

    private static func symbol(for file: FileDto) -> String {
        if file.fileType.hasPrefix("image/") {
            return "photo.fill"
        }
        return "doc.fill"
    }

    private func runtimeContext() -> AppLogContext {
        AppLogContext(attributes: [
            .string("runtime.instance_id", runtimeInstanceID),
            .int("runtime.restart_generation", restartGeneration),
            .string("localsend.protocol_type", currentSettings.protocolType.rawValue)
        ])
    }

    private func sendContext(sessionID: String?, peer: NearbyPeerItem, traceID: String) -> AppLogContext {
        AppLogContext(
            attributes: runtimeContext().attributes + [
                .string("transfer.direction", "sending"),
                .string("peer.id", peer.id),
                .string("peer.alias", peer.name),
                .string("peer.fingerprint_suffix", String(peer.fingerprint.suffix(8))),
                .string("network.protocol.name", "localsend"),
                .string("network.transport", "tcp")
            ] + (sessionID.map { [.string("transfer.session_id", $0)] } ?? []),
            traceID: traceID
        )
    }

    private func incomingDecisionEvent(_ response: IncomingTransferDecision) -> String {
        switch response {
        case .reject:
            "transfer.incoming.rejected"
        case .acceptAll:
            "transfer.incoming.accepted"
        case .acceptSubset:
            "transfer.incoming.accepted_subset"
        case .noTransferNeeded:
            "transfer.incoming.no_transfer_needed"
        }
    }

    private func incomingDecisionAttributes(_ response: IncomingTransferDecision) -> [AppLogAttribute] {
        switch response {
        case .reject(let requestID), .acceptAll(let requestID), .noTransferNeeded(let requestID):
            [.string("transfer.request_id", requestID)]
        case .acceptSubset(let requestID, let fileIDs):
            [.string("transfer.request_id", requestID), .int("transfer.accepted_file_count", fileIDs.count)]
        }
    }

    private func receiveStatusEvent(_ status: ReceiveSessionStatus) -> String {
        switch status {
        case .waiting:
            "transfer.receive.session_waiting"
        case .transferring:
            "transfer.receive.session_transferring"
        case .finished:
            "transfer.receive.session_finished"
        case .canceled:
            "transfer.receive.session_canceled"
        }
    }

    private static func makeTraceID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

private struct ActiveSendSession {
    let id: String
    let peer: NearbyPeerItem
    let client: LocalSendClient
    let traceID: String
}

private actor StreamBroadcaster<Value: Sendable> {
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
                    await self?.removeContinuation(id: id)
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

    func finishCurrentValue() {
        currentValue = nil
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

enum TransferFeatureError: LocalizedError {
    case peerNotFound(String)
    case unreachablePeer(String)

    var errorDescription: String? {
        switch self {
        case .peerNotFound(let id):
            "Peer not found: \(id)"
        case .unreachablePeer(let name):
            "\(name) is not addressable yet."
        }
    }
}
