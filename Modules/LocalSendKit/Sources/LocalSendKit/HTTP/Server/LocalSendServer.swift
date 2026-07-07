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

    public init(
        registerInfo: RegisterInfo,
        pin: String? = nil,
        uploadPolicy: PrepareUploadPolicy = .acceptAll,
        incomingRequestBridge: IncomingTransferRequestBridge? = nil,
        sharedFiles: [String: LocalSharedFile] = [:],
        sharedFilesProvider: (@Sendable () async -> [String: LocalSharedFile])? = nil,
        allowDownloads: Bool = true,
        storageDirectory: URL,
        stateObserver: (@Sendable (LocalSendServerStateSnapshot) async -> Void)? = nil
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
    }
}

public actor LocalSendServer {
    private let configuration: LocalSendServerConfiguration
    private let pinTracker = PinAttemptTracker()
    private let receiveSession = ReceiveSession()
    private let sendSession = SendSession()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(configuration: LocalSendServerConfiguration) {
        self.configuration = configuration
    }

    public func handle(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch (request.method, request.path) {
        case (.post, "\(LocalSendKit.apiPrefix)/register"):
            return try await handleRegister(request)
        case (.get, "\(LocalSendKit.apiPrefix)/info"):
            return try jsonResponse(configuration.registerInfo.asInfoResponse)
        case (.post, "\(LocalSendKit.apiPrefix)/prepare-upload"):
            return try await handlePrepareUpload(request)
        case (.post, "\(LocalSendKit.apiPrefix)/upload"):
            return try await handleUpload(request)
        case (.post, "\(LocalSendKit.apiPrefix)/cancel"):
            return await handleCancel(request)
        case (.post, "\(LocalSendKit.apiPrefix)/prepare-download"):
            return try await handlePrepareDownload(request)
        case (.get, "\(LocalSendKit.apiPrefix)/download"):
            return try await handleDownload(request)
        default:
            return .empty(statusCode: 404)
        }
    }

    public func receiveSnapshot() async -> ReceiveSessionSnapshot? {
        await receiveSession.snapshot()
    }

    public func sendSnapshot(sessionId: String) async -> SendSessionSnapshot? {
        await sendSession.snapshot(sessionId: sessionId)
    }

    private func currentSharedFiles() async -> [String: LocalSharedFile] {
        if let sharedFilesProvider = configuration.sharedFilesProvider {
            return await sharedFilesProvider()
        }
        return configuration.sharedFiles
    }

    private func handleRegister(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.body.isEmpty == false else {
            return .empty(statusCode: 400)
        }
        _ = try decoder.decode(RegisterInfo.self, from: try request.body.loadData())
        return try jsonResponse(configuration.registerInfo)
    }

    private func handlePrepareUpload(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch await pinTracker.validate(
            ipAddress: request.remoteAddress,
            providedPIN: request.query["pin"],
            expectedPIN: configuration.pin
        ) {
        case .allowed:
            break
        case .unauthorized:
            return .empty(statusCode: 401)
        case .rateLimited:
            return .empty(statusCode: 429)
        }

        guard request.body.isEmpty == false else {
            return .empty(statusCode: 400)
        }

        let payload: PrepareUploadRequest
        do {
            payload = try decoder.decode(PrepareUploadRequest.self, from: try request.body.loadData())
        } catch {
            return .empty(statusCode: 400)
        }

        if payload.files.isEmpty {
            return .empty(statusCode: 400)
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
            resolvedResponse = try jsonResponse(response)
        case .rejected:
            resolvedResponse = .empty(statusCode: 403)
        case .blocked:
            resolvedResponse = .empty(statusCode: 409)
        case .noTransferNeeded:
            resolvedResponse = .empty(statusCode: 204)
        }
        await notifyStateObserver()
        return resolvedResponse
    }

    private func handleUpload(_ request: HTTPRequest) async throws -> HTTPResponse {
        let result = try await receiveSession.upload(
            sessionId: request.query["sessionId"],
            fileId: request.query["fileId"],
            token: request.query["token"],
            senderIP: request.remoteAddress,
            body: request.body
        )

        let response: HTTPResponse
        switch result {
        case .success:
            response = .empty(statusCode: 200)
        case .missingParameters:
            response = .empty(statusCode: 400)
        case .forbidden:
            response = .empty(statusCode: 403)
        case .blocked:
            response = .empty(statusCode: 409)
        }
        await notifyStateObserver()
        return response
    }

    private func handleCancel(_ request: HTTPRequest) async -> HTTPResponse {
        guard let sessionId = request.query["sessionId"], sessionId.isEmpty == false else {
            return .empty(statusCode: 400)
        }

        if await receiveSession.cancel(sessionId: sessionId, senderIP: request.remoteAddress) {
            await notifyStateObserver()
            return .empty(statusCode: 200)
        }
        if await sendSession.cancel(sessionId: sessionId, requesterIP: request.remoteAddress) {
            await notifyStateObserver()
            return .empty(statusCode: 200)
        }
        return .empty(statusCode: 409)
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
            return .empty(statusCode: 401)
        case .rateLimited:
            return .empty(statusCode: 429)
        }

        let resolvedResponse: HTTPResponse
        switch await sendSession.prepare(
            requesterIP: request.remoteAddress,
            localInfo: configuration.registerInfo.asInfoResponse,
            files: await currentSharedFiles(),
            allow: configuration.allowDownloads
        ) {
        case .accepted(let response):
            resolvedResponse = try jsonResponse(response)
        case .rejected:
            resolvedResponse = .empty(statusCode: 403)
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
            return .empty(statusCode: 403)
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
        return response
    }

    private func jsonResponse<T: Encodable>(_ value: T) throws -> HTTPResponse {
        let data = try encoder.encode(value)
        return HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
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
}
