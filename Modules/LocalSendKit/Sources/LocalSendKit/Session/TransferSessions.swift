import Foundation

public enum ReceiveSessionStatus: String, Codable, Sendable {
    case waiting
    case transferring
    case finished
    case canceled
}

public struct ReceivedFileRecord: Equatable, Sendable {
    public var file: FileDto
    public var token: String
    public var destinationURL: URL

    public init(file: FileDto, token: String, destinationURL: URL) {
        self.file = file
        self.token = token
        self.destinationURL = destinationURL
    }
}

public struct ReceiveSessionSnapshot: Equatable, Sendable {
    public var sessionId: String
    public var senderIP: String
    public var senderInfo: RegisterInfo
    public var files: [String: ReceivedFileRecord]
    public var status: ReceiveSessionStatus

    public init(
        sessionId: String,
        senderIP: String,
        senderInfo: RegisterInfo,
        files: [String: ReceivedFileRecord],
        status: ReceiveSessionStatus
    ) {
        self.sessionId = sessionId
        self.senderIP = senderIP
        self.senderInfo = senderInfo
        self.files = files
        self.status = status
    }
}

public enum PrepareUploadPolicy: Equatable, Sendable {
    case acceptAll
    case reject
    case acceptOnly(Set<String>)
    case messageOnly
}

public enum PrepareUploadOutcome: Equatable, Sendable {
    case accepted(PrepareUploadResponse)
    case rejected
    case blocked
    case noTransferNeeded
}

public enum UploadFileResult: Equatable, Sendable {
    case success
    case missingParameters
    case forbidden
    case blocked
}

public actor ReceiveSession {
    private var current: ReceiveSessionSnapshot?
    private var lastFinished: ReceiveSessionSnapshot?

    public init() {}

    public func prepare(
        request: PrepareUploadRequest,
        senderIP: String,
        policy: PrepareUploadPolicy,
        destinationDirectory: URL,
        sessionIdFactory: @Sendable () -> String,
        tokenFactory: @Sendable (String) -> String
    ) throws -> PrepareUploadOutcome {
        guard request.files.isEmpty == false else {
            return .noTransferNeeded
        }
        guard current == nil else {
            return .blocked
        }

        switch policy {
        case .reject:
            current = nil
            return .rejected
        case .messageOnly:
            current = nil
            return .noTransferNeeded
        case .acceptAll, .acceptOnly:
            break
        }

        let acceptedIDs: Set<String>
        switch policy {
        case .acceptAll:
            acceptedIDs = Set(request.files.keys)
        case .acceptOnly(let ids):
            acceptedIDs = ids.intersection(request.files.keys)
        case .reject, .messageOnly:
            acceptedIDs = []
        }

        if acceptedIDs.isEmpty {
            current = nil
            return .noTransferNeeded
        }

        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let sessionId = sessionIdFactory()
        var records: [String: ReceivedFileRecord] = [:]
        var tokens: [String: String] = [:]

        for fileID in acceptedIDs.sorted() {
            guard let file = request.files[fileID] else {
                continue
            }
            let token = tokenFactory(fileID)
            let destinationURL = destinationDirectory.appendingPathComponent("\(sessionId)-\(fileID)-\(file.fileName)")
            records[fileID] = ReceivedFileRecord(file: file, token: token, destinationURL: destinationURL)
            tokens[fileID] = token
        }

        let snapshot = ReceiveSessionSnapshot(
            sessionId: sessionId,
            senderIP: senderIP,
            senderInfo: request.info,
            files: records,
            status: .waiting
        )
        current = snapshot
        return .accepted(PrepareUploadResponse(sessionId: sessionId, files: tokens))
    }

    public func upload(
        sessionId: String?,
        fileId: String?,
        token: String?,
        senderIP: String,
        body: HTTPRequestBody
    ) throws -> UploadFileResult {
        guard let sessionId, let fileId, let token else {
            return .missingParameters
        }
        guard var snapshot = current else {
            return .blocked
        }
        guard snapshot.sessionId == sessionId, snapshot.senderIP == senderIP else {
            return .forbidden
        }
        guard snapshot.status == .waiting || snapshot.status == .transferring else {
            return .blocked
        }
        guard let fileRecord = snapshot.files[fileId], fileRecord.token == token else {
            return .forbidden
        }

        try Self.stage(body: body, to: fileRecord.destinationURL)

        snapshot.status = .transferring
        let allExist = snapshot.files.values.allSatisfy { FileManager.default.fileExists(atPath: $0.destinationURL.path) }
        if allExist {
            snapshot.status = .finished
            lastFinished = snapshot
            current = nil
        } else {
            current = snapshot
        }

        return .success
    }

    public func upload(
        sessionId: String?,
        fileId: String?,
        token: String?,
        senderIP: String,
        body: Data
    ) throws -> UploadFileResult {
        try upload(
            sessionId: sessionId,
            fileId: fileId,
            token: token,
            senderIP: senderIP,
            body: .data(body)
        )
    }

    public func cancel(sessionId: String, senderIP: String) -> Bool {
        guard let snapshot = current else {
            return false
        }
        guard snapshot.sessionId == sessionId, snapshot.senderIP == senderIP else {
            return false
        }
        guard snapshot.status == .waiting || snapshot.status == .transferring else {
            return false
        }
        current = nil
        return true
    }

    public func snapshot() -> ReceiveSessionSnapshot? {
        current ?? lastFinished
    }

    private static func stage(body: HTTPRequestBody, to destinationURL: URL) throws {
        switch body {
        case .data(let data):
            try data.write(to: destinationURL, options: .atomic)
        case .file(let sourceURL, _):
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }
    }
}

