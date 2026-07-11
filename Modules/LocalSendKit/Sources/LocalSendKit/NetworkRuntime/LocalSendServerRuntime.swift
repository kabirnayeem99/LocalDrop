import AppLogging
import Foundation
import Network

public struct ServerRequestContext: Sendable {
    public var remoteAddress: String
    public var temporaryDirectory: URL

    public init(remoteAddress: String, temporaryDirectory: URL) {
        self.remoteAddress = remoteAddress
        self.temporaryDirectory = temporaryDirectory
    }
}

public final actor LocalSendServerRuntime {
    public struct BoundEndpoint: Sendable, Equatable {
        public var host: String
        public var port: Int
        public var protocolType: ProtocolType

        public init(host: String, port: Int, protocolType: ProtocolType) {
            self.host = host
            self.port = port
            self.protocolType = protocolType
        }
    }

    private let server: LocalSendServer
    private let tlsConfiguration: LocalSendTLSConfiguration
    private let protocolType: ProtocolType
    private let port: UInt16
    private let limits: LocalSendRuntimeLimits
    private let temporaryDirectory: URL
    private let logger: AppLogger
    private var listener: NWListener?
    private var boundEndpoint: BoundEndpoint?
    private var readyContinuation: CheckedContinuation<BoundEndpoint, Error>?
    private var activeConnectionTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        server: LocalSendServer,
        tlsConfiguration: LocalSendTLSConfiguration,
        protocolType: ProtocolType = .https,
        port: UInt16,
        limits: LocalSendRuntimeLimits = .init(),
        temporaryDirectory: URL,
        logger: AppLogger = .disabled()
    ) {
        self.server = server
        self.tlsConfiguration = tlsConfiguration
        self.protocolType = protocolType
        self.port = port
        self.limits = limits
        self.temporaryDirectory = temporaryDirectory
        self.logger = logger
    }

    public func start() async throws {
        guard listener == nil else { return }
        logger.emit(
            level: .info,
            event: "server.listener.starting",
            scope: "LocalSendServerRuntime",
            attributes: [
                .string("localsend.protocol_type", protocolType.rawValue),
                .int("server.port", Int(port))
            ]
        )
        let listener: NWListener
        let parameters = try makeListenerParameters()
        if let requestedPort = NWEndpoint.Port(rawValue: port), port != 0 {
            listener = try NWListener(using: parameters, on: requestedPort)
        } else {
            listener = try NWListener(using: parameters)
        }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task {
                await self.handle(state: state, listener: listener)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task {
                await self.accept(connection: connection)
            }
        }
        listener.start(queue: tlsConfiguration.queue)
    }

    public func waitUntilReady() async throws -> BoundEndpoint {
        if let boundEndpoint {
            return boundEndpoint
        }
        return try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
        }
    }

    public func stop() async {
        listener?.cancel()
        listener = nil
        for task in activeConnectionTasks.values {
            task.cancel()
        }
        activeConnectionTasks.removeAll()
        logger.emit(level: .info, event: "server.listener.stopped", scope: "LocalSendServerRuntime")
    }

    private func handle(state: NWListener.State, listener: NWListener) {
        switch state {
        case .ready:
            let endpoint = resolvedEndpoint(from: listener)
            boundEndpoint = endpoint
            logger.emit(
                level: .info,
                event: "server.listener.ready",
                scope: "LocalSendServerRuntime",
                attributes: [
                    .string("server.address", endpoint.host),
                    .int("server.port", endpoint.port),
                    .string("localsend.protocol_type", endpoint.protocolType.rawValue)
                ]
            )
            readyContinuation?.resume(returning: endpoint)
            readyContinuation = nil
        case .failed:
            logger.emit(
                level: .error,
                event: "server.listener.failed",
                scope: "LocalSendServerRuntime"
            )
            readyContinuation?.resume(throwing: LocalSendRuntimeError.listenerStartFailed)
            readyContinuation = nil
        default:
            break
        }
    }

    private func accept(connection: NWConnection) {
        let identifier = UUID()
        let connectionID = identifier.uuidString.lowercased()
        let remoteAddress = Self.remoteAddress(from: connection.endpoint)
        logger.emit(
            level: .debug,
            event: "server.connection.accepted",
            scope: "LocalSendServerRuntime",
            context: connectionContext(connectionID: connectionID, remoteAddress: remoteAddress)
        )
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.run(connection: connection, connectionID: connectionID, remoteAddress: remoteAddress)
            await self.finishConnection(id: identifier)
        }
        activeConnectionTasks[identifier] = task
        connection.start(queue: tlsConfiguration.queue)
    }

    private func finishConnection(id: UUID) {
        activeConnectionTasks.removeValue(forKey: id)
    }

    private func run(connection: NWConnection, connectionID: String, remoteAddress: String) async {
        var closeReason = "completed"
        do {
            try await serveNextRequest(on: connection, connectionID: connectionID, remoteAddress: remoteAddress)
        } catch {
            closeReason = "failed"
            logger.emit(
                level: .error,
                event: "server.request.failed",
                scope: "LocalSendServerRuntime",
                context: connectionContext(connectionID: connectionID, remoteAddress: remoteAddress),
                attributes: [
                    .string("result", "failure"),
                    .string("error.message", error.localizedDescription),
                    .string("error.type", String(describing: type(of: error)))
                ]
            )
            _ = try? await send(response: .empty(statusCode: 500), on: connection)
        }
        connection.cancel()
        logger.emit(
            level: .debug,
            event: "server.connection.closed",
            scope: "LocalSendServerRuntime",
            context: connectionContext(connectionID: connectionID, remoteAddress: remoteAddress),
            attributes: [.string("result", closeReason)]
        )
    }

    private func serveNextRequest(on connection: NWConnection, connectionID: String, remoteAddress: String) async throws {
        let (request, leftover) = try await readRequest(
            on: connection,
            connectionID: connectionID,
            remoteAddress: remoteAddress,
            initialBuffer: Data()
        )
        let response = try await server.handle(request)
        try await send(response: response, on: connection)
        if request.wantsKeepAlive {
            logger.emit(
                level: .debug,
                event: "server.request.received",
                scope: "LocalSendServerRuntime",
                context: requestContext(for: request),
                attributes: [.string("event.action", "keep_alive_followup")]
            )
            let (followup, _) = try await readRequest(
                on: connection,
                connectionID: connectionID,
                remoteAddress: remoteAddress,
                initialBuffer: leftover
            )
            let followupResponse = try await server.handle(followup)
            try await send(response: followupResponse, on: connection)
        }
    }

    /// `initialBuffer` carries bytes already read off the wire but not yet consumed — either
    /// leftover from the previous request on a keep-alive connection, or empty for the first
    /// request. The returned `Data` is the symmetric leftover for the *next* call: pipelined
    /// clients (or a TLS/TCP stack that coalesces multiple requests into one `receive()`) can
    /// deliver bytes belonging to a follow-up request in the same read as this request's body,
    /// and those bytes must be carried forward rather than silently truncated/discarded.
    private func readRequest(on connection: NWConnection, connectionID: String, remoteAddress: String, initialBuffer: Data) async throws -> (HTTPRequest, Data) {
        logger.emit(
            level: .debug,
            event: "server.request.received",
            scope: "LocalSendServerRuntime",
            context: connectionContext(connectionID: connectionID, remoteAddress: remoteAddress)
        )
        var buffer = initialBuffer
        var head: HTTPRequestHead?

        while head == nil {
            do {
                head = try HTTPRequestParser.parseHead(from: buffer, maximumHeaderBytes: limits.maximumHeaderBytes)
            } catch {
                if buffer.range(of: HTTPRequestParser.headerTerminator) != nil {
                    throw error
                }
            }
            if head != nil {
                break
            }
            if buffer.count > limits.maximumHeaderBytes {
                logger.emit(
                    level: .warning,
                    event: "server.request.failed",
                    scope: "LocalSendServerRuntime",
                    context: connectionContext(connectionID: connectionID, remoteAddress: remoteAddress),
                    attributes: [
                        .string("result", "headers_too_large"),
                        .int("http.request.body.size", buffer.count)
                    ]
                )
                throw HTTPParserError.headersTooLarge
            }
            let chunk = try await receive(on: connection)
            guard chunk.isEmpty == false else {
                throw HTTPParserError.invalidRequestLine
            }
            buffer.append(chunk)
        }

        let parsedHead = head!
        let requestID = UUID().uuidString.lowercased()
        let bodyStart = parsedHead.headerByteCount
        let routeIsUpload = parsedHead.path == "\(LocalSendKit.apiPrefix)/upload"
        if routeIsUpload == false, parsedHead.contentLength > Int64(limits.maximumJSONBodyBytes) {
            logger.emit(
                level: .warning,
                event: "server.request.failed",
                scope: "LocalSendServerRuntime",
                context: AppLogContext(
                    attributes: connectionContext(connectionID: connectionID, remoteAddress: remoteAddress).attributes + [
                        .string("request.request_id", requestID),
                        .string("url.path", parsedHead.path)
                    ]
                ),
                attributes: [
                    .string("result", "body_too_large"),
                    .int64("http.request.body.size", parsedHead.contentLength)
                ]
            )
            throw LocalSendRuntimeError.bodyTooLarge
        }

        let initialBody = Data(buffer.dropFirst(bodyStart))
        let requestBody: HTTPRequestBody
        let leftover: Data
        if routeIsUpload {
            let (body, remainder) = try await stageUploadBody(
                initialBody: initialBody,
                expectedLength: parsedHead.contentLength,
                on: connection
            )
            requestBody = body
            leftover = remainder
        } else {
            let (body, remainder) = try await readBufferedBody(
                initialBody: initialBody,
                expectedLength: Int(parsedHead.contentLength),
                on: connection
            )
            requestBody = .data(body)
            leftover = remainder
        }

        let request = HTTPRequest(
            method: parsedHead.method,
            path: parsedHead.path,
            query: parsedHead.query,
            headers: parsedHead.headers,
            body: requestBody,
            remoteAddress: remoteAddress,
            requestID: requestID,
            connectionID: connectionID
        )
        logger.emit(
            level: .debug,
            event: "server.request.parsed",
            scope: "LocalSendServerRuntime",
            context: requestContext(for: request),
            attributes: [
                .string("http.request.method", request.method.rawValue),
                .string("url.path", request.path),
                .int64("http.request.body.size", request.body.byteCount)
            ]
        )
        return (request, leftover)
    }

    private func readBufferedBody(initialBody: Data, expectedLength: Int, on connection: NWConnection) async throws -> (body: Data, leftover: Data) {
        var body = initialBody
        while body.count < expectedLength {
            let chunk = try await receive(on: connection)
            guard chunk.isEmpty == false else {
                throw HTTPParserError.incompleteBody
            }
            body.append(chunk)
        }
        guard body.count >= expectedLength else {
            throw HTTPParserError.incompleteBody
        }
        let leftover = body.count > expectedLength ? Data(body.suffix(from: expectedLength)) : Data()
        return (Data(body.prefix(expectedLength)), leftover)
    }

    private func stageUploadBody(initialBody: Data, expectedLength: Int64, on connection: NWConnection) async throws -> (body: HTTPRequestBody, leftover: Data) {
        let fileURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            throw LocalSendRuntimeError.connectionReadFailed
        }
        defer { try? handle.close() }
        logger.emit(
            level: .debug,
            event: "server.body.staged_to_disk",
            scope: "LocalSendServerRuntime",
            attributes: [
                .string("result", "started"),
                .int64("http.request.body.size", expectedLength)
            ]
        )

        var bytesWritten = Int64(0)
        var leftover = Data()

        func write(_ data: Data) throws {
            let remaining = expectedLength - bytesWritten
            if Int64(data.count) > remaining {
                try handle.write(contentsOf: data.prefix(Int(remaining)))
                leftover = Data(data.suffix(from: Int(remaining)))
                bytesWritten += remaining
            } else {
                try handle.write(contentsOf: data)
                bytesWritten += Int64(data.count)
            }
        }

        if initialBody.isEmpty == false {
            try write(initialBody)
        }
        while bytesWritten < expectedLength {
            let chunk = try await receive(on: connection)
            guard chunk.isEmpty == false else {
                throw HTTPParserError.incompleteBody
            }
            try write(chunk)
        }
        guard bytesWritten == expectedLength else {
            throw HTTPParserError.incompleteBody
        }
        logger.emit(
            level: .debug,
            event: "server.body.staged_to_disk",
            scope: "LocalSendServerRuntime",
            attributes: [
                .string("result", "success"),
                .int64("http.request.body.size", expectedLength)
            ]
        )
        return (.file(fileURL, byteCount: expectedLength), leftover)
    }

    private func send(response: HTTPResponse, on connection: NWConnection) async throws {
        let headerData = HTTPResponseWriter.headerData(for: response)
        try await send(data: headerData, on: connection)
        switch response.body {
        case .data(let data):
            if data.isEmpty == false {
                try await send(data: data, on: connection)
            }
        case .file(let url, _):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 64 * 1024), chunk.isEmpty == false {
                try await send(data: chunk, on: connection)
            }
        }
        logger.emit(
            level: .debug,
            event: "server.response.sent",
            scope: "LocalSendServerRuntime",
            attributes: [
                .int("http.response.status_code", response.statusCode),
                .int64("http.response.body.size", response.body.byteCount)
            ]
        )
    }

    private func receive(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: Data())
                    return
                }
                continuation.resume(throwing: LocalSendRuntimeError.connectionReadFailed)
            }
        }
    }

    private func send(data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    private func resolvedEndpoint(from listener: NWListener) -> BoundEndpoint {
        guard let port = listener.port else {
            return BoundEndpoint(host: "127.0.0.1", port: Int(self.port), protocolType: protocolType)
        }
        return BoundEndpoint(host: "127.0.0.1", port: Int(port.rawValue), protocolType: protocolType)
    }

    private func makeListenerParameters() throws -> NWParameters {
        switch protocolType {
        case .https:
            return try tlsConfiguration.makeListenerParameters()
        case .http:
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true
            return parameters
        }
    }

    private static func remoteAddress(from endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else {
            return "127.0.0.1"
        }
        switch host {
        case .ipv4(let value):
            return value.debugDescription
        case .ipv6(let value):
            return value.debugDescription
        case .name(let name, _):
            return name
        @unknown default:
            return "127.0.0.1"
        }
    }

    private func connectionContext(connectionID: String, remoteAddress: String) -> AppLogContext {
        AppLogContext(attributes: [
            .string("request.connection_id", connectionID),
            .string("client.address", remoteAddress)
        ])
    }

    private func requestContext(for request: HTTPRequest) -> AppLogContext {
        AppLogContext(attributes: [
            .string("client.address", request.remoteAddress)
        ] + (request.connectionID.map { [.string("request.connection_id", $0)] } ?? []) + (request.requestID.map { [.string("request.request_id", $0)] } ?? []))
    }
}
