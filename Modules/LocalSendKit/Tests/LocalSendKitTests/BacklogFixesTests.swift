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

// MARK: - Item 37: progress coalescing

struct ProgressCoalescerTests {
    /// `#expect` captures its expression immutably, so `shouldReport` (which is `mutating`) has to
    /// be called into a local first.
    private func makeCoalescer(bytes: Int64, seconds: TimeInterval, clock: MutableClock) -> ProgressCoalescer {
        ProgressCoalescer(
            byteThreshold: bytes,
            timeThreshold: seconds,
            now: { clock.current.timeIntervalSince1970 }
        )
    }

    /// The first sample always publishes — otherwise a transfer smaller than the byte threshold
    /// would show no progress at all until it finished.
    @Test func theFirstSampleAlwaysReports() {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        var coalescer = makeCoalescer(bytes: 1_000, seconds: 10, clock: clock)
        let first = coalescer.shouldReport(bytes: 1)
        #expect(first)
    }

    /// Samples below both thresholds are dropped — this is the ~16,000-updates-per-GB fix.
    @Test func samplesBelowBothThresholdsAreDropped() {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        var coalescer = makeCoalescer(bytes: 1_000, seconds: 10, clock: clock)
        _ = coalescer.shouldReport(bytes: 0)

        clock.current = Date(timeIntervalSince1970: 1)
        let small = coalescer.shouldReport(bytes: 100)
        let alsoSmall = coalescer.shouldReport(bytes: 200)
        #expect(small == false)
        #expect(alsoSmall == false)
    }

    /// Crossing the byte threshold publishes, and resets the baseline.
    @Test func crossingTheByteThresholdReports() {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        var coalescer = makeCoalescer(bytes: 1_000, seconds: 10, clock: clock)
        _ = coalescer.shouldReport(bytes: 0)

        let justUnder = coalescer.shouldReport(bytes: 999)
        let atThreshold = coalescer.shouldReport(bytes: 1_000)
        // Baseline moved to 1_000, so the next 500 bytes are below threshold again.
        let afterReset = coalescer.shouldReport(bytes: 1_500)
        #expect(justUnder == false)
        #expect(atThreshold)
        #expect(afterReset == false)
    }

    /// Bytes-only would go silent on a slow link, so time alone must also publish.
    @Test func crossingTheTimeThresholdReportsEvenOnASlowTransfer() {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        var coalescer = makeCoalescer(bytes: 1_000_000, seconds: 0.1, clock: clock)
        _ = coalescer.shouldReport(bytes: 0)

        let tooSoon = coalescer.shouldReport(bytes: 10)
        clock.current = Date(timeIntervalSince1970: 5)
        let afterTime = coalescer.shouldReport(bytes: 20)
        #expect(tooSoon == false)
        #expect(afterTime, "a slow transfer must still repaint on the time threshold")
    }

    /// A stale out-of-order sample must never walk the count backwards.
    @Test func aBackwardsSampleIsNeverReported() {
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        var coalescer = makeCoalescer(bytes: 10, seconds: 0.001, clock: clock)
        _ = coalescer.shouldReport(bytes: 5_000)

        clock.current = Date(timeIntervalSince1970: 100)
        let backwards = coalescer.shouldReport(bytes: 4_000)
        let unchanged = coalescer.shouldReport(bytes: 5_000)
        #expect(backwards == false)
        #expect(unchanged == false)
    }

    /// The box is what the non-isolated progress callback actually touches.
    @Test func theBoxSharesOneCoalescerAcrossCalls() {
        let box = ProgressCoalescerBox(ProgressCoalescer(byteThreshold: 100, timeThreshold: 3_600))
        #expect(box.shouldReport(bytes: 0))
        #expect(box.shouldReport(bytes: 50) == false)
        #expect(box.shouldReport(bytes: 100))
    }
}

// MARK: - Item 39: per-file receive status replaces stat polling

