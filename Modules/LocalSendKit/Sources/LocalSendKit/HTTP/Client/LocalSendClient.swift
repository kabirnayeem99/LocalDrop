import Foundation

public struct RemotePeer: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var protocolType: ProtocolType
    /// The protocol version this peer announced, as a route-selection decision.
    ///
    /// `ApiRoute.target` (`common/lib/api_route_builder.dart:28-36`) derives every client path from
    /// the target device's version, so it belongs on the peer rather than on each call.
    ///
    /// Defaults to `.v2`, which is exactly the behaviour every call site had before this existed: a
    /// site that forgets to plumb the discovered version keeps talking v2 and can only fail the way
    /// it already did — never worse for a v2 peer.
    public var apiVersion: LocalSendKit.APIVersion

    public init(
        host: String,
        port: Int,
        protocolType: ProtocolType,
        apiVersion: LocalSendKit.APIVersion = .v2
    ) {
        self.host = host
        self.port = port
        self.protocolType = protocolType
        self.apiVersion = apiVersion
    }
}

public struct LocalSendClientTimeoutConfiguration: Equatable, Sendable {
    public var requestTimeout: TimeInterval
    public var resourceTimeout: TimeInterval

    public init(requestTimeout: TimeInterval = 30, resourceTimeout: TimeInterval = 300) {
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
    }
}

public enum LocalSendClientError: Error, Equatable {
    case invalidStatusCode(Int)
    case invalidDownloadResponse
    case missingPeer
    /// `/prepare-upload` responded 401 — a PIN is required, or the supplied PIN was wrong.
    case pinRequired
    /// `/prepare-upload` responded 403 — the recipient declined the transfer.
    case rejected
    /// `/prepare-upload` responded 409 — the recipient is busy with another session.
    case blockedByAnotherSession
    /// `/prepare-upload` responded 429 — too many requests.
    case tooManyRequests
}

public struct FileTransferProgress: Equatable, Sendable {
    public var bytesTransferred: Int64
    public var totalBytes: Int64

    public init(bytesTransferred: Int64, totalBytes: Int64) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
    }
}

public protocol LocalSendTransport: Sendable {
    func send(
        _ request: HTTPRequest,
        to peer: RemotePeer,
        progress: (@Sendable (FileTransferProgress) -> Void)?
    ) async throws -> HTTPResponse
}

public extension LocalSendTransport {
    func send(_ request: HTTPRequest, to peer: RemotePeer) async throws -> HTTPResponse {
        try await send(request, to: peer, progress: nil)
    }
}

public struct InProcessTransport: LocalSendTransport {
    private let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse

    public init(handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        self.handler = handler
    }

    public func send(
        _ request: HTTPRequest,
        to peer: RemotePeer,
        progress: (@Sendable (FileTransferProgress) -> Void)?
    ) async throws -> HTTPResponse {
        var rewritten = request
        rewritten.headers["Host"] = peer.host
        let response = try await handler(rewritten)
        if let progress, rewritten.body.byteCount > 0 {
            progress(FileTransferProgress(bytesTransferred: rewritten.body.byteCount, totalBytes: rewritten.body.byteCount))
        }
        return response
    }
}

public struct DownloadedFile: Equatable, Sendable {
    public var data: Data
    public var headers: [String: String]

    public init(data: Data, headers: [String: String]) {
        self.data = data
        self.headers = headers
    }
}

public struct LocalSendClient: Sendable {
    private let transport: any LocalSendTransport
    private let defaultPeer: RemotePeer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(transport: any LocalSendTransport) {
        self.transport = transport
        self.defaultPeer = nil
    }

    public init(
        peer: RemotePeer,
        expectedFingerprint: String,
        timeoutConfiguration: LocalSendClientTimeoutConfiguration = .init()
    ) {
        self.transport = URLSessionTransport(
            expectedFingerprint: expectedFingerprint,
            timeoutConfiguration: timeoutConfiguration
        )
        self.defaultPeer = peer
    }

