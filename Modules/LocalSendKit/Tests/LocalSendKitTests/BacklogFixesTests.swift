import Foundation
import Testing

@testable import LocalSendKit

// Coverage for the discovery-robustness and protocol-completeness backlog batch:
// items 35, 28, 29 (discovery) and 17, 16, 19 (protocol).

private func makeStorageDirectory() -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeServer(
    storageDirectory: URL,
    peerRegistrationObserver: (@Sendable (String, RegisterInfo) async -> Void)? = nil
) -> LocalSendServer {
    LocalSendServer(
        configuration: LocalSendServerConfiguration(
            registerInfo: RegisterInfo(
                alias: "Receiver",
                deviceModel: "Mac",
                deviceType: .desktop,
                fingerprint: "ABC",
                port: 53317,
                protocolType: .https,
                download: false
            ),
            uploadPolicy: .acceptAll,
            allowDownloads: true,
            storageDirectory: storageDirectory,
            peerRegistrationObserver: peerRegistrationObserver
        )
    )
}

private actor Box<Value: Sendable> {
    private(set) var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ newValue: Value) { value = newValue }
    func append<Element>(_ element: Element) where Value == [Element] { value.append(element) }
}

// MARK: - Item 35: inbound /register adds the caller to the peer list

struct InboundRegisterAddsPeerTests {
    /// The reference's `_registerHandler` records the caller (`RegisterDeviceAction(...)` with
    /// `request.ip`) BEFORE answering with its own info, which is what makes HTTP-only discovery
    /// two-way. Without it a peer that finds us over TCP stays invisible to us.
    @Test func registerRouteReportsTheCallerWithItsTransportAddress() async throws {
        let observed = Box<[(String, RegisterInfo)]>([])
        let server = makeServer(
            storageDirectory: makeStorageDirectory(),
            peerRegistrationObserver: { ip, info in await observed.append((ip, info)) }
        )

        let caller = RegisterInfo(
            alias: "Peer",
            fingerprint: "PEER-FP",
            port: 4242,
            protocolType: .http
        )
        let response = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefix)/register",
                body: .data(try JSONEncoder().encode(caller)),
                remoteAddress: "192.168.1.55"
            )
        )

        #expect(response.statusCode == 200)
        let recorded = await observed.value
        #expect(recorded.count == 1)
        // The HOST comes from the transport, never from the body — a body-supplied host would let a
        // peer point us at a third party.
        #expect(recorded.first?.0 == "192.168.1.55")
        // The body's port/protocol ARE honoured: the caller's HTTP source port is ephemeral and
        // cannot be called back on.
        #expect(recorded.first?.1.port == 4242)
        #expect(recorded.first?.1.protocolType == .http)
    }

    /// Self-discovery must not add us to our own peer list.
    @Test func selfRegisterIsNotRecorded() async throws {
        let observed = Box<[(String, RegisterInfo)]>([])
        let server = makeServer(
            storageDirectory: makeStorageDirectory(),
            peerRegistrationObserver: { ip, info in await observed.append((ip, info)) }
        )

        let response = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefix)/register",
                body: .data(try JSONEncoder().encode(RegisterInfo(alias: "Me", fingerprint: "ABC"))),
                remoteAddress: "192.168.1.55"
            )
        )

        #expect(response.statusCode == 412)
        #expect(await observed.value.isEmpty)
    }

    /// v1 peers register on `/api/localsend/v1/register`; the reference installs both.
    @Test func v1RegisterAlsoRecordsTheCaller() async throws {
        let observed = Box<[(String, RegisterInfo)]>([])
        let server = makeServer(
            storageDirectory: makeStorageDirectory(),
            peerRegistrationObserver: { ip, info in await observed.append((ip, info)) }
        )

        let response = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefixV1)/register",
                body: .data(try JSONEncoder().encode(RegisterInfo(alias: "Legacy", fingerprint: "OLD-FP"))),
                remoteAddress: "10.1.2.3"
            )
        )

        #expect(response.statusCode == 200)
        #expect(await observed.value.count == 1)
    }
}

