import Foundation

public struct HTTPRequestHead: Sendable, Equatable {
    public var method: HTTPMethod
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var headerByteCount: Int
    public var contentLength: Int64

    public init(
        method: HTTPMethod,
        path: String,
        query: [String: String],
        headers: [String: String],
        headerByteCount: Int,
        contentLength: Int64
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.headerByteCount = headerByteCount
        self.contentLength = contentLength
    }
}

public enum HTTPRequestParser {
    public static let headerTerminator = Data("\r\n\r\n".utf8)

    public static func parse(_ data: Data, remoteAddress: String) throws -> HTTPRequest {
        let head = try parseHead(from: data)
        let bodyStart = head.headerByteCount
        let expectedLength = Int(head.contentLength)
        let availableLength = data.count - bodyStart
        guard availableLength == expectedLength else {
            throw HTTPParserError.incompleteBody
        }

        return HTTPRequest(
            method: head.method,
            path: head.path,
            query: head.query,
            headers: head.headers,
            body: .data(Data(data[bodyStart..<data.endIndex])),
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

        let contentLength: Int64
        if let rawContentLength = headerValue(named: "Content-Length", in: headers) {
            guard let parsed = Int64(rawContentLength), parsed >= 0 else {
                throw HTTPParserError.invalidContentLength
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }

        return HTTPRequestHead(
            method: method,
            path: path,
            query: query,
            headers: headers,
            headerByteCount: headerRange.upperBound,
            contentLength: contentLength
        )
    }

    public static func headerValue(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
