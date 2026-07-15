import Foundation
import Testing
@testable import LocalSendKit

struct ClientAndSessionCoverageTests {
    actor StubTransport: LocalSendTransport {
        var requests: [HTTPRequest] = []

        func send(
            _ request: HTTPRequest,
            to peer: RemotePeer,
            progress: (@Sendable (FileTransferProgress) -> Void)?
        ) async throws -> HTTPResponse {
            requests.append(request)
            switch request.path {
            case "\(LocalSendKit.apiPrefix)/register":
                let body = try JSONEncoder().encode(RegisterInfo(alias: "Receiver", fingerprint: "R", port: 53317, protocolType: .https))
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
            case "\(LocalSendKit.apiPrefix)/info":
                let body = try JSONEncoder().encode(InfoResponse(alias: "Receiver", fingerprint: "R", download: true))
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
            case "\(LocalSendKit.apiPrefix)/prepare-upload":
                if request.query["pin"] == "empty" {
                    return .empty(statusCode: 204)
                }
                let body = try JSONEncoder().encode(PrepareUploadResponse(sessionId: "session", files: ["f1": "token"]))
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
            case "\(LocalSendKit.apiPrefix)/cancel":
                return .empty(statusCode: 200)
            case "\(LocalSendKit.apiPrefix)/prepare-download":
                let body = try JSONEncoder().encode(
                    PrepareDownloadResponse(
                        info: InfoResponse(alias: "Receiver", fingerprint: "R", download: true),
                        sessionId: request.query["sessionId"] ?? "session",
                        files: ["d1": FileDto(id: "d1", fileName: "d.txt", size: 1, fileType: "text/plain")]
                    )
                )
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
            case "\(LocalSendKit.apiPrefix)/download":
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/plain"], body: Data("x".utf8))
            default:
                return .empty(statusCode: 500)
            }
        }

        func recordedRequests() -> [HTTPRequest] {
            requests
        }
    }

    @Test func clientCoversRemainingEndpointHelpers() async throws {
        let transport = StubTransport()
        let client = LocalSendClient(transport: transport)
        let peer = RemotePeer(host: "host", port: 53317, protocolType: .https)
        let uploadRequest = PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", fingerprint: "S", port: 53317, protocolType: .https),
            files: ["f1": FileDto(id: "f1", fileName: "x.txt", size: 1, fileType: "text/plain")]
        )

        let register = try await client.register(with: uploadRequest.info, to: peer)
        let info = try await client.info(from: peer)
        let noTransfer = try await client.prepareUpload(uploadRequest, to: peer, pin: "empty")
        let transfer = try await client.prepareUpload(uploadRequest, to: peer, pin: "123")
        try await client.cancel(sessionId: "session", to: peer)
        let download = try await client.prepareDownload(from: peer, pin: "123", sessionId: "resume")
        let file = try await client.download(fileId: "d1", sessionId: "resume", from: peer)

        #expect(register.alias == "Receiver")
        #expect(info.download)
        #expect(noTransfer == nil)
        #expect(transfer?.sessionId == "session")
        #expect(download.sessionId == "resume")
        #expect(String(decoding: file.data, as: UTF8.self) == "x")