// MARK: - Items 28 + 29: DiscoveryService reply path and liveness

private func makeDiscoveryService(
    port: UInt16,
    registerResponder: @escaping @Sendable (DiscoveredPeer) async -> Bool = { _ in true },
    peersObserver: (@Sendable ([DiscoveredPeer]) async -> Void)? = nil,
    reannounce: (@Sendable () async -> Void)? = nil,
    reannounceInterval: TimeInterval = 60,
    peerTTL: TimeInterval = 180,
    maintenanceInterval: TimeInterval = 30,
    now: @escaping @Sendable () -> Date = { Date() }
) throws -> DiscoveryService {
    DiscoveryService(
        listener: try MulticastListenerRuntime(
            multicastHost: "224.0.0.180",
            port: port,
            selfFingerprint: "SELF"
        ) { _ in },
        announcer: try MulticastAnnouncerRuntime(multicastHost: "224.0.0.180", port: port),
        registerResponder: registerResponder,
        peersObserver: peersObserver,
        reannounce: reannounce,
        reannounceInterval: reannounceInterval,
        peerTTL: peerTTL,
        maintenanceInterval: maintenanceInterval,
        now: now
    )
}

struct DiscoveryReplyAndLivenessTests {
    /// Item 28: the responder is handed the whole peer, not just its `RegisterInfo` — a TCP reply
    /// is impossible to address without the announcement's source host.
    @Test func registerResponderReceivesThePeerHost() async throws {
        let seenHost = Box<String?>(nil)
        let service = try makeDiscoveryService(port: 54401) { peer in
            await seenHost.set(peer.host)
            return true
        }

        await service.handle(
            peer: DiscoveredPeer(
                host: "192.168.7.7",
                info: RegisterInfo(alias: "Announcer", fingerprint: "ANN"),
                shouldReplyViaRegister: true
            ),
            localInfo: RegisterInfo(alias: "Me", fingerprint: "SELF")
        )

        #expect(await seenHost.value == "192.168.7.7")
    }

    /// Item 35 wiring: a peer learned via inbound `/register` lands in the snapshot, and — unlike a
    /// multicast announcement — must NOT trigger a reply. The POST already was the peer's reply;
    /// answering it again would loop.
    @Test func inboundRegisterStoresThePeerWithoutReplying() async throws {
        let replied = Box(false)
        let snapshots = Box<[[DiscoveredPeer]]>([])
        let service = try makeDiscoveryService(
            port: 54402,
            registerResponder: { _ in
                await replied.set(true)
                return true
            },
            peersObserver: { await snapshots.append($0) }
        )

        await service.registerInboundPeer(
            host: "172.16.0.4",
            info: RegisterInfo(alias: "HttpOnly", fingerprint: "HTTP-FP")
        )

        #expect(await replied.value == false)
        let peers = service.peersSnapshot()
        #expect(peers.count == 1)
        #expect(peers.first?.host == "172.16.0.4")
        #expect(peers.first?.shouldReplyViaRegister == false)
        #expect(await snapshots.value.isEmpty == false)
    }

    /// Item 29: a peer heard from within the TTL is never evicted.
    @Test func freshPeersSurviveAnEvictionSweep() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let service = try makeDiscoveryService(port: 54403, peerTTL: 100, now: { clock.current })

        await service.registerInboundPeer(host: "10.0.0.1", info: RegisterInfo(alias: "A", fingerprint: "A-FP"))
        #expect(service.peersSnapshot().count == 1)

