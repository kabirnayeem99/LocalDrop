import AppLogging
import Foundation

public struct LocalSendServerConfiguration: Sendable {
    public var registerInfo: RegisterInfo
    public var pin: String?
    public var uploadPolicy: PrepareUploadPolicy
    public var incomingRequestBridge: IncomingTransferRequestBridge?
    public var sharedFiles: [String: LocalSharedFile]
    public var sharedFilesProvider: (@Sendable () async -> [String: LocalSharedFile])?
    public var allowDownloads: Bool
    public var storageDirectory: URL
    public var stateObserver: (@Sendable (LocalSendServerStateSnapshot) async -> Void)?
    /// Notified when a peer registers with us over TCP `POST /register`, so HTTP-only discovery is
    /// two-way: the reference's `_registerHandler` records the caller in its own device list before
    /// answering. Wired to `DiscoveryService.registerInboundPeer(host:info:)`.
    public var peerRegistrationObserver: (@Sendable (_ callerIP: String, _ info: RegisterInfo) async -> Void)?
    public var logger: AppLogger

    public init(
        registerInfo: RegisterInfo,
        pin: String? = nil,
        uploadPolicy: PrepareUploadPolicy = .acceptAll,
        incomingRequestBridge: IncomingTransferRequestBridge? = nil,
        sharedFiles: [String: LocalSharedFile] = [:],
        sharedFilesProvider: (@Sendable () async -> [String: LocalSharedFile])? = nil,
        allowDownloads: Bool = true,
        storageDirectory: URL,
        stateObserver: (@Sendable (LocalSendServerStateSnapshot) async -> Void)? = nil,
        peerRegistrationObserver: (@Sendable (_ callerIP: String, _ info: RegisterInfo) async -> Void)? = nil,
        logger: AppLogger = .disabled()
    ) {
        self.registerInfo = registerInfo
        self.pin = pin
        self.uploadPolicy = uploadPolicy
        self.incomingRequestBridge = incomingRequestBridge
        self.sharedFiles = sharedFiles
        self.sharedFilesProvider = sharedFilesProvider
        self.allowDownloads = allowDownloads
        self.storageDirectory = storageDirectory
        self.stateObserver = stateObserver
        self.peerRegistrationObserver = peerRegistrationObserver
        self.logger = logger
    }
}

