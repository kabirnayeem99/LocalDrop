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
}

/// The reference always answers a non-2xx with `{"message": "..."}` (`respondJson(code, message:)`
/// in the Dart server, `core/src/http/server/error.rs`), and real LocalSend senders surface that
/// text to the user. Modelled as a `Codable` DTO so `JSONEncoder` handles escaping.
public struct ErrorResponseBody: Codable, Sendable, Equatable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

/// The one encoder every server-emitted JSON body goes through, so the wire format is configured
/// in a single place: `.sortedKeys` for byte-stable output, no `.prettyPrinted` (the reference
/// emits compact JSON).
enum ServerJSONEncoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// `Content-Type` for every JSON response. The reference's `respondJson` sets Dart's
    /// `ContentType.json`, which serializes as `application/json; charset=utf-8`
    /// (`app/lib/util/simple_server.dart:95-99`).
    static let contentType = "application/json; charset=utf-8"
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

    /// A non-2xx response carrying the reference's `{"message": "..."}` body.
    ///
    /// Non-throwing on purpose so error call sites stay a single expression: an encoding failure
    /// (impossible for a one-`String` DTO) degrades to a body-less response with the same status
    /// rather than turning a deliberate 4xx into a thrown 500.
    ///
    /// `Content-Length` is not set here — `HTTPResponseWriter.headerData(for:)` derives it from
    /// `body.byteCount` for every status except 204/304, the same way the 200 JSON path relies on.
    public static func error(statusCode: Int, message: String) -> HTTPResponse {
        let body = (try? ServerJSONEncoding.encoder.encode(ErrorResponseBody(message: message))) ?? Data()
        return HTTPResponse(
            statusCode: statusCode,
            headers: body.isEmpty ? [:] : ["Content-Type": ServerJSONEncoding.contentType],
            body: .data(body)
        )
    }

    public var contentLength: Int64 {
        body.byteCount
    }
}

/// How the request body is delimited on the wire. Modelled explicitly rather than as an
/// `Int64?` so that "no body" and "length unknown until the terminating chunk" are distinct
/// states the connection loop is forced to handle — an optional length collapses them and
/// silently produces a zero-byte body for every chunked upload.
public enum BodyFraming: Sendable, Equatable {
    /// No body: neither `Transfer-Encoding` nor `Content-Length` present.
    case none
    /// `Content-Length: n`.
    case length(Int64)
    /// `Transfer-Encoding` whose final coding is `chunked`. Per RFC 7230 §3.3.3 this wins over
    /// any `Content-Length` also present.
    case chunked
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
    /// A `Transfer-Encoding` we cannot decode (e.g. `gzip`). Maps to 501, never a 0-byte 200.
    case unsupportedTransferEncoding
}