        clock.current = Date(timeIntervalSince1970: 1_050)
        await service.evictStalePeers()
        #expect(service.peersSnapshot().count == 1)
    }

    /// Eviction is per peer, not a blanket clear: only entries past the TTL go.
    @Test func evictionRemovesOnlyPeersOlderThanTheTTL() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let service = try makeDiscoveryService(port: 54404, peerTTL: 100, now: { clock.current })

        await service.registerInboundPeer(host: "10.0.0.1", info: RegisterInfo(alias: "Old", fingerprint: "OLD"))

        clock.current = Date(timeIntervalSince1970: 1_150)
        await service.registerInboundPeer(host: "10.0.0.2", info: RegisterInfo(alias: "New", fingerprint: "NEW"))

        // 1_150 - 100 = 1_050, so "Old" (t=1_000) is stale and "New" (t=1_150) is not.
        await service.evictStalePeers()

        let remaining = service.peersSnapshot()
        #expect(remaining.count == 1)
        #expect(remaining.first?.info.fingerprint == "NEW")
    }

    /// Eviction is published to the peers observer — that snapshot, not the additive
    /// `AsyncStream`, is how the UI learns a peer went away.
    @Test func evictionRepublishesTheSnapshot() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let snapshots = Box<[[DiscoveredPeer]]>([])
        let service = try makeDiscoveryService(
            port: 54407,
            peersObserver: { await snapshots.append($0) },
            peerTTL: 100,
            now: { clock.current }
        )

        await service.registerInboundPeer(host: "10.0.0.1", info: RegisterInfo(alias: "Gone", fingerprint: "GONE"))
        let countAfterDiscovery = await snapshots.value.count

        clock.current = Date(timeIntervalSince1970: 2_000)
        await service.evictStalePeers()

        let published = await snapshots.value
        #expect(published.count == countAfterDiscovery + 1)
        #expect(published.last?.isEmpty == true)

        // A sweep that removes nothing must not republish — that would be pure churn.
        await service.evictStalePeers()
        #expect(await snapshots.value.count == published.count)
    }

    /// Re-announcing keeps us discoverable to peers that launched after our start-up announcement.
    @Test func maintenanceTickReannouncesOnceTheIntervalIsCrossed() async throws {
        let announceCount = Box(0)
        let service = try makeDiscoveryService(
            port: 54405,
            reannounce: { await announceCount.set(await announceCount.value + 1) },
            reannounceInterval: 60,
            maintenanceInterval: 30
        )

        // One tick = 30s of the 60s interval: not yet.
        await service.runMaintenanceTick()
        #expect(await announceCount.value == 0)

        // Second tick crosses 60s.
        await service.runMaintenanceTick()
        #expect(await announceCount.value == 1)

        // Counter reset: the next announce is another two ticks away.
        await service.runMaintenanceTick()
        #expect(await announceCount.value == 1)
        await service.runMaintenanceTick()
        #expect(await announceCount.value == 2)
    }

    /// Hearing from a peer again refreshes its `lastSeen`, so an active peer is never evicted.
    @Test func reannouncementRefreshesLastSeenAndPreventsEviction() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 2_000))
        let service = try makeDiscoveryService(port: 54406, peerTTL: 100, now: { clock.current })

        await service.registerInboundPeer(host: "10.0.0.1", info: RegisterInfo(alias: "Chatty", fingerprint: "CHAT"))

        // Heard from again just before the TTL would have expired.
        clock.current = Date(timeIntervalSince1970: 2_090)
        await service.registerInboundPeer(host: "10.0.0.1", info: RegisterInfo(alias: "Chatty", fingerprint: "CHAT"))

        // Now past the ORIGINAL deadline but within the refreshed one.
        clock.current = Date(timeIntervalSince1970: 2_150)
        await service.evictStalePeers()
        #expect(service.peersSnapshot().count == 1)

        // Silence long enough and it goes.
        clock.current = Date(timeIntervalSince1970: 2_300)
        await service.evictStalePeers()
        #expect(service.peersSnapshot().isEmpty)
    }
}

/// A movable clock, one INSTANCE per test.
///
/// `DiscoveryService.now` is a plain `@Sendable () -> Date`, so the clock cannot be an actor
/// without making every read async. It must not be a global either: swift-testing runs tests in
/// parallel, and a shared mutable `static` would let one test's time travel corrupt another's.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    var current: Date {
        get { lock.withLock { date } }
        set { lock.withLock { date = newValue } }
    }
}