    /// Builds a peer URL from a host that may be an IPv4 literal, a DNS name, or an IPv6 literal
    /// with or without an interface zone (`fe80::1%en0`).
    ///
    /// `URLComponents.host` does the RFC 6874 escaping for us: the zone's `%` is percent-encoded to
    /// `%25`, producing `http://[fe80::1%25en0]:53317/…`, which `URLSession` connects on the named
    /// interface. So the host is handed over raw — pre-encoding it here would double-escape to
    /// `%2525`.
    public static func makeURL(
        scheme: ProtocolType,
        host: String,
        port: Int,
        path: String,
        query: [URLQueryItem] = []
    ) -> URL {
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = bracketedHost(host)
        components.port = port
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        if let url = components.url {
            return url
        }

        // Unreachable for every host this kit produces (`NetworkEndpointAddress.canonicalHost`
        // already rejects the characters that could break parsing), but `makeURL` is public and
        // takes an arbitrary `String`. A caller-supplied host must not be able to trap the whole
        // process: fall back to a host RFC 6761 guarantees never resolves, so the request fails at
        // connect time — a recoverable, loggable error — instead of crashing.
        var fallback = URLComponents()
        fallback.scheme = scheme.rawValue
        fallback.host = "invalid.invalid"
        fallback.port = port
        fallback.path = path
        fallback.queryItems = components.queryItems
        return fallback.url ?? URL(string: "\(scheme.rawValue)://invalid.invalid")!
    }

    /// IPv6 literals need `[...]` in a URL authority; IPv4 literals and DNS names must not get it.
    /// An already-bracketed host is left alone so a host that made a second trip through here
    /// cannot become `[[fe80::1%en0]]`.
    static func bracketedHost(_ host: String) -> String {
        guard host.contains(":") else {
            return host
        }
        guard host.hasPrefix("[") && host.hasSuffix("]") else {
            return "[\(host)]"
        }
        return host
    }

    /// `apiVersion` mirrors `ApiRoute.register.target(peer)`, which picks the v1 path for a peer
    /// advertising `version == "1.0"`. A v1-pinned peer has no `/api/localsend/v2/register` route,
    /// so replying to its announcement on the v2 path would 404 and silently fall back to UDP.
    ///
    /// It stays an explicit parameter — rather than reading `peer.apiVersion` like every other
    /// route — because the discovery register responder replies to an announcement *before* any
    /// `RemotePeer` has been given a version. When supplied it is an OVERRIDE and wins; `nil` means
    /// "use the peer's own version".
    public func register(
        with info: RegisterInfo,
        to peer: RemotePeer? = nil,
        apiVersion: LocalSendKit.APIVersion? = nil
    ) async throws -> RegisterInfo {
        let peer = try resolvePeer(peer)
        let request = try jsonRequest(
            .post,
            path: LocalSendKit.clientPath(version: apiVersion ?? peer.apiVersion, route: "register"),
            body: info,
            remoteAddress: peer.host
        )
        let response = try await transport.send(request, to: peer)
        return try decode(response, as: RegisterInfo.self)
    }

    public func info(from peer: RemotePeer? = nil) async throws -> InfoResponse {
        let peer = try resolvePeer(peer)
        let response = try await transport.send(
            HTTPRequest(
                method: .get,
                path: LocalSendKit.clientPath(version: peer.apiVersion, route: "info"),
                remoteAddress: peer.host
            ),
            to: peer
        )
        return try decode(response, as: InfoResponse.self)
    }

    public func prepareUpload(
        _ requestBody: PrepareUploadRequest,
        to peer: RemotePeer? = nil,
        pin: String? = nil
    ) async throws -> PrepareUploadResponse? {
        let peer = try resolvePeer(peer)
        // The `pin` query item is deliberately NOT version-branched. The reference's `checkPin`
        // (`app/lib/provider/network/server/controller/common.dart`) reads `pin` off the query for
        // both versions, so it — and the 401 retry loop above this call — carry to
        // `/v1/send-request` unchanged. Do not "helpfully" add a v1 branch here.
        let request = try jsonRequest(
            .post,
            path: LocalSendKit.clientPath(version: peer.apiVersion, route: "prepare-upload"),
            query: pin.map { ["pin": $0] } ?? [:],
            body: requestBody,
            remoteAddress: peer.host
        )
        let response = try await transport.send(request, to: peer)
        // 204 ("no file transfer needed") is a *successful* outcome distinct from a 403 rejection:
        // the recipient accepted the request but selected nothing. It must stay `nil`, not an error.
        //
        // This early return and the status taxonomy below run BEFORE the version branch on purpose:
        // the reference returns a bodiless 204 for an empty selection under both versions, and
        // decoding an empty body as `[String: String]` would throw where it must return `nil`.
        if response.statusCode == 204 {
            return nil
        }
        if let error = Self.prepareUploadError(forStatusCode: response.statusCode) {
            throw error
        }
        guard peer.apiVersion == .v1 else {
            return try decode(response, as: PrepareUploadResponse.self)
        }
        // v1 answers with the BARE `{fileId: token}` map — no `{sessionId, files}` envelope
        // (`receive_controller.dart:427-437`, where the envelope is built only `if (v2)`).
        //
        // The session id is synthesized locally because the rest of this kit — and every
        // FeatureTransfer progress/cancel lookup — keys send state by `sessionId`. It is local
        // bookkeeping ONLY and never goes back on the wire (see `upload`/`cancel` below). A UUID
        // rather than `""` so two concurrent v1 sends cannot collide on one empty key.
        let files = try decode(response, as: [String: String].self)
        return PrepareUploadResponse(sessionId: UUID().uuidString, files: files)
    }

