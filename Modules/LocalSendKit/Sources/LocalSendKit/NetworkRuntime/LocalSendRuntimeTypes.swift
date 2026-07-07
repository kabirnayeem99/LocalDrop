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
    public var requestTimeout: Duration

    public init(
        maximumHeaderBytes: Int = 64 * 1024,
        maximumJSONBodyBytes: Int = 1 * 1024 * 1024,
        requestTimeout: Duration = .seconds(30)
    ) {
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumJSONBodyBytes = maximumJSONBodyBytes
        self.requestTimeout = requestTimeout
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
    case acceptOnly(Set<String>)
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

public final class IncomingTransferRequestBridge: @unchecked Sendable {
    private let state = IncomingTransferRequestBridgeState()

    public init() {}

    public func requests() async -> AsyncStream<IncomingTransferRequest> {
        await state.requests()
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
    private var requestContinuations: [UUID: AsyncStream<IncomingTransferRequest>.Continuation] = [:]
    private var decisionContinuations: [String: CheckedContinuation<IncomingTransferDecision, Never>] = [:]

    func requests() -> AsyncStream<IncomingTransferRequest> {
        let id = UUID()
        return AsyncStream { continuation in
            requestContinuations[id] = continuation
            if let activeRequest {
                continuation.yield(activeRequest)
            }
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeRequestContinuation(id: id)
                }
            }
        }
    }

    func currentRequest() -> IncomingTransferRequest? {
        activeRequest
    }

    func awaitDecision(for request: IncomingTransferRequest) async -> IncomingTransferDecision {
        activeRequest = request
        for continuation in requestContinuations.values {
            continuation.yield(request)
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
        for continuation in requestContinuations.values {
            continuation.finish()
        }
        requestContinuations.removeAll()
        for continuation in pending.values {
            continuation.resume(returning: decision)
        }
    }

    private func removeRequestContinuation(id: UUID) {
        requestContinuations.removeValue(forKey: id)
    }
}
