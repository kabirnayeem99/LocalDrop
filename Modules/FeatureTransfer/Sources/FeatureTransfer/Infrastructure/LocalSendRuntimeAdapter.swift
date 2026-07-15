import AppLogging
import Dispatch
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
    private let progressBroadcaster = StreamBroadcaster<TransferProgressEvent>()
    private let logger: AppLogger
    private let runtimeInstanceID = UUID().uuidString.lowercased()
    private var restartGeneration = 0
    private var activeSendSession: ActiveSendSession?
    private var lastReceiveStatusKey: String?
    private var emittedReceivedFileKeys: Set<String> = []
    private var emittedReceivedFileKeysSessionID: String?
    private var startupAnnouncementTask: Task<Void, Never>?
    private var progressSequenceNumber: Int64 = 0

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
        let runtimeStartUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        logger.emit(
            level: .info,
            event: "app.runtime.start.requested",
            scope: "LocalSendRuntimeAdapter",
            context: runtimeContext(),
            attributes: [.bool("settings.use_https", currentSettings.useHTTPS)]
        )
        try await components.node.start()
        logger.emit(level: .debug, event: "app.runtime.start.succeeded", scope: "LocalSendRuntimeAdapter", context: runtimeContext(), attributes: [.string("event.action", "node_started")])
        bindNodeObservers()
        let startupNode = components.node
        let startupLogger = logger
        let startupContext = runtimeContext()
        let startupAnnouncementStartUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        startupAnnouncementTask?.cancel()
        startupAnnouncementTask = Task.detached(priority: .utility) {
            do {
                try await startupNode.announce()
                startupLogger.emit(
                    level: .info,
                    event: "discovery.announce.succeeded",
                    scope: "LocalSendRuntimeAdapter",
                    context: startupContext,
                    attributes: [
                        .string("event.action", "startup"),
                        .double(
                            "startup.announce_elapsed_ms",
                            Self.elapsedMilliseconds(since: startupAnnouncementStartUptimeNanoseconds)
                        )
                    ]
                )
            } catch is CancellationError {
                return
            } catch {
                startupLogger.emit(
                    level: .warning,
                    event: "discovery.announce.failed",
                    scope: "LocalSendRuntimeAdapter",
                    context: startupContext,
                    attributes: [
                        .string("event.action", "startup"),
                        .double(
                            "startup.announce_elapsed_ms",
                            Self.elapsedMilliseconds(since: startupAnnouncementStartUptimeNanoseconds)
                        ),
                        .string("error.message", error.localizedDescription),
                        .string("error.type", String(describing: type(of: error)))
                    ]
                )
            }
        }
        logger.emit(
            level: .info,
            event: "app.runtime.start.succeeded",
            scope: "LocalSendRuntimeAdapter",
            context: runtimeContext(),
            attributes: [
                .string("result", "success"),
                .double(
                    "startup.runtime_start_elapsed_ms",
                    Self.elapsedMilliseconds(since: runtimeStartUptimeNanoseconds)
                )
            ]
        )
    }

    func stop() async {
        startupAnnouncementTask?.cancel()
        startupAnnouncementTask = nil
        stateObservationTask?.cancel()
        incomingObservationTask?.cancel()
        logger.emit(level: .debug, event: "app.runtime.stop.requested", scope: "LocalSendRuntimeAdapter", context: runtimeContext(), attributes: [.string("event.action", "stream_teardown")])
        stateObservationTask = nil
        incomingObservationTask = nil
        activeSendSession = nil
        await components.node.stop()
        await peersBroadcaster.yield([])
        await progressBroadcaster.clearCurrentValue()
        await progressBroadcaster.yield(.reset, cache: false)
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

    func progressEvents() async -> AsyncStream<TransferProgressEvent> {
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

        let prepareResponse: PrepareUploadResponse?
        do {
            prepareResponse = try await client.prepareUpload(request, pin: pin)
        } catch {
            await emitRawProgressEvent(
                kind: .transferFailed,
                transferID: UUID().uuidString,
                attemptID: UUID().uuidString,
                direction: .sending,
                counterpartName: peer.name,
                counterpartKind: peer.kind,
                files: stagedItems.enumerated().map { index, item in
                    TransferProgressRawFile(
                        fileID: item.id,
                        displayName: item.name,
                        fileURL: item.fileURL,
                        order: index,
                        attemptIndex: 0,
                        state: item.id == stagedItems.first?.id ? .failed : .queued,
                        declaredTotalBytes: item.byteCount,
                        actualTransferredBytes: 0,
                        errorSummary: error.localizedDescription
                    )
                },
                totalBytesKnown: stagedItems.compactMap(\.byteCount).reduce(0, +),
                actualTransferredBytes: 0,
                cache: false
            )
            logger.emit(
                level: .error,
                event: "transfer.send.file_upload.failed",
                scope: "LocalSendRuntimeAdapter",
                context: context,
                attributes: [
                    .string("result", "prepare_upload_failed"),
                    .string("error.message", error.localizedDescription),
                    .string("error.type", String(describing: type(of: error)))
                ]
            )
            throw error
        }

        guard let prepareResponse else {
            await progressBroadcaster.clearCurrentValue()
            await progressBroadcaster.yield(.reset, cache: false)
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

        let acceptedItems = stagedItems
            .filter { prepareResponse.files[$0.id] != nil }
            .map { SendBatchItem(item: $0, byteCount: resolvedByteCount(for: $0)) }
        let totalBatchBytes = acceptedItems.reduce(Int64.zero) { $0 + $1.byteCount }
        var bytesTransferredBeforeCurrentFile: Int64 = 0
        activeSendSession?.acceptedItems = acceptedItems
        activeSendSession?.currentItemIndex = 0
        activeSendSession?.bytesTransferredBeforeCurrentFile = 0

        await emitRawProgressEvent(
            kind: .transferStarted,
            transferID: prepareResponse.sessionId,
            attemptID: prepareResponse.sessionId,
            direction: .sending,
            counterpartName: peer.name,
            counterpartKind: peer.kind,
            files: Self.makeSendRawFiles(
                batchItems: acceptedItems,
                currentItemIndex: nil,
                currentFileTransferredBytes: 0,
                currentFileTotalBytes: nil,
                currentStatus: nil
            ),
            totalBytesKnown: totalBatchBytes > 0 ? totalBatchBytes : nil,
            actualTransferredBytes: 0
        )

        for (index, acceptedItem) in acceptedItems.enumerated() {
            let item = acceptedItem.item
            let byteCount = acceptedItem.byteCount
            let transferredBeforeCurrentFile = bytesTransferredBeforeCurrentFile
            let currentItemIndex = index + 1
            guard let token = prepareResponse.files[item.id] else {
                continue
            }
            activeSendSession?.currentItemIndex = currentItemIndex
            activeSendSession?.bytesTransferredBeforeCurrentFile = transferredBeforeCurrentFile

            await emitRawProgressEvent(
                kind: .snapshot,
                transferID: prepareResponse.sessionId,
                attemptID: prepareResponse.sessionId,
                direction: .sending,
                counterpartName: peer.name,
                counterpartKind: peer.kind,
                files: Self.makeSendRawFiles(
                    batchItems: acceptedItems,
                    currentItemIndex: currentItemIndex,
                    currentFileTransferredBytes: 0,
                    currentFileTotalBytes: byteCount,
                    currentStatus: .transferring
                ),
                totalBytesKnown: totalBatchBytes > 0 ? totalBatchBytes : nil,
                actualTransferredBytes: bytesTransferredBeforeCurrentFile
            )

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
            do {
                try await client.upload(
                    fileAt: item.fileURL,
                    byteCount: byteCount,
                    sessionId: prepareResponse.sessionId,
                    fileId: item.id,
                    token: token,
                    progress: { [weak self] progress in
                        Task {
                            await self?.emitRawProgressEvent(
                                kind: .snapshot,
                                transferID: prepareResponse.sessionId,
                                attemptID: prepareResponse.sessionId,
                                direction: .sending,
                                counterpartName: peer.name,
                                counterpartKind: peer.kind,
                                files: Self.makeSendRawFiles(
                                    batchItems: acceptedItems,
                                    currentItemIndex: currentItemIndex,
                                    currentFileTransferredBytes: progress.bytesTransferred,
                                    currentFileTotalBytes: progress.totalBytes,
                                    currentStatus: .transferring
                                ),
                                totalBytesKnown: totalBatchBytes > 0 ? totalBatchBytes : nil,
                                actualTransferredBytes: min(totalBatchBytes, transferredBeforeCurrentFile + progress.bytesTransferred)
                            )
                        }
                    }
                )
            } catch {
                await emitRawProgressEvent(
                    kind: .transferFailed,
                    transferID: prepareResponse.sessionId,
                    attemptID: prepareResponse.sessionId,
                    direction: .sending,
                    counterpartName: peer.name,
                    counterpartKind: peer.kind,
                    files: Self.makeSendRawFiles(
                        batchItems: acceptedItems,
                        currentItemIndex: currentItemIndex,
                        currentFileTransferredBytes: 0,
                        currentFileTotalBytes: byteCount,
                        currentStatus: .failed,
                        errorSummary: error.localizedDescription
                    ),
                    totalBytesKnown: totalBatchBytes > 0 ? totalBatchBytes : nil,
                    actualTransferredBytes: bytesTransferredBeforeCurrentFile,
                    cache: false
                )
                activeSendSession = nil
                logger.emit(
                    level: .error,
                    event: "transfer.send.file_upload.failed",
                    scope: "LocalSendRuntimeAdapter",
                    context: sendContext(sessionID: prepareResponse.sessionId, peer: peer, traceID: traceID),
                    attributes: [
                        .string("transfer.file_id", item.id),
                        .string("transfer.file_name", item.name),
                        .int64("transfer.byte_count", byteCount),
                        .string("error.message", error.localizedDescription),
                        .string("error.type", String(describing: type(of: error)))
                    ]
                )
                throw error
            }
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

            bytesTransferredBeforeCurrentFile += byteCount
            activeSendSession?.bytesTransferredBeforeCurrentFile = bytesTransferredBeforeCurrentFile
            if index + 1 == acceptedItems.count {
                await emitRawProgressEvent(
                    kind: .transferCompleted,
                    transferID: prepareResponse.sessionId,
                    attemptID: prepareResponse.sessionId,
                    direction: .sending,
                    counterpartName: peer.name,
                    counterpartKind: peer.kind,
                    files: Self.makeSendRawFiles(
                        batchItems: acceptedItems,
                        currentItemIndex: currentItemIndex,
                        currentFileTransferredBytes: byteCount,
                        currentFileTotalBytes: byteCount,
                        currentStatus: .completed
                    ),
                    totalBytesKnown: totalBatchBytes > 0 ? totalBatchBytes : nil,
                    actualTransferredBytes: bytesTransferredBeforeCurrentFile,
                    cache: false
                )
            } else {
                await emitRawProgressEvent(
                    kind: .snapshot,
                    transferID: prepareResponse.sessionId,
                    attemptID: prepareResponse.sessionId,
                    direction: .sending,
                    counterpartName: peer.name,
                    counterpartKind: peer.kind,
                    files: Self.makeSendRawFiles(
                        batchItems: acceptedItems,
                        currentItemIndex: currentItemIndex,
                        currentFileTransferredBytes: byteCount,
                        currentFileTotalBytes: byteCount,
                        currentStatus: .completed
                    ),
                    totalBytesKnown: totalBatchBytes > 0 ? totalBatchBytes : nil,
                    actualTransferredBytes: bytesTransferredBeforeCurrentFile
                )
            }
        }

        stagedItems.removeAll()
        activeSendSession = nil
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
            let session = activeSendSession
            try await activeSendSession.client.cancel(sessionId: activeSendSession.id)
            self.activeSendSession = nil
            await emitRawProgressEvent(
                kind: .transferCanceled,
                transferID: session.id,
                attemptID: session.id,
                direction: .sending,
                counterpartName: session.peer.name,
                counterpartKind: session.peer.kind,
                files: Self.makeSendRawFiles(
                    batchItems: session.acceptedItems,
                    currentItemIndex: session.currentItemIndex > 0 ? session.currentItemIndex : nil,
                    currentFileTransferredBytes: 0,
                    currentFileTotalBytes: session.currentItemIndex > 0 ? session.acceptedItems[session.currentItemIndex - 1].byteCount : nil,
                    currentStatus: .canceled
                ),
                totalBytesKnown: session.acceptedItems.reduce(0) { $0 + $1.byteCount },
                actualTransferredBytes: session.bytesTransferredBeforeCurrentFile,
                cache: false
            )
            logger.emit(
                level: .notice,
                event: "transfer.send.canceled",
                scope: "LocalSendRuntimeAdapter",
                context: sendContext(sessionID: session.id, peer: session.peer, traceID: session.traceID)
            )
        }
    }

    private func bindNodeObservers() {
        stateObservationTask?.cancel()
        incomingObservationTask?.cancel()

        stateObservationTask = Task {
            logger.emit(level: .debug, event: "discovery.peer.snapshot", scope: "LocalSendRuntimeAdapter", context: runtimeContext(), attributes: [.string("event.action", "stream_started")])
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
                    await handleReceiveSessionUpdate(receiveSession)
                } else {
                    lastReceiveStatusKey = nil
                }
            }
            logger.emit(level: .debug, event: "discovery.peer.snapshot", scope: "LocalSendRuntimeAdapter", context: runtimeContext(), attributes: [.string("event.action", "stream_finished")])
        }

        incomingObservationTask = Task {
            logger.emit(level: .debug, event: "transfer.incoming.request_bridge_finished", scope: "LocalSendRuntimeAdapter", context: runtimeContext(), attributes: [.string("event.action", "stream_started")])
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
                let fileCountLabel = FeatureTransferLocalization.format("incomingRequest.itemCount", mappedFiles.count)
                let totalSizeLabel = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                let subtitle = FeatureTransferLocalization.format("incomingRequest.subtitleFormat", request.info.alias, fileCountLabel, totalSizeLabel)
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
            logger.emit(level: .debug, event: "transfer.incoming.request_bridge_finished", scope: "LocalSendRuntimeAdapter", context: runtimeContext(), attributes: [.string("event.action", "stream_finished")])
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
        case .failed:
            "transfer.receive.session_failed"
        }
    }

    private func handleReceiveSessionUpdate(_ receiveSession: ReceiveSessionSnapshot) async {
        let leadRecord = currentReceiveRecord(in: receiveSession) ?? receiveSession.files.values.first
        guard let leadRecord else { return }

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
                attributes: [.string("transfer.file_name", leadRecord.file.fileName)]
            )
        }
        let files = receiveSession.files.values
            .sorted { $0.file.fileName < $1.file.fileName }
            .enumerated()
            .map { index, record in
                let isCurrent = receiveSession.currentFileID == record.file.id
                let fileState: TransferFileProgress.Status
                switch receiveSession.status {
                case .waiting:
                    fileState = isCurrent ? .queued : .queued
                case .transferring:
                    if FileManager.default.fileExists(atPath: record.destinationURL.path) {
                        fileState = .completed
                    } else if isCurrent {
                        fileState = .transferring
                    } else {
                        fileState = .queued
                    }
                case .finished:
                    fileState = .completed
                case .canceled:
                    fileState = isCurrent ? .canceled : (FileManager.default.fileExists(atPath: record.destinationURL.path) ? .completed : .queued)
                case .failed:
                    fileState = isCurrent ? .failed : (FileManager.default.fileExists(atPath: record.destinationURL.path) ? .completed : .queued)
                }

                let transferredBytes: Int64
                if fileState == .completed {
                    transferredBytes = record.file.size
                } else if isCurrent {
                    transferredBytes = receiveSession.currentFileBytesReceived
                } else {
                    transferredBytes = 0
                }

                return TransferProgressRawFile(
                    fileID: record.file.id,
                    displayName: record.file.fileName,
                    fileURL: record.destinationURL,
                    order: index,
                    attemptIndex: 0,
                    state: fileState,
                    declaredTotalBytes: record.file.size > 0 ? record.file.size : nil,
                    actualTransferredBytes: transferredBytes,
                    errorSummary: receiveSession.status == .failed && isCurrent ? "Transfer failed" : nil
                )
            }

        let kind: TransferProgressRawEvent.Kind
        switch receiveSession.status {
        case .waiting, .transferring:
            kind = .snapshot
        case .finished:
            kind = .transferCompleted
        case .canceled:
            kind = .transferCanceled
        case .failed:
            kind = .transferFailed
        }

        await emitRawProgressEvent(
            kind: kind,
            transferID: receiveSession.sessionId,
            attemptID: receiveSession.sessionId,
            direction: .receiving,
            counterpartName: receiveSession.senderInfo.alias,
            counterpartKind: DeviceKind(deviceType: receiveSession.senderInfo.deviceType),
            files: files,
            totalBytesKnown: receiveSession.totalBytes > 0 ? receiveSession.totalBytes : nil,
            actualTransferredBytes: max(receiveSession.bytesReceived, 0),
            cache: receiveSession.status == .waiting || receiveSession.status == .transferring
        )
        if kind != .snapshot {
            await progressBroadcaster.clearCurrentValue()
        }
    }

    private func currentReceiveRecord(in receiveSession: ReceiveSessionSnapshot) -> ReceivedFileRecord? {
        if let currentFileID = receiveSession.currentFileID,
           let record = receiveSession.files[currentFileID] {
            return record
        }
        return receiveSession.files.values
            .sorted { $0.file.fileName < $1.file.fileName }
            .first { FileManager.default.fileExists(atPath: $0.destinationURL.path) == false }
    }

    private static func makeSendRawFiles(
        batchItems: [SendBatchItem],
        currentItemIndex: Int?,
        currentFileTransferredBytes: Int64,
        currentFileTotalBytes: Int64?,
        currentStatus: TransferFileProgress.Status?,
        errorSummary: String? = nil
    ) -> [TransferProgressRawFile] {
        batchItems.enumerated().map { index, batchItem in
            let itemIndex = index + 1
            let status: TransferFileProgress.Status
            let transferredBytes: Int64

            if let currentItemIndex, itemIndex < currentItemIndex {
                status = .completed
                transferredBytes = batchItem.byteCount
            } else if let currentItemIndex, itemIndex == currentItemIndex {
                status = currentStatus ?? .queued
                transferredBytes = status == .queued ? 0 : currentFileTransferredBytes
            } else {
                status = .queued
                transferredBytes = 0
            }

            return TransferProgressRawFile(
                fileID: batchItem.item.id,
                displayName: batchItem.item.name,
                fileURL: batchItem.item.fileURL,
                order: index,
                attemptIndex: 0,
                state: status,
                declaredTotalBytes: (currentItemIndex == itemIndex ? currentFileTotalBytes : batchItem.byteCount) ?? batchItem.byteCount,
                actualTransferredBytes: transferredBytes,
                errorSummary: status == .failed ? errorSummary : nil
            )
        }
    }

    private func resolvedByteCount(for item: StagedTransferItem) -> Int64 {
        item.byteCount ?? Int64((try? Data(contentsOf: item.fileURL).count) ?? 0)
    }

    private func emitRawProgressEvent(
        kind: TransferProgressRawEvent.Kind,
        transferID: String,
        attemptID: String,
        direction: ActiveTransferProgress.Direction,
        counterpartName: String,
        counterpartKind: DeviceKind,
        files: [TransferProgressRawFile],
        totalBytesKnown: Int64?,
        actualTransferredBytes: Int64,
        cache: Bool = true
    ) async {
        progressSequenceNumber += 1
        await progressBroadcaster.yield(
            .event(
                TransferProgressRawEvent(
                    kind: kind,
                    transferID: transferID,
                    attemptID: attemptID,
                    direction: direction,
                    counterpartName: counterpartName,
                    counterpartKind: counterpartKind,
                    sequenceNumber: progressSequenceNumber,
                    eventMonotonicTime: ProcessInfo.processInfo.systemUptime,
                    files: files,
                    totalBytesKnown: totalBytesKnown,
                    actualTransferredBytes: actualTransferredBytes
                )
            ),
            cache: cache
        )
    }

    private static func makeTraceID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private nonisolated static func elapsedMilliseconds(since startUptimeNanoseconds: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startUptimeNanoseconds) / 1_000_000
    }
}

private struct ActiveSendSession {
    let id: String
    let peer: NearbyPeerItem
    let client: LocalSendClient
    let traceID: String
    var acceptedItems: [SendBatchItem] = []
    var currentItemIndex: Int = 0
    var bytesTransferredBeforeCurrentFile: Int64 = 0
}

private struct SendBatchItem {
    let item: StagedTransferItem
    let byteCount: Int64
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

    func yield(_ value: Value, cache: Bool = true) {
        if cache {
            currentValue = value
        }
        for continuation in continuations.values {
            continuation.yield(value)
        }
    }

    func clearCurrentValue() {
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
            return FeatureTransferLocalization.format("error.peerNotFound", id)
        case .unreachablePeer(let name):
            return FeatureTransferLocalization.format("error.unreachablePeer", name)
        }
    }
}
