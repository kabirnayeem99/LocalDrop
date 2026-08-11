import Foundation

public enum LocalSendRuntimeError: Error, Equatable {
    case listenerStartFailed
    case multicastJoinFailed
    case tlsIdentityUnavailable
    case connectionReadFailed
    case connectionWriteFailed
    case bodyTooLarge
    case requestTimeout
    case incomingTransferRequestNotPending
}

public struct LocalSendRuntimeLimits: Sendable, Equatable {
    public var maximumHeaderBytes: Int
    public var maximumJSONBodyBytes: Int
    /// Per-read inactivity deadline. Between requests on a persistent connection this is the idle
    /// deadline that stops a LAN peer pinning a task, a connection slot and an outstanding
    /// `receive` continuation indefinitely.
    public var requestTimeout: Duration
    public var maximumConcurrentConnections: Int
    /// Absolute backstop on a single staged upload body, applied on top of the `file.size`
    /// declared in the accepted `prepare-upload`. Chunked bodies carry no declared length, so
    /// without this a hostile peer streams unbounded bytes into the user's save directory.
    public var maximumUploadBodyBytes: Int64
    public var maximumRequestsPerConnection: Int

    // New fields are appended, never inserted: the memberwise initializer is public API and
    // existing labeled-argument call sites must keep compiling.
    public init(
        maximumHeaderBytes: Int = 64 * 1024,
        maximumJSONBodyBytes: Int = 1 * 1024 * 1024,
        requestTimeout: Duration = .seconds(30),
        maximumConcurrentConnections: Int = 64,
        maximumUploadBodyBytes: Int64 = 8 * 1024 * 1024 * 1024,
        maximumRequestsPerConnection: Int = 100
    ) {
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumJSONBodyBytes = maximumJSONBodyBytes
        self.requestTimeout = requestTimeout
        self.maximumConcurrentConnections = maximumConcurrentConnections
        self.maximumUploadBodyBytes = maximumUploadBodyBytes
        self.maximumRequestsPerConnection = maximumRequestsPerConnection
    }
}

public struct LocalSendServerRuntimeBoundEndpoint: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var protocolType: ProtocolType

    public init(host: String, port: Int, protocolType: ProtocolType) {
        self.host = host
        self.port = port
        self.protocolType = protocolType
    }
}

public struct IncomingTransferRequest: Identifiable, Equatable, Sendable {
    public var id: String
    public var senderIP: String
    public var info: RegisterInfo
    public var files: [String: FileDto]

    public init(
        id: String = UUID().uuidString,
        senderIP: String,
        info: RegisterInfo,
        files: [String: FileDto]
    ) {
        self.id = id
        self.senderIP = senderIP
        self.info = info
        self.files = files
    }
}

public enum IncomingTransferDecision: Equatable, Sendable {
    case reject
    case acceptAll
    /// Accept a subset of the offered fileIDs, optionally renaming some of them.
    ///
    /// `desiredNames` maps fileID -> the name the *receiver* wants the file saved under, mirroring
    /// the reference's per-file `desiredName`. It is keyed by fileID (not by filename) because two
    /// files in one batch may legitimately share a name. Entries for fileIDs outside the accepted
    /// set are ignored; a missing, empty or whitespace-only entry means "keep the sender's name".
    ///
    /// The names are UNTRUSTED — they come from a text field — and are put through exactly the same
    /// `destinationPlan` sanitizer, `..` rejection, `NAME_MAX` budget and collision probe as a
    /// sender-supplied `fileName`. See `ReceiveSession.prepare`.
    case acceptOnly(Set<String>, desiredNames: [String: String] = [:])
    case noTransferNeeded
}

public struct LocalSendServerStateSnapshot: Equatable, Sendable {
    public var receiveSession: ReceiveSessionSnapshot?
    public var sendSessions: [SendSessionSnapshot]

    public init(
        receiveSession: ReceiveSessionSnapshot?,
        sendSessions: [SendSessionSnapshot]
    ) {
        self.receiveSession = receiveSession
        self.sendSessions = sendSessions
    }
}

public enum LocalSendNodeLifecycleState: Equatable, Sendable {
    case stopped
    case starting
    case running(LocalSendServerRuntimeBoundEndpoint)
    case stopping
}

public struct LocalSendRuntimeSnapshot: Equatable, Sendable {
    public var lifecycle: LocalSendNodeLifecycleState
    public var discoveredPeers: [DiscoveredPeer]
    public var pendingIncomingRequest: IncomingTransferRequest?
    public var receiveSession: ReceiveSessionSnapshot?
    public var sendSessions: [SendSessionSnapshot]

    public init(
        lifecycle: LocalSendNodeLifecycleState,
        discoveredPeers: [DiscoveredPeer] = [],
        pendingIncomingRequest: IncomingTransferRequest? = nil,
        receiveSession: ReceiveSessionSnapshot? = nil,
        sendSessions: [SendSessionSnapshot] = []
    ) {
        self.lifecycle = lifecycle
        self.discoveredPeers = discoveredPeers
        self.pendingIncomingRequest = pendingIncomingRequest
        self.receiveSession = receiveSession
        self.sendSessions = sendSessions
    }
}