struct ReceivedFileStatusTests {
    private func twoFileRequest() -> PrepareUploadRequest {
        PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", version: "2.0", fingerprint: "SND"),
            files: [
                "a": FileDto(id: "a", fileName: "a.txt", size: 4, fileType: "text/plain"),
                "b": FileDto(id: "b", fileName: "b.txt", size: 4, fileType: "text/plain")
            ]
        )
    }

    /// Session state must come from tracked per-file status, not from `stat`-ing the destination.
    @Test func perFileStatusTracksTheTransferWithoutTouchingTheFilesystem() async throws {
        let storage = makeStorageDirectory()
        let session = ReceiveSession()
        _ = try await session.prepare(
            request: twoFileRequest(),
            senderIP: "10.0.0.7",
            policy: .acceptAll,
            destinationDirectory: storage,
            sessionIdFactory: { "S1" },
            tokenFactory: { "token-\($0)" }
        )

        let queued = try #require(await session.snapshot())
        #expect(queued.files["a"]?.status == .queued)
        #expect(queued.files["b"]?.status == .queued)

        _ = try await session.upload(sessionId: "S1", fileId: "a", token: "token-a", senderIP: "10.0.0.7", body: Data("aaaa".utf8))
        let midway = try #require(await session.snapshot())
        #expect(midway.files["a"]?.status == .completed)
        #expect(midway.files["b"]?.status == .queued)
        #expect(midway.status == .transferring)

        _ = try await session.upload(sessionId: "S1", fileId: "b", token: "token-b", senderIP: "10.0.0.7", body: Data("bbbb".utf8))
        let done = try #require(await session.snapshot())
        #expect(done.status == .finished)
        #expect(done.files.values.allSatisfy { $0.status == .completed })
    }

    /// Deleting a completed destination underneath the session must NOT rewrite session state —
    /// this is the concrete misbehaviour the `fileExists` polling had.
    @Test func removingAFinishedFileDoesNotRewriteSessionState() async throws {
        let storage = makeStorageDirectory()
        let session = ReceiveSession()
        _ = try await session.prepare(
            request: twoFileRequest(),
            senderIP: "10.0.0.7",
            policy: .acceptAll,
            destinationDirectory: storage,
            sessionIdFactory: { "S1" },
            tokenFactory: { "token-\($0)" }
        )
        _ = try await session.upload(sessionId: "S1", fileId: "a", token: "token-a", senderIP: "10.0.0.7", body: Data("aaaa".utf8))

        // The user (or anything else) removes the saved file mid-session.
        try FileManager.default.removeItem(at: storage.appendingPathComponent("a.txt"))

        _ = try await session.upload(sessionId: "S1", fileId: "b", token: "token-b", senderIP: "10.0.0.7", body: Data("bbbb".utf8))

        let done = try #require(await session.snapshot())
        // Under `fileExists` polling the vanished "a" made the session never reach `.finished`.
        #expect(done.status == .finished)
        #expect(done.files["a"]?.status == .completed)
    }

    /// `failedFileIDs` is derived from the per-file statuses, so there is one source of truth.
    @Test func failedFileIDsIsDerivedFromPerFileStatus() async throws {
        let storage = makeStorageDirectory()
        let session = ReceiveSession()
        _ = try await session.prepare(
            request: twoFileRequest(),
            senderIP: "10.0.0.7",
            policy: .acceptAll,
            destinationDirectory: storage,
            sessionIdFactory: { "S1" },
            tokenFactory: { "token-\($0)" }
        )
        _ = try await session.upload(sessionId: "S1", fileId: "a", token: "token-a", senderIP: "10.0.0.7", body: Data("aaaa".utf8))
        _ = await session.failUpload(sessionId: "S1", fileId: "b", senderIP: "10.0.0.7")

        let snapshot = try #require(await session.snapshot())
        #expect(snapshot.files["b"]?.status == .failed)
        #expect(snapshot.failedFileIDs == ["b"])

        // A successful retry clears both the status and the derived set.
        _ = try await session.upload(sessionId: "S1", fileId: "b", token: "token-b", senderIP: "10.0.0.7", body: Data("bbbb".utf8))
        let retried = try #require(await session.snapshot())
        #expect(retried.files["b"]?.status == .completed)
        #expect(retried.failedFileIDs.isEmpty)
    }
}

// MARK: - Item 49: busy check runs before the PIN check

private func makePINServer(storageDirectory: URL, pin: String) -> LocalSendServer {
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
            pin: pin,
            uploadPolicy: .acceptAll,
            allowDownloads: true,
            storageDirectory: storageDirectory
        )
    )
}