public actor LocalSendServer {
    private let configuration: LocalSendServerConfiguration
    private let pinTracker = PinAttemptTracker()
    private let receiveSession = ReceiveSession()
    private let sendSession = SendSession()
    /// Shared with `HTTPResponse.error` so the 2xx and non-2xx bodies cannot drift apart.
    private let encoder = ServerJSONEncoding.encoder
    private let decoder = JSONDecoder()

    public init(configuration: LocalSendServerConfiguration) {
        self.configuration = configuration
    }

    public func handle(_ request: HTTPRequest) async throws -> HTTPResponse {
        // Canonical names, so `v1/send-request` and `v2/prepare-upload` reach the same handler and
        // only the genuine v1/v2 payload differences are branched on inside it.
        let resolved = LocalSendKit.resolveCanonicalRoute(path: request.path)
        switch (request.method, resolved?.version, resolved?.route) {
        // v1 and v2 `/info` are served by the same handler with a byte-identical `InfoDto` in the
        // reference (`receive_controller.dart:74-80`, `_infoHandler` at `:124-147`). GET only —
        // there is no POST info route. The v1 route specifically matters because the reference's
        // "add device by IP" feature deliberately calls it
        // (`common/lib/src/task/discovery/http_target_discovery.dart:32-36`).
        case (.get, _, "info"):
            // Self-discovery guard. The reference's `_infoHandler` reads the peer fingerprint from
            // the QUERY STRING (`receive_controller.dart:128`) — not the body — and answers
            // `412 Self-discovered` on a match. An absent parameter is not a match: most clients
            // never send it and must still get a 200.
            if let senderFingerprint = request.query["fingerprint"],
               senderFingerprint == configuration.registerInfo.fingerprint {
                logRouteOutcome(event: "protocol.info.handled", request: request, statusCode: 412, result: "self_discovered", level: .notice)
                return .error(statusCode: 412, message: "Self-discovered")
            }
            return try jsonResponse(configuration.registerInfo.asInfoResponse)
        // The transfer routes are served for BOTH versions. The reference installs a v1 and a v2
        // handler for every one of them (`receive_controller.dart:installRoutes`), so a peer pinned
        // to protocol v1 must not get a 404 on anything but the download API.
        case (.post, _, "register"):
            return try await handleRegister(request)
        case (.post, .some(let version), "prepare-upload"):
            return try await handlePrepareUpload(request, version: version)
        case (.post, .some(let version), "upload"):
            return try await handleUpload(request, version: version)
        case (.post, .some(let version), "cancel"):
            return await handleCancel(request, version: version)
        case (.post, .v2, "prepare-download"):
            return try await handlePrepareDownload(request)
        case (.get, .v2, "download"):
            return try await handleDownload(request)
        default:
            // Still 404 by design: the download API (`prepare-download`/`download`) is v2-only in
            // the reference, and `/show` plus the browser web-send assets (`/`, `/main.js`,
            // `/i18n.json`) are unimplemented — which is why `/info` now advertises
            // `download: false` rather than pointing browsers at a dead end.
            configuration.logger.emit(
                level: .warning,
                event: "server.request.failed",
                scope: "LocalSendServer",
                context: requestContext(for: request),
                attributes: [
                    .string("result", "route_miss"),
                    .string("http.request.method", request.method.rawValue),
                    .string("url.path", request.path),
                    .int("http.response.status_code", 404)
                ]
            )
            return .error(statusCode: 404, message: "Not found")
        }
    }

    public func receiveSnapshot() async -> ReceiveSessionSnapshot? {
        await receiveSession.snapshot()
    }

    public func sendSnapshot(sessionId: String) async -> SendSessionSnapshot? {
        await sendSession.snapshot(sessionId: sessionId)
    }

    /// Locally initiated cancel of the live receive session (the receive-side cancel button), as
    /// opposed to the `/cancel` route, which is a peer telling us to stop.
    ///
    /// Only the local teardown and the resulting state notification happen here. Telling the SENDER
    /// is deliberately NOT done at this layer: this type answers the network, it does not call out
    /// on the user's behalf, and driving an outbound `/cancel` off this state change would bounce a
    /// cancel back at any peer that cancelled us.
    public func cancelReceiveSession(sessionId: String) async -> Bool {
        guard await receiveSession.cancelLocally(sessionId: sessionId) else {
            return false
        }
        await notifyStateObserver()
        return true
    }

    public func beginStreamingUpload(
        sessionId: String?,
        fileId: String?,
        token: String?,
        senderIP: String
    ) async {
        guard await receiveSession.beginUpload(
            sessionId: sessionId,
            fileId: fileId,
            token: token,
            senderIP: senderIP
        ) else {
            return
        }
        await notifyStateObserver()
    }

    /// The `file.size` the accepted `prepare-upload` declared for this file, if the parameters
    /// match a live session. Used to bound how much a peer may stream to disk when the request
    /// carries no `Content-Length` (chunked).
    public func expectedUploadByteCount(
        sessionId: String?,
        fileId: String?,
        senderIP: String
    ) async -> Int64? {
        await receiveSession.expectedByteCount(
            sessionId: sessionId,
            fileId: fileId,
            senderIP: senderIP
        )
    }

    public func updateStreamingUpload(
        sessionId: String?,
        fileId: String?,
        senderIP: String,
        bytesReceived: Int64
    ) async {
        guard await receiveSession.updateUploadProgress(
            sessionId: sessionId,
            fileId: fileId,
            senderIP: senderIP,
            bytesReceived: bytesReceived
        ) else {
            return
        }
        await notifyStateObserver()
    }

    public func failStreamingUpload(
        sessionId: String?,
        fileId: String?,
        senderIP: String
    ) async {
        guard await receiveSession.failUpload(
            sessionId: sessionId,
            fileId: fileId,
            senderIP: senderIP
        ) else {
            return
        }
        await notifyStateObserver()
    }

    private func currentSharedFiles() async -> [String: LocalSharedFile] {
        if let sharedFilesProvider = configuration.sharedFilesProvider {
            return await sharedFilesProvider()
        }
        return configuration.sharedFiles
    }

    private func handleRegister(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.body.isEmpty == false else {
            logRouteOutcome(event: "protocol.register.handled", request: request, statusCode: 400, result: "bad_request", level: .warning)
            return .error(statusCode: 400, message: "Request body malformed")
        }
        // A body that is present but not decodable is a client error, not a server error: the
        // reference answers `400 {"message": "Request body malformed"}`
        // (`receive_controller.dart:157-162`). Letting the decode throw here would surface as a
        // body-less 500 from the runtime's catch-all, and would disagree with the empty-body guard
        // directly above, which already returns that exact 400.
        let payload: RegisterInfo
        do {
            payload = try decoder.decode(RegisterInfo.self, from: try request.body.loadData())
        } catch {
            logRouteOutcome(event: "protocol.register.handled", request: request, statusCode: 400, result: "decode_failed", level: .warning)
            return .error(statusCode: 400, message: "Request body malformed")
        }
        // Self-discovery guard. Unlike `/info`, `_registerHandler` (`receive_controller.dart:163`)
        // compares the fingerprint from the decoded request BODY.
        if payload.fingerprint == configuration.registerInfo.fingerprint {
            logRouteOutcome(event: "protocol.register.handled", request: request, statusCode: 412, result: "self_discovered", level: .notice)
            return .error(statusCode: 412, message: "Self-discovered")
        }
        // Two-way discovery: the caller becomes visible to US, not just us to it. Ordered exactly
        // as the reference does — after the self-discovery guard (we must never add ourselves) and
        // before the 200, so a peer is in the list by the time it believes registration succeeded.
        //
        // The caller's transport address is used as the host; the BODY's `port`/`protocol` are
        // kept, because the source port of this HTTP request is ephemeral and cannot be called back.
        await configuration.peerRegistrationObserver?(request.remoteAddress, payload)

        logRouteOutcome(event: "protocol.register.handled", request: request, statusCode: 200, result: "success", level: .debug)
        return try jsonResponse(configuration.registerInfo.asInfoResponse)
    }

    private func handlePrepareUpload(_ request: HTTPRequest, version: LocalSendKit.APIVersion) async throws -> HTTPResponse {
        switch await pinTracker.validate(
            ipAddress: request.remoteAddress,
            providedPIN: request.query["pin"],
            expectedPIN: configuration.pin
        ) {
        case .allowed:
            break
        case .unauthorized:
            logRouteOutcome(event: "protocol.prepare_upload.unauthorized", request: request, statusCode: 401, result: "unauthorized", level: .notice)
            return .error(statusCode: 401, message: "PIN required or invalid")
        case .rateLimited:
            logRouteOutcome(event: "protocol.prepare_upload.rate_limited", request: request, statusCode: 429, result: "rate_limited", level: .notice)
            return .error(statusCode: 429, message: "Too many attempts")
        }

        guard request.body.isEmpty == false else {
            logRouteOutcome(event: "protocol.prepare_upload.rejected", request: request, statusCode: 400, result: "bad_request", level: .warning)
            return .error(statusCode: 400, message: "Request body malformed")
        }

        let payload: PrepareUploadRequest
        do {
            payload = try decoder.decode(PrepareUploadRequest.self, from: try request.body.loadData())
        } catch {
            logRouteOutcome(event: "protocol.prepare_upload.rejected", request: request, statusCode: 400, result: "decode_failed", level: .warning)
            return .error(statusCode: 400, message: "Request body malformed")
        }

        if payload.files.isEmpty {
            logRouteOutcome(event: "protocol.prepare_upload.rejected", request: request, statusCode: 400, result: "empty_files", level: .warning)
            return .error(statusCode: 400, message: "No files in request")
        }

        let resolvedResponse: HTTPResponse
        switch try await receiveSession.prepare(
            request: payload,
            senderIP: request.remoteAddress,
            policy: configuration.uploadPolicy,
            incomingRequestBridge: configuration.incomingRequestBridge,
            destinationDirectory: configuration.storageDirectory,
            sessionIdFactory: { UUID().uuidString },
            tokenFactory: { _ in UUID().uuidString }
        ) {
        case .accepted(let response):
            logRouteOutcome(
                event: "protocol.prepare_upload.allowed",
                request: request,
                statusCode: 200,
                result: "success",
                level: .info,
                attributes: [
                    .string("transfer.session_id", response.sessionId),
                    .int("transfer.accepted_file_count", response.files.count)
                ]
            )
            // v1 answers with the BARE `{fileId: token}` map; the `{sessionId, files}` envelope is
            // a v2 addition (`receive_controller.dart`: `if (v2) … PrepareUploadResponseDto … ;
            // return await request.respondJson(200, body: files);`). A v1 peer handed the envelope
            // would find no tokens at all.
            resolvedResponse = version == .v1
                ? try jsonResponse(response.files)
                : try jsonResponse(response)
        case .rejected:
            logRouteOutcome(event: "protocol.prepare_upload.rejected", request: request, statusCode: 403, result: "rejected", level: .notice)
            resolvedResponse = .error(statusCode: 403, message: "Rejected")
        case .blocked:
            logRouteOutcome(event: "protocol.prepare_upload.rejected", request: request, statusCode: 409, result: "blocked", level: .warning)
            resolvedResponse = .error(statusCode: 409, message: "Blocked by another session")
        case .noTransferNeeded:
            logRouteOutcome(event: "protocol.prepare_upload.rejected", request: request, statusCode: 204, result: "no_transfer_needed", level: .notice)
            resolvedResponse = .empty(statusCode: 204)
        }
        await notifyStateObserver()
        return resolvedResponse
    }

    /// The session id an upload should be validated against.
    ///
    /// v1 has no `sessionId` parameter at all — `_uploadHandler` validates `fileId` + `token` only
    /// (`if (fileId == null || token == null || (v2 && sessionId == null))`, and the id-equality
    /// check is likewise `if (v2 && …)`). Substituting the live session's own id keeps ONE
    /// validation path rather than a parallel v1 one; the per-file token is what actually
    /// authorizes the write, exactly as in the reference.
    ///
    /// Public because the streaming path in `LocalSendServerRuntime` resolves the same id *before*
    /// the body is read, and the two must not disagree — a mismatch would stage bytes under a
    /// session the handler then rejects.
    public func resolveUploadSessionId(path: String, query: [String: String]) async -> String? {
        if let explicit = query["sessionId"], explicit.isEmpty == false {
            return explicit
        }
        guard LocalSendKit.resolveCanonicalRoute(path: path)?.version == .v1 else {
            return nil
        }
        return await receiveSession.currentSessionId()
    }

    private func handleUpload(_ request: HTTPRequest, version: LocalSendKit.APIVersion) async throws -> HTTPResponse {
        let sessionId = await resolveUploadSessionId(path: request.path, query: request.query)

        let result: UploadFileResult
        do {
            result = try await receiveSession.upload(
                sessionId: sessionId,
                fileId: request.query["fileId"],
                token: request.query["token"],
                senderIP: request.remoteAddress,
                body: request.body
            )
        } catch ReceiveSessionError.destinationDirectoryUnavailable {
            // A path this file needs as a directory is occupied by another file in the same batch.
            // Report it explicitly rather than letting it escape as the runtime's anonymous 500.
            logRouteOutcome(
                event: "protocol.upload.failed",
                request: request,
                statusCode: 500,
                result: "destination_directory_unavailable",
                level: .error
            )
            await notifyStateObserver()
            return .error(statusCode: 500, message: "Could not save file. Check receiving device for more information.")
        }

        let response: HTTPResponse
        switch result {
        case .success:
            logRouteOutcome(
                event: "protocol.upload.accepted",
                request: request,
                statusCode: 200,
                result: "success",
                level: .info,
                attributes: requestTransferIdentifiers(request)
            )
            response = .empty(statusCode: 200)
        case .missingParameters:
            logRouteOutcome(event: "protocol.upload.blocked", request: request, statusCode: 400, result: "missing_parameters", level: .warning)
            response = .error(statusCode: 400, message: "Missing parameters")
        case .forbidden:
            logRouteOutcome(event: "protocol.upload.blocked", request: request, statusCode: 403, result: "forbidden", level: .notice)
            response = .error(statusCode: 403, message: "Invalid token or IP address")
        case .blocked:
            logRouteOutcome(event: "protocol.upload.blocked", request: request, statusCode: 409, result: "blocked", level: .warning)
            response = .error(statusCode: 409, message: "Blocked by another session")
        }
        await notifyStateObserver()
        return response
    }

    private func handleCancel(_ request: HTTPRequest, version: LocalSendKit.APIVersion) async -> HTTPResponse {
        // A v1 cancel may not touch a session belonging to a v2 sender
        // (`_cancelHandler`: `if (!v2 && receiveSession.sender.version != '1.0') → 403`). Without
        // this, any peer on the LAN could kill a v2 transfer with an unauthenticated, session-id-less
        // v1 cancel — the v1 route deliberately accepts no session id, so there is nothing else to
        // check against.
        if version == .v1,
           let senderVersion = await receiveSession.currentSenderVersion(),
           senderVersion != LocalSendKit.fallbackProtocolVersion {
            logRouteOutcome(event: "protocol.cancel.handled", request: request, statusCode: 403, result: "v1_cancel_against_v2_session", level: .warning)
            return .error(statusCode: 403, message: "No permission")
        }

        // While the accept/decline prompt is up the reference authorizes a cancel on the sender's
        // IP alone and does not look at `sessionId` at all
        // (`receive_controller.dart:657`: "require session id for v2 / don't require it when
        // during waiting state"). IP matching is applied ONLY to a pending prompt — never to an
        // established session, where a stray cancel from a shared-NAT or spoofed peer would kill
        // an in-flight transfer.
        if await receiveSession.withdrawPendingRequest(
            senderIP: request.remoteAddress,
            incomingRequestBridge: configuration.incomingRequestBridge
        ) {
            await notifyStateObserver()
            logRouteOutcome(event: "protocol.cancel.handled", request: request, statusCode: 200, result: "pending_request_withdrawn", level: .info)
            return .empty(statusCode: 200)
        }

        // Everything below still requires a session id, and anything unmatched falls through to
        // the reference's `403 No permission` (`_cancelHandler`, `receive_controller.dart:646-653`)
        // rather than a blanket 200 that would mask real errors.
        // v1 carries no session id (`_cancelHandler` reads one only `if (v2 …)`), so the live
        // session's own id stands in. The sender-IP check inside `receiveSession.cancel` is what
        // authorizes it — the same and only authorization the reference applies on this path.
        var resolvedSessionId = request.query["sessionId"].flatMap { $0.isEmpty ? nil : $0 }
        if resolvedSessionId == nil, version == .v1 {
            resolvedSessionId = await receiveSession.currentSessionId()
        }

        guard let sessionId = resolvedSessionId else {
            // A prompt IS in flight, this cancel just did not match it (different sender IP). That
            // is a conflict, not a malformed request — 400 stays reserved for "nothing pending and
            // no session id given".
            if await receiveSession.pendingIncomingRequest() != nil {
                logRouteOutcome(event: "protocol.cancel.handled", request: request, statusCode: 409, result: "sender_mismatch", level: .warning)
                return .error(statusCode: 409, message: "Blocked by another session")
            }
            logRouteOutcome(event: "protocol.cancel.handled", request: request, statusCode: 400, result: "missing_session", level: .warning)
            return .error(statusCode: 400, message: "Missing session id")
        }

        if await receiveSession.cancel(sessionId: sessionId, senderIP: request.remoteAddress) {
            await notifyStateObserver()
            logRouteOutcome(event: "protocol.cancel.handled", request: request, statusCode: 200, result: "success", level: .info, attributes: [.string("transfer.session_id", sessionId)])
            return .empty(statusCode: 200)
        }
        if await sendSession.cancel(sessionId: sessionId, requesterIP: request.remoteAddress) {
            await notifyStateObserver()
            logRouteOutcome(event: "protocol.cancel.handled", request: request, statusCode: 200, result: "success", level: .info, attributes: [.string("transfer.session_id", sessionId)])
            return .empty(statusCode: 200)
        }
        logRouteOutcome(event: "protocol.cancel.handled", request: request, statusCode: 403, result: "blocked", level: .warning, attributes: [.string("transfer.session_id", sessionId)])
        return .error(statusCode: 403, message: "No permission")
    }

    private func handlePrepareDownload(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch await pinTracker.validate(
            ipAddress: request.remoteAddress,
            providedPIN: request.query["pin"],
            expectedPIN: configuration.pin
        ) {
        case .allowed:
            break
        case .unauthorized:
            logRouteOutcome(event: "protocol.prepare_download.rejected", request: request, statusCode: 401, result: "unauthorized", level: .notice)
            return .error(statusCode: 401, message: "PIN required or invalid")
        case .rateLimited:
            logRouteOutcome(event: "protocol.prepare_download.rejected", request: request, statusCode: 429, result: "rate_limited", level: .notice)
            return .error(statusCode: 429, message: "Too many attempts")
        }

        let resolvedResponse: HTTPResponse
        switch await sendSession.prepare(
            requesterIP: request.remoteAddress,
            localInfo: configuration.registerInfo.asInfoResponse,
            files: await currentSharedFiles(),
            allow: configuration.allowDownloads
        ) {
        case .accepted(let response):
            logRouteOutcome(
                event: "protocol.prepare_download.allowed",
                request: request,
                statusCode: 200,
                result: "success",
                level: .info,
                attributes: [.string("transfer.session_id", response.sessionId)]
            )
            resolvedResponse = try jsonResponse(response)
        case .rejected:
            logRouteOutcome(event: "protocol.prepare_download.rejected", request: request, statusCode: 403, result: "rejected", level: .notice)
            resolvedResponse = .error(statusCode: 403, message: "Rejected")
        }
        await notifyStateObserver()
        return resolvedResponse
    }

    private func handleDownload(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let sessionId = request.query["sessionId"],
              let fileId = request.query["fileId"],
              let file = try await sendSession.download(
                sessionId: sessionId,
                fileId: fileId,
                requesterIP: request.remoteAddress
              ) else {
            logRouteOutcome(event: "protocol.download.rejected", request: request, statusCode: 403, result: "rejected", level: .notice)
            return .error(statusCode: 403, message: "Rejected")
        }

        let response = HTTPResponse(
            statusCode: 200,
            headers: [
                "Content-Disposition": "attachment; filename=\"\(file.file.fileName)\"",
                "Content-Length": "\(file.responseBody.byteCount)",
                "Content-Type": file.file.fileType
            ],
            body: file.responseBody
        )
        await notifyStateObserver()
        logRouteOutcome(
            event: "protocol.download.allowed",
            request: request,
            statusCode: 200,
            result: "success",
            level: .info,
            attributes: [
                .string("transfer.session_id", sessionId),
                .string("transfer.file_id", fileId),
                .int64("http.response.body.size", response.contentLength)
            ]
        )
        return response
    }

    private func jsonResponse<T: Encodable>(_ value: T) throws -> HTTPResponse {
        let data = try encoder.encode(value)
        return HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": ServerJSONEncoding.contentType],
            body: data
        )
    }

    private func notifyStateObserver() async {
        guard let stateObserver = configuration.stateObserver else {
            return
        }
        await stateObserver(
            LocalSendServerStateSnapshot(
                receiveSession: await receiveSession.snapshot(),
                sendSessions: await sendSession.snapshots()
            )
        )
    }

    private func logRouteOutcome(
        event: String,
        request: HTTPRequest,
        statusCode: Int,
        result: String,
        level: AppLogLevel,
        attributes: [AppLogAttribute] = []
    ) {
        configuration.logger.emit(
            level: level,
            event: event,
            scope: "LocalSendServer",
            context: requestContext(for: request),
            attributes: [
                .string("result", result),
                .string("http.request.method", request.method.rawValue),
                .string("url.path", request.path),
                .int("http.response.status_code", statusCode)
            ] + requestTransferIdentifiers(request) + attributes
        )
    }

    private func requestContext(for request: HTTPRequest) -> AppLogContext {
        AppLogContext(attributes: [
            .string("client.address", request.remoteAddress)
        ] + (request.connectionID.map { [.string("request.connection_id", $0)] } ?? []) + (request.requestID.map { [.string("request.request_id", $0)] } ?? []))
    }

    private func requestTransferIdentifiers(_ request: HTTPRequest) -> [AppLogAttribute] {
        var attributes: [AppLogAttribute] = []
        if let sessionID = request.query["sessionId"], sessionID.isEmpty == false {
            attributes.append(.string("transfer.session_id", sessionID))
        }
        if let fileID = request.query["fileId"], fileID.isEmpty == false {
            attributes.append(.string("transfer.file_id", fileID))
        }
        return attributes
    }
}
