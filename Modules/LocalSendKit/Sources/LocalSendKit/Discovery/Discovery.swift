import AppLogging
import Foundation
import Network

public struct DiscoveredPeer: Equatable, Sendable {
    public var host: String
    public var info: RegisterInfo
    public var shouldReplyViaRegister: Bool

    public init(host: String, info: RegisterInfo, shouldReplyViaRegister: Bool) {
        self.host = host
        self.info = info
        self.shouldReplyViaRegister = shouldReplyViaRegister
    }
}

public enum MulticastListener {
    public static func decodeAnnouncement(_ data: Data, selfFingerprint: String, host: String) throws -> DiscoveredPeer? {
        let message = try JSONDecoder().decode(MulticastMessage.self, from: data)
        guard message.fingerprint != selfFingerprint else {
            return nil
        }
        return DiscoveredPeer(host: host, info: message.registerInfo, shouldReplyViaRegister: message.announce || message.announcement)
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
    private let logger: AppLogger

    public init(
        multicastHost: String,
        port: UInt16,
        selfFingerprint: String,
        queue: DispatchQueue = DispatchQueue(label: "MulticastListenerRuntime"),
        logger: AppLogger = .disabled(),
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
        self.logger = logger
        self.callback = callback
    }

    public func start() {
        logger.emit(
            level: .info,
            event: "discovery.listener.started",
            scope: "MulticastListenerRuntime"
        )
        group.setReceiveHandler(maximumMessageSize: 64 * 1024, rejectOversizedMessages: true) { [self] message, content, _ in
            guard let data = content else { return }
            guard let remoteHost = Self.remoteHost(from: message.remoteEndpoint) else {
                logger.emit(level: .debug, event: "discovery.multicast.receive_failed", scope: "MulticastListenerRuntime")
                return
            }

            do {
                guard let peer = try MulticastListener.decodeAnnouncement(data, selfFingerprint: selfFingerprint, host: remoteHost) else {
                    return
                }
                callback(peer)
            } catch {
                logger.emit(
                    level: .warning,
                    event: "discovery.multicast.receive_failed",
                    scope: "MulticastListenerRuntime",
                    attributes: [
                        .string("client.address", remoteHost),
                        .string("error.message", error.localizedDescription),
                        .string("error.type", String(describing: type(of: error)))
                    ]
                )
                return
            }
        }
        group.start(queue: queue)
    }

    public func stop() {
        logger.emit(
            level: .info,
            event: "discovery.listener.stopped",
            scope: "MulticastListenerRuntime"
        )
        group.cancel()
    }

    private static func remoteHost(from endpoint: NWEndpoint?) -> String? {
        guard let endpoint else {
            return nil
        }
        if case .hostPort(let host, _) = endpoint {
            return host.debugDescription
        }
        return nil
    }
}

public final class MulticastAnnouncerRuntime: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let logError: @Sendable (Error) -> Void
    private let logger: AppLogger