/// A prompt appearing, or that same prompt being withdrawn by the network side (a sender-initiated
/// `/cancel` arriving while the accept/decline prompt is still up) rather than answered by the user.
public enum IncomingTransferRequestEvent: Sendable, Equatable {
    case request(IncomingTransferRequest)
    case withdrawal(requestID: String)
}

public final class IncomingTransferRequestBridge: @unchecked Sendable {
    private let state = IncomingTransferRequestBridgeState()

    public init() {}

    /// Prompts and their withdrawals on ONE ordered stream.
    ///
    /// Deliberately a single event enum rather than two additive streams: a withdrawal is only ever
    /// emitted for a request that was already emitted (`withdraw(requestID:)` is a no-op unless
    /// `awaitDecision(for:)` registered the matching decision continuation), so the source ordering
    /// is already total. Fanning the two facts out over separate continuation sets would hand them
    /// to separate consumers and manufacture an out-of-order case the producer cannot actually
    /// produce. One continuation set is what makes request-before-withdrawal hold for *every*
    /// subscriber, all the way down to the UI.
    public func events() async -> AsyncStream<IncomingTransferRequestEvent> {
        await state.events()
    }

    /// Resolves an in-flight prompt as a rejection without disturbing the request stream.
    /// Returns `true` only if this call is the one that resumed the awaiting decision.
    @discardableResult
    public func withdraw(requestID: String) async -> Bool {
        await state.withdraw(requestID: requestID)
    }

    public func currentRequest() async -> IncomingTransferRequest? {
        await state.currentRequest()
    }

    public func respond(
        to requestID: String,
        decision: IncomingTransferDecision
    ) async throws {
        try await state.respond(to: requestID, decision: decision)
    }

    public func finishPending(decision: IncomingTransferDecision = .reject) async {
        await state.finishPending(decision: decision)
    }

    func awaitDecision(for request: IncomingTransferRequest) async -> IncomingTransferDecision {
        await state.awaitDecision(for: request)
    }
}

private actor IncomingTransferRequestBridgeState {
    private var activeRequest: IncomingTransferRequest?
    private var eventContinuations: [UUID: AsyncStream<IncomingTransferRequestEvent>.Continuation] = [:]
    private var decisionContinuations: [String: CheckedContinuation<IncomingTransferDecision, Never>] = [:]

    /// A new subscriber is replayed the pending `activeRequest` (as `.request`) if there is one.
    /// Withdrawals are never replayed, which falls out naturally: only `activeRequest` is retained,
    /// and `withdraw` clears it before yielding.
    func events() -> AsyncStream<IncomingTransferRequestEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            if let activeRequest {
                continuation.yield(.request(activeRequest))
            }
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeEventContinuation(id: id)
                }
            }
        }
    }

    func currentRequest() -> IncomingTransferRequest? {
        activeRequest
    }

    /// Mirrors `respond(to:decision:)`'s `decisionContinuations.removeValue(forKey:)` guard: that
    /// removal is exactly what makes UI-respond and network-cancel safe against each other —
    /// whoever removes the continuation first wins, and the loser is a no-op. A
    /// `CheckedContinuation` resumed twice traps, so this must be airtight.
    ///
    /// Note what it deliberately does NOT do: *finish* `eventContinuations`. `finishPending`
    /// finishes them all and clears them, which would permanently kill the adapter's `for await`
    /// loop — `bindNodeObservers()` is only called from `start()`, so a single cancel would leave
    /// the app unable to show any further prompt until a full runtime restart. Yielding a
    /// `.withdrawal` into that same set is exactly what keeps it ordered behind its `.request`.
    func withdraw(requestID: String) -> Bool {
        guard let continuation = decisionContinuations.removeValue(forKey: requestID) else {
            return false
        }
        if activeRequest?.id == requestID {
            activeRequest = nil
        }
        for eventContinuation in eventContinuations.values {
            eventContinuation.yield(.withdrawal(requestID: requestID))
        }
        continuation.resume(returning: .reject)
        return true
    }

    func awaitDecision(for request: IncomingTransferRequest) async -> IncomingTransferDecision {
        activeRequest = request
        for continuation in eventContinuations.values {
            continuation.yield(.request(request))
        }

        return await withCheckedContinuation { continuation in
            decisionContinuations[request.id] = continuation
        }
    }

    func respond(
        to requestID: String,
        decision: IncomingTransferDecision
    ) throws {
        guard activeRequest?.id == requestID,
              let continuation = decisionContinuations.removeValue(forKey: requestID) else {
            throw LocalSendRuntimeError.incomingTransferRequestNotPending
        }

        activeRequest = nil
        continuation.resume(returning: decision)
    }

    func finishPending(decision: IncomingTransferDecision) {
        let pending = decisionContinuations
        decisionContinuations.removeAll()
        activeRequest = nil
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll()
        for continuation in pending.values {
            continuation.resume(returning: decision)
        }
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }
}
