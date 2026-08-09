import Darwin
import Foundation
import Network
import Testing
@testable import LocalSendKit

// MARK: - NWEndpoint -> host string parsing
//
// Both the discovery listener and the HTTP listener turn a peer `NWEndpoint` into a plain host
// string, and both go through `NetworkEndpointAddress.canonicalHost(from:)`. The two conversions
// are tested together here so the pair cannot drift: the discovery side decides what we *connect
// to* and the server side decides what we *store as the session owner*, and if only one of them
// kept the IPv6 zone id the two would stop comparing equal.

struct EndpointHostParsingTests {
    /// A link-local IPv6 peer arrives as `fe80::1%en0` and keeps its zone all the way into the URL,
    /// where `URLComponents` applies the RFC 6874 `%` -> `%25` escaping.
    @Test func linkLocalIPv6EndpointKeepsItsInterfaceScope() throws {
        let address = try #require(IPv6Address("fe80::1%en0"))
        let endpoint = NWEndpoint.hostPort(host: .ipv6(address), port: 53_317)
        let host = try #require(MulticastListenerRuntime.remoteHost(from: endpoint))
        #expect(host == "fe80::1%en0")

        let url = LocalSendClient.makeURL(scheme: .http, host: host, port: 53_317, path: "\(LocalSendKit.apiPrefix)/info")
        #expect(url.absoluteString == "http://[fe80::1%25en0]:53317\(LocalSendKit.apiPrefix)/info")
    }

    @Test func ipv4AndNamedEndpointsArePassedThroughUnchanged() throws {
        let ipv4 = try #require(IPv4Address("192.168.1.5"))
        #expect(MulticastListenerRuntime.remoteHost(from: .hostPort(host: .ipv4(ipv4), port: 53_317)) == "192.168.1.5")
        #expect(MulticastListenerRuntime.remoteHost(from: .hostPort(host: .name("peer.local", nil), port: 53_317)) == "peer.local")
        #expect(MulticastListenerRuntime.remoteHost(from: nil) == nil)
        #expect(MulticastListenerRuntime.remoteHost(from: .service(name: "a", type: "_x._tcp", domain: "local", interface: nil)) == nil)
    }

    /// The server side is the one an actual IPv6 peer reaches: this result becomes
    /// `HTTPRequest.remoteAddress` and is compared against the session's stored sender IP. It must
    /// keep the zone for the same reason the client side does — see
    /// `sessionOwnerCheckDoesNotCollapsePeersOnDifferentInterfaces`.
    @Test func serverRemoteAddressKeepsIPv6InterfaceScope() throws {
        let address = try #require(IPv6Address("fe80::1%en0"))
        let endpoint = NWEndpoint.hostPort(host: .ipv6(address), port: 53_317)
        #expect(LocalSendServerRuntime.remoteAddress(from: endpoint) == "fe80::1%en0")
    }

    /// The store side and the connect side must agree byte-for-byte, or a session created from a
    /// `prepare-upload` stops matching the `upload` that follows it.
    @Test func discoveryAndServerAgreeOnTheSameEndpoint() throws {
        let address = try #require(IPv6Address("fe80::1%en0"))
        let endpoint = NWEndpoint.hostPort(host: .ipv6(address), port: 53_317)
        #expect(MulticastListenerRuntime.remoteHost(from: endpoint) == LocalSendServerRuntime.remoteAddress(from: endpoint))
    }

