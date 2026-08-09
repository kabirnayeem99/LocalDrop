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
        guard Fingerprint.matches(message.fingerprint, selfFingerprint) == false else {
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

    /// The peer host as a string usable in a URL.
    ///
    /// A link-local IPv6 peer announces from an address carrying a zone/scope id (`fe80::1%en0`).
    /// The zone is **kept**: `URLComponents` percent-encodes it per RFC 6874 and `URLSession`
    /// honours it, so the announcing peer is reachable — without it the follow-up `/api/.../info`
    /// call to a link-local peer cannot connect at all. See `NetworkEndpointAddress.canonicalHost`
    /// for the measured behaviour and the malformed-zone rules.
    ///
    /// Matching on the `NWEndpoint.Host` cases first keeps the address text canonical; `.ipv6`'s
    /// description is what carries the interface suffix.
    ///
    /// The result is a live-connection host and must not be persisted — the zone is boot-local.
    static func remoteHost(from endpoint: NWEndpoint?) -> String? {
        guard let endpoint, case .hostPort(let host, _) = endpoint else {
            return nil
        }
        let raw: String
        switch host {
        case .ipv4(let address):
            raw = address.debugDescription
        case .ipv6(let address):
            raw = address.debugDescription
        case .name(let name, _):
            raw = name
        @unknown default:
            raw = host.debugDescription
        }
        return NetworkEndpointAddress.canonicalHost(from: raw)
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
    /// A discovered peer plus the moment we last heard from it. `lastSeen` is what TTL eviction
    /// keys off; it is deliberately internal state rather than a field on the public
    /// `DiscoveredPeer`, which stays a pure wire-derived value.
    private struct PeerEntry {
        var peer: DiscoveredPeer
        var lastSeen: Date
    }

    private let listener: MulticastListenerRuntime
    private let announcer: MulticastAnnouncerRuntime
    /// Answers a multicast announcement over TCP `POST /register` — the reference's PRIMARY reply
    /// path (`multicast_discovery.dart:_answerAnnouncement`). Returns `true` when the TCP reply
    /// succeeded, in which case the UDP reply is suppressed; `false` falls back to UDP.
    ///
    /// Takes the whole `DiscoveredPeer` rather than just its `RegisterInfo` because a TCP reply
    /// needs the peer's HOST, which only the announcement's source address carries.
    private let registerResponder: @Sendable (DiscoveredPeer) async -> Bool
    private let peersObserver: (@Sendable ([DiscoveredPeer]) async -> Void)?
    private let logger: AppLogger
    private let stateQueue = DispatchQueue(label: "DiscoveryService.state")
    private var continuations: [UUID: AsyncStream<DiscoveredPeer>.Continuation] = [:]
    private var peersByFingerprint: [String: PeerEntry] = [:]

    // MARK: Liveness policy (item 29)

    /// How often the whole network is re-announced to, so peers that start after us still find us.
    private let reannounceInterval: TimeInterval
    /// How long a peer survives without being heard from before it is evicted.
    private let peerTTL: TimeInterval
    /// Maintenance loop period. Eviction runs every tick; the re-announce runs on the tick that
    /// crosses `reannounceInterval`.
    private let maintenanceInterval: TimeInterval
    /// Injected clock. Required so TTL eviction is testable without sleeping.
    private let now: @Sendable () -> Date
    private let reannounce: (@Sendable () async -> Void)?
    private var maintenanceTask: Task<Void, Never>?
    private var elapsedSinceReannounce: TimeInterval = 0

    public init(
        listener: MulticastListenerRuntime,
        announcer: MulticastAnnouncerRuntime,
        registerResponder: @escaping @Sendable (DiscoveredPeer) async -> Bool,
        peersObserver: (@Sendable ([DiscoveredPeer]) async -> Void)? = nil,
        reannounce: (@Sendable () async -> Void)? = nil,
        reannounceInterval: TimeInterval = 60,
        peerTTL: TimeInterval = 180,
        maintenanceInterval: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { Date() },
        logger: AppLogger = .disabled()
    ) {
        self.listener = listener
        self.announcer = announcer
        self.registerResponder = registerResponder
        self.peersObserver = peersObserver
        self.reannounce = reannounce
        self.reannounceInterval = reannounceInterval
        self.peerTTL = peerTTL
        self.maintenanceInterval = maintenanceInterval
        self.now = now
        self.logger = logger
    }

    public func start() {
        listener.start()
        announcer.start()
        startMaintenanceLoop()
    }

    public func stop() {
        listener.stop()
        announcer.stop()
        stateQueue.sync {
            maintenanceTask?.cancel()
            maintenanceTask = nil
            elapsedSinceReannounce = 0
        }
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
        await store(peer: peer)

        guard peer.shouldReplyViaRegister else { return }
        let didRespondViaRegister = await registerResponder(peer)
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

    /// Records a peer that reached us over TCP `POST /register` rather than multicast.
    ///
    /// The reference does exactly this in `_registerHandler` (`receive_controller.dart`), which
    /// dispatches `RegisterDeviceAction(requestDto.toDevice(request.ip, …))` before answering with
    /// its own `InfoDto` — so a peer that only ever finds us via HTTP-only discovery becomes
    /// visible to us too.
    ///
    /// Crucially this does NOT go through the reply path: an inbound `/register` IS the peer's
    /// reply, and the HTTP response body carries ours. Replying again would loop.
    ///
    /// `host` must be the transport-level caller address, never a body-supplied one. The body's
    /// `port`/`protocol` ARE honoured, because the caller's HTTP source port is ephemeral and
    /// useless for calling back — this mirrors `InfoRegisterDtoExt.toDevice(ip, …)`.
    public func registerInboundPeer(host: String, info: RegisterInfo) async {
        await store(
            peer: DiscoveredPeer(host: host, info: info, shouldReplyViaRegister: false)
        )
    }

    public func announce(_ message: MulticastMessage) async throws {
        try await announcer.announce(message)
    }

    public func peersSnapshot() -> [DiscoveredPeer] {
        stateQueue.sync {
            sortedPeersLocked()
        }
    }

    /// Drops every peer we have not heard from within `peerTTL` and republishes the snapshot.
    ///
    /// Exposed (not private) so tests can drive eviction with an injected clock instead of
    /// sleeping through `maintenanceInterval`.
    public func evictStalePeers() async {
        let deadline = now().addingTimeInterval(-peerTTL)
        let (evicted, peersSnapshot) = stateQueue.sync { () -> ([String], [DiscoveredPeer]) in
            let stale = peersByFingerprint.filter { $0.value.lastSeen < deadline }
            for key in stale.keys {
                peersByFingerprint.removeValue(forKey: key)
            }
            return (stale.values.map(\.peer.info.alias), sortedPeersLocked())
        }
        guard evicted.isEmpty == false else {
            return
        }
        logger.emit(
            level: .info,
            event: "discovery.peer.evicted",
            scope: "DiscoveryService",
            attributes: [
                .int("peer.evicted_count", evicted.count),
                .int("peer.count", peersSnapshot.count)
            ]
        )
        await peersObserver?(peersSnapshot)
    }

    /// One maintenance tick: always evict, and re-announce on the tick that crosses
    /// `reannounceInterval`. Separated from the timer so tests can drive it directly.
    public func runMaintenanceTick() async {
        await evictStalePeers()

        let shouldReannounce = stateQueue.sync { () -> Bool in
            elapsedSinceReannounce += maintenanceInterval
            guard elapsedSinceReannounce >= reannounceInterval else {
                return false
            }
            elapsedSinceReannounce = 0
            return true
        }
        guard shouldReannounce, let reannounce else {
            return
        }
        logger.emit(level: .debug, event: "discovery.reannounce.started", scope: "DiscoveryService")
        await reannounce()
    }

    /// Stores/refreshes a peer and publishes it, without any reply behaviour.
    ///
    /// The `stateQueue.sync` blocks here are deliberately await-free: `stateQueue` is a
    /// non-reentrant serial queue, so suspending inside one (or calling anything that re-enters it,
    /// as `continuation.finish()` does via `onTermination`) deadlocks. See `stop()`.
    private func store(peer: DiscoveredPeer) async {
        let timestamp = now()
        let (peersSnapshot, eventName) = stateQueue.sync { () -> ([DiscoveredPeer], String) in
            // Keyed case-insensitively so a peer that changes fingerprint hex casing between
            // announcements updates its entry instead of creating a duplicate one.
            let key = peer.info.fingerprint.lowercased()
            let existing = peersByFingerprint[key]
            peersByFingerprint[key] = PeerEntry(peer: peer, lastSeen: timestamp)
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
    }

    /// A single detached loop, not a `Task` per tick, so task creation stays bounded. `weak self`
    /// is re-acquired each iteration so a released service ends the loop even if `stop()` was never
    /// called.
    private func startMaintenanceLoop() {
        guard maintenanceInterval > 0 else {
            return
        }
        let interval = maintenanceInterval
        stateQueue.sync {
            maintenanceTask?.cancel()
            maintenanceTask = Task { [weak self] in
                while Task.isCancelled == false {
                    do {
                        try await Task.sleep(for: .seconds(interval))
                    } catch {
                        return
                    }
                    guard let self, Task.isCancelled == false else {
                        return
                    }
                    await self.runMaintenanceTick()
                }
            }
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
        peersByFingerprint.values.map(\.peer).sorted { lhs, rhs in
            lhs.info.alias < rhs.info.alias
        }
    }
}
