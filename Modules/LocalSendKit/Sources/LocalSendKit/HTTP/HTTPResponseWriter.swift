import Foundation

public enum HTTPResponseWriter {
    private static let reasons: [Int: String] = [
        200: "OK",
        204: "No Content",
        304: "Not Modified",
        400: "Bad Request",
        401: "Unauthorized",
        403: "Forbidden",
        404: "Not Found",
        409: "Conflict",
        412: "Precondition Failed",
        413: "Payload Too Large",
        429: "Too Many Requests",
        431: "Request Header Fields Too Large",
        500: "Internal Server Error",
        501: "Not Implemented"
    ]

    /// RFC 7230 §3.3.2 forbids `Content-Length` on these. Under persistent connections a strict
    /// client treats one as a framing error — and `noTransferNeeded` returns a 204.
    private static let statusCodesWithoutContentLength: Set<Int> = [204, 304]

    public static func write(_ response: HTTPResponse) throws -> Data {
        var result = headerData(for: response)
        result.append(try response.body.loadData())
        return result
    }

    public static func headerData(for response: HTTPResponse) -> Data {
        let reason = reasons[response.statusCode, default: "Unknown"]
        var lines = ["HTTP/1.1 \(response.statusCode) \(reason)"]
        var headers = response.headers
        if statusCodesWithoutContentLength.contains(response.statusCode) {
            for key in Array(headers.keys) where key.caseInsensitiveCompare("Content-Length") == .orderedSame {
                headers.removeValue(forKey: key)
            }
        } else {
            headers["Content-Length"] = "\(response.contentLength)"
        }
        for key in headers.keys.sorted() {
            if let value = headers[key] {
                lines.append("\(key): \(value)")
            }
        }
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }
}