    @Test func serverRemoteAddressPassesThroughIPv4NamesAndUnsupportedEndpoints() throws {
        let ipv4 = try #require(IPv4Address("192.168.1.5"))
        #expect(LocalSendServerRuntime.remoteAddress(from: .hostPort(host: .ipv4(ipv4), port: 53_317)) == "192.168.1.5")
        #expect(LocalSendServerRuntime.remoteAddress(from: .hostPort(host: .name("peer.local", nil), port: 53_317)) == "peer.local")
        #expect(
            LocalSendServerRuntime.remoteAddress(
                from: .service(name: "a", type: "_x._tcp", domain: "local", interface: nil)
            ) == "127.0.0.1"
        )
    }

    @Test func canonicalHostLeavesUnscopedHostsAlone() {
        #expect(NetworkEndpointAddress.canonicalHost(from: "192.168.1.5") == "192.168.1.5")
        #expect(NetworkEndpointAddress.canonicalHost(from: "fe80::1") == "fe80::1")
        #expect(NetworkEndpointAddress.canonicalHost(from: "peer.local") == "peer.local")
    }

    @Test func canonicalHostKeepsWellFormedZones() {
        #expect(NetworkEndpointAddress.canonicalHost(from: "fe80::1%en0") == "fe80::1%en0")
        #expect(NetworkEndpointAddress.canonicalHost(from: "fe80::1%utun3") == "fe80::1%utun3")
        // Numeric scope ids are as valid as interface names, and URLSession accepts both.
        #expect(NetworkEndpointAddress.canonicalHost(from: "fe80::1%11") == "fe80::1%11")
        #expect(NetworkEndpointAddress.canonicalHost(from: "ff02::1%en0") == "ff02::1%en0")
    }

    /// Malformed zones are dropped rather than forwarded. This is a *latency* assertion as much as
    /// a correctness one: handing `URLSession` a bogus zone buys a multi-second connect stall,
    /// where dropping it resolves immediately. The rejection is pure string work, so the whole
    /// case must complete in well under the time a single stalled connect would take.
    @Test func canonicalHostRejectsMalformedZonesWithoutStalling() {
        let start = Date()

        // Two separators: which one is the zone is ambiguous, so neither is trusted.
        #expect(NetworkEndpointAddress.canonicalHost(from: "fe80::1%en0%weird") == "fe80::1")
        // Empty zone.
        #expect(NetworkEndpointAddress.canonicalHost(from: "fe80::1%") == "fe80::1")
        // Path-ish and otherwise out-of-charset zones.
        #expect(NetworkEndpointAddress.canonicalHost(from: "fe80::1%../x") == "fe80::1")
        #expect(NetworkEndpointAddress.canonicalHost(from: "fe80::1%en 0") == "fe80::1")
        #expect(NetworkEndpointAddress.canonicalHost(from: "fe80::1%en0@evil") == "fe80::1")
        #expect(NetworkEndpointAddress.canonicalHost(from: "fe80::1%[]") == "fe80::1")
        // A zone on something that cannot legitimately carry one is dropped, not kept.
        #expect(NetworkEndpointAddress.canonicalHost(from: "192.168.1.5%en0") == "192.168.1.5")
        #expect(NetworkEndpointAddress.canonicalHost(from: "peer.local%en0") == "peer.local")

        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    /// A host that has already been bracketed must not be bracketed again — `[[fe80::1%en0]]` is
    /// not a URL any peer can be reached at.
    @Test func makeURLDoesNotDoubleBracketIPv6Literals() {
        let direct = LocalSendClient.makeURL(scheme: .http, host: "fe80::1%en0", port: 53_317, path: "/x")
        let bracketed = LocalSendClient.makeURL(scheme: .http, host: "[fe80::1%en0]", port: 53_317, path: "/x")
        #expect(direct.absoluteString == "http://[fe80::1%25en0]:53317/x")
        #expect(bracketed.absoluteString == direct.absoluteString)
        #expect(direct.absoluteString.contains("[[") == false)
    }

    /// `makeURL` is public and used to force-unwrap `components.url`. Nothing a caller can pass may
    /// trap the process.
    @Test func makeURLNeverTrapsOnHostileHosts() {
        let hosts = ["", " ", "fe80::1%../x", "a b", "[", "]", "%%%", "host/../x", "ho\u{0}st", "🙂.local"]
        for host in hosts {
            let url = LocalSendClient.makeURL(scheme: .https, host: host, port: 53_317, path: "/x")
            #expect(url.scheme == "https")
        }
    }
}

// MARK: - Session ownership

/// Stripping the zone id collapsed every `fe80::1` on every interface into one identity, and the
/// receive session's owner check is a plain `snapshot.senderIP == senderIP`. That made the check
/// authorise a *different* host that happened to share a link-local address on another interface —
/// which, for link-local addresses, is not a remote possibility but the common case (they are only
/// unique per link, and `::1`-style low addresses recur).
///
/// No network is involved here; this drives `ReceiveSession` directly.
struct SessionOwnerScopeTests {
    private func makeStorageDirectory() -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func sessionOwnerCheckDoesNotCollapsePeersOnDifferentInterfaces() async throws {
        let directory = makeStorageDirectory()
        let session = ReceiveSession()
        let outcome = try await session.prepare(
            request: PrepareUploadRequest(
                info: RegisterInfo(alias: "Sender", fingerprint: "SENDER", port: 1, protocolType: .https),
                files: ["f-1": FileDto(id: "f-1", fileName: "a.txt", size: 4, fileType: "application/octet-stream")]
            ),
            senderIP: "fe80::1%en0",
            policy: .acceptAll,
            destinationDirectory: directory,
            sessionIdFactory: { "session" },
            tokenFactory: { "token-" + $0 }
        )
        guard case .accepted(let response) = outcome else {
            Issue.record("expected acceptance, got \(outcome)")
            return
        }
        let token = try #require(response.files["f-1"])

        // A different interface is a different host.
        #expect(await session.cancel(sessionId: response.sessionId, senderIP: "fe80::1%en1") == false)
        #expect(
            try await session.upload(
                sessionId: response.sessionId,
                fileId: "f-1",
                token: token,
                senderIP: "fe80::1%en1",
                body: Data("XXXX".utf8)
            ) == .forbidden
        )
        #expect(await session.beginUpload(sessionId: response.sessionId, fileId: "f-1", token: token, senderIP: "fe80::1%en1") == false)
        #expect(await session.expectedByteCount(sessionId: response.sessionId, fileId: "f-1", senderIP: "fe80::1%en1") == nil)