// MARK: - Item 16: text messages never reach disk

struct MessagePayloadTests {
    private func messageRequest(preview: String?, fileType: String = "text/plain") -> PrepareUploadRequest {
        PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", fingerprint: "SND"),
            files: [
                "m1": FileDto(
                    id: "m1",
                    fileName: "message.txt",
                    size: 5,
                    fileType: fileType,
                    preview: preview
                )
            ]
        )
    }

    /// The reference treats a lone text file carrying a `preview` as a MESSAGE: the selection comes
    /// back empty, `prepare-upload` answers 204, and the text goes to history, never to disk.
    @Test func singleTextFileWithPreviewIsAMessageAndYields204() async throws {
        let storage = makeStorageDirectory()
        let server = makeServer(storageDirectory: storage)

        let response = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefix)/prepare-upload",
                body: .data(try JSONEncoder().encode(messageRequest(preview: "hello"))),
                remoteAddress: "10.0.0.2"
            )
        )

        #expect(response.statusCode == 204)
        // No session was created, so no token was ever handed out and nothing can be uploaded.
        #expect(await server.receiveSnapshot() == nil)
        let contents = try FileManager.default.contentsOfDirectory(atPath: storage.path)
        #expect(contents.contains("message.txt") == false)
    }

    /// The reference's null check means an EMPTY preview still counts as a message.
    @Test func emptyPreviewStillCountsAsAMessage() async throws {
        let server = makeServer(storageDirectory: makeStorageDirectory())
        let response = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefix)/prepare-upload",
                body: .data(try JSONEncoder().encode(messageRequest(preview: ""))),
                remoteAddress: "10.0.0.2"
            )
        )
        #expect(response.statusCode == 204)
    }

    /// Regression guard: a lone `.txt` with NO preview is an ordinary document and must still
    /// transfer normally. Getting this wrong would silently swallow real text files.
    @Test func textFileWithoutPreviewIsAnOrdinaryDocument() async throws {
        let server = makeServer(storageDirectory: makeStorageDirectory())
        let response = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefix)/prepare-upload",
                body: .data(try JSONEncoder().encode(messageRequest(preview: nil))),
                remoteAddress: "10.0.0.2"
            )
        )
        #expect(response.statusCode == 200)
    }

    /// Two files are never a message, even when one of them looks like one.
    @Test func multiFileRequestIsNeverAMessage() async throws {
        let server = makeServer(storageDirectory: makeStorageDirectory())
        let request = PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", fingerprint: "SND"),
            files: [
                "m1": FileDto(id: "m1", fileName: "note.txt", size: 5, fileType: "text/plain", preview: "hi"),
                "f1": FileDto(id: "f1", fileName: "photo.png", size: 9, fileType: "image/png")
            ]
        )
        let response = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefix)/prepare-upload",
                body: .data(try JSONEncoder().encode(request)),
                remoteAddress: "10.0.0.2"
            )
        )
        #expect(response.statusCode == 200)
    }

    /// Item 16 is inherited by the v1 route because both versions share `ReceiveSession.prepare`.
    @Test func v1SendRequestAlsoTreatsAMessageAs204() async throws {
        let server = makeServer(storageDirectory: makeStorageDirectory())
        let response = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefixV1)/send-request",
                body: .data(try JSONEncoder().encode(messageRequest(preview: "hello"))),
                remoteAddress: "10.0.0.2"
            )
        )
        #expect(response.statusCode == 204)
    }
}

// MARK: - Item 17: v1 transfer route wire shapes

struct V1TransferRouteTests {
    private func v1PrepareBody() -> Data {
        // A genuine v1 `info`: no fingerprint, no port, no protocol, no version.
        let json = """
        {
          "info": { "alias": "Legacy Sender", "deviceModel": "Android", "deviceType": "mobile" },
          "files": {
            "f1": { "id": "f1", "fileName": "a.txt", "size": 4, "fileType": "text/plain" }
          }
        }
        """
        return Data(json.utf8)
    }

