import Foundation

public struct HTTPRequestHead: Sendable, Equatable {
    public var method: HTTPMethod
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var headerByteCount: Int
    public var framing: BodyFraming
    /// The raw request-line version token, e.g. `HTTP/1.1`. Needed because HTTP/1.0 defaults to
    /// non-persistent connections unless the client opts in with `Connection: keep-alive`.
    public var httpVersion: String

    public init(
        method: HTTPMethod,
        path: String,
        query: [String: String],
        headers: [String: String],
        headerByteCount: Int,
        framing: BodyFraming,
        httpVersion: String = "HTTP/1.1"
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.headerByteCount = headerByteCount
        self.framing = framing
        self.httpVersion = httpVersion
    }

    public var isHTTP10: Bool {
        httpVersion.caseInsensitiveCompare("HTTP/1.0") == .orderedSame
    }

    /// Lowercased, comma-split `Connection` header tokens.
    public var connectionTokens: Set<String> {
        guard let raw = HTTPRequestParser.headerValue(named: "Connection", in: headers) else {
            return []
        }
        return Set(
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { $0.isEmpty == false }
        )
    }
}

public enum HTTPRequestParser {
    public static let headerTerminator = Data("\r\n\r\n".utf8)

    /// Non-streaming entry point: `data` must contain the complete request. A chunked body is
    /// decoded inline here rather than being rejected, so this stays usable for chunked fixtures;
    /// an unterminated chunked body throws `incompleteBody` like any other short read.
    public static func parse(_ data: Data, remoteAddress: String) throws -> HTTPRequest {
        let head = try parseHead(from: data)
        let rest = Data(data.dropFirst(head.headerByteCount))

        let body: Data
        switch head.framing {
        case .none:
            guard rest.isEmpty else {
                throw HTTPParserError.incompleteBody
            }
            body = Data()
        case .length(let expectedLength):
            guard Int64(rest.count) == expectedLength else {
                throw HTTPParserError.incompleteBody
            }
            body = rest
        case .chunked:
            var decoder = ChunkedBodyDecoder()
            let output = try decoder.decode(rest)
            guard output.isComplete, output.consumedInputOffset == rest.count else {
                throw HTTPParserError.incompleteBody
            }
            body = output.decodedBytes
        }

        return HTTPRequest(
            method: head.method,
            path: head.path,
            query: head.query,
            headers: head.headers,
            body: .data(body),
            remoteAddress: remoteAddress
        )
    }

    public static func parseHead(from data: Data, maximumHeaderBytes: Int = 64 * 1024) throws -> HTTPRequestHead {
        guard data.count <= maximumHeaderBytes || data.range(of: headerTerminator) != nil else {
            throw HTTPParserError.headersTooLarge
        }
        guard let headerRange = data.range(of: headerTerminator) else {
            throw HTTPParserError.invalidRequestLine
        }
        guard headerRange.lowerBound <= maximumHeaderBytes else {
            throw HTTPParserError.headersTooLarge
        }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw HTTPParserError.invalidEncoding
        }

        var lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw HTTPParserError.invalidRequestLine
        }
        lines.removeFirst()

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count == 3 else {
            throw HTTPParserError.invalidRequestLine
        }
        guard let method = HTTPMethod(rawValue: String(requestParts[0])) else {
            throw HTTPParserError.invalidMethod
        }

        let target = String(requestParts[1])
        let components = URLComponents(string: "http://localhost\(target)")
        let path = components?.path ?? target
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        var headers: [String: String] = [:]
        for line in lines where line.isEmpty == false {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else {
                throw HTTPParserError.invalidHeader
            }
            headers[String(pieces[0]).trimmingCharacters(in: .whitespaces)] = String(pieces[1]).trimmingCharacters(in: .whitespaces)
        }

        return HTTPRequestHead(
            method: method,
            path: path,
            query: query,
            headers: headers,
            headerByteCount: data.distance(from: data.startIndex, to: headerRange.upperBound),
            framing: try framing(from: headers),
            httpVersion: String(requestParts[2])
        )
    }

    /// RFC 7230 §3.3.3: when `Transfer-Encoding` is present it takes precedence over
    /// `Content-Length`, and the final coding must be `chunked` for us to be able to find the end
    /// of the message. Anything else (`gzip`, `deflate`, …) is a 501, not a silently empty body.
    public static func framing(from headers: [String: String]) throws -> BodyFraming {
        if let rawTransferEncoding = headerValue(named: "Transfer-Encoding", in: headers) {
            let codings = rawTransferEncoding
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { $0.isEmpty == false }
            guard codings.last == "chunked",
                  codings.dropLast().allSatisfy({ $0 == "identity" }) else {
                throw HTTPParserError.unsupportedTransferEncoding
            }
            return .chunked
        }

        if let rawContentLength = headerValue(named: "Content-Length", in: headers) {
            guard let parsed = Int64(rawContentLength), parsed >= 0 else {
                throw HTTPParserError.invalidContentLength
            }
            return .length(parsed)
        }

        return .none
    }

    public static func headerValue(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
