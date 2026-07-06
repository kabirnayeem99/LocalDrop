import Foundation
import Testing
@testable import LocalSendKit

struct HTTPTests {
    @Test func requestParserParsesPathHeadersAndBody() throws {
        let raw = Data("POST /api/localsend/v2/upload?sessionId=s&fileId=f&token=t HTTP/1.1\r\nContent-Length: 4\r\nX-Test: true\r\n\r\nbody".utf8)
        let request = try HTTPRequestParser.parse(raw, remoteAddress: "127.0.0.1")
        #expect(request.method == .post)
        #expect(request.path == "/api/localsend/v2/upload")
        #expect(request.query["sessionId"] == "s")
        #expect(request.headers["X-Test"] == "true")
        #expect(String(decoding: try request.body.loadData(), as: UTF8.self) == "body")
    }

    @Test func requestParserRejectsBadContentLength() {
        let raw = Data("POST / HTTP/1.1\r\nContent-Length: nope\r\n\r\n".utf8)
        #expect(throws: HTTPParserError.self) {
            _ = try HTTPRequestParser.parse(raw, remoteAddress: "127.0.0.1")
        }
    }

    @Test func requestParserRejectsOtherMalformedInputs() {
        #expect(throws: HTTPParserError.self) {
            _ = try HTTPRequestParser.parse(Data("bad".utf8), remoteAddress: "127.0.0.1")
        }
        #expect(throws: HTTPParserError.self) {
            _ = try HTTPRequestParser.parse(Data([0xFF, 0xFE, 0xFD, 0x0D, 0x0A, 0x0D, 0x0A]), remoteAddress: "127.0.0.1")
        }
        #expect(throws: HTTPParserError.self) {
            _ = try HTTPRequestParser.parse(Data("\r\n\r\n".utf8), remoteAddress: "127.0.0.1")
        }
        #expect(throws: HTTPParserError.self) {
            _ = try HTTPRequestParser.parse(Data("GET /\r\n\r\n".utf8), remoteAddress: "127.0.0.1")
        }
        #expect(throws: HTTPParserError.self) {
            _ = try HTTPRequestParser.parse(Data("BOGUS / HTTP/1.1\r\n\r\n".utf8), remoteAddress: "127.0.0.1")
        }
        #expect(throws: HTTPParserError.self) {
            _ = try HTTPRequestParser.parse(Data("GET / HTTP/1.1\r\nBroken\r\n\r\n".utf8), remoteAddress: "127.0.0.1")
        }
        #expect(throws: HTTPParserError.self) {
            _ = try HTTPRequestParser.parse(Data("POST / HTTP/1.1\r\nContent-Length: 4\r\n\r\nabc".utf8), remoteAddress: "127.0.0.1")
        }
    }

    @Test func responseWriterIncludesContentLength() {
        let response = HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/plain"], body: Data("ok".utf8))
        let raw = String(decoding: try! HTTPResponseWriter.write(response), as: UTF8.self)
        #expect(raw.contains("HTTP/1.1 200 OK"))
        #expect(raw.contains("Content-Length: 2"))
    }

    @Test func responseWriterHandlesUnknownStatusCodes() {
        let response = HTTPResponse(statusCode: 299, body: Data())
        let raw = String(decoding: try! HTTPResponseWriter.write(response), as: UTF8.self)
        #expect(raw.contains("HTTP/1.1 299 Unknown"))
    }

    @Test func urlBuilderHandlesIPv4AndIPv6() {
        let ipv4 = LocalSendClient.makeURL(
            scheme: .http,
            host: "127.0.0.1",
            port: 8080,
            path: "/path",
            query: [URLQueryItem(name: "a", value: "1")]
        )
        let ipv6 = LocalSendClient.makeURL(
            scheme: .https,
            host: "fe80::1",
            port: 53317,
            path: "/path",
            query: [URLQueryItem(name: "b", value: "2")]
        )

        #expect(ipv4.absoluteString == "http://127.0.0.1:8080/path?a=1")
        #expect(ipv6.absoluteString == "https://[fe80::1]:53317/path?b=2")
    }
}
