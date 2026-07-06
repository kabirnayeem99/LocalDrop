import Foundation
import Network

public struct DiscoveredPeer: Equatable, Sendable {
    public var info: RegisterInfo
    public var shouldReplyViaRegister: Bool

    public init(info: RegisterInfo, shouldReplyViaRegister: Bool) {
        self.info = info
        self.shouldReplyViaRegister = shouldReplyViaRegister
    }
}

public enum MulticastListener {
    public static func decodeAnnouncement(_ data: Data, selfFingerprint: String) throws -> DiscoveredPeer? {
        let message = try JSONDecoder().decode(MulticastMessage.self, from: data)
        guard message.fingerprint != selfFingerprint else {
            return nil
        }
        return DiscoveredPeer(info: message.registerInfo, shouldReplyViaRegister: message.announce || message.announcement)
    }
}

public struct AnnouncementAttempt: Equatable, Sendable {
    public var payload: Data
    public var delayMilliseconds: Int

    public init(payload: Data, delayMilliseconds: Int) {
        self.payload = payload
        self.delayMilliseconds = delayMilliseconds
    }
}

public enum MulticastAnnouncer {
    public static func makeAttempts(for message: MulticastMessage) throws -> [AnnouncementAttempt] {
        let payload = try JSONEncoder().encode(message)
        return [
            AnnouncementAttempt(payload: payload, delayMilliseconds: 100),
            AnnouncementAttempt(payload: payload, delayMilliseconds: 500),
            AnnouncementAttempt(payload: payload, delayMilliseconds: 2000)
        ]
    }
}

public protocol LegacyScannerClient: Sendable {
    func register(host: String, info: RegisterInfo) async throws -> RegisterInfo
}

public struct LegacyHTTPScanner: Sendable {
    private let client: any LegacyScannerClient

    public init(client: any LegacyScannerClient) {
        self.client = client
    }

    public func scan(
        hosts: [String],
        info: RegisterInfo,
        fallback: @escaping @Sendable (String) async -> RegisterInfo?
    ) async -> [RegisterInfo] {
        await withTaskGroup(of: RegisterInfo?.self) { group in
            for host in hosts {
                group.addTask {
                    do {
                        return try await client.register(host: host, info: info)
                    } catch {
                        return await fallback(host)
                    }
                }
            }

            var results: [RegisterInfo] = []
            for await result in group {
                if let result {
                    results.append(result)
                }
            }
            return results.sorted { $0.alias < $1.alias }
        }
    }
}

public final class MulticastListenerRuntime: @unchecked Sendable {
    private let selfFingerprint: String
    private let group: NWConnectionGroup
    private let queue: DispatchQueue
    private let callback: @Sendable (DiscoveredPeer) -> Void

    public init(
        multicastHost: String,
        port: UInt16,
        selfFingerprint: String,
        queue: DispatchQueue = DispatchQueue(label: "MulticastListenerRuntime"),
        callback: @escaping @Sendable (DiscoveredPeer) -> Void
    ) throws {
        guard let host = IPv4Address(multicastHost) else {
            throw LocalSendRuntimeError.multicastJoinFailed
        }
        let endpoint = NWEndpoint.hostPort(host: .ipv4(host), port: NWEndpoint.Port(rawValue: port)!)
        let group = try NWMulticastGroup(for: [endpoint])
        self.group = NWConnectionGroup(with: group, using: .udp)
        self.selfFingerprint = selfFingerprint
        self.queue = queue
        self.callback = callback
    }

    public func start() {
        group.setReceiveHandler(maximumMessageSize: 64 * 1024, rejectOversizedMessages: true) { [self] _, content, _ in
            guard let data = content else { return }
            guard let peer = try? MulticastListener.decodeAnnouncement(data, selfFingerprint: selfFingerprint) else {
                return
            }
            callback(peer)
        }
        group.start(queue: queue)
    }