    /// The single most interop-critical shape in item 17: v1 answers with the BARE `{fileId: token}`
    /// map. A v1 peer handed v2's `{sessionId, files}` envelope finds no tokens at all.
    @Test func v1SendRequestReturnsTheBareTokenMap() async throws {
        let server = makeServer(storageDirectory: makeStorageDirectory())
        let response = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefixV1)/send-request",
                body: .data(v1PrepareBody()),
                remoteAddress: "10.0.0.3"
            )
        )

        #expect(response.statusCode == 200)
        let object = try JSONSerialization.jsonObject(with: try response.body.loadData()) as? [String: Any]
        let unwrapped = try #require(object)
        #expect(unwrapped["sessionId"] == nil)
        #expect(unwrapped["files"] == nil)
        #expect(unwrapped["f1"] is String)
    }

    /// v2 keeps the envelope.
    @Test func v2PrepareUploadKeepsTheSessionEnvelope() async throws {
        let server = makeServer(storageDirectory: makeStorageDirectory())
        let response = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefix)/prepare-upload",
                body: .data(v1PrepareBody()),
                remoteAddress: "10.0.0.3"
            )
        )
        #expect(response.statusCode == 200)
        let decoded = try JSONDecoder().decode(PrepareUploadResponse.self, from: try response.body.loadData())
        #expect(decoded.sessionId.isEmpty == false)
        #expect(decoded.files["f1"] != nil)
    }

    /// v1's `info` object has no `fingerprint` — the reference's `InfoRegisterDto` exists solely to
    /// make it nullable, resolving to `''`. Decoding must not fail.
    @Test func prepareUploadAcceptsAnInfoWithoutAFingerprint() throws {
        let decoded = try JSONDecoder().decode(PrepareUploadRequest.self, from: v1PrepareBody())
        #expect(decoded.info.fingerprint == "")
        #expect(decoded.info.alias == "Legacy Sender")
        // Absent `version` resolves to the v1 fallback, not to our own protocol version.
        #expect(decoded.info.version == LocalSendKit.fallbackProtocolVersion)
        #expect(decoded.info.port == nil)
    }

    /// A full v2 `info` still decodes through the normal path, fingerprint preserved.
    @Test func prepareUploadStillDecodesAFullV2Info() throws {
        let request = PrepareUploadRequest(
            info: RegisterInfo(alias: "Modern", fingerprint: "FP", port: 53317, protocolType: .https),
            files: ["f1": FileDto(id: "f1", fileName: "a.txt", size: 4, fileType: "text/plain")]
        )
        let decoded = try JSONDecoder().decode(PrepareUploadRequest.self, from: try JSONEncoder().encode(request))
        #expect(decoded.info.fingerprint == "FP")
        #expect(decoded.info.port == 53317)
    }

    /// v1 `/send` carries no `sessionId`; only `fileId` + `token` are validated.
    @Test func v1SendUploadsWithoutASessionId() async throws {
        let storage = makeStorageDirectory()
        let server = makeServer(storageDirectory: storage)

        let prepare = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefixV1)/send-request",
                body: .data(v1PrepareBody()),
                remoteAddress: "10.0.0.3"
            )
        )
        let tokens = try JSONDecoder().decode([String: String].self, from: try prepare.body.loadData())
        let token = try #require(tokens["f1"])

        let upload = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefixV1)/send",
                query: ["fileId": "f1", "token": token],
                body: .data(Data("abcd".utf8)),
                remoteAddress: "10.0.0.3"
            )
        )

        #expect(upload.statusCode == 200)
        #expect(FileManager.default.fileExists(atPath: storage.appendingPathComponent("a.txt").path))
    }

    /// The token remains the real authorization on the v1 path.
    @Test func v1SendWithAWrongTokenIsForbidden() async throws {
        let server = makeServer(storageDirectory: makeStorageDirectory())
        _ = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefixV1)/send-request",
                body: .data(v1PrepareBody()),
                remoteAddress: "10.0.0.3"
            )
        )

        let upload = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefixV1)/send",
                query: ["fileId": "f1", "token": "not-the-token"],
                body: .data(Data("abcd".utf8)),
                remoteAddress: "10.0.0.3"
            )
        )
        #expect(upload.statusCode == 403)
    }

    /// v1 `/cancel` carries no `sessionId` either; the sender IP authorizes it.
    @Test func v1CancelWithoutASessionIdCancelsTheLiveSession() async throws {
        let server = makeServer(storageDirectory: makeStorageDirectory())
        _ = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefixV1)/send-request",
                body: .data(v1PrepareBody()),
                remoteAddress: "10.0.0.3"
            )
        )

        let cancel = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefixV1)/cancel", remoteAddress: "10.0.0.3")
        )
        #expect(cancel.statusCode == 200)
        #expect(await server.receiveSnapshot()?.status == .canceled)
    }

    /// A v1 cancel must not be able to kill a v2 sender's session — the v1 route accepts no session
    /// id, so without this guard any LAN peer could tear down an in-flight v2 transfer.
    @Test func v1CancelAgainstAV2SessionIsForbidden() async throws {
        let server = makeServer(storageDirectory: makeStorageDirectory())
        let v2Request = PrepareUploadRequest(
            info: RegisterInfo(alias: "Modern", version: "2.0", fingerprint: "FP", port: 53317, protocolType: .https),
            files: ["f1": FileDto(id: "f1", fileName: "a.txt", size: 4, fileType: "text/plain")]
        )
        _ = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefix)/prepare-upload",
                body: .data(try JSONEncoder().encode(v2Request)),
                remoteAddress: "10.0.0.3"
            )
        )

        let cancel = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefixV1)/cancel", remoteAddress: "10.0.0.3")
        )
        #expect(cancel.statusCode == 403)
        #expect(await server.receiveSnapshot()?.status != .canceled)
    }

    /// A v1 sender's own session stays cancellable over v1.
    @Test func v1CancelAgainstAV1SessionIsAllowed() async throws {
        let server = makeServer(storageDirectory: makeStorageDirectory())
        _ = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefixV1)/send-request",
                body: .data(v1PrepareBody()),
                remoteAddress: "10.0.0.3"
            )
        )
        let cancel = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefixV1)/cancel",
                remoteAddress: "10.0.0.3"
            )
        )
        #expect(cancel.statusCode == 200)
    }
}