        // So is the zone-less form — that is exactly the string the old stripping produced, and it
        // must no longer open the session.
        #expect(await session.cancel(sessionId: response.sessionId, senderIP: "fe80::1") == false)
        #expect(
            try await session.upload(
                sessionId: response.sessionId,
                fileId: "f-1",
                token: token,
                senderIP: "fe80::1",
                body: Data("XXXX".utf8)
            ) == .forbidden
        )

        // The real owner still works, and none of the rejections disturbed the session.
        #expect(await session.snapshot()?.status == .waiting)
        #expect(
            try await session.upload(
                sessionId: response.sessionId,
                fileId: "f-1",
                token: token,
                senderIP: "fe80::1%en0",
                body: Data("OKOK".utf8)
            ) == .success
        )

        try? FileManager.default.removeItem(at: directory)
    }

    @Test func pendingRequestWithdrawalIsAlsoScopedToTheInterface() async throws {
        let session = ReceiveSession()
        #expect(await session.withdrawPendingRequest(senderIP: "fe80::1%en1", incomingRequestBridge: nil) == false)
        #expect(await session.withdrawPendingRequest(senderIP: "fe80::1", incomingRequestBridge: nil) == false)
    }
}

// MARK: - Live reachability round-trip

/// The proof that the zone id is load-bearing, rather than an assertion about what we believe
/// `URLSession` does.
///
/// A real `NWListener` is bound on an OS-assigned port, the machine's actual link-local IPv6
/// addresses are enumerated with `getifaddrs`, and both halves are asserted:
///
///  - the zoned URL (`http://[fe80::…%25en0]:PORT/`) reaches the listener;
///  - the *same* URL with the zone removed does not.
///
/// The negative half is what makes this a regression test — without it, a change that silently
/// re-strips the zone could still pass. Timeouts are short so a hang cannot wedge the suite, and
/// the whole case skips (rather than fails) on a machine with no link-local IPv6 address.
struct LinkLocalReachabilityTests {
    @Test func zonedLinkLocalURLReachesTheListenerAndTheZonelessOneDoesNot() async throws {
        guard let candidate = Self.linkLocalIPv6Addresses().first else {
            // Not a failure: a machine with every interface down has nothing to prove here.
            print("[skip] no link-local IPv6 address on this machine; nothing to reach")
            return
        }

        let listener = try LoopbackHTTPListener()
        let port = try await listener.start()
        defer { listener.stop() }

        let zonedHost = "\(candidate.address)%\(candidate.interface)"
        let zonedURL = LocalSendClient.makeURL(scheme: .http, host: zonedHost, port: Int(port), path: "/probe")
        let zonelessURL = LocalSendClient.makeURL(scheme: .http, host: candidate.address, port: Int(port), path: "/probe")

        #expect(zonedURL.absoluteString.contains("%25\(candidate.interface)"))
        #expect(zonelessURL.absoluteString.contains("%25") == false)

        // Positive half.
        let reachedWithZone = await Self.probe(zonedURL)
        #expect(reachedWithZone == true, "zoned link-local URL \(zonedURL) should reach the local listener")

        // Negative half: identical URL, zone removed. Unroutable — the kernel has no way to pick
        // the interface for a scoped address.
        let reachedWithoutZone = await Self.probe(zonelessURL)
        #expect(reachedWithoutZone == false, "zone-less link-local URL \(zonelessURL) must NOT reach the listener")
    }

    /// Returns true iff the URL answered 200 within the timeout.
    private static func probe(_ url: URL, timeout: TimeInterval = 3) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// The machine's real, up, non-loopback `fe80::/10` addresses, each paired with the interface
    /// that owns it. `getnameinfo` appends `%iface` itself for scoped addresses, so the address is
    /// split back apart and the interface taken from `ifa_name` — the authoritative source.
    static func linkLocalIPv6Addresses() -> [(address: String, interface: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            return []
        }
        defer { freeifaddrs(head) }

        var results: [(address: String, interface: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else {
                continue
            }
            guard let socketAddress = pointer.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET6) else {
                continue
            }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard status == 0 else {
                continue
            }
            let text = String(cString: buffer)
            let bare = text.split(separator: "%").first.map(String.init) ?? text
            guard bare.lowercased().hasPrefix("fe80") else {
                continue
            }
            results.append((bare, String(cString: pointer.pointee.ifa_name)))
        }
        return results
    }
}

/// The smallest thing that can answer `200 OK`: enough HTTP to satisfy `URLSession`, and no more.
/// Deliberately not `LocalSendServerRuntime` — the point is to test reachability of a socket, not
/// the kit's request handling, and a raw responder cannot fail for a protocol reason.
private final class LoopbackHTTPListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackHTTPListener")
    private var connections: [NWConnection] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // `.any` binds dual-stack, so the link-local IPv6 address is one of the addresses this
        // socket answers on.
        self.listener = try NWListener(using: parameters, on: .any)
    }

    /// Starts the listener and returns the OS-assigned port once it is actually ready.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeGuard()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = self?.listener.port?.rawValue else {
                        return
                    }
                    if resumed.claim() {
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    if resumed.claim() {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        queue.async { self.connections.append(connection) }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { _, _, _, _ in
            let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

/// `stateUpdateHandler` can fire `.ready`/`.failed` more than once; a continuation may be resumed
/// only once.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard claimed == false else {
            return false
        }
        claimed = true
        return true
    }
}