        let requests = await transport.recordedRequests()
        #expect(requests.contains { $0.path == "\(LocalSendKit.apiPrefix)/cancel" })
        #expect(requests.contains { $0.query["pin"] == "123" && $0.path == "\(LocalSendKit.apiPrefix)/prepare-download" })
    }

    @Test func receiveAndSendSessionsCoverEdgeBranches() async throws {
        let receive = ReceiveSession()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let request = PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", fingerprint: "S", port: 1, protocolType: .https),
            files: [
                "keep": FileDto(id: "keep", fileName: "keep.txt", size: 1, fileType: "text/plain"),
                "drop": FileDto(id: "drop", fileName: "drop.txt", size: 1, fileType: "text/plain")
            ]
        )

        #expect(try await receive.prepare(request: PrepareUploadRequest(info: request.info, files: [:]), senderIP: "1.1.1.1", policy: .acceptAll, destinationDirectory: directory, sessionIdFactory: { "s0" }, tokenFactory: { _ in "t0" }) == .noTransferNeeded)
        #expect(try await receive.prepare(request: request, senderIP: "1.1.1.1", policy: .acceptOnly(["missing"]), destinationDirectory: directory, sessionIdFactory: { "s1" }, tokenFactory: { _ in "t1" }) == .noTransferNeeded)

        let accepted = try await receive.prepare(request: request, senderIP: "1.1.1.1", policy: .acceptOnly(["keep"]), destinationDirectory: directory, sessionIdFactory: { "s2" }, tokenFactory: { _ in "t2" })
        let response = try #require({
            if case .accepted(let value) = accepted { return value }
            return nil
        }())

        #expect(try await receive.upload(sessionId: "missing", fileId: "keep", token: "t2", senderIP: "1.1.1.1", body: Data()) == .forbidden)
        #expect(await receive.cancel(sessionId: response.sessionId, senderIP: "wrong") == false)
        #expect(try await receive.upload(sessionId: response.sessionId, fileId: "keep", token: "t2", senderIP: "1.1.1.1", body: Data("1".utf8)) == .success)
        #expect(try await receive.upload(sessionId: response.sessionId, fileId: "keep", token: "t2", senderIP: "1.1.1.1", body: Data("1".utf8)) == .blocked)

        let fileURL = directory.appendingPathComponent("download.txt")
        try Data("body".utf8).write(to: fileURL)
        let shared = LocalSharedFile(
            file: FileDto(id: "d1", fileName: "download.txt", size: 4, fileType: "text/plain"),
            source: .file(fileURL, byteCount: 4)
        )
        #expect(try shared.loadData() == Data("body".utf8))

        let send = SendSession()
        let info = InfoResponse(alias: "Receiver", fingerprint: "R", download: true)
        #expect(await send.prepare(requesterIP: "2.2.2.2", localInfo: info, files: ["d1": shared], allow: false) == .rejected)
        _ = await send.prepare(requesterIP: "2.2.2.2", localInfo: info, files: ["d1": shared], allow: true)
        _ = await send.prepare(requesterIP: "2.2.2.2", localInfo: info, files: ["d1": shared], allow: true)
        #expect(try await send.download(sessionId: "missing", fileId: "d1", requesterIP: "2.2.2.2") == nil)
        #expect(try await send.download(sessionId: "2.2.2.2", fileId: "missing", requesterIP: "2.2.2.2") == nil)
        _ = try await send.download(sessionId: "2.2.2.2", fileId: "d1", requesterIP: "2.2.2.2")
        #expect(await send.cancel(sessionId: "2.2.2.2", requesterIP: "2.2.2.2") == false)
        #expect(await send.snapshot(sessionId: "2.2.2.2")?.status == .finished)
    }

    @Test func receiveSessionTracksAggregateByteProgressAcrossFiles() async throws {
        let session = ReceiveSession()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let request = PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", fingerprint: "S", port: 1, protocolType: .https),
            files: [
                "f1": FileDto(id: "f1", fileName: "a.bin", size: 100, fileType: "application/octet-stream"),
                "f2": FileDto(id: "f2", fileName: "b.bin", size: 300, fileType: "application/octet-stream")
            ]
        )

        let accepted = try await session.prepare(
            request: request,
            senderIP: "1.1.1.1",
            policy: .acceptAll,
            destinationDirectory: directory,
            sessionIdFactory: { "progress-session" },
            tokenFactory: { "token-\($0)" }
        )
        let response = try #require({
            if case .accepted(let value) = accepted { return value }
            return nil
        }())

        #expect(await session.beginUpload(sessionId: response.sessionId, fileId: "f1", token: response.files["f1"], senderIP: "1.1.1.1"))
        #expect(await session.updateUploadProgress(sessionId: response.sessionId, fileId: "f1", senderIP: "1.1.1.1", bytesReceived: 40))
        let firstSnapshot = try #require(await session.snapshot())
        #expect(firstSnapshot.status == .transferring)
        #expect(firstSnapshot.totalBytes == 400)
        #expect(firstSnapshot.bytesReceived == 40)
        #expect(firstSnapshot.currentFileID == "f1")
        #expect(firstSnapshot.currentFileBytesReceived == 40)

        #expect(try await session.upload(sessionId: response.sessionId, fileId: "f1", token: response.files["f1"], senderIP: "1.1.1.1", body: Data(repeating: 0x1, count: 100)) == .success)
        #expect(await session.beginUpload(sessionId: response.sessionId, fileId: "f2", token: response.files["f2"], senderIP: "1.1.1.1"))
        #expect(await session.updateUploadProgress(sessionId: response.sessionId, fileId: "f2", senderIP: "1.1.1.1", bytesReceived: 120))
        let secondSnapshot = try #require(await session.snapshot())
        #expect(secondSnapshot.bytesReceived == 220)
        #expect(secondSnapshot.currentFileID == "f2")
        #expect(secondSnapshot.currentFileBytesReceived == 120)
        #expect(secondSnapshot.currentFileTotalBytes == 300)
    }
}
