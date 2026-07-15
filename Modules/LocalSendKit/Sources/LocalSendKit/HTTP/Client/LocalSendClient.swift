import Foundation

public struct RemotePeer: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var protocolType: ProtocolType

    public init(host: String, port: Int, protocolType: ProtocolType) {
        self.host = host
        self.port = port
        self.protocolType = protocolType
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

    public static func makeURL(
        scheme: ProtocolType,
        host: String,
        port: Int,
        path: String,
        query: [URLQueryItem] = []
    ) -> URL {
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = port
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }

    public func register(with info: RegisterInfo, to peer: RemotePeer? = nil) async throws -> RegisterInfo {
        let peer = try resolvePeer(peer)
        let request = try jsonRequest(.post, path: "\(LocalSendKit.apiPrefix)/register", body: info, remoteAddress: peer.host)
        let response = try await transport.send(request, to: peer)
        return try decode(response, as: RegisterInfo.self)
    }

    public func info(from peer: RemotePeer? = nil) async throws -> InfoResponse {
        let peer = try resolvePeer(peer)
        let response = try await transport.send(
            HTTPRequest(method: .get, path: "\(LocalSendKit.apiPrefix)/info", remoteAddress: peer.host),
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
        let request = try jsonRequest(
            .post,
            path: "\(LocalSendKit.apiPrefix)/prepare-upload",
            query: pin.map { ["pin": $0] } ?? [:],
            body: requestBody,
            remoteAddress: peer.host
        )
        let response = try await transport.send(request, to: peer)
        if response.statusCode == 204 {
            return nil
        }
        return try decode(response, as: PrepareUploadResponse.self)
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
        let request = HTTPRequest(
            method: .post,
            path: "\(LocalSendKit.apiPrefix)/cancel",
            query: ["sessionId": sessionId],
            remoteAddress: peer.host
        )
        let response = try await transport.send(request, to: peer)
        try expectSuccess(response)
    }

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
        let request = HTTPRequest(
            method: .post,
            path: "\(LocalSendKit.apiPrefix)/upload",
            query: [
                "sessionId": sessionId,
                "fileId": fileId,
                "token": token
            ],
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
