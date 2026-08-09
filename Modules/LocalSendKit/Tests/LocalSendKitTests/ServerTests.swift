import AppLogging
import Foundation
import Testing
@testable import LocalSendKit

struct ServerTests {
    private func makeServer(
        uploadPolicy: PrepareUploadPolicy = .acceptAll,
        pin: String? = nil,
        sharedFiles: [String: LocalSharedFile] = [:],
        allowDownloads: Bool = true,
        stateObserver: (@Sendable (LocalSendServerStateSnapshot) async -> Void)? = nil,
        logger: AppLogger = .disabled()
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
                storageDirectory: directory,
                stateObserver: stateObserver,
                logger: logger
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
        func request(pin: String?) -> HTTPRequest {
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefix)/prepare-upload",
                query: pin.map { ["pin": $0] } ?? [:],
                headers: ["Content-Length": "\(body.count)"],
                body: body,
                remoteAddress: "10.0.0.1"
            )
        }

        // A PIN-less prepare-upload is "PIN required": unauthorized, but it must never consume an
        // attempt. The reference implementation only counts an actual wrong guess.
        for _ in 0..<5 {
            #expect(try await server.handle(request(pin: nil)).statusCode == 401)
        }
        #expect(try await server.handle(request(pin: "")).statusCode == 401)

        // Only non-empty wrong guesses are counted: 1st and 2nd are 401, the 3rd trips the limit.
        let first = try await server.handle(request(pin: "000000"))
        let second = try await server.handle(request(pin: "000000"))
        let third = try await server.handle(request(pin: "000000"))
        let fourth = try await server.handle(request(pin: "000000"))

        #expect(first.statusCode == 401)
        #expect(second.statusCode == 401)
        #expect(third.statusCode == 429)
        #expect(fourth.statusCode == 429)

        // Once locked out, even the correct PIN stays rate limited — the counter is never reset.
        #expect(try await server.handle(request(pin: "123456")).statusCode == 429)
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
        // An unknown session is the reference's `403 No permission`
        // (`receive_controller.dart:646-653`), not a conflict.
        #expect(wrong.statusCode == 403)
        #expect(try errorMessage(of: wrong) == "No permission")
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
        // No PIN supplied: "PIN required", repeated indefinitely without consuming an attempt.
        let unauthorized = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/prepare-download", remoteAddress: "10.0.0.12")
        )
        let pinless = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/prepare-download", remoteAddress: "10.0.0.12")
        )
        // Wrong non-empty guesses are what count: 401, 401, then 429 on the third.
        let second = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/prepare-download", query: ["pin": "000000"], remoteAddress: "10.0.0.12")
        )
        let secondWrong = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/prepare-download", query: ["pin": "000000"], remoteAddress: "10.0.0.12")
        )
        let third = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/prepare-download", query: ["pin": "000000"], remoteAddress: "10.0.0.12")
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
        #expect(pinless.statusCode == 401)
        #expect(second.statusCode == 401)
        #expect(secondWrong.statusCode == 401)
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

    @Test func structuredServerLogsIncludeRouteAndRequestCorrelation() async throws {
        let sink = RecordingLogSink()
        let logger = AppLogger(
            configuration: AppLoggerConfiguration(minimumLevel: .debug, redactSensitiveValues: true),
            sinks: [sink]
        )
        let server = makeServer(logger: logger)
        let body = try JSONEncoder().encode(sampleUploadRequest())
        let request = HTTPRequest(
            method: .post,
            path: "\(LocalSendKit.apiPrefix)/prepare-upload",
            headers: ["Content-Length": "\(body.count)"],
            body: body,
            remoteAddress: "10.0.0.14",
            requestID: "request-1",
            connectionID: "connection-1"
        )

        let response = try await server.handle(request)
        #expect(response.statusCode == 200)

        try await Task.sleep(for: .milliseconds(50))
        await logger.flush()
        let records = await sink.records()
        let allowed = try #require(records.last(where: { $0.attributes["event.name"] == .string("protocol.prepare_upload.allowed") }))
        #expect(allowed.attributes["request.request_id"] == .string("request-1"))
        #expect(allowed.attributes["request.connection_id"] == .string("connection-1"))
        #expect(allowed.attributes["url.path"] == .string("\(LocalSendKit.apiPrefix)/prepare-upload"))
        #expect(allowed.attributes["http.response.status_code"] == .int(200))
    }

    // MARK: - Self-discovery (412)

    /// `_infoHandler` (`receive_controller.dart:128`) reads the peer fingerprint from the QUERY
    /// STRING and answers `412 Self-discovered` when it is our own.
    @Test func infoWithOwnFingerprintQueryParameterIsSelfDiscovered() async throws {
        let server = makeServer()
        for prefix in [LocalSendKit.apiPrefix, LocalSendKit.apiPrefixV1] {
            let response = try await server.handle(
                HTTPRequest(method: .get, path: "\(prefix)/info", query: ["fingerprint": "ABC"], remoteAddress: "10.0.0.20")
            )
            #expect(response.statusCode == 412, "\(prefix)")
            #expect(try errorMessage(of: response) == "Self-discovered")
        }
    }

    /// Most clients never send the parameter at all, and a foreign fingerprint is a normal peer.
    /// Both must still get the 200 `InfoDto`.
    @Test func infoWithoutOrWithForeignFingerprintStillReturnsInfo() async throws {
        let server = makeServer()
        let absent = try await server.handle(
            HTTPRequest(method: .get, path: "\(LocalSendKit.apiPrefix)/info", remoteAddress: "10.0.0.20")
        )
        let foreign = try await server.handle(
            HTTPRequest(method: .get, path: "\(LocalSendKit.apiPrefix)/info", query: ["fingerprint": "OTHER"], remoteAddress: "10.0.0.20")
        )
        #expect(absent.statusCode == 200)
        #expect(foreign.statusCode == 200)
        #expect(try JSONDecoder().decode(InfoResponse.self, from: absent.body.loadData()).fingerprint == "ABC")
    }

    /// `_registerHandler` (`receive_controller.dart:163`) compares the fingerprint from the decoded
    /// request BODY instead.
    @Test func registerWithOwnFingerprintInBodyIsSelfDiscovered() async throws {
        let server = makeServer()
        let body = try JSONEncoder().encode(
            RegisterInfo(alias: "Me", fingerprint: "ABC", port: 53317, protocolType: .https)
        )
        let response = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/register", headers: ["Content-Length": "\(body.count)"], body: body, remoteAddress: "10.0.0.21")
        )
        #expect(response.statusCode == 412)
        #expect(try errorMessage(of: response) == "Self-discovered")

        // A fingerprint in the query string is NOT what /register looks at.
        let queryOnly = try JSONEncoder().encode(
            RegisterInfo(alias: "Peer", fingerprint: "PEER", port: 53317, protocolType: .https)
        )
        let accepted = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/register", query: ["fingerprint": "ABC"], headers: ["Content-Length": "\(queryOnly.count)"], body: queryOnly, remoteAddress: "10.0.0.21")
        )
        #expect(accepted.statusCode == 200)
    }

    /// A present-but-undecodable `/register` body is a client error. The reference answers
    /// `400 {"message": "Request body malformed"}` (`receive_controller.dart:157-162`); letting the
    /// decode throw would surface as a body-less 500 and disagree with the empty-body guard, which
    /// already returns that exact 400.
    @Test func registerWithMalformedBodyIsBadRequest() async throws {
        let server = makeServer()
        let body = Data("not json at all".utf8)
        let response = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefix)/register",
                headers: ["Content-Length": "\(body.count)"],
                body: body,
                remoteAddress: "10.0.0.23"
            )
        )
        #expect(response.statusCode == 400)
        #expect(try errorMessage(of: response) == "Request body malformed")

        // Well-formed JSON that is not a RegisterInfo takes the same path.
        let wrongShape = Data(#"{"unrelated":true}"#.utf8)
        let wrongShapeResponse = try await server.handle(
            HTTPRequest(
                method: .post,
                path: "\(LocalSendKit.apiPrefix)/register",
                headers: ["Content-Length": "\(wrongShape.count)"],
                body: wrongShape,
                remoteAddress: "10.0.0.23"
            )
        )
        #expect(wrongShapeResponse.statusCode == 400)
        #expect(try errorMessage(of: wrongShapeResponse) == "Request body malformed")

        // The empty-body guard above it agrees.
        let empty = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/register", remoteAddress: "10.0.0.23")
        )
        #expect(empty.statusCode == 400)
        #expect(try errorMessage(of: empty) == "Request body malformed")
    }

    // MARK: - JSON error bodies

    /// Every non-2xx except 204 carries the reference's `{"message": "..."}`; real senders surface
    /// that text to the user.
    @Test func nonSuccessResponsesCarryAJSONMessageBody() async throws {
        let server = makeServer(allowDownloads: false)
        let notFound = try await server.handle(
            HTTPRequest(method: .get, path: "/missing", remoteAddress: "10.0.0.22")
        )
        let rejectedDownload = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/prepare-download", remoteAddress: "10.0.0.22")
        )
        let missingCancel = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/cancel", remoteAddress: "10.0.0.22")
        )

        #expect(notFound.statusCode == 404)
        #expect(try errorMessage(of: notFound) == "Not found")
        #expect(notFound.headers["Content-Type"] == "application/json; charset=utf-8")

        #expect(rejectedDownload.statusCode == 403)
        #expect(try errorMessage(of: rejectedDownload) == "Rejected")
        #expect(rejectedDownload.headers["Content-Type"] == "application/json; charset=utf-8")

        #expect(missingCancel.statusCode == 400)
        #expect(try errorMessage(of: missingCancel) == "Missing session id")

        // RFC 7230: a 204 must stay body-less, so it keeps the empty response.
        let noTransferNeeded = HTTPResponse.empty(statusCode: 204)
        #expect(noTransferNeeded.contentLength == 0)
    }

    /// `HTTPResponseWriter` derives `Content-Length` from the body for every status but 204/304, so
    /// the error helper does not need to set it — but the emitted frame must still be correct.
    @Test func errorResponsesAreFramedWithTheEncodedLength() throws {
        let response = HTTPResponse.error(statusCode: 403, message: "No permission")
        let header = String(decoding: HTTPResponseWriter.headerData(for: response), as: UTF8.self)
        #expect(header.contains("HTTP/1.1 403 Forbidden"))
        #expect(header.contains("Content-Length: \(response.contentLength)"))
        #expect(header.contains("Content-Type: application/json; charset=utf-8"))
    }

    /// 412 is emitted by both self-discovery guards; without a reason-phrase table entry it would
    /// serialize as `HTTP/1.1 412 Unknown`.
    @Test func selfDiscoveryResponseCarriesItsReasonPhrase() throws {
        let response = HTTPResponse.error(statusCode: 412, message: "Self-discovered")
        let header = String(decoding: HTTPResponseWriter.headerData(for: response), as: UTF8.self)
        let statusLine = try #require(header.split(separator: "\r\n", omittingEmptySubsequences: false).first)
        #expect(statusLine == "HTTP/1.1 412 Precondition Failed")
    }

    /// Every status the server can emit needs a reason phrase, not the `Unknown` fallback.
    @Test func everyEmittedStatusCodeHasAReasonPhrase() {
        for statusCode in [200, 204, 400, 401, 403, 404, 409, 412, 429, 500, 501] {
            let header = String(
                decoding: HTTPResponseWriter.headerData(for: .empty(statusCode: statusCode)),
                as: UTF8.self
            )
            #expect(header.contains("HTTP/1.1 \(statusCode) Unknown") == false, "status \(statusCode) has no reason phrase")
        }
    }

    /// Escaping comes from `JSONEncoder`, not string interpolation.
    @Test func errorMessagesAreJSONEscaped() throws {
        let response = HTTPResponse.error(statusCode: 400, message: #"quote " and \ backslash"#)
        #expect(try errorMessage(of: response) == #"quote " and \ backslash"#)
    }

    private func errorMessage(of response: HTTPResponse) throws -> String {
        try JSONDecoder().decode(ErrorResponseBody.self, from: response.body.loadData()).message
    }

    // MARK: - Locally initiated receive cancel (backlog #23)

    /// The receive-side cancel button. Unlike `/cancel` it carries no sender IP to authorize with,
    /// and it must still tear the session down — otherwise the session goes on 409-blocking every
    /// later transfer.
    @Test func localReceiveCancelTearsDownTheSessionAndPublishesIt() async throws {
        let observed = ObservedSnapshots()
        let server = makeServer(stateObserver: { snapshot in await observed.append(snapshot.receiveSession) })
        let body = try JSONEncoder().encode(sampleUploadRequest())
        let prepared = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefix)/prepare-upload", headers: ["Content-Length": "\(body.count)"], body: body, remoteAddress: "10.0.0.7")
        )
        #expect(prepared.statusCode == 200)
        let sessionId = try JSONDecoder().decode(PrepareUploadResponse.self, from: prepared.body.loadData()).sessionId

        #expect(await server.cancelReceiveSession(sessionId: sessionId))
        #expect(await server.receiveSnapshot()?.status == .canceled)
        #expect(await observed.statuses().last == .canceled, "The cancel has to reach observers, or the UI never updates")

        // Idempotent at this layer too: nothing live is left to cancel.
        #expect(await server.cancelReceiveSession(sessionId: sessionId) == false)
        #expect(await server.cancelReceiveSession(sessionId: "never-existed") == false)
    }

    /// The local cancel skips the sender-IP check; the network one must not.
    @Test func localReceiveCancelIgnoresSenderIPWhileTheRouteStillEnforcesIt() async throws {
        let session = ReceiveSession()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let prepared = try await session.prepare(
            request: sampleUploadRequest(),
            senderIP: "10.0.0.7",
            policy: .acceptAll,
            destinationDirectory: directory,
            sessionIdFactory: { "session-local-cancel" },
            tokenFactory: { "token-\($0)" }
        )
        guard case .accepted(let response) = prepared else {
            Issue.record("Expected the sample request to be accepted, got \(prepared)")
            return
        }

        #expect(await session.cancel(sessionId: response.sessionId, senderIP: "10.0.0.99") == false)
        #expect(await session.cancelLocally(sessionId: "some-other-session") == false)
        #expect(await session.cancelLocally(sessionId: response.sessionId))
        #expect(await session.snapshot()?.status == .canceled)
    }

    private actor ObservedSnapshots {
        private var snapshots: [ReceiveSessionSnapshot?] = []

        func append(_ snapshot: ReceiveSessionSnapshot?) {
            snapshots.append(snapshot)
        }

        func statuses() -> [ReceiveSessionStatus?] {
            snapshots.map(\.?.status)
        }
    }
}
