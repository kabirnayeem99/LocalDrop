import Foundation

public enum LocalSendRuntimeError: Error, Equatable {
    case listenerStartFailed
    case multicastJoinFailed
    case tlsIdentityUnavailable
    case connectionReadFailed
    case connectionWriteFailed
    case bodyTooLarge
    case requestTimeout
}

public struct LocalSendRuntimeLimits: Sendable, Equatable {
    public var maximumHeaderBytes: Int
    public var maximumJSONBodyBytes: Int
    public var requestTimeout: Duration

    public init(
        maximumHeaderBytes: Int = 64 * 1024,
        maximumJSONBodyBytes: Int = 1 * 1024 * 1024,
        requestTimeout: Duration = .seconds(30)
    ) {
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumJSONBodyBytes = maximumJSONBodyBytes
        self.requestTimeout = requestTimeout
    }
}

public struct LocalSendServerRuntimeBoundEndpoint: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var protocolType: ProtocolType

    public init(host: String, port: Int, protocolType: ProtocolType) {
        self.host = host
        self.port = port
        self.protocolType = protocolType
    }
}
