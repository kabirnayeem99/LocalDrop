import Foundation
import Testing
@testable import LocalSendKit

struct IntegrationTests {
    private func makePeer() -> RemotePeer {
        RemotePeer(host: "127.0.0.1", port: 53317, protocolType: .https)
    }

    private func makeServer(sharedFiles: [String: LocalSharedFile] = [:], pin: String? = nil) -> LocalSendServer {
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
                uploadPolicy: .acceptAll,
                sharedFiles: sharedFiles,
                allowDownloads: true,
                storageDirectory: directory
            )
        )
    }

    private func makeIdentity() throws -> LocalIdentity {
        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        let authority = CertificateAuthority(store: FileCertificateStore(identityURL: storeURL))
        return try authority.loadOrCreateIdentity()
    }

    @Test func fullUploadHandshakeWritesBytesAndFinishes() async throws {
        let server = makeServer()
        let client = LocalSendClient(transport: InProcessTransport(handler: { request in try await server.handle(request) }))
        let request = PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", fingerprint: "SENDER", port: 53317, protocolType: .https),
            files: ["f1": FileDto(id: "f1", fileName: "hello.txt", size: 5, fileType: "text/plain")]
        )

        let response = try #require(await client.prepareUpload(request, to: makePeer()))
        try await client.upload(Data("hello".utf8), sessionId: response.sessionId, fileId: "f1", token: response.files["f1"]!, to: makePeer())

        let snapshot = try #require(await server.receiveSnapshot())
        let data = try Data(contentsOf: snapshot.files["f1"]!.destinationURL)
        #expect(String(decoding: data, as: UTF8.self) == "hello")
        #expect(snapshot.status == .finished)
    }

    @Test func pinProtectedTransferFailsThenSucceeds() async throws {
        let server = makeServer(pin: "123456")
        let client = LocalSendClient(transport: InProcessTransport(handler: { request in try await server.handle(request) }))
        let request = PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", fingerprint: "SENDER", port: 53317, protocolType: .https),
            files: ["f1": FileDto(id: "f1", fileName: "hello.txt", size: 5, fileType: "text/plain")]
        )

        await #expect(throws: LocalSendClientError.self) {
            _ = try await client.prepareUpload(request, to: makePeer(), pin: "111111")
        }

        let response = try #require(await client.prepareUpload(request, to: makePeer(), pin: "123456"))
        #expect(response.files.keys.contains("f1"))
    }

    @Test func reverseTransferReturnsDispositionAndContentLength() async throws {
        let sharedFile = LocalSharedFile(
            file: FileDto(id: "d1", fileName: "download.txt", size: 4, fileType: "text/plain"),
            source: .data(Data("test".utf8))
        )
        let server = makeServer(sharedFiles: ["d1": sharedFile])
        let client = LocalSendClient(transport: InProcessTransport(handler: { request in try await server.handle(request) }))

        let prepared = try await client.prepareDownload(from: makePeer())
        let file = try await client.download(fileId: "d1", sessionId: prepared.sessionId, from: makePeer())

        #expect(String(decoding: file.data, as: UTF8.self) == "test")
        #expect(file.headers["Content-Disposition"] == #"attachment; filename="download.txt""#)
        #expect(file.headers["Content-Length"] == "4")
    }

    @Test func concurrentMultiFileUploadCompletes() async throws {
        let server = makeServer()
        let client = LocalSendClient(transport: InProcessTransport(handler: { request in try await server.handle(request) }))
        let request = PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", fingerprint: "SENDER", port: 53317, protocolType: .https),
            files: [
                "f1": FileDto(id: "f1", fileName: "1.txt", size: 1, fileType: "text/plain"),
                "f2": FileDto(id: "f2", fileName: "2.txt", size: 1, fileType: "text/plain")
            ]
        )

        let response = try #require(await client.prepareUpload(request, to: makePeer()))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for fileId in ["f1", "f2"] {
                group.addTask {
                    try await client.upload(
                        Data(fileId.utf8),
                        sessionId: response.sessionId,
                        fileId: fileId,
                        token: response.files[fileId]!,
                        to: self.makePeer()
                    )
                }
            }
            try await group.waitForAll()
        }

        let snapshot = try #require(await server.receiveSnapshot())
        #expect(snapshot.status == .finished)
    }

    @Test func realTLSRuntimeServesInfoOverLoopback() async throws {
        let identity = try makeIdentity()
        let server = LocalSendServer(
            configuration: LocalSendServerConfiguration(
                registerInfo: RegisterInfo(
                    alias: "Receiver",
                    deviceModel: "Mac",
                    deviceType: .desktop,
                    fingerprint: identity.fingerprint,
                    port: nil,
                    protocolType: .https,
                    download: true
                ),
                storageDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            )
        )
        let runtime = LocalSendServerRuntime(
            server: server,
            tlsConfiguration: LocalSendTLSConfiguration(identity: identity),
            port: 0,
            temporaryDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        )
        try await runtime.start()
        let endpoint = try await runtime.waitUntilReady()
        defer { Task { await runtime.stop() } }

        let client = LocalSendClient(
            peer: RemotePeer(host: endpoint.host, port: endpoint.port, protocolType: endpoint.protocolType),
            expectedFingerprint: identity.fingerprint
        )
        let info = try await client.info()
        #expect(info.alias == "Receiver")
        #expect(info.fingerprint == identity.fingerprint)
    }

    @Test func realTLSRuntimeRejectsFingerprintMismatch() async throws {
        let identity = try makeIdentity()
        let server = LocalSendServer(
            configuration: LocalSendServerConfiguration(
                registerInfo: RegisterInfo(alias: "Receiver", fingerprint: identity.fingerprint, port: nil, protocolType: .https),
                storageDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            )
        )
        let runtime = LocalSendServerRuntime(
            server: server,
            tlsConfiguration: LocalSendTLSConfiguration(identity: identity),
            port: 0,
            temporaryDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        )
        try await runtime.start()
        let endpoint = try await runtime.waitUntilReady()
        defer { Task { await runtime.stop() } }

        let client = LocalSendClient(
            peer: RemotePeer(host: endpoint.host, port: endpoint.port, protocolType: endpoint.protocolType),
            expectedFingerprint: String(repeating: "0", count: identity.fingerprint.count)
        )
        await #expect(throws: Error.self) {
            _ = try await client.info()
        }
    }
}
