import Foundation

public enum DeviceType: String, CaseIterable, Sendable, Codable {
    case mobile
    case desktop
    case web
    case headless
    case server

    private static let rawMap: [String: DeviceType] = [
        "MOBILE": .mobile,
        "DESKTOP": .desktop,
        "WEB": .web,
        "HEADLESS": .headless,
        "SERVER": .server
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self).uppercased()
        self = Self.rawMap[rawValue] ?? .desktop
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uppercased())
    }
}

public enum ProtocolType: String, CaseIterable, Sendable, Codable {
    case http
    case https

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self).lowercased()
        self = ProtocolType(rawValue: rawValue) ?? .https
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.lowercased())
    }
}

public struct FileMetadata: Codable, Equatable, Sendable {
    public var modified: String?
    public var accessed: String?

    public init(modified: String? = nil, accessed: String? = nil) {
        self.modified = modified
        self.accessed = accessed
    }
}

public struct FileDto: Codable, Equatable, Sendable {
    public var id: String
    public var fileName: String
    public var size: Int64
    public var fileType: String
    public var sha256: String?
    public var preview: String?
    public var metadata: FileMetadata?

    public init(
        id: String,
        fileName: String,
        size: Int64,
        fileType: String,
        sha256: String? = nil,
        preview: String? = nil,
        metadata: FileMetadata? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.size = size
        self.fileType = fileType
        self.sha256 = sha256
        self.preview = preview
        self.metadata = metadata
    }
}

public struct RegisterInfo: Codable, Equatable, Sendable {
    public var alias: String
    public var version: String
    public var deviceModel: String?
    public var deviceType: DeviceType?
    public var fingerprint: String
    public var port: Int?
    public var protocolType: ProtocolType?
    public var download: Bool

    enum CodingKeys: String, CodingKey {
        case alias
        case version
        case deviceModel
        case deviceType
        case fingerprint
        case port
        case protocolType = "protocol"
        case download
    }

    public init(
        alias: String,
        version: String = LocalSendKit.protocolVersion,
        deviceModel: String? = nil,
        deviceType: DeviceType? = nil,
        fingerprint: String,
        port: Int? = nil,
        protocolType: ProtocolType? = nil,
        download: Bool = false
    ) {
        self.alias = alias
        self.version = version
        self.deviceModel = deviceModel
        self.deviceType = deviceType
        self.fingerprint = fingerprint
        self.port = port
        self.protocolType = protocolType
        self.download = download
    }

    public var asInfoResponse: InfoResponse {
        InfoResponse(
            alias: alias,
            version: version,
            deviceModel: deviceModel,
            deviceType: deviceType,
            fingerprint: fingerprint,
            download: download
        )
    }
}

public struct MulticastMessage: Codable, Equatable, Sendable {
    public var alias: String
    public var version: String
    public var deviceModel: String?
    public var deviceType: DeviceType?
    public var fingerprint: String
    public var port: Int
    public var protocolType: ProtocolType
    public var download: Bool
    public var announce: Bool
    public var announcement: Bool

    enum CodingKeys: String, CodingKey {
        case alias
        case version
        case deviceModel
        case deviceType
        case fingerprint
        case port
        case protocolType = "protocol"
        case download
        case announce
        case announcement
    }

    public init(
        alias: String,
        version: String = LocalSendKit.protocolVersion,
        deviceModel: String? = nil,
        deviceType: DeviceType? = nil,
        fingerprint: String,
        port: Int,
        protocolType: ProtocolType,
        download: Bool = false,
        announce: Bool
    ) {
        self.alias = alias
        self.version = version
        self.deviceModel = deviceModel
        self.deviceType = deviceType
        self.fingerprint = fingerprint
        self.port = port
        self.protocolType = protocolType
        self.download = download
        self.announce = announce
        self.announcement = announce
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alias = try container.decode(String.self, forKey: .alias)
        version = try container.decode(String.self, forKey: .version)
        deviceModel = try container.decodeIfPresent(String.self, forKey: .deviceModel)
        deviceType = try container.decodeIfPresent(DeviceType.self, forKey: .deviceType)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        port = try container.decode(Int.self, forKey: .port)
        protocolType = try container.decode(ProtocolType.self, forKey: .protocolType)
        download = try container.decodeIfPresent(Bool.self, forKey: .download) ?? false
        let announceValue = try container.decodeIfPresent(Bool.self, forKey: .announce) ?? false
        let announcementValue = try container.decodeIfPresent(Bool.self, forKey: .announcement) ?? false
        let combined = announceValue || announcementValue
        announce = combined
        announcement = combined
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(alias, forKey: .alias)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(deviceModel, forKey: .deviceModel)
        try container.encodeIfPresent(deviceType, forKey: .deviceType)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encode(port, forKey: .port)
        try container.encode(protocolType, forKey: .protocolType)
        try container.encode(download, forKey: .download)
        try container.encode(announce, forKey: .announce)
        try container.encode(announce, forKey: .announcement)
    }

    public var registerInfo: RegisterInfo {
        RegisterInfo(
            alias: alias,
            version: version,
            deviceModel: deviceModel,
            deviceType: deviceType,
            fingerprint: fingerprint,
            port: port,
            protocolType: protocolType,
            download: download
        )
    }
}

public struct PrepareUploadRequest: Codable, Equatable, Sendable {
    public var info: RegisterInfo
    public var files: [String: FileDto]

    public init(info: RegisterInfo, files: [String: FileDto]) {
        self.info = info
        self.files = files
    }
}

public struct PrepareUploadResponse: Codable, Equatable, Sendable {
    public var sessionId: String
    public var files: [String: String]

    public init(sessionId: String, files: [String: String]) {
        self.sessionId = sessionId
        self.files = files
    }
}

public struct PrepareDownloadResponse: Codable, Equatable, Sendable {
    public var info: InfoResponse
    public var sessionId: String
    public var files: [String: FileDto]

    public init(info: InfoResponse, sessionId: String, files: [String: FileDto]) {
        self.info = info
        self.sessionId = sessionId
        self.files = files
    }
}

public struct InfoResponse: Codable, Equatable, Sendable {
    public var alias: String
    public var version: String
    public var deviceModel: String?
    public var deviceType: DeviceType?
    public var fingerprint: String
    public var download: Bool

    public init(
        alias: String,
        version: String = LocalSendKit.protocolVersion,
        deviceModel: String? = nil,
        deviceType: DeviceType? = nil,
        fingerprint: String,
        download: Bool = false
    ) {
        self.alias = alias
        self.version = version
        self.deviceModel = deviceModel
        self.deviceType = deviceType
        self.fingerprint = fingerprint
        self.download = download
    }
}