    public func upload(
        _ data: Data,
        sessionId: String,
        fileId: String,
        token: String,
        to peer: RemotePeer? = nil,
        progress: (@Sendable (FileTransferProgress) -> Void)? = nil
    ) async throws {
        try await upload(.data(data), sessionId: sessionId, fileId: fileId, token: token, to: peer, progress: progress)
    }

    public func upload(
        fileAt fileURL: URL,
        byteCount: Int64,
        sessionId: String,
        fileId: String,
        token: String,
        to peer: RemotePeer? = nil,
        progress: (@Sendable (FileTransferProgress) -> Void)? = nil
    ) async throws {
        try await upload(.file(fileURL, byteCount: byteCount), sessionId: sessionId, fileId: fileId, token: token, to: peer, progress: progress)
    }

    public func cancel(sessionId: String, to peer: RemotePeer? = nil) async throws {
        let peer = try resolvePeer(peer)
        // v1 carries no `sessionId`: the reference receiver does not read one off a v1 cancel and
        // instead infers the session, being "a little bit more tolerant"
        // (`receive_controller.dart:646-696`). Sending our locally synthesized id would be a
        // fabricated value that a tolerant receiver might try to match against.
        let request = HTTPRequest(
            method: .post,
            path: LocalSendKit.clientPath(version: peer.apiVersion, route: "cancel"),
            query: peer.apiVersion == .v1 ? [:] : ["sessionId": sessionId],
            remoteAddress: peer.host
        )
        let response = try await transport.send(request, to: peer)
        try expectSuccess(response)
    }

    /// **Deliberately pinned to the v2 prefix regardless of `peer.apiVersion`** — the one place this
    /// client does not follow the peer's version.
    ///
    /// `api_route_builder.dart` *generates* a `.v1` string for every enum case, but the reference
    /// only ever *installs* `prepare-download` and `download` on v2
    /// (`app/lib/provider/network/server/controller/send_controller.dart:82` and `:191`, both
    /// `ApiRoute.…v2`), and no reference client calls either route. Targeting
    /// `/api/localsend/v1/prepare-download` would be a route we invented, served by nobody.
    public func prepareDownload(
        from peer: RemotePeer? = nil,
        pin: String? = nil,
        sessionId: String? = nil
    ) async throws -> PrepareDownloadResponse {
        let peer = try resolvePeer(peer)
        var query: [String: String] = [:]
        if let pin {
            query["pin"] = pin
        }
        if let sessionId {
            query["sessionId"] = sessionId
        }
        let request = HTTPRequest(
            method: .post,
            path: "\(LocalSendKit.apiPrefix)/prepare-download",
            query: query,
            remoteAddress: peer.host
        )
        let response = try await transport.send(request, to: peer)
        return try decode(response, as: PrepareDownloadResponse.self)
    }

    /// v2-pinned for the same reason as `prepareDownload` above (`send_controller.dart:191`).
    public func download(fileId: String, sessionId: String, from peer: RemotePeer? = nil) async throws -> DownloadedFile {
        let peer = try resolvePeer(peer)
        let request = HTTPRequest(
            method: .get,
            path: "\(LocalSendKit.apiPrefix)/download",
            query: [
                "sessionId": sessionId,
                "fileId": fileId
            ],
            remoteAddress: peer.host
        )
        let response = try await transport.send(request, to: peer)
        try expectSuccess(response)
        return DownloadedFile(data: try response.body.loadData(), headers: response.headers)
    }

    private func upload(
        _ body: HTTPRequestBody,
        sessionId: String,
        fileId: String,
        token: String,
        to peer: RemotePeer?,
        progress: (@Sendable (FileTransferProgress) -> Void)?
    ) async throws {
        let peer = try resolvePeer(peer)
        // v1 validates `fileId` + `token` alone; `sessionId` is required only when v2
        // (`receive_controller.dart:463-470`). Our v1 session id is locally synthesized, so putting
        // it on the wire would send the receiver a value that matches nothing it knows.
        var query = [
            "fileId": fileId,
            "token": token
        ]
        if peer.apiVersion != .v1 {
            query["sessionId"] = sessionId
        }
        let request = HTTPRequest(
            method: .post,
            path: LocalSendKit.clientPath(version: peer.apiVersion, route: "upload"),
            query: query,
            headers: [
                "Content-Length": "\(body.byteCount)"
            ],
            body: body,
            remoteAddress: peer.host
        )
        let response = try await transport.send(request, to: peer, progress: progress)
        try expectSuccess(response)
    }

