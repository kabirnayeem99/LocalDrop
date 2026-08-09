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
    /// The `NWConnection` objects themselves must be retained, not just their driving tasks:
    /// `Task.cancel()` cannot resume a task parked in the non-cancellation-aware
    /// `withCheckedThrowingContinuation` around `NWConnection.receive`. Only cancelling the
    /// connection resumes that callback.
    private var activeConnections: [UUID: NWConnection] = [:]

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
        // Sweep-then-create: a crash or `SIGKILL` never reaches `stop()`, and every settings change
        // builds a new node, so orphaned bodies would otherwise accumulate in the save folder.
        UploadStagingArea.prepare(at: temporaryDirectory)
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

        let connections = Array(activeConnections.values)
        let tasks = Array(activeConnectionTasks.values)
        // Cancel the connections FIRST — that is what resumes any outstanding `receive`
        // continuation (with an error) and lets the connection tasks unwind. Cancelling the tasks
        // alone would leave `stop()` returning while live connections keep being served.
        for connection in connections {
            connection.cancel()
        }
        for task in tasks {
            task.cancel()
        }
        // Awaiting here suspends the actor, so each task's `finishConnection` can still run.
        //
        // Bounded, because `await Task<Void, Never>.value` is not cancellable: a connection task
        // parked inside `server.handle` on an accept/decline prompt would otherwise make `stop()`
        // hang forever, which is worse than the bug being fixed. `LocalSendNode.stop()` resolves
        // those prompts via `finishPending()` before it gets here, so the deadline is a backstop.
        let drained = await Self.drain(tasks, timeout: Self.stopDrainTimeout, on: tlsConfiguration.queue)
        activeConnections.removeAll()
        activeConnectionTasks.removeAll()
        // Only once the drain actually completed, so nothing is still writing into it. Also runs on
        // the settings-restart path, which goes through `LocalSendNode.stop()`.
        //
        // Skipped when the drain hit its deadline instead: a connection still streaming a body past
        // the timeout holds an open handle on a file in here, and unlinking it from underneath is
        // pointless destruction. The orphan is not leaked — `UploadStagingArea.prepare` sweeps on
        // every `start()`, so the next node to come up reclaims it.
        if drained {
            UploadStagingArea.sweep(at: temporaryDirectory)
        } else {
            logger.emit(
                level: .info,
                event: "server.staging.sweep_skipped",
                scope: "LocalSendServerRuntime"
            )
        }
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
        guard activeConnections.count < limits.maximumConcurrentConnections else {
            logger.emit(
                level: .warning,
                event: "server.connection.rejected",
                scope: "LocalSendServerRuntime",
                context: connectionContext(connectionID: connectionID, remoteAddress: remoteAddress),
                attributes: [
                    .string("result", "connection_limit"),
                    .int("server.active_connections", activeConnections.count)
                ]
            )
            connection.cancel()
            return
        }
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
        activeConnections[identifier] = connection
        connection.start(queue: tlsConfiguration.queue)
    }

    private func finishConnection(id: UUID) {
        activeConnectionTasks.removeValue(forKey: id)
        activeConnections.removeValue(forKey: id)
    }

    // MARK: - Connection loop

    /// Outcome of trying to read a request head off the wire.
    private enum HeadOutcome {
        case head(HTTPRequestHead)
        /// FIN arrived with nothing buffered: the peer is done with a persistent connection. This
        /// is a normal close, not an error, and must not produce a 500 write onto a dead socket.
        case cleanEOF
        /// The idle-read deadline expired between requests. Also not an error.
        case idle
    }

    /// One connection, many requests. The loop is explicit about *why* it stops, because the
    /// close reason and the `Connection:` header on the last response have to agree — telling a
    /// pooled client the socket is reusable and then closing it is an interop regression.
    private func run(connection: NWConnection, connectionID: String, remoteAddress: String) async {
        var buffer = Data()
        var requestsServed = 0
        var closeReason = "completed"

        serve: while true {
            if requestsServed >= limits.maximumRequestsPerConnection {
                closeReason = "request_cap"
                break serve
            }

            // --- head ---
            let headOutcome: HeadOutcome
            do {
                (headOutcome, buffer) = try await readHead(
                    on: connection,
                    buffer: buffer,
                    connectionID: connectionID,
                    remoteAddress: remoteAddress
                )
            } catch {
                closeReason = "failed"
                logConnectionFailure(error, connectionID: connectionID, remoteAddress: remoteAddress)
                await sendClosing(error: error, on: connection)
                break serve
            }

            let head: HTTPRequestHead
            switch headOutcome {
            case .cleanEOF:
                closeReason = "eof"
                break serve
            case .idle:
                closeReason = "idle"
                break serve
            case .head(let parsed):
                head = parsed
            }

            // --- body ---
            let requestID = UUID().uuidString.lowercased()
            let request: HTTPRequest
            var temporaryFileURL: URL?
            do {
                let read = try await readBody(
                    head: head,
                    buffer: buffer,
                    on: connection,
                    connectionID: connectionID,
                    remoteAddress: remoteAddress,
                    requestID: requestID
                )
                buffer = read.leftover
                temporaryFileURL = read.temporaryFileURL
                request = HTTPRequest(
                    method: head.method,
                    path: head.path,
                    query: head.query,
                    headers: head.headers,
                    body: read.body,
                    remoteAddress: remoteAddress,
                    requestID: requestID,
                    connectionID: connectionID
                )
            } catch {
                // The body was NOT drained, so undrained bytes are still in the socket. Continuing
                // would parse them as the next request line and desync the stream: close.
                closeReason = "failed"
                logConnectionFailure(error, connectionID: connectionID, remoteAddress: remoteAddress)
                await sendClosing(error: error, on: connection)
                break serve
            }

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

            // --- handle ---
            var response: HTTPResponse
            do {
                response = try await server.handle(request)
            } catch {
                logConnectionFailure(error, connectionID: connectionID, remoteAddress: remoteAddress)
                // Every other non-2xx path in `LocalSendServer` answers with the reference's
                // `{"message": "..."}` body; a body-less 500 here left interoperating senders with
                // nothing to surface. The message is deliberately generic — `error` has already
                // been logged locally, and its detail (paths, syscall text) is not a peer's
                // business.
                response = .error(statusCode: 500, message: "Internal server error")
            }
            if let temporaryFileURL {
                try? FileManager.default.removeItem(at: temporaryFileURL)
            }

            // --- respond ---
            // Computed BEFORE the response header is serialized, so the `Connection:` header we
            // emit is guaranteed to match what we actually do next.
            let closeAfterResponse = Self.closeReason(
                head: head,
                requestsServed: requestsServed,
                limits: limits
            )
            response.headers["Connection"] = closeAfterResponse == nil ? "keep-alive" : "close"
            do {
                try await send(response: response, on: connection)
            } catch {
                closeReason = "failed"
                logConnectionFailure(error, connectionID: connectionID, remoteAddress: remoteAddress)
                break serve
            }

            requestsServed += 1
            if let closeAfterResponse {
                closeReason = closeAfterResponse
                break serve
            }
        }

        connection.cancel()
        logger.emit(
            level: .debug,
            event: "server.connection.closed",
            scope: "LocalSendServerRuntime",
            context: connectionContext(connectionID: connectionID, remoteAddress: remoteAddress),
            attributes: [
                .string("result", closeReason),
                .int("http.requests_served", requestsServed)
            ]
        )
    }

    /// Returns the close reason, or `nil` if the connection may be reused.
    ///
    /// Note the deliberate absence of an "error before the body was drained" clause here: every
    /// such path in `run` breaks out of the loop directly via `sendClosing`, which always emits
    /// `Connection: close`. Keeping the two mechanisms separate means a newly added error path
    /// cannot accidentally opt into persistence.
    private static func closeReason(
        head: HTTPRequestHead,
        requestsServed: Int,
        limits: LocalSendRuntimeLimits
    ) -> String? {
        let tokens = head.connectionTokens
        if tokens.contains("close") {
            return "client_close"
        }
        if head.isHTTP10, tokens.contains("keep-alive") == false {
            return "http_1_0"
        }
        if requestsServed + 1 >= limits.maximumRequestsPerConnection {
            return "request_cap"
        }
        return nil
    }

    private func readHead(
        on connection: NWConnection,
        buffer initialBuffer: Data,
        connectionID: String,
        remoteAddress: String
    ) async throws -> (outcome: HeadOutcome, buffer: Data) {
        var buffer = initialBuffer

        while true {
            if buffer.range(of: HTTPRequestParser.headerTerminator) != nil {
                let head = try HTTPRequestParser.parseHead(from: buffer, maximumHeaderBytes: limits.maximumHeaderBytes)
                logger.emit(
                    level: .debug,
                    event: "server.request.received",
                    scope: "LocalSendServerRuntime",
                    context: connectionContext(connectionID: connectionID, remoteAddress: remoteAddress)
                )
                return (.head(head), buffer)
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

            let received: (data: Data, isComplete: Bool)
            do {
                received = try await receive(on: connection, timeout: limits.requestTimeout)
            } catch LocalSendRuntimeError.requestTimeout {
                return (.idle, buffer)
            }

            if received.data.isEmpty == false {
                buffer.append(received.data)
            }
            if received.isComplete {
                guard buffer.isEmpty == false else {
                    return (.cleanEOF, buffer)
                }
                guard buffer.range(of: HTTPRequestParser.headerTerminator) != nil else {
                    // FIN with a partial request buffered: genuinely truncated.
                    throw HTTPParserError.incompleteBody
                }
            } else if received.data.isEmpty {
                throw LocalSendRuntimeError.connectionReadFailed
            }
        }
    }

    private func readBody(
        head: HTTPRequestHead,
        buffer: Data,
        on connection: NWConnection,
        connectionID: String,
        remoteAddress: String,
        requestID: String
    ) async throws -> (body: HTTPRequestBody, leftover: Data, temporaryFileURL: URL?) {
        let afterHead = Data(buffer.dropFirst(head.headerByteCount))

        guard LocalSendKit.isUploadRoute(path: head.path) else {
            if case .length(let declared) = head.framing, declared > Int64(limits.maximumJSONBodyBytes) {
                logBodyTooLarge(
                    head: head,
                    size: declared,
                    connectionID: connectionID,
                    remoteAddress: remoteAddress,
                    requestID: requestID
                )
                throw LocalSendRuntimeError.bodyTooLarge
            }
            do {
                let (body, leftover) = try await readBufferedBody(
                    framing: head.framing,
                    initialBody: afterHead,
                    limit: limits.maximumJSONBodyBytes,
                    on: connection
                )
                return (.data(body), leftover, nil)
            } catch LocalSendRuntimeError.bodyTooLarge {
                logBodyTooLarge(
                    head: head,
                    size: Int64(limits.maximumJSONBodyBytes),
                    connectionID: connectionID,
                    remoteAddress: remoteAddress,
                    requestID: requestID
                )
                throw LocalSendRuntimeError.bodyTooLarge
            }
        }

        // Not `head.query["sessionId"]` directly: a v1 `/send` carries no session id, and every
        // call below would then miss the live session and silently skip progress/staging bounds.
        let sessionId = await server.resolveUploadSessionId(path: head.path, query: head.query)
        let fileId = head.query["fileId"]
        await server.beginStreamingUpload(
            sessionId: sessionId,
            fileId: fileId,
            token: head.query["token"],
            senderIP: remoteAddress
        )

        // `stageUploadBody`'s old clamp to `Content-Length` was the only thing bounding how much
        // a peer could write into the save directory, and a chunked body has no declared length
        // at all. Bound it by the `file.size` the accepted prepare-upload declared, and by an
        // absolute backstop when no session matches.
        let declaredSize = await server.expectedUploadByteCount(
            sessionId: sessionId,
            fileId: fileId,
            senderIP: remoteAddress
        )
        let ceiling = min(limits.maximumUploadBodyBytes, declaredSize ?? limits.maximumUploadBodyBytes)

        do {
            let staged = try await stageUploadBody(
                framing: head.framing,
                initialBody: afterHead,
                ceiling: ceiling,
                on: connection,
                // Coalesced: this fires once per 64 KiB read, and each call is an actor hop plus a
                // snapshot recompute plus a broadcast to every state observer — ~16,000 of them
                // for a 1 GB file, none of it perceivable. Dropping intermediate samples costs
                // nothing: `ReceiveSession.upload` sets `bytesReceived` to the file's full size on
                // completion, so the terminal total is exact regardless of what is skipped here.
                progressObserver: { [server, coalescer = ProgressCoalescerBox()] bytesWritten in
                    guard coalescer.shouldReport(bytes: bytesWritten) else {
                        return
                    }
                    await server.updateStreamingUpload(
                        sessionId: sessionId,
                        fileId: fileId,
                        senderIP: remoteAddress,
                        bytesReceived: bytesWritten
                    )
                }
            )
            return (staged.body, staged.leftover, staged.fileURL)
        } catch {
            await server.failStreamingUpload(
                sessionId: sessionId,
                fileId: fileId,
                senderIP: remoteAddress
            )
            throw error
        }
    }

    private func readBufferedBody(
        framing: BodyFraming,
        initialBody: Data,
        limit: Int,
        on connection: NWConnection
    ) async throws -> (body: Data, leftover: Data) {
        switch framing {
        case .none:
            return (Data(), initialBody)

        case .length(let declared):
            let expectedLength = Int(declared)
            var body = initialBody
            while body.count < expectedLength {
                let received = try await receive(on: connection, timeout: limits.requestTimeout)
                guard received.data.isEmpty == false else {
                    throw HTTPParserError.incompleteBody
                }
                body.append(received.data)
                if received.isComplete, body.count < expectedLength {
                    throw HTTPParserError.incompleteBody
                }
            }
            let leftover = body.count > expectedLength ? Data(body.dropFirst(expectedLength)) : Data()
            return (Data(body.prefix(expectedLength)), leftover)

        case .chunked:
            // `maximumJSONBodyBytes` used to key off `Content-Length`, which chunked bypasses
            // entirely; the ceiling has to accumulate during decode instead.
            var decoder = ChunkedBodyDecoder()
            var pending = initialBody
            var body = Data()
            while true {
                let output = try decoder.decode(pending)
                body.append(output.decodedBytes)
                if body.count > limit {
                    throw LocalSendRuntimeError.bodyTooLarge
                }
                pending = Data(pending.dropFirst(output.consumedInputOffset))
                if output.isComplete {
                    return (body, pending)
                }
                let received = try await receive(on: connection, timeout: limits.requestTimeout)
                guard received.data.isEmpty == false else {
                    throw HTTPParserError.incompleteBody
                }
                pending.append(received.data)
            }
        }
    }

    private func stageUploadBody(
        framing: BodyFraming,
        initialBody: Data,
        ceiling: Int64,
        on connection: NWConnection,
        progressObserver: (@Sendable (Int64) async -> Void)? = nil
    ) async throws -> (body: HTTPRequestBody, leftover: Data, fileURL: URL) {
        // Idempotent, and the only thing standing between a swept/never-prepared staging directory
        // and a `FileHandle` failure that would surface to the peer as a 500.
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let fileURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            try? FileManager.default.removeItem(at: fileURL)
            throw LocalSendRuntimeError.connectionReadFailed
        }
        // Nothing used to delete this file on a throw, so every failed or oversized upload leaked
        // a full-size temp file into the user's directory.
        var succeeded = false
        defer {
            try? handle.close()
            if succeeded == false {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        logger.emit(
            level: .debug,
            event: "server.body.staged_to_disk",
            scope: "LocalSendServerRuntime",
            attributes: [
                .string("result", "started"),
                .int64("http.request.body.size", ceiling)
            ]
        )

        var bytesWritten = Int64(0)
        var leftover = Data()

        switch framing {
        case .none:
            leftover = initialBody

        case .length(let expectedLength):
            guard expectedLength <= ceiling else {
                throw LocalSendRuntimeError.bodyTooLarge
            }

            func write(_ data: Data) throws {
                let remaining = expectedLength - bytesWritten
                if Int64(data.count) > remaining {
                    try handle.write(contentsOf: data.prefix(Int(remaining)))
                    leftover = Data(data.dropFirst(Int(remaining)))
                    bytesWritten += remaining
                } else {
                    try handle.write(contentsOf: data)
                    bytesWritten += Int64(data.count)
                }
            }

            if initialBody.isEmpty == false {
                try write(initialBody)
                if let progressObserver {
                    await progressObserver(bytesWritten)
                }
            }
            while bytesWritten < expectedLength {
                let received = try await receive(on: connection, timeout: limits.requestTimeout)
                guard received.data.isEmpty == false else {
                    throw HTTPParserError.incompleteBody
                }
                try write(received.data)
                if let progressObserver {
                    await progressObserver(bytesWritten)
                }
            }

        case .chunked:
            var decoder = ChunkedBodyDecoder()
            var pending = initialBody
            while true {
                let output = try decoder.decode(pending)
                if output.decodedBytes.isEmpty == false {
                    bytesWritten += Int64(output.decodedBytes.count)
                    guard bytesWritten <= ceiling else {
                        throw LocalSendRuntimeError.bodyTooLarge
                    }
                    try handle.write(contentsOf: output.decodedBytes)
                    if let progressObserver {
                        await progressObserver(bytesWritten)
                    }
                }
                // Leftover is sliced from the decoder's reported input offset, never from a byte
                // count: what follows the terminating `0\r\n` may include a trailer section, and
                // getting this wrong starts the next request parse mid-stream.
                pending = Data(pending.dropFirst(output.consumedInputOffset))
                if output.isComplete {
                    leftover = pending
                    break
                }
                let received = try await receive(on: connection, timeout: limits.requestTimeout)
                guard received.data.isEmpty == false else {
                    throw HTTPParserError.incompleteBody
                }
                pending.append(received.data)
            }
        }

        logger.emit(
            level: .debug,
            event: "server.body.staged_to_disk",
            scope: "LocalSendServerRuntime",
            attributes: [
                .string("result", "success"),
                .int64("http.request.body.size", bytesWritten)
            ]
        )
        succeeded = true
        return (.file(fileURL, byteCount: bytesWritten), leftover, fileURL)
    }

    // MARK: - Error responses

    private static func statusCode(for error: Error) -> Int {
        if let parserError = error as? HTTPParserError {
            switch parserError {
            case .headersTooLarge:
                return 431
            case .unsupportedTransferEncoding:
                return 501
            case .bodyTooLarge:
                return 413
            case .invalidRequestLine, .invalidMethod, .invalidHeader, .invalidContentLength, .incompleteBody, .invalidEncoding:
                return 400
            }
        }
        if error is ChunkedBodyDecoderError {
            return 400
        }
        if let runtimeError = error as? LocalSendRuntimeError {
            switch runtimeError {
            case .bodyTooLarge:
                return 413
            case .requestTimeout:
                return 408
            default:
                return 500
            }
        }
        return 500
    }

    private func sendClosing(error: Error, on connection: NWConnection) async {
        let response = HTTPResponse(
            statusCode: Self.statusCode(for: error),
            headers: ["Connection": "close"]
        )
        _ = try? await send(response: response, on: connection)
    }

    private func logConnectionFailure(_ error: Error, connectionID: String, remoteAddress: String) {
        logger.emit(
            level: .error,
            event: "server.request.failed",
            scope: "LocalSendServerRuntime",
            context: connectionContext(connectionID: connectionID, remoteAddress: remoteAddress),
            attributes: [
                .string("result", "failure"),
                .int("http.response.status_code", Self.statusCode(for: error)),
                .string("error.message", error.localizedDescription),
                .string("error.type", String(describing: type(of: error)))
            ]
        )
    }

    private func logBodyTooLarge(
        head: HTTPRequestHead,
        size: Int64,
        connectionID: String,
        remoteAddress: String,
        requestID: String
    ) {
        logger.emit(
            level: .warning,
            event: "server.request.failed",
            scope: "LocalSendServerRuntime",
            context: AppLogContext(
                attributes: connectionContext(connectionID: connectionID, remoteAddress: remoteAddress).attributes + [
                    .string("request.request_id", requestID),
                    .string("url.path", head.path)
                ]
            ),
            attributes: [
                .string("result", "body_too_large"),
                .int64("http.request.body.size", size)
            ]
        )
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

    /// Surfaces `isComplete` (FIN) rather than discarding it. Without it the loop always issues
    /// one extra read after the peer closes, takes the error path, and writes a 500 onto a dead
    /// socket.
    ///
    /// `timeout` is the per-read inactivity deadline. Both the timer and the `receive` callback
    /// are delivered on `tlsConfiguration.queue`, which is serial, so the one-shot box below needs
    /// no additional locking — and a `CheckedContinuation` resumed twice would trap.
    private func receive(
        on connection: NWConnection,
        timeout: Duration?
    ) async throws -> (data: Data, isComplete: Bool) {
        let queue = tlsConfiguration.queue
        return try await withCheckedThrowingContinuation { continuation in
            let box = ReceiveContinuationBox(continuation)
            if let timeout {
                queue.asyncAfter(deadline: .now() + Self.timeInterval(from: timeout)) {
                    box.resume(throwing: LocalSendRuntimeError.requestTimeout)
                }
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    box.resume(throwing: error)
                    return
                }
                box.resume(returning: (data ?? Data(), isComplete))
            }
        }
    }

    private static let stopDrainTimeout: Duration = .seconds(2)

    /// Returns `true` when every task finished, `false` when the deadline fired first — callers use
    /// that to tell "everything has stopped touching the filesystem" from "we gave up waiting".
    private static func drain(
        _ tasks: [Task<Void, Never>],
        timeout: Duration,
        on queue: DispatchQueue
    ) async -> Bool {
        guard tasks.isEmpty == false else { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let signal = OnceSignal(continuation)
            Task.detached {
                for task in tasks {
                    await task.value
                }
                signal.fire(true)
            }
            queue.asyncAfter(deadline: .now() + timeInterval(from: timeout)) {
                signal.fire(false)
            }
        }
    }

    private static func timeInterval(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
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

    /// The peer address recorded as `HTTPRequest.remoteAddress`.
    ///
    /// A real IPv6 peer connects with a link-local address carrying an interface scope
    /// (`fe80::1%en0`). That text becomes the session's sender IP and is compared against the
    /// address of the follow-up `/upload` and `/cancel` connections
    /// (`ReceiveSession`'s `snapshot.senderIP == senderIP` guards), so the zone is **kept**:
    /// dropping it would merge `fe80::1%en0` and `fe80::1%en1` — two distinct hosts on two
    /// interfaces — into one identity and widen the equality class of a security-relevant check.
    ///
    /// This must stay in lockstep with `MulticastListenerRuntime.remoteHost(from:)`: both go
    /// through `NetworkEndpointAddress.canonicalHost(from:)` so the address we store can never
    /// disagree with the address we connect to. The kernel populates `sin6_scope_id` consistently
    /// per address, so a peer that presents a zone on `prepare-upload` presents the same one on
    /// `upload`.
    static func remoteAddress(from endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else {
            return "127.0.0.1"
        }
        let raw: String
        switch host {
        case .ipv4(let value):
            raw = value.debugDescription
        case .ipv6(let value):
            raw = value.debugDescription
        case .name(let name, _):
            raw = name
        @unknown default:
            return "127.0.0.1"
        }
        return NetworkEndpointAddress.canonicalHost(from: raw)
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

/// One-shot continuation holder. Only ever touched from `LocalSendTLSConfiguration.queue`
/// (serial), so the unchecked conformance is sound.
private final class ReceiveContinuationBox: @unchecked Sendable {
    private var continuation: CheckedContinuation<(data: Data, isComplete: Bool), Error>?

    init(_ continuation: CheckedContinuation<(data: Data, isComplete: Bool), Error>) {
        self.continuation = continuation
    }

    func resume(returning value: (data: Data, isComplete: Bool)) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }
}

/// Resumes its continuation exactly once, whichever of two racing callers gets there first.
/// Unlike `ReceiveContinuationBox` the callers here are on different threads, so this one locks.
/// Resumes its continuation exactly once, with whichever value reached it first. Both racers always
/// fire; the loser is dropped.
private final class OnceSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func fire(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
