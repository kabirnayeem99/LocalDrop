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
        try container.encode(rawValue.lowercased())
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

    /// The protocol document calls this field `sha256`, but the reference Dart `FileDto`
    /// (`common/lib/model/dto/file_dto.dart`) reads and writes the JSON key `hash`. LocalDrop
    /// therefore accepts either key on decode (preferring `hash`) and emits `hash` on encode,
    /// while keeping the Swift property name `sha256` that call sites already use.
    enum CodingKeys: String, CodingKey {
        case id
        case fileName
        case size
        case fileType
        case hash
        case sha256
        case preview
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        size = try container.decode(Int64.self, forKey: .size)
        fileType = try container.decode(String.self, forKey: .fileType)
        sha256 = try container.decodeIfPresent(String.self, forKey: .hash)
            ?? container.decodeIfPresent(String.self, forKey: .sha256)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        metadata = try container.decodeIfPresent(FileMetadata.self, forKey: .metadata)
    }

    /// Whether the reference implementation would classify this file's `fileType` as
    /// `FileType.text`.
    ///
    /// LocalDrop keeps `fileType` as the raw wire string rather than an enum, so this mirrors the
    /// reference decoder in `common/lib/model/dto/file_dto.dart:66-73` exactly, including its
    /// branch on whether the value looks like a MIME type:
    ///
    /// - a value containing `/` goes through `decodeFromMime` (`file_dto.dart:104-117`), which maps
    ///   any `text/…` MIME (e.g. `text/plain`) to `FileType.text`;
    /// - any other value is matched against the bare enum case name, i.e. exactly `text`.
    ///
    /// Comparison is case-insensitive and ignores surrounding whitespace, which is more lenient than
    /// the reference's exact match — deliberately, since misclassifying a text payload as a document
    /// is the unsafe direction (it would let a message be written to disk without a prompt).
    public var isTextPayload: Bool {
        let normalized = fileType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("/") {
            return normalized.hasPrefix("text/")
        }
        return normalized == "text"
    }

    /// Whether this file is a message payload rather than a document: a text file that carries its
    /// content in `preview`.
    ///
    /// The reference derives its `message` from exactly this (`app/lib/model/state/server/
    /// receive_session_state.dart:63-68`) — a text file with no preview *at all* is a plain document
    /// and is still eligible for quick save. Presence is what counts, not content: the reference's
    /// null check treats an empty-string preview as a message, so an empty message prompts rather
    /// than being written silently to disk. Matching that is also the safe direction.
    public var isMessagePayload: Bool {
        guard preview != nil else { return false }
        return isTextPayload
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(size, forKey: .size)
        try container.encode(fileType, forKey: .fileType)
        try container.encodeIfPresent(sha256, forKey: .hash)
        try container.encodeIfPresent(preview, forKey: .preview)
        try container.encodeIfPresent(metadata, forKey: .metadata)
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

    /// The reference `RegisterDto` (`common/lib/model/dto/register_dto.dart:10-17`) makes every
    /// field except `alias` and `fingerprint` optional, and resolves an absent `version` to
    /// `fallbackProtocolVersion` (`register_dto.dart:38`). Encoding stays synthesized, so the
    /// stored properties remain non-optional and no call site changes.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alias = try container.decode(String.self, forKey: .alias)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? LocalSendKit.fallbackProtocolVersion
        deviceModel = try container.decodeIfPresent(String.self, forKey: .deviceModel)
        deviceType = try container.decodeIfPresent(DeviceType.self, forKey: .deviceType)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        protocolType = try container.decodeIfPresent(ProtocolType.self, forKey: .protocolType)
        download = try container.decodeIfPresent(Bool.self, forKey: .download) ?? false
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
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? LocalSendKit.fallbackProtocolVersion
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

    /// `prepare-upload` is the one route whose `info` object is NOT a `RegisterDto`.
    ///
    /// The reference decodes it as `InfoRegisterDto`, which exists solely "to be compatible with
    /// v1" and whose comment reads *"The `fingerprint` does not exist in v1, so it is nullable
    /// here"* (`common/lib/model/dto/info_register_dto.dart`). `toDevice` then resolves it with
    /// `fingerprint ?? ''`.
    ///
    /// This is deliberately NOT gated on the request's API version: the reference uses the lenient
    /// DTO for the v2 route too, so a v1-era sender reaching the v2 path is accepted either way.
    /// `RegisterInfo`'s own decoder — used by `/register`, where the reference's `RegisterDto` does
    /// require a fingerprint — is untouched.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = try container.decode([String: FileDto].self, forKey: .files)
        do {
            info = try container.decode(RegisterInfo.self, forKey: .info)
        } catch {
            info = try container.decode(LenientRegisterInfo.self, forKey: .info).registerInfo
        }
    }
}

/// The `InfoRegisterDto` shape: every field optional, including `fingerprint`. Used only as the
/// fallback decode for `PrepareUploadRequest.info`.
private struct LenientRegisterInfo: Decodable {
    var alias: String
    var version: String?
    var deviceModel: String?
    var deviceType: DeviceType?
    var fingerprint: String?
    var port: Int?
    var protocolType: ProtocolType?
    var download: Bool?

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

    var registerInfo: RegisterInfo {
        RegisterInfo(
            alias: alias,
            version: version ?? LocalSendKit.fallbackProtocolVersion,
            deviceModel: deviceModel,
            deviceType: deviceType,
            // `fingerprint ?? ''`, matching `InfoRegisterDtoExt.toDevice`. An empty fingerprint
            // never matches a favorite, which is the safe direction.
            fingerprint: fingerprint ?? "",
            port: port,
            protocolType: protocolType,
            download: download ?? false
        )
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

    /// The reference `InfoDto` (`common/lib/model/dto/info_dto.dart:9-14`) makes `version`,
    /// `deviceModel`, `deviceType`, `fingerprint` and `download` all optional, resolving them to
    /// `fallbackProtocolVersion`, `nil`, `nil`, `""` and `false` respectively
    /// (`info_dto.dart:36-38`). A legacy peer that omits them used to fail to decode here and be
    /// silently dropped by `LocalSendClient.info()`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alias = try container.decode(String.self, forKey: .alias)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? LocalSendKit.fallbackProtocolVersion
        deviceModel = try container.decodeIfPresent(String.self, forKey: .deviceModel)
        deviceType = try container.decodeIfPresent(DeviceType.self, forKey: .deviceType)
        fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
        download = try container.decodeIfPresent(Bool.self, forKey: .download) ?? false
    }
}
