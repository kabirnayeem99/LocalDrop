import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
}

public enum HTTPRequestBody: Sendable, Equatable {
    case data(Data)
    case file(URL, byteCount: Int64)

    public var byteCount: Int64 {
        switch self {
        case .data(let data):
            return Int64(data.count)
        case .file(_, let byteCount):
            return byteCount
        }
    }

    public var isEmpty: Bool {
        byteCount == 0
    }

    public func loadData() throws -> Data {
        switch self {
        case .data(let data):
            return data
        case .file(let url, _):
            return try Data(contentsOf: url)
        }
    }

    public var inlineData: Data? {
        if case .data(let data) = self {
            return data
        }
        return nil
    }
}

public enum HTTPResponseBody: Sendable, Equatable {
    case data(Data)
    case file(URL, byteCount: Int64)

    public var byteCount: Int64 {
        switch self {
        case .data(let data):
            return Int64(data.count)
        case .file(_, let byteCount):
            return byteCount
        }
    }

    public func loadData() throws -> Data {
        switch self {
        case .data(let data):
            return data
        case .file(let url, _):
            return try Data(contentsOf: url)
        }
    }

    public var inlineData: Data? {
        if case .data(let data) = self {
            return data
        }
        return nil
    }
}

public struct HTTPRequest: Sendable, Equatable {
    public var method: HTTPMethod
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: HTTPRequestBody
    public var remoteAddress: String
    public var requestID: String?
    public var connectionID: String?

    public init(
        method: HTTPMethod,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: HTTPRequestBody = .data(Data()),
        remoteAddress: String,
        requestID: String? = nil,
        connectionID: String? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.remoteAddress = remoteAddress
        self.requestID = requestID
        self.connectionID = connectionID
    }

    public init(
        method: HTTPMethod,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data,
        remoteAddress: String,
        requestID: String? = nil,
        connectionID: String? = nil
    ) {
        self.init(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: .data(body),
            remoteAddress: remoteAddress,
            requestID: requestID,
            connectionID: connectionID
        )
    }

    public var contentLength: Int64 {
        body.byteCount
    }

    public var wantsKeepAlive: Bool {
        headers.first { $0.key.caseInsensitiveCompare("Connection") == .orderedSame }?.value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "keep-alive"
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: HTTPResponseBody

    public init(statusCode: Int, headers: [String: String] = [:], body: HTTPResponseBody = .data(Data())) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.init(statusCode: statusCode, headers: headers, body: .data(body))
    }

    public static func empty(statusCode: Int) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, body: .data(Data()))
    }

    public var contentLength: Int64 {
        body.byteCount
    }
}

public enum HTTPParserError: Error, Equatable {
    case invalidRequestLine
    case invalidMethod
    case invalidHeader
    case invalidContentLength
    case incompleteBody
    case invalidEncoding
    case headersTooLarge
    case bodyTooLarge
}