public enum SendSessionStatus: String, Codable, Sendable {
    case waiting
    case finished
    case canceled
}

public enum DownloadSource: Equatable, Sendable {
    case data(Data)
    case file(URL, byteCount: Int64)
}

public struct LocalSharedFile: Equatable, Sendable {
    public var file: FileDto
    public var source: DownloadSource

    public init(file: FileDto, source: DownloadSource) {
        self.file = file
        self.source = source
    }

    public func loadData() throws -> Data {
        switch source {
        case .data(let data):
            return data
        case .file(let url, _):
            return try Data(contentsOf: url)
        }
    }

    public var responseBody: HTTPResponseBody {
        switch source {
        case .data(let data):
            return .data(data)
        case .file(let url, let byteCount):
            return .file(url, byteCount: byteCount)
        }
    }
}

public struct SendSessionSnapshot: Equatable, Sendable {
    public var sessionId: String
    public var requesterIP: String
    public var files: [String: LocalSharedFile]
    public var status: SendSessionStatus

    public init(sessionId: String, requesterIP: String, files: [String: LocalSharedFile], status: SendSessionStatus) {
        self.sessionId = sessionId
        self.requesterIP = requesterIP
        self.files = files
        self.status = status
    }
}

public enum PrepareDownloadOutcome: Equatable, Sendable {
    case accepted(PrepareDownloadResponse)
    case rejected
}

public actor SendSession {
    private var sessionsByID: [String: SendSessionSnapshot] = [:]

    public init() {}

    public func prepare(
        requesterIP: String,
        localInfo: InfoResponse,
        files: [String: LocalSharedFile],
        allow: Bool
    ) -> PrepareDownloadOutcome {
        guard allow else {
            return .rejected
        }

        let sessionId = requesterIP
        if let existing = sessionsByID[sessionId], existing.status == .waiting {
            let responseFiles = Dictionary(uniqueKeysWithValues: existing.files.map { ($0.key, $0.value.file) })
            return .accepted(PrepareDownloadResponse(info: localInfo, sessionId: sessionId, files: responseFiles))
        }

        let snapshot = SendSessionSnapshot(
            sessionId: sessionId,
            requesterIP: requesterIP,
            files: files,
            status: .waiting
        )
        sessionsByID[sessionId] = snapshot
        let responseFiles = Dictionary(uniqueKeysWithValues: files.map { ($0.key, $0.value.file) })
        return .accepted(PrepareDownloadResponse(info: localInfo, sessionId: sessionId, files: responseFiles))
    }

    public func download(sessionId: String, fileId: String, requesterIP: String) throws -> LocalSharedFile? {
        guard let snapshot = sessionsByID[sessionId], snapshot.requesterIP == requesterIP, snapshot.status == .waiting else {
            return nil
        }
        guard let sharedFile = snapshot.files[fileId] else {
            return nil
        }

        var finished = snapshot
        finished.status = .finished
        sessionsByID[sessionId] = finished
        return sharedFile
    }

    public func cancel(sessionId: String, requesterIP: String) -> Bool {
        guard let snapshot = sessionsByID[sessionId], snapshot.requesterIP == requesterIP else {
            return false
        }
        guard snapshot.status == .waiting else {
            return false
        }
        sessionsByID.removeValue(forKey: sessionId)
        return true
    }

    public func snapshot(sessionId: String) -> SendSessionSnapshot? {
        sessionsByID[sessionId]
    }
}
