import Foundation
import Testing
@testable import LocalSendKit

/// Backlog item #59 — the client (sender) side of LocalSend's per-peer version routing.
///
/// `ApiRoute.target` (`common/lib/api_route_builder.dart:28-36`) picks the path for EVERY client
/// route from `target.version`, not just `register`. LocalDrop was already a correct v1 *server*
/// but hardcoded the v2 prefix on every outbound request except the register reply, so initiating a
/// transfer to a v1-pinned peer 404'd.
struct ClientV1RoutingTests {
    /// Records every request it is handed and replies with whatever the caller queued.
    actor RecordingTransport: LocalSendTransport {
        private var requests: [HTTPRequest] = []
        private let responder: @Sendable (HTTPRequest) throws -> HTTPResponse

        init(responder: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) {
            self.responder = responder
        }

        func send(
            _ request: HTTPRequest,
            to peer: RemotePeer,
            progress: (@Sendable (FileTransferProgress) -> Void)?
        ) async throws -> HTTPResponse {
            requests.append(request)
            return try responder(request)
        }

        func recordedRequests() -> [HTTPRequest] {
            requests
        }
    }

    /// Observes what the client actually put on the wire while a real `LocalSendServer` answers it.
    actor RequestLog {
        private(set) var requests: [HTTPRequest] = []

        func record(_ request: HTTPRequest) {
            requests.append(request)
        }
    }

    private static func registerInfo(alias: String) -> RegisterInfo {
        RegisterInfo(alias: alias, fingerprint: "FPR-\(alias)", port: 53317, protocolType: .https)
    }