struct PrepareUploadBusyBeforePINTests {
    private func request(files: [String: FileDto]) -> PrepareUploadRequest {
        PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", version: "2.0", fingerprint: "SND", port: 53317, protocolType: .https),
            files: files
        )
    }

    private func oneFileRequest() -> PrepareUploadRequest {
        request(files: ["a": FileDto(id: "a", fileName: "a.txt", size: 4, fileType: "text/plain")])
    }

    private func twoFileRequest() -> PrepareUploadRequest {
        request(files: [
            "a": FileDto(id: "a", fileName: "a.txt", size: 4, fileType: "text/plain"),
            "b": FileDto(id: "b", fileName: "b.txt", size: 4, fileType: "text/plain")
        ])
    }

    private func prepareRequest(
        _ payload: PrepareUploadRequest,
        pin: String?,
        from senderIP: String
    ) throws -> HTTPRequest {
        let body = try JSONEncoder().encode(payload)
        return HTTPRequest(
            method: .post,
            path: "\(LocalSendKit.apiPrefix)/prepare-upload",
            query: pin.map { ["pin": $0] } ?? [:],
            headers: ["Content-Length": "\(body.count)"],
            body: body,
            remoteAddress: senderIP
        )
    }

    /// A busy receiver answers 409 *before* looking at the PIN, as the reference does
    /// (`receive_controller.dart:189-207`). The load-bearing half is the second assertion: a
    /// wrong-PIN probe against a receiver that was never going to accept must not burn one of the
    /// sender's three attempts and lock it out of the transfer it retries later.
    @Test func aBusyReceiverAnswers409WithoutConsumingAPINAttempt() async throws {
        let server = makePINServer(storageDirectory: makeStorageDirectory(), pin: "123456")

        let first = try await server.handle(prepareRequest(oneFileRequest(), pin: "123456", from: "10.0.0.4"))
        #expect(first.statusCode == 200)

        // Wrong PIN *and* busy. Busy wins, and the guess is never evaluated.
        for _ in 0..<5 {
            let blocked = try await server.handle(prepareRequest(oneFileRequest(), pin: "000000", from: "10.0.0.5"))
            #expect(blocked.statusCode == 409)
        }
        #expect(await server.pinAttempts(for: "10.0.0.5") == 0)
    }

    /// A retained `.finishedWithErrors` session is deliberately NOT busy — there is no
    /// session-close affordance and no timeout, so counting it would block every later transfer
    /// forever (the trap `aNewPrepareSupersedesARetainedFinishedWithErrorsSession` covers at the
    /// actor level). Asserted here through the new pre-check, with a PIN configured.
    @Test func aFinishedWithErrorsSessionIsNotBusyAtThePreCheck() async throws {
        let server = makePINServer(storageDirectory: makeStorageDirectory(), pin: "123456")

        let prepared = try await server.handle(prepareRequest(twoFileRequest(), pin: "123456", from: "10.0.0.4"))
        #expect(prepared.statusCode == 200)
        let response = try JSONDecoder().decode(PrepareUploadResponse.self, from: prepared.body.loadData())

        let uploaded = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefix)/upload",
                query: [
                    "sessionId": response.sessionId,
                    "fileId": "a",
                    "token": try #require(response.files["a"])
                ],
                body: Data("aaaa".utf8),
                remoteAddress: "10.0.0.4"
            )
        )
        #expect(uploaded.statusCode == 200)

        await server.failStreamingUpload(sessionId: response.sessionId, fileId: "b", senderIP: "10.0.0.4")
        #expect(await server.receiveSnapshot()?.status == .finishedWithErrors)

        // Not busy: a correct-PIN prepare supersedes the retained session rather than 409ing.
        let second = try await server.handle(prepareRequest(oneFileRequest(), pin: "123456", from: "10.0.0.6"))
        #expect(second.statusCode == 200)
    }
}

// MARK: - Item 55: `upload` staging runs off the actor, finish re-reads from scratch

