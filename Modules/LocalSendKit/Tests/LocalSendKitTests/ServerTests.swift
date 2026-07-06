import Foundation
import Testing
@testable import LocalSendKit

struct ServerTests {
    private func makeServer(
        uploadPolicy: PrepareUploadPolicy = .acceptAll,
        pin: String? = nil,
        sharedFiles: [String: LocalSharedFile] = [:],
        allowDownloads: Bool = true
    ) -> LocalSendServer {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        return LocalSendServer(
            configuration: LocalSendServerConfiguration(
                registerInfo: RegisterInfo(
                    alias: "Receiver",
                    deviceModel: "Mac",
                    deviceType: .desktop,
                    fingerprint: "ABC",
                    port: 53317,
                    protocolType: .https,
                    download: true
                ),
                pin: pin,
                uploadPolicy: uploadPolicy,
                sharedFiles: sharedFiles,
                allowDownloads: allowDownloads,
                storageDirectory: directory
            )
        )
    }

    private func sampleUploadRequest() -> PrepareUploadRequest {
        PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", fingerprint: "SENDER", port: 53317, protocolType: .https),
            files: [
                "file-1": FileDto(id: "file-1", fileName: "a.txt", size: 3, fileType: "text/plain")
            ]
        )
    }

    @Test func prepareUploadRejectsMalformedJSON() async throws {
        let server = makeServer()
        let response = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefix)/prepare-upload",
                headers: ["Content-Length": "1"],
                body: Data("{".utf8),
                remoteAddress: "10.0.0.1"
            )
        )
        #expect(response.statusCode == 400)
    }

    @Test func pinTrackerBoundaryMatchesPlan() async throws {
        let server = makeServer(pin: "123456")
        let body = try JSONEncoder().encode(sampleUploadRequest())
        let request = HTTPRequest(
            method: .post,
            path: "\(LocalSendKit.apiPrefix)/prepare-upload",
            headers: ["Content-Length": "\(body.count)"],
            body: body,
            remoteAddress: "10.0.0.1"
        )

        let first = try await server.handle(request)
        let second = try await server.handle(request)
        let third = try await server.handle(request)
        let fourth = try await server.handle(request)

        #expect(first.statusCode == 401)
        #expect(second.statusCode == 401)
        #expect(third.statusCode == 429)
        #expect(fourth.statusCode == 429)
    }

    @Test func prepareUploadRejectsEmptyFilesAndBlockedRejectedMessageOnly() async throws {
        let emptyServer = makeServer()
        let emptyBody = try JSONEncoder().encode(PrepareUploadRequest(info: RegisterInfo(alias: "Sender", fingerprint: "S", port: 1, protocolType: .https), files: [:]))
        let emptyResponse = try await emptyServer.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/prepare-upload", headers: ["Content-Length": "\(emptyBody.count)"], body: emptyBody, remoteAddress: "10.0.0.2")
        )
        #expect(emptyResponse.statusCode == 400)

        let blockedServer = makeServer()
        let body = try JSONEncoder().encode(sampleUploadRequest())
        let first = try await blockedServer.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/prepare-upload", headers: ["Content-Length": "\(body.count)"], body: body, remoteAddress: "10.0.0.3")
        )
        let second = try await blockedServer.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/prepare-upload", headers: ["Content-Length": "\(body.count)"], body: body, remoteAddress: "10.0.0.4")
        )
        #expect(first.statusCode == 200)
        #expect(second.statusCode == 409)

        let rejectedServer = makeServer(uploadPolicy: .reject)
        let rejected = try await rejectedServer.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/prepare-upload", headers: ["Content-Length": "\(body.count)"], body: body, remoteAddress: "10.0.0.5")
        )
        #expect(rejected.statusCode == 403)

        let messageOnlyServer = makeServer(uploadPolicy: .messageOnly)
        let noTransfer = try await messageOnlyServer.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/prepare-upload", headers: ["Content-Length": "\(body.count)"], body: body, remoteAddress: "10.0.0.6")
        )
        #expect(noTransfer.statusCode == 204)
    }

    @Test func uploadMismatchMatrixReturnsExpectedStatuses() async throws {
        let server = makeServer()
        let client = LocalSendClient(transport: InProcessTransport(handler: { request in try await server.handle(request) }))
        let peer = RemotePeer(host: "10.0.0.7", port: 53317, protocolType: .https)
        let response = try #require(await client.prepareUpload(sampleUploadRequest(), to: peer))

        await #expect(throws: LocalSendClientError.self) {
            try await client.upload(Data("a".utf8), sessionId: response.sessionId, fileId: "wrong", token: "bad", to: peer)
        }

        let wrongIPResponse = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefix)/upload",
                query: ["sessionId": response.sessionId, "fileId": "file-1", "token": response.files["file-1"]!],
                body: Data("abc".utf8),
                remoteAddress: "10.0.0.99"
            )
        )
        #expect(wrongIPResponse.statusCode == 403)

        let missingParameters = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/upload", body: Data(), remoteAddress: "10.0.0.7")
        )
        #expect(missingParameters.statusCode == 400)
    }

    @Test func cancelHandlesReceiveAndSendSessions() async throws {
        let shared = LocalSharedFile(
            file: FileDto(id: "download-1", fileName: "b.txt", size: 3, fileType: "text/plain"),
            source: .data(Data("hey".utf8))
        )
        let receiveServer = makeServer()
        let body = try JSONEncoder().encode(sampleUploadRequest())
        let prepared = try await receiveServer.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/prepare-upload", headers: ["Content-Length": "\(body.count)"], body: body, remoteAddress: "10.0.0.8")
        )
        let uploadResponse = try JSONDecoder().decode(PrepareUploadResponse.self, from: prepared.body.loadData())
        let canceledReceive = try await receiveServer.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/cancel", query: ["sessionId": uploadResponse.sessionId], remoteAddress: "10.0.0.8")
        )
        #expect(canceledReceive.statusCode == 200)

        let sendServer = makeServer(sharedFiles: ["download-1": shared])
        _ = try await sendServer.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/prepare-download", remoteAddress: "10.0.0.9")
        )
        let canceledSend = try await sendServer.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/cancel", query: ["sessionId": "10.0.0.9"], remoteAddress: "10.0.0.9")
        )
        #expect(canceledSend.statusCode == 200)

        let wrong = try await sendServer.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/cancel", query: ["sessionId": "missing"], remoteAddress: "10.0.0.10")
        )
        #expect(wrong.statusCode == 409)
    }

    @Test func registerInfo404AndDownloadFailuresAreHandled() async throws {
        let server = makeServer(allowDownloads: false)
        let registerBody = try JSONEncoder().encode(RegisterInfo(alias: "Peer", fingerprint: "PEER", port: 53317, protocolType: .https))

        let register = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/register", headers: ["Content-Length": "\(registerBody.count)"], body: registerBody, remoteAddress: "10.0.0.11")
        )
        let info = try await server.handle(
            HTTPRequest(method: .get, path: "\(LocalSendKit.apiPrefix)/info", remoteAddress: "10.0.0.11")
        )
        let notFound = try await server.handle(
            HTTPRequest(method: .get, path: "/missing", remoteAddress: "10.0.0.11")
        )
        let missingCancel = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/cancel", remoteAddress: "10.0.0.11")
        )
        let rejectedDownload = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/prepare-download", remoteAddress: "10.0.0.11")
        )
        let missingRegisterBody = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/register", remoteAddress: "10.0.0.11")
        )
        let badDownload = try await server.handle(
            HTTPRequest(method: .get, path: "\(LocalSendKit.apiPrefix)/download", query: ["sessionId": "missing", "fileId": "missing"], remoteAddress: "10.0.0.11")
        )

        #expect(register.statusCode == 200)
        #expect(info.statusCode == 200)
        #expect(notFound.statusCode == 404)
        #expect(missingCancel.statusCode == 400)
        #expect(rejectedDownload.statusCode == 403)
        #expect(missingRegisterBody.statusCode == 400)
        #expect(badDownload.statusCode == 403)
    }

    @Test func prepareDownloadPinBranchesAndUploadBlockedBranch() async throws {
        let shared = LocalSharedFile(
            file: FileDto(id: "download-1", fileName: "b.txt", size: 3, fileType: "text/plain"),
            source: .data(Data("hey".utf8))
        )
        let server = makeServer(pin: "999999", sharedFiles: ["download-1": shared])
        let unauthorized = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/prepare-download", remoteAddress: "10.0.0.12")
        )
        let second = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/prepare-download", remoteAddress: "10.0.0.12")
        )
        let third = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/prepare-download", remoteAddress: "10.0.0.12")
        )
        let blockedUpload = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefix)/upload",
                query: ["sessionId": "missing", "fileId": "missing", "token": "missing"],
                body: Data("x".utf8),
                remoteAddress: "10.0.0.12"
            )
        )

        #expect(unauthorized.statusCode == 401)
        #expect(second.statusCode == 401)
        #expect(third.statusCode == 429)
        #expect(blockedUpload.statusCode == 409)
        #expect(await server.sendSnapshot(sessionId: "10.0.0.12") == nil)
    }

    @Test func prepareUploadEmptyBodyReturnsBadRequest() async throws {
        let server = makeServer()
        let response = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/prepare-upload", remoteAddress: "10.0.0.13")
        )
        #expect(response.statusCode == 400)
    }
}