    public func stop() {
        group.cancel()
    }
}

public final class MulticastAnnouncerRuntime: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let logError: @Sendable (Error) -> Void

    public init(
        multicastHost: String,
        port: UInt16,
        queue: DispatchQueue = DispatchQueue(label: "MulticastAnnouncerRuntime"),
        logError: @escaping @Sendable (Error) -> Void = { _ in }
    ) throws {
        guard let host = IPv4Address(multicastHost) else {
            throw LocalSendRuntimeError.multicastJoinFailed
        }
        self.connection = NWConnection(host: .ipv4(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        self.queue = queue
        self.logError = logError
    }

    public func start() {
        connection.start(queue: queue)
    }

    public func stop() {
        connection.cancel()
    }

    public func announce(_ message: MulticastMessage) async throws {
        for attempt in try MulticastAnnouncer.makeAttempts(for: message) {
            try await Task.sleep(for: .milliseconds(attempt.delayMilliseconds))
            try await send(payload: attempt.payload)
        }
    }

    public func respond(to message: MulticastMessage) async throws {
        let payload = try JSONEncoder().encode(message)
        try await send(payload: payload)
    }

    private func send(payload: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    self.logError(error)
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }
}

public final class DiscoveryService: @unchecked Sendable {
    private let listener: MulticastListenerRuntime
    private let announcer: MulticastAnnouncerRuntime
    private let registerResponder: @Sendable (RegisterInfo) async -> Bool
    private let stateQueue = DispatchQueue(label: "DiscoveryService.state")
    private var continuations: [UUID: AsyncStream<DiscoveredPeer>.Continuation] = [:]

    public init(
        listener: MulticastListenerRuntime,
        announcer: MulticastAnnouncerRuntime,
        registerResponder: @escaping @Sendable (RegisterInfo) async -> Bool
    ) {
        self.listener = listener
        self.announcer = announcer
        self.registerResponder = registerResponder
    }

    public func start() {
        listener.start()
        announcer.start()
    }

    public func stop() {
        listener.stop()
        announcer.stop()
        // Snapshot and clear under the lock, then finish() each continuation *after*
        // releasing it. AsyncStream.Continuation.finish() synchronously invokes
        // onTermination, which (via removeContinuation(id:)) re-enters stateQueue.sync
        // — finishing while still holding the queue would deadlock (this serial queue
        // does not support reentrant sync calls).
        let continuationsToFinish = stateQueue.sync { () -> [AsyncStream<DiscoveredPeer>.Continuation] in
            let values = Array(continuations.values)
            continuations.removeAll()
            return values
        }
        for continuation in continuationsToFinish {
            continuation.finish()
        }
    }

    public func stream() -> AsyncStream<DiscoveredPeer> {
        let id = UUID()
        return AsyncStream { continuation in
            stateQueue.sync {
                continuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: id)
            }
        }
    }

    public func handle(peer: DiscoveredPeer, localInfo: RegisterInfo) async {
        stateQueue.sync {
            for continuation in continuations.values {
                continuation.yield(peer)
            }
        }

        guard peer.shouldReplyViaRegister else { return }
        let didRespondViaRegister = await registerResponder(peer.info)
        guard didRespondViaRegister == false else { return }
        let response = MulticastMessage(
            alias: localInfo.alias,
            version: localInfo.version,
            deviceModel: localInfo.deviceModel,
            deviceType: localInfo.deviceType,
            fingerprint: localInfo.fingerprint,
            port: localInfo.port ?? 0,
            protocolType: localInfo.protocolType ?? .https,
            download: localInfo.download,
            announce: false
        )
        try? await announcer.respond(to: response)
    }

    public func announce(_ message: MulticastMessage) async throws {
        try await announcer.announce(message)
    }

    private func removeContinuation(id: UUID) {
        _ = stateQueue.sync {
            continuations.removeValue(forKey: id)
        }
    }
}
