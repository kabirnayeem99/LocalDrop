import Foundation

public enum HTTPResponseWriter {
    private static let reasons: [Int: String] = [
        200: "OK",
        204: "No Content",
        400: "Bad Request",
        401: "Unauthorized",
        403: "Forbidden",
        404: "Not Found",
        409: "Conflict",
        413: "Payload Too Large",
        429: "Too Many Requests",
        500: "Internal Server Error"
    ]

    public static func write(_ response: HTTPResponse) throws -> Data {
        var result = headerData(for: response)
        result.append(try response.body.loadData())
        return result
    }

    public static func headerData(for response: HTTPResponse) -> Data {
        let reason = reasons[response.statusCode, default: "Unknown"]
        var lines = ["HTTP/1.1 \(response.statusCode) \(reason)"]
        var headers = response.headers
        headers["Content-Length"] = "\(response.contentLength)"
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
