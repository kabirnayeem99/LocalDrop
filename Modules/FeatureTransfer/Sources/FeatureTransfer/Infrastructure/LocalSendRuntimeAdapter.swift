import AppLogging
import Dispatch
import Foundation
import LocalSendKit
import UniformTypeIdentifiers

struct LiveRuntimeComponents {
    let node: LocalSendNode
    let registerInfo: RegisterInfo
}

/// Fires the best-effort `POST /api/localsend/v2/cancel?sessionId=…` at the peer that is sending
/// to us, when the LOCAL user cancels an inbound transfer.
///
/// A seam rather than a direct `LocalSendClient` call so the "exactly one POST, and only from the
/// user-initiated entry point" contract is assertable without a live peer on the LAN.
typealias ReceiveCancelNotifier = @Sendable (
    _ sessionID: String,
    _ peer: RemotePeer,
    _ expectedFingerprint: String
) async throws -> Void

actor LocalSendRuntimeAdapter: TransferRuntime {
    private var components: LiveRuntimeComponents
    private let makeComponents: @Sendable (TransferProtocolSettings) throws -> LiveRuntimeComponents
    private var currentSettings: TransferProtocolSettings
    private var stagedItems: [StagedTransferItem] = []
    private var stateObservationTask: Task<Void, Never>?
    private var incomingObservationTask: Task<Void, Never>?
    private var withdrawalObservationTask: Task<Void, Never>?
    private let peersBroadcaster = StreamBroadcaster<[NearbyPeerItem]>(initialValue: [])
    private let incomingBroadcaster = StreamBroadcaster<IncomingTransferRequest>()
    private let withdrawalBroadcaster = StreamBroadcaster<String>()
    private let progressBroadcaster = StreamBroadcaster<TransferProgressEvent>()
    private let logger: AppLogger
    private let runtimeInstanceID = UUID().uuidString.lowercased()
    private var restartGeneration = 0
    /// Outbound send sessions, keyed by their `sessionId`.
    ///
    /// Was a single `ActiveSendSession?`, which structurally limited the app to one outbound
    /// transfer: starting a send to device B silently replaced the bookkeeping for the send still
    /// running to device A, so A's cancel button and progress rows pointed at the wrong session.
    /// The session id is unique per target per send, so keying by it isolates them completely —
    /// tokens, progress and cancellation never cross.
    private var activeSendSessions: [String: ActiveSendSession] = [:]

    /// Upper bound on files uploading at once WITHIN one send session.
    ///
    /// Protocol section 4.2 says the upload route "can be called in parallel", but prescribes no
    /// number. Kept deliberately modest: the receiver writes to a single session's file pipeline,
    /// so beyond a small degree of overlap the extra TLS handshakes cost more than they gain, and
    /// an aggressive pool risks the receiver's `429 Too many requests` path against unknown
    /// hardware (phones, headless nodes). Concurrency ACROSS target devices is not bounded here —
    /// that is limited only by how many devices the user sends to.
    static let maximumConcurrentUploads = 3
    private var lastReceiveStatusKey: String?
    private var emittedReceivedFileKeys: Set<String> = []
    private var emittedReceivedFileKeysSessionID: String?
    private var startupAnnouncementTask: Task<Void, Never>?
    private var progressSequenceNumber: Int64 = 0
    private let receiveCancelNotifier: ReceiveCancelNotifier
    /// Receive sessions this app has already cancelled outbound, most recent last. Bounded, because
    /// its only job is to keep a second press of the cancel button (or a re-entrant call racing the
    /// state observation) from POSTing `/cancel` twice.
    private var outboundCanceledReceiveSessionIDs: [String] = []

    /// A dead or unreachable sender must not stall our own teardown, so the notification gets its
    /// own budget instead of `LocalSendClientTimeoutConfiguration`'s 30s default. Nothing waits on
    /// the result, so the only cost of it expiring is that the sender falls back to its own timeout
    /// — exactly the behaviour we had before this notification existed.
    static let receiveCancelNotificationTimeout: TimeInterval = 4

    /// The real POST. Built per call: a cancel is a single request to a peer we do not otherwise
    /// hold a client for, and its timeouts differ from every other request we make.
    static let liveReceiveCancelNotifier: ReceiveCancelNotifier = { sessionID, peer, expectedFingerprint in
        let client = LocalSendClient(
            peer: peer,
            expectedFingerprint: expectedFingerprint,
            timeoutConfiguration: LocalSendClientTimeoutConfiguration(
                requestTimeout: LocalSendRuntimeAdapter.receiveCancelNotificationTimeout,
                resourceTimeout: LocalSendRuntimeAdapter.receiveCancelNotificationTimeout
            )
        )
        try await client.cancel(sessionId: sessionID)
    }

    init(
        components: LiveRuntimeComponents,
        settings: TransferProtocolSettings,
        makeComponents: @escaping @Sendable (TransferProtocolSettings) throws -> LiveRuntimeComponents,
        receiveCancelNotifier: @escaping ReceiveCancelNotifier = LocalSendRuntimeAdapter.liveReceiveCancelNotifier,
        logger: AppLogger = .disabled()
    ) {
        self.components = components
        self.currentSettings = settings
        self.makeComponents = makeComponents
        self.receiveCancelNotifier = receiveCancelNotifier
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
        withdrawalObservationTask?.cancel()
        logger.emit(level: .debug, event: "app.runtime.stop.requested", scope: "LocalSendRuntimeAdapter", context: runtimeContext(), attributes: [.string("event.action", "stream_teardown")])
        stateObservationTask = nil
        incomingObservationTask = nil
        withdrawalObservationTask = nil
        // Every outbound session, not just "the" one — a runtime stop ends them all.
        activeSendSessions.removeAll()
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

    func inboundRequestWithdrawals() async -> AsyncStream<String> {
        await withdrawalBroadcaster.stream()
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

    func sendStagedItems(
        to peerID: NearbyPeerItem.ID,
        pin: String?,
        requestPIN: TransferPINProvider?
    ) async throws {
        // The batch is captured ONCE, up front, and never re-read from the actor afterwards.
        // `stagedItems` is shared mutable actor state: a second, overlapping send — or a PIN prompt
        // dismissal on another one — can empty it across any of the awaits below, which would leave
        // this send with an empty `acceptedItems`, a zero-byte total, an upload loop that never
        // runs, and a "completed" log carrying `file_count: 0`.
        let batch = stagedItems
        guard batch.isEmpty == false else {
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

        let files = makeFileMap(from: batch)
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

        let phaseOutcome = try await runPrepareUploadPhase(
            peer: peer,
            context: context,
            batch: batch,
            initialPIN: pin,
            requestPIN: requestPIN,
            attempt: { attemptPIN in
                try await client.prepareUpload(request, pin: attemptPIN)
            }
        )

        // The user dismissed the PIN prompt: the send is discarded, staged items already cleared.
        // No terminal failure is reported because nothing failed.
        guard case .prepared(let preparedResponse) = phaseOutcome else {
            return
        }

        guard let prepareResponse = preparedResponse else {
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

        let sessionID = prepareResponse.sessionId
        let acceptedItems = batch
            .filter { prepareResponse.files[$0.id] != nil }
            .map { SendBatchItem(item: $0, byteCount: resolvedByteCount(for: $0)) }

        var session = ActiveSendSession(
            id: sessionID,
            peer: peer,
            client: client,
            traceID: traceID
        )
        session.acceptedItems = acceptedItems
        activeSendSessions[sessionID] = session

        logger.emit(
            level: .info,
            event: "transfer.send.prepare_upload.succeeded",
            scope: "LocalSendRuntimeAdapter",
            context: sendContext(sessionID: sessionID, peer: peer, traceID: traceID),
            attributes: [.int("transfer.accepted_file_count", prepareResponse.files.count)]
        )

        await emitSendProgress(sessionID: sessionID, kind: .transferStarted)

        // Bounded concurrent uploads. The protocol allows the upload route to be called in
        // parallel; the pool keeps that from becoming an unbounded fan-out of one connection per
        // file, which would be worse for both peers than the old sequential loop.
        //
        // Failures are COLLECTED, never rethrown out of the group: one bad file must not abandon
        // the rest of the batch, both because the user's other files should still arrive and
        // because the receiver now keeps such a session alive in `finishedWithErrors` so those
        // files can be retried. Throwing here would tear down uploads that were about to succeed.
        var pending = acceptedItems.makeIterator()
        var failureCount = 0

        await withTaskGroup(of: SendFileOutcome.self) { group in
            var inFlight = 0

            func addNext() -> Bool {
                while let batchItem = pending.next() {
                    guard let token = prepareResponse.files[batchItem.item.id] else {
                        continue
                    }
                    group.addTask { [weak self] in
                        guard let self else {
                            return SendFileOutcome(fileID: batchItem.item.id, errorSummary: "cancelled")
                        }
                        return await self.uploadOneFile(
                            batchItem: batchItem,
                            token: token,
                            sessionID: sessionID,
                            client: client,
                            peer: peer,
                            traceID: traceID
                        )
                    }
                    return true
                }
                return false
            }

            while inFlight < Self.maximumConcurrentUploads, addNext() {
                inFlight += 1
            }

            while let outcome = await group.next() {
                inFlight -= 1
                if outcome.errorSummary != nil {
                    failureCount += 1
                }
                // One completion frees exactly one slot, so the pool width is held at the bound
                // rather than refilling to it in bursts.
                if addNext() {
                    inFlight += 1
                }
            }
        }

        // The session may have been cancelled (or the runtime restarted) while uploads were in
        // flight, in which case its terminal event was already emitted and its entry removed.
        guard activeSendSessions[sessionID] != nil else {
            removeStagedItems(in: batch)
            return
        }

        await emitSendProgress(
            sessionID: sessionID,
            kind: failureCount > 0 ? .transferFailed : .transferCompleted,
            cache: false
        )
        logger.emit(
            level: failureCount > 0 ? .error : .info,
            event: failureCount > 0 ? "transfer.send.completed_with_errors" : "transfer.send.completed",
            scope: "LocalSendRuntimeAdapter",
            context: sendContext(sessionID: sessionID, peer: peer, traceID: traceID),
            attributes: [
                .int("transfer.file_count", acceptedItems.count),
                .int("transfer.failed_file_count", failureCount)
            ]
        )
        activeSendSessions[sessionID] = nil

        // Scoped to this send's own batch so a concurrent send's staged items survive.
        removeStagedItems(in: batch)
    }

    /// Uploads exactly one file of a batch and folds its progress into the session.
    ///
    /// Returns rather than throws: the caller runs these in a group and a throw would cancel the
    /// sibling uploads that are mid-flight.
    private func uploadOneFile(
        batchItem: SendBatchItem,
        token: String,
        sessionID: String,
        client: LocalSendClient,
        peer: NearbyPeerItem,
        traceID: String
    ) async -> SendFileOutcome {
        let item = batchItem.item
        let byteCount = batchItem.byteCount

        markFileState(sessionID: sessionID, fileID: item.id, status: .transferring, transferredBytes: 0)
        await emitSendProgress(sessionID: sessionID, kind: .snapshot)

        logger.emit(
            level: .info,
            event: "transfer.send.file_upload.started",
            scope: "LocalSendRuntimeAdapter",
            context: sendContext(sessionID: sessionID, peer: peer, traceID: traceID),
            attributes: [
                .string("transfer.file_id", item.id),
                .string("transfer.file_name", item.name),
                .int64("transfer.byte_count", byteCount)
            ]
        )

        // ONE consumer task per file, instead of a `Task { }` per `didSendBodyData` callback.
        //
        // URLSession fires that callback for every buffer it writes, so the old shape created an
        // unbounded, unordered swarm of tasks whose only job was a single actor hop. Here the
        // callback is a synchronous `yield` and a single long-lived task drains it.
        //
        // `.bufferingNewest(1)` is what makes this correct as well as cheap: if the consumer falls
        // behind, the intermediate byte counts are dropped and it observes only the most recent
        // one. For a monotonically increasing progress counter that is exactly right — the stale
        // samples carry no information the newest one lacks. `recordUploadProgress` additionally
        // ignores any sample that would move the count backwards.
        let (progressStream, progressContinuation) = AsyncStream<Int64>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let progressConsumer = Task { [weak self] in
            for await transferredBytes in progressStream {
                guard let self else { return }
                await self.recordUploadProgress(
                    sessionID: sessionID,
                    fileID: item.id,
                    transferredBytes: transferredBytes
                )
            }
        }
        // Ends the consumer on every exit path, including the throw below. Without this the task
        // would outlive the upload and leak for the lifetime of the process.
        defer {
            progressContinuation.finish()
        }
        _ = progressConsumer

        do {
            try await client.upload(
                fileAt: item.fileURL,
                byteCount: byteCount,
                sessionId: sessionID,
                fileId: item.id,
                token: token,
                progress: { progress in
                    progressContinuation.yield(progress.bytesTransferred)
                }
            )
        } catch {
            let summary = SensitiveTextRedaction.redactedDescription(of: error)
            markFileState(sessionID: sessionID, fileID: item.id, status: .failed, transferredBytes: 0, errorSummary: summary)
            await emitSendProgress(sessionID: sessionID, kind: .snapshot, cache: false)
            logger.emit(
                level: .error,
                event: "transfer.send.file_upload.failed",
                scope: "LocalSendRuntimeAdapter",
                context: sendContext(sessionID: sessionID, peer: peer, traceID: traceID),
                attributes: [
                    .string("transfer.file_id", item.id),
                    .string("transfer.file_name", item.name),
                    .int64("transfer.byte_count", byteCount),
                    .string("error.message", summary),
                    .string("error.type", String(describing: type(of: error)))
                ]
            )
            return SendFileOutcome(fileID: item.id, errorSummary: summary)
        }

        markFileState(sessionID: sessionID, fileID: item.id, status: .completed, transferredBytes: byteCount)
        await emitSendProgress(sessionID: sessionID, kind: .snapshot)
        logger.emit(
            level: .info,
            event: "transfer.send.file_upload.completed",
            scope: "LocalSendRuntimeAdapter",
            context: sendContext(sessionID: sessionID, peer: peer, traceID: traceID),
            attributes: [
                .string("transfer.file_id", item.id),
                .string("transfer.file_name", item.name),
                .int64("transfer.byte_count", byteCount)
            ]
        )
        return SendFileOutcome(fileID: item.id, errorSummary: nil)
    }

    private func markFileState(
        sessionID: String,
        fileID: String,
        status: TransferFileProgress.Status,
        transferredBytes: Int64,
        errorSummary: String? = nil
    ) {
        guard var session = activeSendSessions[sessionID] else {
            return
        }
        session.statusByFileID[fileID] = status
        session.transferredBytesByFileID[fileID] = transferredBytes
        if let errorSummary {
            session.errorByFileID[fileID] = errorSummary
        }
        activeSendSessions[sessionID] = session
    }

    /// Folds a URLSession byte callback into the session total.
    ///
    /// `max` rather than assignment: `didSendBodyData` callbacks for one task are ordered, but the
    /// hop through this actor is not, so a stale smaller value must never walk the count backwards
    /// and make the progress bar jump about.
    private func recordUploadProgress(sessionID: String, fileID: String, transferredBytes: Int64) async {
        guard var session = activeSendSessions[sessionID],
              session.statusByFileID[fileID] == .transferring else {
            return
        }
        let previous = session.transferredBytesByFileID[fileID] ?? 0
        guard transferredBytes > previous else {
            return
        }
        session.transferredBytesByFileID[fileID] = transferredBytes
        activeSendSessions[sessionID] = session
        await emitSendProgress(sessionID: sessionID, kind: .snapshot)
    }

    /// Emits the current state of one send session. Every send-side progress event goes through
    /// here so the file rows and the batch totals are always derived from the same snapshot.
    private func emitSendProgress(
        sessionID: String,
        kind: TransferProgressRawEvent.Kind,
        cache: Bool = true
    ) async {
        guard let session = activeSendSessions[sessionID] else {
            return
        }
        let totalBatchBytes = session.totalBatchBytes
        await emitRawProgressEvent(
            kind: kind,
            transferID: session.id,
            attemptID: session.id,
            direction: .sending,
            counterpartName: session.peer.name,
            counterpartKind: session.peer.kind,
            files: Self.makeSendRawFiles(session: session),
            totalBytesKnown: totalBatchBytes > 0 ? totalBatchBytes : nil,
            actualTransferredBytes: session.transferredBytes,
            cache: cache
        )
    }

    /// Outcome of the `/prepare-upload` phase, which now spans more than one request.
    enum PrepareUploadPhaseOutcome {
        /// The recipient answered; `nil` is the 204 "no file transfer needed" success.
        case prepared(PrepareUploadResponse?)
        /// The user dismissed the PIN prompt. Not a failure — the send is simply discarded.
        case canceledByPINPrompt
    }

    /// Runs `/prepare-upload`, re-issuing it with a user-supplied PIN for as long as the recipient
    /// answers 401 and the user keeps submitting one.
    ///
    /// Three properties are load-bearing:
    ///
    /// 1. A 401 emits **no** progress event. It is a prompt, not a terminal state — and because
    ///    `TransferProgressReducer` keys transfer continuity on the transfer ID, a terminal event
    ///    here (which carries a freshly minted random ID) would strand a "failed" card that the
    ///    eventual real transfer could never reconcile with.
    /// 2. The loop lives inside one `sendStagedItems` invocation, so the batch is one logical
    ///    transfer and the staged items are never re-staged.
    /// 3. Every retry is a deliberate user submission. Nothing here retries on its own: the
    ///    receiver locks out after three wrong non-empty PINs (`PinAttemptTracker`), and a 429
    ///    (`.tooManyRequests`) leaves via the terminal path below without re-prompting.
    ///
    /// `internal` rather than `private` so the retry semantics are exercisable without a live peer.
    ///
    /// `batch` is the caller's own captured batch. It defaults to the currently staged items so the
    /// phase stays callable on its own, but `sendStagedItems` always passes its local copy: both the
    /// cancel-path teardown and the failure event must describe *this* send, not whatever another
    /// concurrent send happens to have staged by the time an await resumes.
    func runPrepareUploadPhase(
        peer: NearbyPeerItem,
        context: AppLogContext,
        batch: [StagedTransferItem]? = nil,
        initialPIN: String?,
        requestPIN: TransferPINProvider?,
        attempt: @Sendable (String?) async throws -> PrepareUploadResponse?
    ) async throws -> PrepareUploadPhaseOutcome {
        let scopedBatch = batch ?? stagedItems
        var currentPIN = initialPIN
        // Mirrors the reference implementation's `pinFirstAttempt`.
        var isFirstPINAttempt = true

        while true {
            do {
                return .prepared(try await attempt(currentPIN))
            } catch {
                // 403 / 409 / 429 and every transport error take the terminal path unchanged, and
                // so does a 401 when no prompt is wired up (preserving the pre-existing behaviour).
                guard (error as? LocalSendClientError) == .pinRequired, let requestPIN else {
                    await emitPrepareUploadFailure(error, peer: peer, context: context, batch: scopedBatch)
                    throw error
                }

                logger.emit(
                    level: .notice,
                    event: "transfer.send.prepare_upload.pin_required",
                    scope: "LocalSendRuntimeAdapter",
                    context: context,
                    attributes: [.bool("transfer.pin_first_attempt", isFirstPINAttempt)]
                )

                let promptContext = TransferPINPromptContext(
                    peerID: peer.id,
                    peerName: peer.name,
                    isFirstAttempt: isFirstPINAttempt
                )
                guard let submittedPIN = await requestPIN(promptContext) else {
                    // The staged items were held for the duration of the prompt; dismissing it
                    // discards this send — and only this send's items, so an overlapping send's
                    // batch is not collaterally emptied.
                    removeStagedItems(in: scopedBatch)
                    await progressBroadcaster.clearCurrentValue()
                    await progressBroadcaster.yield(.reset, cache: false)
                    logger.emit(
                        level: .notice,
                        event: "transfer.send.prepare_upload.pin_prompt_canceled",
                        scope: "LocalSendRuntimeAdapter",
                        context: context
                    )
                    return .canceledByPINPrompt
                }

                isFirstPINAttempt = false
                currentPIN = submittedPIN
            }
        }
    }

    /// Terminal `/prepare-upload` outcome: one progress event carrying the mapped status, plus the
    /// log line. The message is PIN-redacted because a transport error can wrap the request URL.
    private func emitPrepareUploadFailure(
        _ error: any Error,
        peer: NearbyPeerItem,
        context: AppLogContext,
        batch: [StagedTransferItem]
    ) async {
        await emitRawProgressEvent(
            kind: Self.progressKind(forPrepareUploadError: error),
            transferID: UUID().uuidString,
            attemptID: UUID().uuidString,
            direction: .sending,
            counterpartName: peer.name,
            counterpartKind: peer.kind,
            files: batch.enumerated().map { index, item in
                TransferProgressRawFile(
                    fileID: item.id,
                    displayName: item.name,
                    fileURL: item.fileURL,
                    order: index,
                    attemptIndex: 0,
                    state: item.id == batch.first?.id ? .failed : .queued,
                    declaredTotalBytes: item.byteCount,
                    actualTransferredBytes: 0,
                    errorSummary: Self.failureSummary(forPrepareUploadError: error)
                )
            },
            totalBytesKnown: batch.compactMap(\.byteCount).reduce(0, +),
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
                .string("error.message", SensitiveTextRedaction.redactedDescription(of: error)),
                .string("error.type", String(describing: type(of: error)))
            ]
        )
    }

    /// MainActor-free read of the held staged batch, for tests that pin the "a throw must not
    /// discard the staged items" invariant the PIN retry depends on.
    func stagedItemsSnapshot() -> [StagedTransferItem] {
        stagedItems
    }

    /// Drops exactly the items of one send's batch, leaving anything another concurrent send has
    /// staged in place. A blanket `stagedItems.removeAll()` here would empty the other send's batch.
    private func removeStagedItems(in batch: [StagedTransferItem]) {
        let batchIDs = Set(batch.map(\.id))
        stagedItems.removeAll { batchIDs.contains($0.id) }
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
        case .acceptSubset(let requestID, let fileIDs, let desiredNames):
            try await components.node.respondToIncomingTransfer(
                requestID: requestID,
                decision: .acceptOnly(fileIDs, desiredNames: desiredNames)
            )
        case .noTransferNeeded(let requestID):
            try await components.node.respondToIncomingTransfer(requestID: requestID, decision: .noTransferNeeded)
        }
    }

    func cancelActiveTransfer(_ id: ActiveTransferProgress.ID) async throws {
        // Keyed lookup, so cancelling the send to device A cannot touch a concurrent send to
        // device B: only the matching session's `/cancel` is posted and only its entry is removed.
        if var session = activeSendSessions[id] {
            try await session.client.cancel(sessionId: session.id)

            // Files still in flight become `.canceled` rather than staying `.transferring`, so the
            // terminal event describes the batch honestly. Completed files keep their status.
            for batchItem in session.acceptedItems {
                let fileID = batchItem.item.id
                let status = session.statusByFileID[fileID] ?? .queued
                if status != .completed && status != .failed {
                    session.statusByFileID[fileID] = .canceled
                }
            }
            activeSendSessions[id] = session

            await emitSendProgress(sessionID: id, kind: .transferCanceled, cache: false)
            // Removed only AFTER the event is emitted — `emitSendProgress` reads the session.
            activeSendSessions[id] = nil

            logger.emit(
                level: .notice,
                event: "transfer.send.canceled",
                scope: "LocalSendRuntimeAdapter",
                context: sendContext(sessionID: session.id, peer: session.peer, traceID: session.traceID)
            )
            return
        }

        await cancelActiveReceiveTransfer(id)
    }

    /// User-initiated cancel of an INBOUND transfer (backlog #23).
    ///
    /// Three things have to happen, and none of them may depend on another succeeding:
    ///
    ///  1. the local `ReceiveSession` is torn down — without this the cancel button did literally
    ///     nothing, and the session went on blocking every later transfer with a 409;
    ///  2. the UI is told, via the `.transferCanceled` that `handleReceiveSessionUpdate` emits when
    ///     the server's state notification lands (so the receive card reaches its terminal state
    ///     through exactly one code path, whoever initiated the cancel);
    ///  3. the SENDER is told, so it stops uploading now instead of waiting out its own timeout.
    ///
    /// (3) is detached and best-effort: an unreachable sender must not stall (1), and its failure
    /// is logged, never surfaced.
    ///
    /// **The outbound POST is fired ONLY from here.** It must never be driven off the observed
    /// `.canceled` transition: a peer-initiated `/cancel` reaches us through that very observation,
    /// so doing so would bounce a `/cancel` straight back at the peer that just cancelled us.
    private func cancelActiveReceiveTransfer(_ id: ActiveTransferProgress.ID) async {
        guard let session = await components.node.runtimeSnapshot().receiveSession,
              session.sessionId == id,
              session.status == .waiting || session.status == .transferring else {
            return
        }
        guard outboundCanceledReceiveSessionIDs.contains(id) == false else {
            return
        }
        rememberOutboundCanceledReceiveSession(id)

        let context = receiveContext(sessionID: id, senderAlias: session.senderInfo.alias)
        // Local teardown first, and unconditionally: it is the only part the user can see fail.
        let canceled = await components.node.cancelReceiveSession(sessionId: id)
        logger.emit(
            level: .notice,
            event: "transfer.receive.canceled",
            scope: "LocalSendRuntimeAdapter",
            context: context,
            attributes: [
                .string("event.action", "user_canceled"),
                .bool("transfer.session_canceled", canceled)
            ]
        )

        guard let port = session.senderInfo.port else {
            // No port means no way to reach the sender — the local cancel above still stands.
            logger.emit(
                level: .warning,
                event: "transfer.receive.cancel_notification_skipped",
                scope: "LocalSendRuntimeAdapter",
                context: context,
                attributes: [.string("result", "sender_port_unknown")]
            )
            return
        }

        let peer = RemotePeer(
            host: session.senderIP,
            port: port,
            protocolType: session.senderInfo.protocolType ?? currentSettings.protocolType
        )
        let fingerprint = session.senderInfo.fingerprint
        let notifier = receiveCancelNotifier
        let notificationLogger = logger
        Task.detached(priority: .utility) {
            do {
                try await notifier(id, peer, fingerprint)
                notificationLogger.emit(
                    level: .info,
                    event: "transfer.receive.cancel_notification_succeeded",
                    scope: "LocalSendRuntimeAdapter",
                    context: context
                )
            } catch {
                // Swallowed on purpose. The sender being unreachable changes nothing about the
                // local cancel, and there is no user-actionable recovery to offer.
                notificationLogger.emit(
                    level: .warning,
                    event: "transfer.receive.cancel_notification_failed",
                    scope: "LocalSendRuntimeAdapter",
                    context: context,
                    attributes: [
                        .string("error.message", SensitiveTextRedaction.redactedDescription(of: error)),
                        .string("error.type", String(describing: type(of: error)))
                    ]
                )
            }
        }
    }

    private func rememberOutboundCanceledReceiveSession(_ id: String) {
        outboundCanceledReceiveSessionIDs.append(id)
        let overflow = outboundCanceledReceiveSessionIDs.count - Self.outboundCanceledReceiveSessionMemory
        if overflow > 0 {
            outboundCanceledReceiveSessionIDs.removeFirst(overflow)
        }
    }

    private static let outboundCanceledReceiveSessionMemory = 64

    private func bindNodeObservers() {
        stateObservationTask?.cancel()
        incomingObservationTask?.cancel()
        withdrawalObservationTask?.cancel()

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
                    IncomingTransferFile(file: file, symbol: Self.symbol(for: file))
                }
                let totalBytes = request.files.values.reduce(Int64.zero) { $0 + $1.size }
                let fileCountLabel = FeatureTransferLocalization.format("incomingRequest.itemCount", mappedFiles.count)
                let totalSizeLabel = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                let subtitle = FeatureTransferLocalization.format("incomingRequest.subtitleFormat", request.info.alias, fileCountLabel, totalSizeLabel)
                // `cache: false` (as with withdrawals below): a cached request would be replayed to any
                // later subscriber, which now means silently re-accepting and re-downloading a request
                // that has already been resolved.
                await incomingBroadcaster.yield(
                    IncomingTransferRequest(
                        id: request.id,
                        deviceName: request.info.alias,
                        subtitle: subtitle,
                        sourceKind: DeviceKind(deviceType: request.info.deviceType),
                        files: mappedFiles,
                        senderFingerprint: request.info.fingerprint
                    ),
                    cache: false
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

        // Third, additive observation: prompts withdrawn by the network side. Nothing else clears
        // `TransferFeatureStore.incomingRequest` without a user action, which is why the sheet used
        // to stick after a sender-initiated cancel.
        withdrawalObservationTask = Task {
            let withdrawalStream = await components.node.incomingTransferRequestWithdrawals()
            for await requestID in withdrawalStream {
                await withdrawalBroadcaster.yield(requestID, cache: false)
                logger.emit(
                    level: .notice,
                    event: "transfer.incoming.request_withdrawn",
                    scope: "LocalSendRuntimeAdapter",
                    context: AppLogContext(
                        attributes: runtimeContext().attributes + [.string("transfer.request_id", requestID)]
                    ),
                    attributes: [.string("event.action", "sender_canceled")]
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

    private func receiveContext(sessionID: String, senderAlias: String) -> AppLogContext {
        AppLogContext(
            attributes: runtimeContext().attributes + [
                .string("transfer.direction", "receiving"),
                .string("transfer.session_id", sessionID),
                .string("peer.alias", senderAlias),
                .string("network.protocol.name", "localsend"),
                .string("network.transport", "tcp")
            ]
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
        case .acceptSubset(let requestID, let fileIDs, let desiredNames):
            // The renamed COUNT, never the names themselves — a filename is user content.
            [
                .string("transfer.request_id", requestID),
                .int("transfer.accepted_file_count", fileIDs.count),
                .int("transfer.renamed_file_count", desiredNames.keys.filter(fileIDs.contains).count)
            ]
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
        case .finishedWithErrors:
            "transfer.receive.session_finished_with_errors"
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
                    // Nothing has begun while the session waits, so `isCurrent` draws no
                    // distinction here: every file is queued.
                    fileState = .queued
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
                case .finishedWithErrors:
                    // Every file is terminal, so per-file state comes from the session's explicit
                    // failure set rather than from `isCurrent` — under a partial failure there is
                    // no single "current" file, and the ones that succeeded are genuinely on disk.
                    fileState = receiveSession.failedFileIDs.contains(record.file.id) ? .failed : .completed
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
                    errorSummary: receiveSession.status == .failed && isCurrent
                        ? FeatureTransferLocalization.string(forKey: "feedback.transferFailed")
                        : nil
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
        case .finishedWithErrors:
            // Terminal, and partially unsuccessful: surfaced as a failure so the user is told some
            // files did not arrive, rather than as a clean completion.
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

    /// Maps the `/prepare-upload` error taxonomy (protocol section 4.1) onto the progress event
    /// kinds so each outcome reaches the user with its own copy instead of a generic failure.
    /// Note this is only correct for `/prepare-upload`; upload- and cancel-time failures keep
    /// `.transferFailed` because the same status codes mean different things there.
    private static func progressKind(forPrepareUploadError error: Error) -> TransferProgressRawEvent.Kind {
        switch error as? LocalSendClientError {
        case .pinRequired:
            return .transferPINRequired
        case .rejected:
            return .transferRejected
        case .blockedByAnotherSession:
            return .transferBlocked
        case .tooManyRequests:
            return .transferRateLimited
        default:
            return .transferFailed
        }
    }

    /// Per-file summary shown next to the failed row. `LocalSendClientError` has no
    /// `LocalizedError` conformance (LocalSendKit is deliberately free of user-facing copy), so
    /// its `localizedDescription` would read "operation couldn't be completed … error 3".
    private static func failureSummary(forPrepareUploadError error: Error) -> String {
        switch error as? LocalSendClientError {
        case .pinRequired:
            return FeatureTransferLocalization.string(forKey: "feedback.transferPINRequired")
        case .rejected:
            return FeatureTransferLocalization.string(forKey: "feedback.transferDeclined")
        case .blockedByAnotherSession:
            return FeatureTransferLocalization.string(forKey: "feedback.transferBlocked")
        case .tooManyRequests:
            return FeatureTransferLocalization.string(forKey: "feedback.transferRateLimited")
        default:
            // Rendered in the transfer card, so it goes through the same PIN redaction as the logs.
            return SensitiveTextRedaction.redactedDescription(of: error)
        }
    }

    /// Renders the per-file progress rows straight from the session's per-file maps.
    ///
    /// The previous shape derived every file's state from a single `currentItemIndex` ("everything
    /// before me is done, everything after me is queued"). That is only true for a strictly
    /// sequential loop; with a bounded pool several files are in flight at once and they finish out
    /// of order, so state has to be tracked per file rather than inferred from position.
    private static func makeSendRawFiles(session: ActiveSendSession) -> [TransferProgressRawFile] {
        session.acceptedItems.enumerated().map { index, batchItem in
            let fileID = batchItem.item.id
            let status = session.statusByFileID[fileID] ?? .queued
            let transferredBytes: Int64
            switch status {
            case .completed:
                transferredBytes = batchItem.byteCount
            case .queued:
                transferredBytes = 0
            default:
                transferredBytes = session.transferredBytesByFileID[fileID] ?? 0
            }

            return TransferProgressRawFile(
                fileID: fileID,
                displayName: batchItem.item.name,
                fileURL: batchItem.item.fileURL,
                order: index,
                attemptIndex: 0,
                state: status,
                declaredTotalBytes: batchItem.byteCount,
                actualTransferredBytes: transferredBytes,
                errorSummary: status == .failed ? session.errorByFileID[fileID] : nil
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
    /// Bytes acknowledged per file, keyed by file id.
    ///
    /// Replaces the old `currentItemIndex` + `bytesTransferredBeforeCurrentFile` pair, which
    /// assumed exactly one file was in flight and that files completed in enumeration order.
    /// Neither holds under a concurrent pool. The batch total is the SUM of these values, so it
    /// stays byte-accurate at any instant regardless of completion order.
    var transferredBytesByFileID: [String: Int64] = [:]
    var statusByFileID: [String: TransferFileProgress.Status] = [:]
    var errorByFileID: [String: String] = [:]

    var totalBatchBytes: Int64 {
        acceptedItems.reduce(0) { $0 + $1.byteCount }
    }

    var transferredBytes: Int64 {
        min(totalBatchBytes, transferredBytesByFileID.values.reduce(0, +))
    }
}

private struct SendBatchItem {
    let item: StagedTransferItem
    let byteCount: Int64
}

/// Result of one file's upload. A value rather than a thrown error so a failure cannot cancel the
/// sibling uploads running in the same task group.
private struct SendFileOutcome: Sendable {
    let fileID: String
    let errorSummary: String?
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