    public init(
        multicastHost: String,
        port: UInt16,
        queue: DispatchQueue = DispatchQueue(label: "MulticastAnnouncerRuntime"),
        logger: AppLogger = .disabled(),
        logError: @escaping @Sendable (Error) -> Void = { _ in }
    ) throws {
        guard let host = IPv4Address(multicastHost) else {
            throw LocalSendRuntimeError.multicastJoinFailed
        }
        self.connection = NWConnection(host: .ipv4(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        self.queue = queue
        self.logger = logger
        self.logError = logError
    }

    public func start() {
        connection.start(queue: queue)
    }

    public func stop() {
        connection.cancel()
    }

    public func announce(_ message: MulticastMessage) async throws {
        logger.emit(
            level: .debug,
            event: "discovery.announce.started",
            scope: "MulticastAnnouncerRuntime",
            attributes: [.string("peer.protocol_type", message.protocolType.rawValue)]
        )
        for attempt in try MulticastAnnouncer.makeAttempts(for: message) {
            try await Task.sleep(for: .milliseconds(attempt.delayMilliseconds))
            try await send(payload: attempt.payload)
        }
        logger.emit(
            level: .debug,
            event: "discovery.announce.succeeded",
            scope: "MulticastAnnouncerRuntime",
            attributes: [.string("peer.protocol_type", message.protocolType.rawValue)]
        )
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
                    self.logger.emit(
                        level: .warning,
                        event: "discovery.multicast.send_failed",
                        scope: "MulticastAnnouncerRuntime",
                        attributes: [
                            .string("error.message", error.localizedDescription),
                            .string("error.type", String(describing: type(of: error)))
                        ]
                    )
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
    private let peersObserver: (@Sendable ([DiscoveredPeer]) async -> Void)?
    private let logger: AppLogger
    private let stateQueue = DispatchQueue(label: "DiscoveryService.state")
    private var continuations: [UUID: AsyncStream<DiscoveredPeer>.Continuation] = [:]
    private var peersByFingerprint: [String: DiscoveredPeer] = [:]

    public init(
        listener: MulticastListenerRuntime,
        announcer: MulticastAnnouncerRuntime,
        registerResponder: @escaping @Sendable (RegisterInfo) async -> Bool,
        peersObserver: (@Sendable ([DiscoveredPeer]) async -> Void)? = nil,
        logger: AppLogger = .disabled()
    ) {
        self.listener = listener
        self.announcer = announcer
        self.registerResponder = registerResponder
        self.peersObserver = peersObserver
        self.logger = logger
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
            peersByFingerprint.removeAll()
            return values
        }
        for continuation in continuationsToFinish {
            continuation.finish()
        }
        notifyPeersObserver()
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
        let (peersSnapshot, eventName) = stateQueue.sync { () -> ([DiscoveredPeer], String) in
            let existing = peersByFingerprint[peer.info.fingerprint]
            peersByFingerprint[peer.info.fingerprint] = peer
            return (sortedPeersLocked(), existing == nil ? "discovery.peer.discovered" : "discovery.peer.updated")
        }
        logger.emit(
            level: eventName == "discovery.peer.discovered" ? .info : .debug,
            event: eventName,
            scope: "DiscoveryService",
            attributes: [
                .string("peer.id", peer.info.fingerprint),
                .string("peer.alias", peer.info.alias),
                .string("peer.host", peer.host),
                .string("peer.protocol_type", peer.info.protocolType?.rawValue ?? "https")
            ]
        )
        stateQueue.sync {
            for continuation in continuations.values {
                continuation.yield(peer)
            }
        }
        await peersObserver?(peersSnapshot)
        logger.emit(
            level: .debug,
            event: "discovery.peer.snapshot",
            scope: "DiscoveryService",
            attributes: [.int("peer.count", peersSnapshot.count)]
        )

        guard peer.shouldReplyViaRegister else { return }
        let didRespondViaRegister = await registerResponder(peer.info)
        guard didRespondViaRegister == false else { return }
        logger.emit(
            level: .debug,
            event: "discovery.announce.started",
            scope: "DiscoveryService",
            attributes: [
                .string("event.action", "register_fallback"),
                .string("peer.alias", peer.info.alias)
            ]
        )
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
        do {
            try await announcer.respond(to: response)
            logger.emit(
                level: .debug,
                event: "discovery.announce.succeeded",
                scope: "DiscoveryService",
                attributes: [
                    .string("event.action", "register_fallback"),
                    .string("peer.alias", peer.info.alias)
                ]
            )
        } catch {
            logger.emit(
                level: .warning,
                event: "discovery.announce.failed",
                scope: "DiscoveryService",
                attributes: [
                    .string("event.action", "register_fallback"),
                    .string("peer.alias", peer.info.alias),
                    .string("error.message", error.localizedDescription),
                    .string("error.type", String(describing: type(of: error)))
                ]
            )
        }
    }

    public func announce(_ message: MulticastMessage) async throws {
        try await announcer.announce(message)
    }

    public func peersSnapshot() -> [DiscoveredPeer] {
        stateQueue.sync {
            sortedPeersLocked()
        }
    }

    private func removeContinuation(id: UUID) {
        _ = stateQueue.sync {
            continuations.removeValue(forKey: id)
        }
    }

    private func notifyPeersObserver() {
        guard let peersObserver else {
            return
        }
        let peersSnapshot = stateQueue.sync {
            sortedPeersLocked()
        }
        Task {
            await peersObserver(peersSnapshot)
        }
    }

    private func sortedPeersLocked() -> [DiscoveredPeer] {
        peersByFingerprint.values.sorted { lhs, rhs in
            lhs.info.alias < rhs.info.alias
        }
    }
}