    private func resolvePeer(_ peer: RemotePeer?) throws -> RemotePeer {
        if let peer {
            return peer
        }
        if let defaultPeer {
            return defaultPeer
        }
        throw LocalSendClientError.missingPeer
    }

    private func jsonRequest<T: Encodable>(
        _ method: HTTPMethod,
        path: String,
        query: [String: String] = [:],
        body: T,
        remoteAddress: String
    ) throws -> HTTPRequest {
        let data = try encoder.encode(body)
        return HTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: [
                "Content-Type": "application/json",
                "Content-Length": "\(data.count)"
            ],
            body: .data(data),
            remoteAddress: remoteAddress
        )
    }

    private func decode<T: Decodable>(_ response: HTTPResponse, as type: T.Type) throws -> T {
        try expectSuccess(response)
        return try decoder.decode(T.self, from: response.body.loadData())
    }

    /// The `/prepare-upload` error taxonomy from protocol section 4.1.
    ///
    /// Deliberately *not* applied inside `expectSuccess`: that helper is shared by `/cancel`,
    /// `/download`, `/upload` and `/register`, where the same status codes mean different things
    /// (an upload-time 403 is "invalid token or IP address", not "recipient declined"). Only
    /// `/prepare-upload` gets this mapping; everything else keeps `.invalidStatusCode`.
    private static func prepareUploadError(forStatusCode statusCode: Int) -> LocalSendClientError? {
        switch statusCode {
        case 401:
            return .pinRequired
        case 403:
            return .rejected
        case 409:
            return .blockedByAnotherSession
        case 429:
            return .tooManyRequests
        default:
            return nil
        }
    }

    private func expectSuccess(_ response: HTTPResponse) throws {
        guard (200...299).contains(response.statusCode) else {
            throw LocalSendClientError.invalidStatusCode(response.statusCode)
        }
    }
}

struct URLSessionTransport: LocalSendTransport {
    private let timeoutConfiguration: LocalSendClientTimeoutConfiguration
    private let expectedFingerprint: String

    init(expectedFingerprint: String, timeoutConfiguration: LocalSendClientTimeoutConfiguration) {
        self.expectedFingerprint = expectedFingerprint
        self.timeoutConfiguration = timeoutConfiguration
    }

    func send(
        _ request: HTTPRequest,
        to peer: RemotePeer,
        progress: (@Sendable (FileTransferProgress) -> Void)?
    ) async throws -> HTTPResponse {
        let delegate = UploadSessionDelegate(expectedFingerprint: expectedFingerprint, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutConfiguration.requestTimeout
        configuration.timeoutIntervalForResource = timeoutConfiguration.resourceTimeout
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer {
            session.finishTasksAndInvalidate()
        }

        let url = LocalSendClient.makeURL(
            scheme: peer.protocolType,
            host: peer.host,
            port: peer.port,
            path: request.path,
            query: request.query.map { URLQueryItem(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }
        )
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let response: URLResponse
        let body: HTTPResponseBody
        switch (request.body, request.method, request.path) {
        case (.data(let data), _, _):
            urlRequest.httpBody = data
            let (responseData, urlResponse) = try await session.data(for: urlRequest)
            response = urlResponse
            body = .data(responseData)
        case (.file(let fileURL, _), _, _):
            let (responseData, urlResponse) = try await session.upload(for: urlRequest, fromFile: fileURL)
            response = urlResponse
            body = .data(responseData)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LocalSendClientError.invalidDownloadResponse
        }

        var headers: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        return HTTPResponse(statusCode: httpResponse.statusCode, headers: headers, body: body)
    }
}

private final class UploadSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let tofuDelegate: TOFUSessionDelegate
    private let progress: (@Sendable (FileTransferProgress) -> Void)?

    init(
        expectedFingerprint: String,
        progress: (@Sendable (FileTransferProgress) -> Void)?
    ) {
        self.tofuDelegate = TOFUSessionDelegate(expectedFingerprint: expectedFingerprint)
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        tofuDelegate.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let progress else { return }
        let expected = max(totalBytesExpectedToSend, totalBytesSent)
        progress(FileTransferProgress(bytesTransferred: totalBytesSent, totalBytes: expected))
    }
}