// MARK: - Item 19: per-file retry after a partial failure

struct PartialFailureRetryTests {
    private func twoFileRequest() -> PrepareUploadRequest {
        PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", version: "2.0", fingerprint: "SND"),
            files: [
                "a": FileDto(id: "a", fileName: "a.txt", size: 4, fileType: "text/plain"),
                "b": FileDto(id: "b", fileName: "b.txt", size: 4, fileType: "text/plain")
            ]
        )
    }

    /// A failure used to set `.failed` and clear the whole session, discarding every token — the
    /// sender's only recovery was re-sending the entire batch. The reference keeps the session in
    /// `finishedWithErrors` with tokens intact.
    @Test func aFailedFileLeavesTheSessionRetryableWithTokensIntact() async throws {
        let storage = makeStorageDirectory()
        let session = ReceiveSession()
        let outcome = try await session.prepare(
            request: twoFileRequest(),
            senderIP: "10.0.0.4",
            policy: .acceptAll,
            destinationDirectory: storage,
            sessionIdFactory: { "S1" },
            tokenFactory: { "token-\($0)" }
        )
        guard case .accepted = outcome else {
            Issue.record("expected accepted")
            return
        }

        // "a" succeeds, "b" fails.
        _ = try await session.upload(sessionId: "S1", fileId: "a", token: "token-a", senderIP: "10.0.0.4", body: Data("aaaa".utf8))
        #expect(await session.failUpload(sessionId: "S1", fileId: "b", senderIP: "10.0.0.4"))

        let snapshot = try #require(await session.snapshot())
        #expect(snapshot.status == .finishedWithErrors)
        #expect(snapshot.failedFileIDs == ["b"])
        // The session is RETAINED — this is what makes the retry below possible.
        #expect(await session.currentSessionId() == "S1")

        // Retry just the failed file with its original token.
        let retry = try await session.upload(sessionId: "S1", fileId: "b", token: "token-b", senderIP: "10.0.0.4", body: Data("bbbb".utf8))
        #expect(retry == .success)

        let final = try #require(await session.snapshot())
        #expect(final.status == .finished)
        #expect(final.failedFileIDs.isEmpty)
    }

    /// A session where nothing succeeded is still a whole-session failure — there is no partial
    /// result worth retaining.
    @Test func aSessionWithNoSuccessesStillFailsOutright() async throws {
        let session = ReceiveSession()
        let request = PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", version: "2.0", fingerprint: "SND"),
            files: ["a": FileDto(id: "a", fileName: "a.txt", size: 4, fileType: "text/plain")]
        )
        _ = try await session.prepare(
            request: request,
            senderIP: "10.0.0.4",
            policy: .acceptAll,
            destinationDirectory: makeStorageDirectory(),
            sessionIdFactory: { "S1" },
            tokenFactory: { "token-\($0)" }
        )

        #expect(await session.failUpload(sessionId: "S1", fileId: "a", senderIP: "10.0.0.4"))
        #expect(await session.snapshot()?.status == .failed)
        #expect(await session.currentSessionId() == nil)
    }

    /// The permanent-409 trap: a RETAINED `finishedWithErrors` session would otherwise block every
    /// later transfer forever, because there is no session timeout anywhere.
    @Test func aNewPrepareSupersedesARetainedFinishedWithErrorsSession() async throws {
        let storage = makeStorageDirectory()
        let session = ReceiveSession()
        _ = try await session.prepare(
            request: twoFileRequest(),
            senderIP: "10.0.0.4",
            policy: .acceptAll,
            destinationDirectory: storage,
            sessionIdFactory: { "S1" },
            tokenFactory: { "token-\($0)" }
        )
        _ = try await session.upload(sessionId: "S1", fileId: "a", token: "token-a", senderIP: "10.0.0.4", body: Data("aaaa".utf8))
        _ = await session.failUpload(sessionId: "S1", fileId: "b", senderIP: "10.0.0.4")
        #expect(await session.snapshot()?.status == .finishedWithErrors)

        let second = try await session.prepare(
            request: twoFileRequest(),
            senderIP: "10.0.0.5",
            policy: .acceptAll,
            destinationDirectory: storage,
            sessionIdFactory: { "S2" },
            tokenFactory: { "second-\($0)" }
        )
        guard case .accepted(let response) = second else {
            Issue.record("a new prepare must not be blocked by a retained finishedWithErrors session")
            return
        }
        #expect(response.sessionId == "S2")
    }

    /// A `finishedWithErrors` session is terminal for cancel purposes: the reference rejects a
    /// cancel for anything but `waiting`/`sending`.
    @Test func cancelIsRejectedForAFinishedWithErrorsSession() async throws {
        let storage = makeStorageDirectory()
        let session = ReceiveSession()
        _ = try await session.prepare(
            request: twoFileRequest(),
            senderIP: "10.0.0.4",
            policy: .acceptAll,
            destinationDirectory: storage,
            sessionIdFactory: { "S1" },
            tokenFactory: { "token-\($0)" }
        )
        _ = try await session.upload(sessionId: "S1", fileId: "a", token: "token-a", senderIP: "10.0.0.4", body: Data("aaaa".utf8))
        _ = await session.failUpload(sessionId: "S1", fileId: "b", senderIP: "10.0.0.4")

        #expect(await session.cancel(sessionId: "S1", senderIP: "10.0.0.4") == false)
    }
}