/// Releases every participant only once `partySize` of them have arrived.
///
/// Used to pin the reentrancy window open deterministically: without it the interleavings the
/// finish phase is written to survive can only be provoked by racing, which is exactly the kind of
/// test that turns flaky.
private actor StagingRendezvous {
    private let partySize: Int
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(partySize: Int) {
        self.partySize = partySize
    }

    func arrive() async {
        arrived += 1
        guard arrived < partySize else {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending {
                waiter.resume()
            }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

struct UploadStagingReentrancyTests {
    private func twoFileRequest() -> PrepareUploadRequest {
        PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", version: "2.0", fingerprint: "SND"),
            files: [
                "a": FileDto(id: "a", fileName: "a.txt", size: 4, fileType: "text/plain"),
                "b": FileDto(id: "b", fileName: "b.txt", size: 4, fileType: "text/plain")
            ]
        )
    }

    private func oneFileRequest() -> PrepareUploadRequest {
        PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", version: "2.0", fingerprint: "SND"),
            files: ["a": FileDto(id: "a", fileName: "a.txt", size: 4, fileType: "text/plain")]
        )
    }

    /// The F6 regression: both finish phases run after both staging hops, so the second one resumes
    /// holding a snapshot that predates the first one's `.completed`. Writing that stale snapshot
    /// back would lose the sibling's completion and strand the session in `.transferring` forever.
    @Test func twoConcurrentUploadsOfDifferentFilesBothComplete() async throws {
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

        // Neither upload may finish until both have staged.
        let rendezvous = StagingRendezvous(partySize: 2)
        await session.setStagingBarrier { _ in await rendezvous.arrive() }

        async let first = session.upload(
            sessionId: "S1", fileId: "a", token: "token-a", senderIP: "10.0.0.4", body: Data("aaaa".utf8)
        )
        async let second = session.upload(
            sessionId: "S1", fileId: "b", token: "token-b", senderIP: "10.0.0.4", body: Data("bbbb".utf8)
        )
        let results = try await [first, second]
        #expect(results == [.success, .success])

        await session.setStagingBarrier(nil)

        let snapshot = try #require(await session.snapshot())
        #expect(snapshot.files["a"]?.status == .completed)
        #expect(snapshot.files["b"]?.status == .completed)
        #expect(snapshot.status == .finished)
        #expect(snapshot.bytesReceived == snapshot.totalBytes)
    }

    /// `stage` moves into the USER'S SAVE FOLDER, so a session torn down while the hop was in
    /// flight must not leave the file sitting in Downloads for a transfer the UI says was canceled.
    @Test func cancelDuringStagingLeavesNothingInTheSaveFolder() async throws {
        let storage = makeStorageDirectory()
        let session = ReceiveSession()
        _ = try await session.prepare(
            request: oneFileRequest(),
            senderIP: "10.0.0.4",
            policy: .acceptAll,
            destinationDirectory: storage,
            sessionIdFactory: { "S1" },
            tokenFactory: { "token-\($0)" }
        )

        // The cancel lands in the exact window between the move and the finish phase.
        await session.setStagingBarrier { [session] _ in
            _ = await session.cancelLocally(sessionId: "S1")
        }

        let result = try await session.upload(
            sessionId: "S1", fileId: "a", token: "token-a", senderIP: "10.0.0.4", body: Data("aaaa".utf8)
        )
        await session.setStagingBarrier(nil)

        // `.blocked` is a 409: the session is gone, so a sender retry gets 409 again rather than
        // walking `resolveDestination`'s ` (2)` probe into a duplicate.
        #expect(result == .blocked)
        #expect(await session.snapshot()?.status == .canceled)

        let leftovers = try FileManager.default.contentsOfDirectory(
            at: storage,
            includingPropertiesForKeys: nil
        )
        #expect(leftovers.isEmpty, "canceled transfer left \(leftovers.map(\.lastPathComponent)) behind")
    }

    /// The F8 contract. Two retries of the same file both deliver the bytes; whichever finish phase
    /// runs second finds the session already closed by the first and must still answer `.success`.
    /// A 409 for bytes we actually wrote would make the sender retry into the ` (2)` probe.
    @Test func theLoserOfAConcurrentSameFileRetryReportsSuccess() async throws {
        let storage = makeStorageDirectory()
        let session = ReceiveSession()
        _ = try await session.prepare(
            request: oneFileRequest(),
            senderIP: "10.0.0.4",
            policy: .acceptAll,
            destinationDirectory: storage,
            sessionIdFactory: { "S1" },
            tokenFactory: { "token-\($0)" }
        )

        let rendezvous = StagingRendezvous(partySize: 2)
        await session.setStagingBarrier { _ in await rendezvous.arrive() }

        async let first = session.upload(
            sessionId: "S1", fileId: "a", token: "token-a", senderIP: "10.0.0.4", body: Data("aaaa".utf8)
        )
        async let second = session.upload(
            sessionId: "S1", fileId: "a", token: "token-a", senderIP: "10.0.0.4", body: Data("aaaa".utf8)
        )
        let results = try await [first, second]
        await session.setStagingBarrier(nil)

        #expect(results == [.success, .success])
        #expect(await session.snapshot()?.status == .finished)

        // Exactly one file, under its real name — no ` (2)` duplicate.
        let saved = try FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .sorted()
        #expect(saved == ["a.txt"])
    }
}