    private static func registerResponder() -> @Sendable (HTTPRequest) throws -> HTTPResponse {
        { _ in
            HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(Self.registerInfo(alias: "Receiver"))
            )
        }
    }

    // MARK: - register (written before the routing change touched it)

    /// `register` is the one v1 client behaviour that already worked, and it had zero regression
    /// coverage. Pinned here first so the routing rework cannot silently break it.
    @Test func registerTargetsTheV1PathForAV1Peer() async throws {
        let transport = RecordingTransport(responder: Self.registerResponder())
        let client = LocalSendClient(transport: transport)
        let peer = RemotePeer(host: "10.0.0.9", port: 53317, protocolType: .https)

        _ = try await client.register(with: Self.registerInfo(alias: "Sender"), to: peer, apiVersion: .v1)

        let paths = await transport.recordedRequests().map(\.path)
        #expect(paths == ["\(LocalSendKit.apiPrefixV1)/register"])
    }

    @Test func registerTargetsTheV2PathByDefault() async throws {
        let transport = RecordingTransport(responder: Self.registerResponder())
        let client = LocalSendClient(transport: transport)
        let peer = RemotePeer(host: "10.0.0.9", port: 53317, protocolType: .https)

        _ = try await client.register(with: Self.registerInfo(alias: "Sender"), to: peer)

        let paths = await transport.recordedRequests().map(\.path)
        #expect(paths == ["\(LocalSendKit.apiPrefix)/register"])
    }

    /// Precedence rule: the explicit `apiVersion:` argument is an OVERRIDE. The discovery responder
    /// passes it before any `RemotePeer.apiVersion` has been established, so it must win; when it is
    /// omitted the peer's own version decides.
    @Test func registerExplicitAPIVersionOverridesThePeerVersion() async throws {
        let transport = RecordingTransport(responder: Self.registerResponder())
        let client = LocalSendClient(transport: transport)
        let v2Peer = RemotePeer(host: "10.0.0.9", port: 53317, protocolType: .https, apiVersion: .v2)
        let v1Peer = RemotePeer(host: "10.0.0.9", port: 53317, protocolType: .https, apiVersion: .v1)

        // Explicit argument wins in both directions...
        _ = try await client.register(with: Self.registerInfo(alias: "Sender"), to: v2Peer, apiVersion: .v1)
        _ = try await client.register(with: Self.registerInfo(alias: "Sender"), to: v1Peer, apiVersion: .v2)
        // ...and omitting it falls back to the peer's own version.
        _ = try await client.register(with: Self.registerInfo(alias: "Sender"), to: v1Peer)

        let paths = await transport.recordedRequests().map(\.path)
        #expect(paths == [
            "\(LocalSendKit.apiPrefixV1)/register",
            "\(LocalSendKit.apiPrefix)/register",
            "\(LocalSendKit.apiPrefixV1)/register"
        ])
    }

    // MARK: - clientPath route table

    @Test func clientPathRenamesExactlyTheTwoLegacyRoutesUnderV1() {
        #expect(LocalSendKit.clientPath(version: .v1, route: "prepare-upload") == "\(LocalSendKit.apiPrefixV1)/send-request")
        #expect(LocalSendKit.clientPath(version: .v1, route: "upload") == "\(LocalSendKit.apiPrefixV1)/send")

        // Everything else keeps its name under /v1.
        for route in ["info", "register", "cancel", "show", "prepare-download", "download"] {
            #expect(LocalSendKit.clientPath(version: .v1, route: route) == "\(LocalSendKit.apiPrefixV1)/\(route)")
        }
    }

    @Test func clientPathIsIdentityUnderV2() {
        for route in ["info", "register", "prepare-upload", "upload", "cancel", "show", "prepare-download", "download"] {
            #expect(LocalSendKit.clientPath(version: .v2, route: route) == "\(LocalSendKit.apiPrefix)/\(route)")
        }
    }

    /// `clientPath` and `canonicalRoute` are NOT inverses and must never be folded into one
    /// bidirectional map: the server deliberately refuses `/api/localsend/v1/upload` (returns `nil`)
    /// while the client must emit `/api/localsend/v1/send` for the canonical route `upload`.
    @Test func clientPathIsNotTheInverseOfCanonicalRoute() {
        #expect(LocalSendKit.canonicalRoute(version: .v1, route: "upload") == nil)
        #expect(LocalSendKit.clientPath(version: .v1, route: "upload") == "\(LocalSendKit.apiPrefixV1)/send")

        #expect(LocalSendKit.canonicalRoute(version: .v1, route: "prepare-upload") == nil)
        #expect(LocalSendKit.clientPath(version: .v1, route: "prepare-upload") == "\(LocalSendKit.apiPrefixV1)/send-request")
    }

    // MARK: - APIVersion(protocolVersion:)

    /// The reference tests strict string equality against `'1.0'`
    /// (`api_route_builder.dart:33`), so `"1.0.0"` and `"1.1"` are NOT v1. No `hasPrefix`.
    @Test func apiVersionUsesStrictEqualityAgainstOneDotZero() {
        #expect(LocalSendKit.APIVersion(protocolVersion: "1.0") == .v1)
        #expect(LocalSendKit.APIVersion(protocolVersion: LocalSendKit.fallbackProtocolVersion) == .v1)

        #expect(LocalSendKit.APIVersion(protocolVersion: "1.0.0") == .v2)
        #expect(LocalSendKit.APIVersion(protocolVersion: "1.1") == .v2)
        #expect(LocalSendKit.APIVersion(protocolVersion: "2.0") == .v2)
        #expect(LocalSendKit.APIVersion(protocolVersion: "2.1") == .v2)
        #expect(LocalSendKit.APIVersion(protocolVersion: LocalSendKit.protocolVersion) == .v2)
        #expect(LocalSendKit.APIVersion(protocolVersion: "") == .v2)
        #expect(LocalSendKit.APIVersion(protocolVersion: nil) == .v2)
    }

    // MARK: - In-process v1 round trip (the regression test for the reported bug)

    /// The bug report end to end: a `.v1`-pinned client driving a real `LocalSendServer` through
    /// prepare-upload -> upload. The server half is already known-correct for v1, so the two halves
    /// validate each other — before this fix the client posted to `/v2/prepare-upload` and the
    /// legacy-only receiver 404'd.
    @Test func v1ClientCompletesAPrepareUploadThenUploadRoundTripAgainstTheServer() async throws {
        let storageDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let server = LocalSendServer(
            configuration: LocalSendServerConfiguration(
                registerInfo: Self.registerInfo(alias: "Receiver"),
                uploadPolicy: .acceptAll,
                allowDownloads: true,
                storageDirectory: storageDirectory
            )
        )

        let log = RequestLog()
        let transport = InProcessTransport { request in
            await log.record(request)
            return try await server.handle(request)
        }
        let client = LocalSendClient(transport: transport)
        let peer = RemotePeer(host: "192.168.1.42", port: 53317, protocolType: .https, apiVersion: .v1)

        let payload = Data("legacy-payload".utf8)
        let prepareRequest = PrepareUploadRequest(
            info: Self.registerInfo(alias: "Sender"),
            files: [
                "file-1": FileDto(
                    id: "file-1",
                    fileName: "legacy.txt",
                    size: Int64(payload.count),
                    fileType: "text/plain"
                )
            ]
        )

        // v1 answers prepare-upload with the BARE `{fileId: token}` map, no `{sessionId, files}`
        // envelope (`receive_controller.dart:427-437`). The client must wrap it locally.
        let prepared = try #require(try await client.prepareUpload(prepareRequest, to: peer))
        let token = try #require(prepared.files["file-1"])
        #expect(prepared.sessionId.isEmpty == false)

        try await client.upload(
            payload,
            sessionId: prepared.sessionId,
            fileId: "file-1",
            token: token,
            to: peer
        )

        let observed = await log.requests
        #expect(observed.map(\.path) == [
            "\(LocalSendKit.apiPrefixV1)/send-request",
            "\(LocalSendKit.apiPrefixV1)/send"
        ])

        // The synthetic session id is local bookkeeping and must never reach the wire: a real v1
        // client sends only `fileId` + `token` (`receive_controller.dart:463-470`).
        let uploadQuery = try #require(observed.last?.query)
        #expect(uploadQuery["sessionId"] == nil)
        #expect(uploadQuery["fileId"] == "file-1")
        #expect(uploadQuery["token"] == token)

        let written = try Data(contentsOf: storageDirectory.appendingPathComponent("legacy.txt"))
        #expect(written == payload)
    }

    /// v1 `/cancel` carries no `sessionId` — the reference receiver infers the session instead
    /// (`receive_controller.dart:673-696`).
    @Test func v1CancelOmitsTheSessionIdQueryItem() async throws {
        let transport = RecordingTransport(responder: { _ in .empty(statusCode: 200) })
        let client = LocalSendClient(transport: transport)
        let peer = RemotePeer(host: "10.0.0.9", port: 53317, protocolType: .https, apiVersion: .v1)

        try await client.cancel(sessionId: "local-only-session", to: peer)

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.path == "\(LocalSendKit.apiPrefixV1)/cancel")
        #expect(request.query["sessionId"] == nil)
    }

    /// `info` is renamed in neither version but still has to follow the peer's prefix.
    @Test func v1InfoUsesTheV1Prefix() async throws {
        let transport = RecordingTransport(responder: { _ in
            HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(InfoResponse(alias: "Receiver", fingerprint: "R", download: true))
            )
        })
        let client = LocalSendClient(transport: transport)
        let peer = RemotePeer(host: "10.0.0.9", port: 53317, protocolType: .https, apiVersion: .v1)

        _ = try await client.info(from: peer)

        let paths = await transport.recordedRequests().map(\.path)
        #expect(paths == ["\(LocalSendKit.apiPrefixV1)/info"])
    }

    /// **Deliberate non-change.** `api_route_builder.dart` generates a `.v1` string for every enum
    /// case, but the reference only ever *installs* prepare-download/download on v2
    /// (`send_controller.dart:82,191`) and no reference client calls them. Targeting
    /// `/v1/prepare-download` would be a route we invented, so both stay pinned to the v2 prefix
    /// even for a `.v1` peer.
    @Test func prepareDownloadAndDownloadStayOnTheV2PrefixForAV1Peer() async throws {
        let transport = RecordingTransport(responder: { request in
            if request.path.hasSuffix("/prepare-download") {
                return HTTPResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: try JSONEncoder().encode(
                        PrepareDownloadResponse(
                            info: InfoResponse(alias: "Receiver", fingerprint: "R", download: true),
                            sessionId: "session",
                            files: ["d1": FileDto(id: "d1", fileName: "d.txt", size: 1, fileType: "text/plain")]
                        )
                    )
                )
            }
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/plain"], body: Data("x".utf8))
        })
        let client = LocalSendClient(transport: transport)
        let peer = RemotePeer(host: "10.0.0.9", port: 53317, protocolType: .https, apiVersion: .v1)

        _ = try await client.prepareDownload(from: peer)
        _ = try await client.download(fileId: "d1", sessionId: "session", from: peer)

        let paths = await transport.recordedRequests().map(\.path)
        #expect(paths == [
            "\(LocalSendKit.apiPrefix)/prepare-download",
            "\(LocalSendKit.apiPrefix)/download"
        ])
    }

    // MARK: - v2 regression

    /// The default `.v2` peer must be byte-for-byte what it was before item #59: v2 paths, and the
    /// `sessionId` query item present on both upload and cancel.
    @Test func defaultV2PeerKeepsItsPathsAndSessionIdQueryItems() async throws {
        let transport = RecordingTransport(responder: { request in
            if request.path.hasSuffix("/prepare-upload") {
                return HTTPResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: try JSONEncoder().encode(PrepareUploadResponse(sessionId: "remote-session", files: ["f1": "tok"]))
                )
            }
            return .empty(statusCode: 200)
        })
        let client = LocalSendClient(transport: transport)
        let peer = RemotePeer(host: "10.0.0.9", port: 53317, protocolType: .https)
        #expect(peer.apiVersion == .v2)

        let prepareRequest = PrepareUploadRequest(
            info: Self.registerInfo(alias: "Sender"),
            files: ["f1": FileDto(id: "f1", fileName: "x.txt", size: 1, fileType: "text/plain")]
        )
        let prepared = try #require(try await client.prepareUpload(prepareRequest, to: peer, pin: "123456"))
        #expect(prepared.sessionId == "remote-session")
        try await client.upload(Data("x".utf8), sessionId: prepared.sessionId, fileId: "f1", token: "tok", to: peer)
        try await client.cancel(sessionId: prepared.sessionId, to: peer)

        let requests = await transport.recordedRequests()
        #expect(requests.map(\.path) == [
            "\(LocalSendKit.apiPrefix)/prepare-upload",
            "\(LocalSendKit.apiPrefix)/upload",
            "\(LocalSendKit.apiPrefix)/cancel"
        ])
        #expect(requests[0].query["pin"] == "123456")
        #expect(requests[1].query["sessionId"] == "remote-session")
        #expect(requests[2].query["sessionId"] == "remote-session")
    }

    /// The `pin` query item is version-independent: the reference's `checkPin` (`common.dart`) reads
    /// it off the query on both routes, so it carries to `/v1/send-request` unbranched.
    @Test func v1PrepareUploadStillCarriesThePinQueryItem() async throws {
        let transport = RecordingTransport(responder: { _ in
            HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(["f1": "tok"])
            )
        })
        let client = LocalSendClient(transport: transport)
        let peer = RemotePeer(host: "10.0.0.9", port: 53317, protocolType: .https, apiVersion: .v1)

        let prepareRequest = PrepareUploadRequest(
            info: Self.registerInfo(alias: "Sender"),
            files: ["f1": FileDto(id: "f1", fileName: "x.txt", size: 1, fileType: "text/plain")]
        )
        _ = try await client.prepareUpload(prepareRequest, to: peer, pin: "654321")

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.path == "\(LocalSendKit.apiPrefixV1)/send-request")
        #expect(request.query["pin"] == "654321")
    }

    /// **[F8]** The v1 decode branch applies to the final `decode` call ONLY. A 204 ("no file
    /// transfer needed") is bodiless under both versions, and decoding an empty body as
    /// `[String: String]` would throw where it must return `nil`.
    @Test func v1PrepareUploadStillReturnsNilForABodiless204() async throws {
        let transport = RecordingTransport(responder: { _ in .empty(statusCode: 204) })
        let client = LocalSendClient(transport: transport)
        let peer = RemotePeer(host: "10.0.0.9", port: 53317, protocolType: .https, apiVersion: .v1)

        let prepareRequest = PrepareUploadRequest(
            info: Self.registerInfo(alias: "Sender"),
            files: ["f1": FileDto(id: "f1", fileName: "x.txt", size: 1, fileType: "text/plain")]
        )
        #expect(try await client.prepareUpload(prepareRequest, to: peer) == nil)
    }

    /// ...and the 401/403/409/429 taxonomy runs before the decode branch too, unchanged.
    @Test func v1PrepareUploadKeepsTheErrorTaxonomy() async throws {
        let cases: [(Int, LocalSendClientError)] = [
            (401, .pinRequired),
            (403, .rejected),
            (409, .blockedByAnotherSession),
            (429, .tooManyRequests)
        ]
        let prepareRequest = PrepareUploadRequest(
            info: Self.registerInfo(alias: "Sender"),
            files: ["f1": FileDto(id: "f1", fileName: "x.txt", size: 1, fileType: "text/plain")]
        )

        for (statusCode, expected) in cases {
            let transport = RecordingTransport(responder: { _ in .empty(statusCode: statusCode) })
            let client = LocalSendClient(transport: transport)
            let peer = RemotePeer(host: "10.0.0.9", port: 53317, protocolType: .https, apiVersion: .v1)
            await #expect(throws: expected) {
                _ = try await client.prepareUpload(prepareRequest, to: peer)
            }
        }
    }

    /// Two concurrent v1 sends must not collide on the synthetic session id — hence a UUID rather
    /// than `""`.
    @Test func v1PrepareUploadSynthesizesADistinctSessionIdPerCall() async throws {
        let transport = RecordingTransport(responder: { _ in
            HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(["f1": "tok"])
            )
        })
        let client = LocalSendClient(transport: transport)
        let peer = RemotePeer(host: "10.0.0.9", port: 53317, protocolType: .https, apiVersion: .v1)
        let prepareRequest = PrepareUploadRequest(
            info: Self.registerInfo(alias: "Sender"),
            files: ["f1": FileDto(id: "f1", fileName: "x.txt", size: 1, fileType: "text/plain")]
        )

        let first = try #require(try await client.prepareUpload(prepareRequest, to: peer))
        let second = try #require(try await client.prepareUpload(prepareRequest, to: peer))
        #expect(first.sessionId != second.sessionId)
        #expect(first.files == ["f1": "tok"])
    }

    // MARK: - Server-side negative regression (guards `canonicalRoute`'s nil)

    /// The v2 spellings are NOT routes under `/v1`. `clientPath` gaining a `v1/upload -> v1/send`
    /// mapping must not tempt anyone into making `canonicalRoute` its inverse, which would open
    /// `/api/localsend/v1/upload` as a second, undocumented alias.
    @Test func serverStill404sTheV2SpellingsUnderTheV1Prefix() async throws {
        let storageDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let server = LocalSendServer(
            configuration: LocalSendServerConfiguration(
                registerInfo: Self.registerInfo(alias: "Receiver"),
                uploadPolicy: .acceptAll,
                allowDownloads: true,
                storageDirectory: storageDirectory
            )
        )

        let prepareUpload = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefixV1)/prepare-upload",
                body: .data(try JSONEncoder().encode(
                    PrepareUploadRequest(
                        info: Self.registerInfo(alias: "Sender"),
                        files: ["f1": FileDto(id: "f1", fileName: "x.txt", size: 1, fileType: "text/plain")]
                    )
                )),
                remoteAddress: "192.168.1.42"
            )
        )
        let upload = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefixV1)/upload",
                query: ["fileId": "f1", "token": "tok"],
                body: .data(Data("x".utf8)),
                remoteAddress: "192.168.1.42"
            )
        )

        #expect(prepareUpload.statusCode == 404)
        #expect(upload.statusCode == 404)
    }
}
