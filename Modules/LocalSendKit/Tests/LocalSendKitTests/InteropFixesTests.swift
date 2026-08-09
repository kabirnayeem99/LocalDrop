import Foundation
import Testing
@testable import LocalSendKit

// MARK: - Helpers

private func makeStorageDirectory() -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeServer(
    storageDirectory: URL,
    bridge: IncomingTransferRequestBridge? = nil,
    uploadPolicy: PrepareUploadPolicy = .acceptAll
) -> LocalSendServer {
    LocalSendServer(
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
            uploadPolicy: uploadPolicy,
            incomingRequestBridge: bridge,
            allowDownloads: true,
            storageDirectory: storageDirectory
        )
    )
}

private func prepareUploadRequest(
    from senderIP: String,
    files: [String: FileDto] = ["file-1": FileDto(id: "file-1", fileName: "a.txt", size: 3, fileType: "text/plain")]
) throws -> HTTPRequest {
    let body = try JSONEncoder().encode(
        PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", fingerprint: "SENDER", port: 53317, protocolType: .https),
            files: files
        )
    )
    return HTTPRequest(
        method: .post,
        path: "\(LocalSendKit.apiPrefix)/prepare-upload",
        headers: ["Content-Length": "\(body.count)"],
        body: body,
        remoteAddress: senderIP
    )
}

private func cancelRequest(from senderIP: String, sessionId: String? = nil) -> HTTPRequest {
    HTTPRequest(
        method: .post,
        path: "\(LocalSendKit.apiPrefix)/cancel",
        query: sessionId.map { ["sessionId": $0] } ?? [:],
        remoteAddress: senderIP
    )
}

/// Polls until the bridge has published a prompt. The prompt only exists while `prepare` is
/// suspended, so there is no deterministic hook to await.
private func waitForPrompt(
    on bridge: IncomingTransferRequestBridge,
    timeoutSeconds: Double = 5
) async throws -> IncomingTransferRequest {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if let request = await bridge.currentRequest() {
            return request
        }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    throw LocalSendRuntimeError.incomingTransferRequestNotPending
}

// MARK: - P2: decode tolerance for optional wire fields

struct OptionalWireFieldDecodingTests {
    @Test func registerInfoDefaultsAbsentVersionToFallbackAndDownloadToFalse() throws {
        let json = Data(#"{"alias":"Legacy","fingerprint":"FP"}"#.utf8)
        let info = try JSONDecoder().decode(RegisterInfo.self, from: json)
        // An absent version means a v1-era peer. Defaulting to our own protocol version would
        // mislabel it as v2.
        #expect(info.version == "1.0")
        #expect(info.version == LocalSendKit.fallbackProtocolVersion)
        #expect(info.download == false)
        #expect(info.deviceModel == nil)
        #expect(info.deviceType == nil)
        #expect(info.port == nil)
        #expect(info.protocolType == nil)
    }

    @Test func registerInfoStillRequiresAliasAndFingerprint() {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(RegisterInfo.self, from: Data(#"{"alias":"NoPrint"}"#.utf8))
        }
    }

    @Test func infoResponseToleratesEveryOptionalFieldBeingAbsent() throws {
        let json = Data(#"{"alias":"Legacy"}"#.utf8)
        let info = try JSONDecoder().decode(InfoResponse.self, from: json)
        #expect(info.version == "1.0")
        #expect(info.download == false)
        #expect(info.fingerprint == "")
        #expect(info.deviceModel == nil)
        #expect(info.deviceType == nil)
    }

    @Test func multicastMessageDefaultsAbsentVersion() throws {
        let json = Data(#"{"alias":"Legacy","fingerprint":"FP","port":53317,"protocol":"https","announce":true}"#.utf8)
        let message = try JSONDecoder().decode(MulticastMessage.self, from: json)
        #expect(message.version == "1.0")
        #expect(message.download == false)
        #expect(message.announce)
    }

    @Test func encodingIsUnchangedByTheDecodeTolerance() throws {
        let info = RegisterInfo(alias: "Me", fingerprint: "FP", port: 1, protocolType: .https, download: true)
        let object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(info)) as? [String: Any]
        #expect(object?["version"] as? String == LocalSendKit.protocolVersion)
        #expect(object?["download"] as? Bool == true)
        #expect(object?["protocol"] as? String == "https")
    }
}

// MARK: - P1: v1 /info route

struct APIVersionRoutingTests {
    @Test func resolveRouteRecognizesBothPrefixes() {
        #expect(LocalSendKit.resolveRoute(path: "\(LocalSendKit.apiPrefix)/info")?.version == .v2)
        #expect(LocalSendKit.resolveRoute(path: "\(LocalSendKit.apiPrefixV1)/info")?.version == .v1)
        #expect(LocalSendKit.resolveRoute(path: "\(LocalSendKit.apiPrefixV1)/info")?.route == "info")
        #expect(LocalSendKit.resolveRoute(path: "/api/localsend/v3/info") == nil)
        #expect(LocalSendKit.resolveRoute(path: "/missing") == nil)
        #expect(LocalSendKit.resolveRoute(path: "\(LocalSendKit.apiPrefix)/") == nil)
    }

    /// The runtime's disk-staging decision must come from the same table as the server's routing,
    /// not from a second hand-rolled prefix comparison.
    @Test func bothSpellingsOfTheUploadRouteAreTreatedAsUploads() {
        #expect(LocalSendKit.isUploadRoute(path: "\(LocalSendKit.apiPrefix)/upload"))
        // v1 spells the upload route `send` (`api_route_builder.dart`: `upload('upload', 'send')`).
        // Missing it here would buffer a whole v1 upload in memory and reject it as oversized.
        #expect(LocalSendKit.isUploadRoute(path: "\(LocalSendKit.apiPrefixV1)/send"))
        // The v2 spelling is NOT a route under /v1, so it must not be staged to disk either.
        #expect(LocalSendKit.isUploadRoute(path: "\(LocalSendKit.apiPrefixV1)/upload") == false)
        #expect(LocalSendKit.isUploadRoute(path: "\(LocalSendKit.apiPrefix)/prepare-upload") == false)
        #expect(LocalSendKit.isUploadRoute(path: "\(LocalSendKit.apiPrefixV1)/send-request") == false)
    }

    @Test func canonicalRouteMapsOnlyTheTwoLegacySpellings() {
        #expect(LocalSendKit.canonicalRoute(version: .v1, route: "send-request") == "prepare-upload")
        #expect(LocalSendKit.canonicalRoute(version: .v1, route: "send") == "upload")
        // Unrenamed in v1.
        #expect(LocalSendKit.canonicalRoute(version: .v1, route: "cancel") == "cancel")
        #expect(LocalSendKit.canonicalRoute(version: .v1, route: "register") == "register")
        #expect(LocalSendKit.canonicalRoute(version: .v1, route: "info") == "info")
        // The v2 names do not exist under /v1.
        #expect(LocalSendKit.canonicalRoute(version: .v1, route: "upload") == nil)
        #expect(LocalSendKit.canonicalRoute(version: .v1, route: "prepare-upload") == nil)
        // v2 is always identity.
        #expect(LocalSendKit.canonicalRoute(version: .v2, route: "send-request") == "send-request")
    }

    /// The reference serves v1 and v2 `/info` from the same handler with a byte-identical
    /// `InfoDto` (`receive_controller.dart:74-80`).
    @Test func v1InfoReturnsTheIdenticalPayloadToV2() async throws {
        let server = makeServer(storageDirectory: makeStorageDirectory())
        let v2 = try await server.handle(HTTPRequest(method: .get, path: "\(LocalSendKit.apiPrefix)/info", remoteAddress: "10.0.0.1"))
        let v1 = try await server.handle(HTTPRequest(method: .get, path: "\(LocalSendKit.apiPrefixV1)/info", remoteAddress: "10.0.0.1"))
        #expect(v1.statusCode == 200)
        #expect(v2.statusCode == 200)
        // Compared as decoded values, not bytes: routing is what is under test, and a byte
        // comparison would also be asserting the encoder's key order.
        let decoder = JSONDecoder()
        let v1Payload = try decoder.decode(InfoResponse.self, from: try v1.body.loadData())
        let v2Payload = try decoder.decode(InfoResponse.self, from: try v2.body.loadData())
        #expect(v1Payload == v2Payload)
        #expect(v1Payload.version == LocalSendKit.protocolVersion)
        #expect(v1.headers["Content-Type"] == v2.headers["Content-Type"])
    }

    @Test func v1InfoIsGETOnly() async throws {
        let server = makeServer(storageDirectory: makeStorageDirectory())
        let postInfo = try await server.handle(HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefixV1)/info", remoteAddress: "10.0.0.1"))
        #expect(postInfo.statusCode == 404)
    }

    /// The v1 transfer routes are now SERVED, so they must no longer 404. Each is asserted via a
    /// status code only reachable once routing succeeded — a 404 would mean the route never
    /// dispatched at all.
    @Test func v1TransferRoutesAreServed() async throws {
        let server = makeServer(storageDirectory: makeStorageDirectory())
        for route in ["register", "send-request"] {
            let response = try await server.handle(
                HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefixV1)/\(route)", remoteAddress: "10.0.0.1")
            )
            // Empty body ⇒ "Request body malformed", i.e. the handler ran.
            #expect(response.statusCode == 400, "v1/\(route)")
        }

        // No parameters at all ⇒ missing-parameters, again proving dispatch.
        let send = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefixV1)/send", remoteAddress: "10.0.0.1")
        )
        #expect(send.statusCode == 400)

        // No live session and no session id ⇒ the cancel handler's own 400.
        let cancel = try await server.handle(
            HTTPRequest(method: .post, path: "\(LocalSendKit.apiPrefixV1)/cancel", remoteAddress: "10.0.0.1")
        )
        #expect(cancel.statusCode == 400)
    }

    /// `/show` and the browser web-send assets remain unimplemented, which is exactly why `/info`
    /// advertises `download: false`. A browser must get a clean 404, not a half-served page.
    @Test func webSendRoutesStay404() async throws {
        let server = makeServer(storageDirectory: makeStorageDirectory())
        for path in ["/", "/show", "/main.js", "/i18n.json", "\(LocalSendKit.apiPrefixV1)/show", "\(LocalSendKit.apiPrefix)/show"] {
            let response = try await server.handle(HTTPRequest(method: .get, path: path, remoteAddress: "10.0.0.1"))
            #expect(response.statusCode == 404, "GET \(path)")
        }
    }
}

// MARK: - P5: cancel during the accept/decline prompt

struct CancelDuringPromptTests {
    /// Test 7 from the brief. The second transfer at the end is the part that proves the
    /// reentrancy guards hold and no orphan session was left behind — without it a stuck session
    /// would 409 forever, since there is no session timeout anywhere.
    @Test func cancelWithdrawsThePromptAndLeavesTheReceiverReusable() async throws {
        let bridge = IncomingTransferRequestBridge()
        let server = makeServer(storageDirectory: makeStorageDirectory(), bridge: bridge)
        var withdrawals = await bridge.withdrawals().makeAsyncIterator()

        async let firstOutcome = server.handle(try prepareUploadRequest(from: "10.0.0.5"))
        let prompt = try await waitForPrompt(on: bridge)

        // No sessionId: the sender does not have one yet. Sender IP alone authorizes.
        let cancel = try await server.handle(cancelRequest(from: "10.0.0.5"))
        #expect(cancel.statusCode == 200)

        #expect(try await firstOutcome.statusCode == 403)
        #expect(await withdrawals.next() == prompt.id)
        #expect(await bridge.currentRequest() == nil)
        #expect(await server.receiveSnapshot() == nil)

        // A second transfer from the same sender must go straight through.
        async let secondOutcome = server.handle(try prepareUploadRequest(from: "10.0.0.5"))
        let secondPrompt = try await waitForPrompt(on: bridge)
        try await bridge.respond(to: secondPrompt.id, decision: .acceptAll)
        #expect(try await secondOutcome.statusCode == 200)
    }

    /// Test 8. IP matching applies only to a pending prompt, so a stray cancel from a different
    /// peer must not take it down.
    @Test func cancelFromADifferentIPIsRejectedAndThePromptSurvives() async throws {
        let bridge = IncomingTransferRequestBridge()
        let server = makeServer(storageDirectory: makeStorageDirectory(), bridge: bridge)

        async let outcome = server.handle(try prepareUploadRequest(from: "10.0.0.5"))
        let prompt = try await waitForPrompt(on: bridge)

        let cancel = try await server.handle(cancelRequest(from: "10.0.0.99"))
        #expect(cancel.statusCode == 409)
        #expect(await bridge.currentRequest()?.id == prompt.id)

        try await bridge.respond(to: prompt.id, decision: .acceptAll)
        #expect(try await outcome.statusCode == 200)
    }

    /// With nothing pending at all, the pre-existing 400 for a session-less cancel is preserved.
    @Test func cancelWithNoPendingPromptAndNoSessionIsStill400() async throws {
        let server = makeServer(storageDirectory: makeStorageDirectory())
        let response = try await server.handle(cancelRequest(from: "10.0.0.5"))
        #expect(response.statusCode == 400)
    }

    /// Test 9. A `CheckedContinuation` resumed twice traps, so the loser of this race must be a
    /// clean no-op — and whichever way it lands there must be no orphan session.
    @Test func cancelRacingAnAcceptProducesExactlyOneOutcome() async throws {
        for _ in 0..<25 {
            let bridge = IncomingTransferRequestBridge()
            let server = makeServer(storageDirectory: makeStorageDirectory(), bridge: bridge)

            async let outcome = server.handle(try prepareUploadRequest(from: "10.0.0.5"))
            let prompt = try await waitForPrompt(on: bridge)

            async let cancelStatus = server.handle(cancelRequest(from: "10.0.0.5")).statusCode
            async let respondSucceeded: Bool = {
                do {
                    try await bridge.respond(to: prompt.id, decision: .acceptAll)
                    return true
                } catch {
                    return false
                }
            }()

            _ = try await cancelStatus
            _ = await respondSucceeded
            let status = try await outcome.statusCode

            #expect(status == 200 || status == 403)
            let snapshot = await server.receiveSnapshot()
            if status == 200 {
                #expect(snapshot?.status == .waiting)
            } else {
                // Rejected: nothing may be left behind, or the next transfer would 409 forever.
                #expect(snapshot == nil)
            }
            #expect(await bridge.currentRequest() == nil)
        }
    }

    /// A cancel must not go through `finishPending`: that finishes every `requests()` continuation
    /// and clears them, permanently killing the stream the app's prompt is bound to.
    @Test func withdrawalKeepsTheRequestStreamAlive() async throws {
        let bridge = IncomingTransferRequestBridge()
        let server = makeServer(storageDirectory: makeStorageDirectory(), bridge: bridge)
        var requests = await bridge.requests().makeAsyncIterator()

        async let firstOutcome = server.handle(try prepareUploadRequest(from: "10.0.0.5"))
        let first = try await waitForPrompt(on: bridge)
        #expect(await requests.next()?.id == first.id)
        _ = try await server.handle(cancelRequest(from: "10.0.0.5"))
        _ = try await firstOutcome

        async let secondOutcome = server.handle(try prepareUploadRequest(from: "10.0.0.5"))
        let second = try await waitForPrompt(on: bridge)
        // The same stream must still deliver the next prompt.
        #expect(await requests.next()?.id == second.id)
        try await bridge.respond(to: second.id, decision: .acceptAll)
        _ = try await secondOutcome
    }
}

// MARK: - P6: folder transfers + path traversal

struct DestinationResolutionTests {
    /// A path that does not exist on disk, so the collision probe never fires unless a test makes
    /// it fire.
    private let root = URL(fileURLWithPath: "/tmp/localdrop-destination-root-\(UUID().uuidString)")

    private func resolve(_ fileName: String) -> URL? {
        ReceiveSession.resolveDestination(fileName: fileName, destinationDirectory: root)
    }

    /// Test 10. Note `".."` on its own: the reference's guard sits inside
    /// `if (fileNameParts.length > 1)` and therefore misses exactly this case.
    @Test func traversalShapesAreRejected() {
        for fileName in ["../../etc/passwd", "..", "../x.txt", "a/../../b", "", ".", "./", "/", "..\\..\\x", "a/../.."] {
            #expect(resolve(fileName) == nil, "expected rejection for \(fileName.debugDescription)")
        }
    }

    @Test func benignShapesAreSanitizedRatherThanRejected() throws {
        let absolute = try #require(resolve("/abs/path/file.txt"))
        #expect(absolute.path == root.appendingPathComponent("abs/path/file.txt").path)

        let dotted = try #require(resolve("./nested//deep/file.txt"))
        #expect(dotted.path == root.appendingPathComponent("nested/deep/file.txt").path)

        let backslashes = try #require(resolve("folder\\sub\\file.txt"))
        #expect(backslashes.path == root.appendingPathComponent("folder/sub/file.txt").path)

        let trailing = try #require(resolve("dir. /name.txt.  "))
        #expect(trailing.lastPathComponent == "name.txt")
        #expect(trailing.deletingLastPathComponent().lastPathComponent == "dir")

        let illegal = try #require(resolve("we:ird?name<x>.txt"))
        #expect(illegal.lastPathComponent == "we_ird_name_x_.txt")
    }

    /// Item #20: files save under the name the sender gave them.
    @Test func resolvedDestinationCarriesNoSessionOrFileIDPrefix() throws {
        let url = try #require(resolve("holiday photo.jpeg"))
        #expect(url.lastPathComponent == "holiday photo.jpeg")
        #expect(url.path == root.appendingPathComponent("holiday photo.jpeg").path)
    }

    @Test func everyResolvedDestinationStaysUnderTheRoot() throws {
        for fileName in ["file.txt", "a/b/c.txt", "/abs/x.bin", "folder\\y.bin"] {
            let url = try #require(resolve(fileName))
            #expect(url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
        }
    }

    // MARK: - The staging area is not addressable by an incoming name

    /// The blocker: the staging area is a child of the save directory, so `.localdrop-staging/x.txt`
    /// clears every other guard — no `..`, no illegal scalars, and it genuinely *is* under the root.
    /// It used to stage successfully, flip the session to `.finished`, and then be deleted by the
    /// next sweep (which runs on every settings change, not just relaunch): silent data loss the UI
    /// and history both reported as a success.
    @Test func namesResolvingIntoTheStagingAreaAreRejected() {
        let staging = UploadStagingArea.directoryName
        for fileName in [
            "\(staging)/x.txt",
            "\(staging)/nested/x.txt",
            "/\(staging)/x.txt",
            "./\(staging)/x.txt",
            "\(staging)\\x.txt",
            // Folded: the destination filesystem is case- and normalization-insensitive, so a
            // case-variant name lands on the very same directory.
            "\(staging.uppercased())/x.txt",
            "\(staging.precomposedStringWithCanonicalMapping)/x.txt"
        ] {
            #expect(resolve(fileName) == nil, "expected rejection for \(fileName.debugDescription)")
        }
    }

    /// Only the *first* component is ours. A `.localdrop-staging` nested deeper is an ordinary
    /// user-visible folder that no sweep ever touches, so rejecting it would drop a legitimate file.
    @Test func aNestedStagingLikeDirectoryNameIsStillAllowed() throws {
        let url = try #require(resolve("photos/\(UploadStagingArea.directoryName)/x.txt"))
        #expect(url.path == root.appendingPathComponent("photos/\(UploadStagingArea.directoryName)/x.txt").path)
    }

    /// A *leaf* with the staging name is only a name clash, not an escape, so it takes the ordinary
    /// ` (n)` suffix rather than being dropped — and never lands on the directory itself.
    @Test func aLeafNamedLikeTheStagingDirectoryIsSuffixedNotRejected() throws {
        let url = try #require(resolve(UploadStagingArea.directoryName))
        #expect(url.lastPathComponent != UploadStagingArea.directoryName)
        #expect(url.lastPathComponent.hasPrefix(UploadStagingArea.directoryName))
    }

    // MARK: - Containment survives a symlinked component

    /// `standardizedFileURL` collapses `.`/`..` lexically only — it does not resolve symlinks. A
    /// pre-existing `X -> /somewhere/else` in the save folder made `X/file.txt` pass the textual
    /// `hasPrefix` test and be written outside the save root (and potentially onto another volume,
    /// where the final `moveItem` degrades to copy-then-unlink).
    @Test func aSymlinkedDirectoryComponentIsRejected() throws {
        let directory = makeStorageDirectory()
        let outside = makeStorageDirectory()
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape"), withDestinationURL: outside)

        #expect(ReceiveSession.resolveDestination(fileName: "escape/file.txt", destinationDirectory: directory) == nil)
        #expect(ReceiveSession.resolveDestination(fileName: "escape/deep/file.txt", destinationDirectory: directory) == nil)
        // Nothing was created outside the root as a side effect of asking.
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    /// The counterpart: a symlink that stays *inside* the root is not an escape and must still
    /// resolve, so the fix does not become a blanket ban on symlinks in the save folder.
    @Test func aSymlinkPointingBackInsideTheRootIsAccepted() throws {
        let directory = makeStorageDirectory()
        let inside = directory.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("alias"), withDestinationURL: inside)

        let url = try #require(ReceiveSession.resolveDestination(fileName: "alias/file.txt", destinationDirectory: directory))
        #expect(url.lastPathComponent == "file.txt")
    }

    /// A long basename from a folder tree used to throw mid-transfer with no recovery.
    @Test func longBasenamesAreTruncatedPreservingTheExtension() throws {
        let longName = String(repeating: "n", count: 250) + ".tar.gz"
        let url = try #require(resolve(longName))
        let component = url.lastPathComponent
        #expect(component.decomposedStringWithCanonicalMapping.utf8.count <= 255)
        #expect(component.hasSuffix(".gz"))
        #expect(component.hasPrefix("nnn"))
    }

    @Test func multiByteBasenamesAreTruncatedOnCharacterBoundaries() throws {
        let url = try #require(resolve(String(repeating: "é", count: 200) + ".txt"))
        let component = url.lastPathComponent
        #expect(component.decomposedStringWithCanonicalMapping.utf8.count <= 255)
        // Truncating mid-scalar would make this unrepresentable.
        #expect(component.hasSuffix(".txt"))
    }

    // MARK: - Item #20: collision resolution

    private func resolve(_ fileName: String, claiming claimed: inout Set<String>) -> URL? {
        ReceiveSession.resolveDestination(
            fileName: fileName,
            destinationDirectory: root,
            claimedDestinationKeys: &claimed
        )
    }

    @Test func inBatchCollisionsAreSuffixedBeforeTheExtension() throws {
        var claimed: Set<String> = []
        #expect(try #require(resolve("report.pdf", claiming: &claimed)).lastPathComponent == "report.pdf")
        #expect(try #require(resolve("report.pdf", claiming: &claimed)).lastPathComponent == "report (2).pdf")
        #expect(try #require(resolve("report.pdf", claiming: &claimed)).lastPathComponent == "report (3).pdf")
        // Never `report.pdf (2)`.
        #expect(try #require(resolve("notes", claiming: &claimed)).lastPathComponent == "notes")
        #expect(try #require(resolve("notes", claiming: &claimed)).lastPathComponent == "notes (2)")
    }

    /// The old behaviour DROPPED the later file on a folded collision, which — now that files save
    /// under their real name — would silently lose a file the sender was told was accepted.
    @Test func caseAndNormalizationFoldedCollisionsAreSuffixedNotDropped() throws {
        var claimed: Set<String> = []
        #expect(try #require(resolve("Photo.JPG", claiming: &claimed)).lastPathComponent == "Photo.JPG")
        #expect(try #require(resolve("photo.jpg", claiming: &claimed)).lastPathComponent == "photo (2).jpg")

        var normalization: Set<String> = []
        let precomposed = "café.txt".precomposedStringWithCanonicalMapping
        let decomposed = "café.txt".decomposedStringWithCanonicalMapping
        let first = try #require(resolve(precomposed, claiming: &normalization))
        let second = try #require(resolve(decomposed, claiming: &normalization))
        #expect(first.lastPathComponent.precomposedStringWithCanonicalMapping == "café.txt")
        #expect(second.lastPathComponent.precomposedStringWithCanonicalMapping == "café (2).txt")
    }

    /// The probe must consult the filesystem in the same iteration as the in-batch set: checking
    /// them in separate passes lets `name (2)` be claimed by the set while it also exists on disk.
    @Test func collisionProbeRespectsFilesAlreadyOnDisk() throws {
        let directory = makeStorageDirectory()
        try Data("existing".utf8).write(to: directory.appendingPathComponent("report.pdf"))
        try Data("existing".utf8).write(to: directory.appendingPathComponent("report (2).pdf"))

        var claimed: Set<String> = []
        let resolved = try #require(
            ReceiveSession.resolveDestination(
                fileName: "report.pdf",
                destinationDirectory: directory,
                claimedDestinationKeys: &claimed
            )
        )
        #expect(resolved.lastPathComponent == "report (3).pdf")
        #expect(FileManager.default.fileExists(atPath: resolved.path) == false)
    }

    /// The suffix budget is reserved BEFORE truncation. Reserving it afterwards is how a
    /// maximally long name plus ` (17)` ends up over NAME_MAX.
    @Test func suffixedMaximallyLongNamesStillFitNameMax() throws {
        let directory = makeStorageDirectory()
        let longName = String(repeating: "é", count: 400) + ".txt"

        var claimed: Set<String> = []
        var lastComponent = ""
        for _ in 0..<12 {
            let url = try #require(
                ReceiveSession.resolveDestination(
                    fileName: longName,
                    destinationDirectory: directory,
                    claimedDestinationKeys: &claimed
                )
            )
            lastComponent = url.lastPathComponent
            #expect(lastComponent.decomposedStringWithCanonicalMapping.utf8.count <= 255)
            // Provable rather than assumed: the name must actually be creatable.
            try Data("x".utf8).write(to: url)
        }
        #expect(lastComponent.contains(" (12)"))
        #expect(lastComponent.hasSuffix(".txt"))
    }
}

struct FolderTransferSessionTests {
    private func fileDto(_ id: String, _ name: String, size: Int64 = 4) -> FileDto {
        FileDto(id: id, fileName: name, size: size, fileType: "application/octet-stream")
    }

    private func prepare(
        files: [String: FileDto],
        destinationDirectory: URL
    ) async throws -> PrepareUploadOutcome {
        try await ReceiveSession().prepare(
            request: PrepareUploadRequest(
                info: RegisterInfo(alias: "Sender", fingerprint: "SENDER", port: 1, protocolType: .https),
                files: files
            ),
            senderIP: "10.0.0.5",
            policy: .acceptAll,
            destinationDirectory: destinationDirectory,
            sessionIdFactory: { "session" },
            tokenFactory: { "token-" + $0 }
        )
    }

    /// One bad name drops that file only — the session and the other files survive, matching the
    /// reference's per-file failure semantics without failing a 500-file folder over one name.
    @Test func offendingFileIsDroppedWhileTheBatchSurvives() async throws {
        let directory = makeStorageDirectory()
        let outcome = try await prepare(
            files: [
                "good": fileDto("good", "docs/report.pdf"),
                "evil": fileDto("evil", "../../etc/passwd"),
                "bare": fileDto("bare", "..")
            ],
            destinationDirectory: directory
        )
        guard case .accepted(let response) = outcome else {
            Issue.record("expected acceptance, got \(outcome)")
            return
        }
        #expect(response.files.keys.sorted() == ["good"])
    }

    /// End-to-end guard for the same blocker: a sender aiming at the staging area gets that file
    /// dropped at `prepare` time, so nothing is ever staged, reported finished, and then swept.
    @Test func aFileNameAimedAtTheStagingAreaIsDroppedWhileTheBatchSurvives() async throws {
        let directory = makeStorageDirectory()
        let staging = UploadStagingArea.directoryName
        let outcome = try await prepare(
            files: [
                "good": fileDto("good", "report.pdf"),
                "staged": fileDto("staged", "\(staging)/x.txt"),
                "stagedUpper": fileDto("stagedUpper", "\(staging.uppercased())/x.txt")
            ],
            destinationDirectory: directory
        )
        guard case .accepted(let response) = outcome else {
            Issue.record("expected acceptance, got \(outcome)")
            return
        }
        #expect(response.files.keys.sorted() == ["good"])
    }

    @Test func aBatchOfNothingButBadNamesYieldsNoTransferNeeded() async throws {
        let outcome = try await prepare(
            files: ["evil": fileDto("evil", "../../etc/passwd")],
            destinationDirectory: makeStorageDirectory()
        )
        #expect(outcome == .noTransferNeeded)
    }

    /// Test 11. `FileManager.fileExists(atPath:)` returns true for a directory, so the directory
    /// `a` used to satisfy the existence check for the *file* `a` — flipping the session to
    /// `.finished` and clearing `current` before `a` ever arrived, and 409-ing the rest.
    @Test func aFileAndADirectoryOfTheSameNameBothArrive() async throws {
        let directory = makeStorageDirectory()
        let session = ReceiveSession()
        let outcome = try await session.prepare(
            request: PrepareUploadRequest(
                info: RegisterInfo(alias: "Sender", fingerprint: "SENDER", port: 1, protocolType: .https),
                files: [
                    "f-a": fileDto("f-a", "a", size: 1),
                    "f-b": fileDto("f-b", "a/b.txt", size: 1)
                ]
            ),
            senderIP: "10.0.0.5",
            policy: .acceptAll,
            destinationDirectory: directory,
            sessionIdFactory: { "session" },
            tokenFactory: { "token-" + $0 }
        )
        guard case .accepted(let response) = outcome else {
            Issue.record("expected acceptance, got \(outcome)")
            return
        }
        #expect(response.files.count == 2)

        // Nested file first: this creates the directory `a`, whose mere existence used to be
        // mistaken for the arrival of the sibling *file* named `a`.
        let nested = try await session.upload(
            sessionId: response.sessionId,
            fileId: "f-b",
            token: try #require(response.files["f-b"]),
            senderIP: "10.0.0.5",
            body: Data("B".utf8)
        )
        #expect(nested == .success)
        #expect(await session.snapshot()?.status == .transferring)

        let sibling = try await session.upload(
            sessionId: response.sessionId,
            fileId: "f-a",
            token: try #require(response.files["f-a"]),
            senderIP: "10.0.0.5",
            body: Data("A".utf8)
        )
        #expect(sibling == .success)
        #expect(await session.snapshot()?.status == .finished)

        // Without the old `sessionId-fileID-` prefix the plain file `a` and the directory `a`
        // genuinely contend for one path. Directories keep their name; the file yields to ` (2)`.
        #expect(try Data(contentsOf: directory.appendingPathComponent("a (2)")) == Data("A".utf8))
        #expect(try Data(contentsOf: directory.appendingPathComponent("a/b.txt")) == Data("B".utf8))
    }

    /// Intermediate directories are created at stage time, so a rejected transfer must not leave
    /// an empty tree behind.
    @Test func rejectedTransferLeavesNoEmptyDirectoryTree() async throws {
        let directory = makeStorageDirectory()
        let outcome = try await ReceiveSession().prepare(
            request: PrepareUploadRequest(
                info: RegisterInfo(alias: "Sender", fingerprint: "SENDER", port: 1, protocolType: .https),
                files: ["f": fileDto("f", "deep/nested/tree/file.bin")]
            ),
            senderIP: "10.0.0.5",
            policy: .reject,
            destinationDirectory: directory,
            sessionIdFactory: { "session" },
            tokenFactory: { "token-" + $0 }
        )
        #expect(outcome == .rejected)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("deep").path) == false)
    }

    /// A file occupying a path a later file needs as a directory surfaces as an explicit, mapped
    /// error rather than an anonymous throw out of `handleUpload`.
    @Test func fileBlockingADirectoryPathRaisesTheMappedError() async throws {
        let directory = makeStorageDirectory()
        let session = ReceiveSession()
        let outcome = try await session.prepare(
            request: PrepareUploadRequest(
                info: RegisterInfo(alias: "Sender", fingerprint: "SENDER", port: 1, protocolType: .https),
                files: ["f": fileDto("f", "blocked/file.bin")]
            ),
            senderIP: "10.0.0.5",
            policy: .acceptAll,
            destinationDirectory: directory,
            sessionIdFactory: { "session" },
            tokenFactory: { "token-" + $0 }
        )
        guard case .accepted(let response) = outcome else {
            Issue.record("expected acceptance, got \(outcome)")
            return
        }
        try Data("occupied".utf8).write(to: directory.appendingPathComponent("blocked"))

        await #expect(throws: ReceiveSessionError.destinationDirectoryUnavailable) {
            _ = try await session.upload(
                sessionId: response.sessionId,
                fileId: "f",
                token: try #require(response.files["f"]),
                senderIP: "10.0.0.5",
                body: Data("x".utf8)
            )
        }
    }
}

// MARK: - Item #15: per-file rename on accept (`desiredName`)

/// The receiver-supplied name is not a second, gentler naming path: it REPLACES the sender's
/// `fileName` at the top of the same pipeline, so every one of these expectations is deliberately
/// identical to the sender-supplied expectation asserted above.
struct DesiredNameTests {
    private func fileDto(_ id: String, _ name: String, size: Int64 = 1) -> FileDto {
        FileDto(id: id, fileName: name, size: size, fileType: "application/octet-stream")
    }

    /// Runs a real prompt round trip — the only way a rename can reach `prepare`, since the static
    /// `PrepareUploadPolicy` deliberately has no rename map — and returns the resolved destination
    /// per fileID.
    private func prepare(
        files: [String: FileDto],
        decision: IncomingTransferDecision,
        in directory: URL
    ) async throws -> (session: ReceiveSession, outcome: PrepareUploadOutcome, urls: [String: URL]) {
        let session = ReceiveSession()
        let bridge = IncomingTransferRequestBridge()
        async let outcome = session.prepare(
            request: PrepareUploadRequest(
                info: RegisterInfo(alias: "Sender", fingerprint: "SENDER", port: 1, protocolType: .https),
                files: files
            ),
            senderIP: "10.0.0.5",
            policy: .reject,
            incomingRequestBridge: bridge,
            destinationDirectory: directory,
            sessionIdFactory: { "session" },
            tokenFactory: { "token-" + $0 }
        )
        let prompt = try await waitForPrompt(on: bridge)
        try await bridge.respond(to: prompt.id, decision: decision)
        let resolvedOutcome = try await outcome
        let urls = await session.snapshot()?.files.mapValues(\.destinationURL) ?? [:]
        return (session, resolvedOutcome, urls)
    }

    /// The accept-everything-with-renames case, which is what the sheet sends.
    private func destinations(
        files: [String: FileDto],
        desiredNames: [String: String] = [:],
        in directory: URL
    ) async throws -> (session: ReceiveSession, response: PrepareUploadResponse, urls: [String: URL]) {
        let prepared = try await prepare(
            files: files,
            decision: .acceptOnly(Set(files.keys), desiredNames: desiredNames),
            in: directory
        )
        guard case .accepted(let response) = prepared.outcome else {
            throw DesiredNameTestFailure.notAccepted(prepared.outcome)
        }
        return (prepared.session, response, prepared.urls)
    }

    @Test func desiredNameIsHonouredAndTheFileLandsUnderIt() async throws {
        let directory = makeStorageDirectory()
        let prepared = try await destinations(
            files: ["f": fileDto("f", "original.txt")],
            desiredNames: ["f": "renamed.txt"],
            in: directory
        )
        #expect(prepared.urls["f"]?.lastPathComponent == "renamed.txt")

        let result = try await prepared.session.upload(
            sessionId: prepared.response.sessionId,
            fileId: "f",
            token: try #require(prepared.response.files["f"]),
            senderIP: "10.0.0.5",
            body: Data("X".utf8)
        )
        #expect(result == .success)
        #expect(try Data(contentsOf: directory.appendingPathComponent("renamed.txt")) == Data("X".utf8))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("original.txt").path) == false)
    }

    /// The rename map is keyed by fileID, so renaming one file leaves its siblings alone.
    @Test func onlyTheRenamedFileIsAffected() async throws {
        let directory = makeStorageDirectory()
        let prepared = try await destinations(
            files: ["a": fileDto("a", "a.txt"), "b": fileDto("b", "b.txt")],
            desiredNames: ["a": "renamed.txt"],
            in: directory
        )
        #expect(prepared.urls["a"]?.lastPathComponent == "renamed.txt")
        #expect(prepared.urls["b"]?.lastPathComponent == "b.txt")
    }

    /// A user typing `../../etc/passwd` must be dropped exactly like a malicious sender sending it.
    @Test func traversalShapesAreRejectedInDesiredNamesToo() async throws {
        for hostile in ["../../etc/passwd", "..", "../x.txt", "a/../..", ".", "/", "..\\..\\x"] {
            let directory = makeStorageDirectory()
            let prepared = try await prepare(
                files: ["f": fileDto("f", "safe.txt")],
                decision: .acceptOnly(["f"], desiredNames: ["f": hostile]),
                in: directory
            )
            // The lone file was dropped, exactly as `aBatchOfNothingButBadNamesYieldsNoTransferNeeded`
            // asserts for the same shapes arriving as a sender-supplied `fileName`. Notably NOT a
            // fallback to `safe.txt`: a rejected name is rejected, not quietly rewritten.
            #expect(
                prepared.outcome == .noTransferNeeded,
                "expected rejection for \(hostile.debugDescription), got \(prepared.outcome)"
            )
            #expect(prepared.urls.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    /// A user typing the staging directory into the rename field must be dropped exactly like a
    /// sender putting it in `fileName` — the staging area is reachable from both name sources.
    @Test func desiredNamesAimedAtTheStagingAreaAreRejectedToo() async throws {
        let staging = UploadStagingArea.directoryName
        for hostile in ["\(staging)/x.txt", "/\(staging)/x.txt", "\(staging.uppercased())/x.txt"] {
            let directory = makeStorageDirectory()
            let prepared = try await prepare(
                files: ["f": fileDto("f", "safe.txt")],
                decision: .acceptOnly(["f"], desiredNames: ["f": hostile]),
                in: directory
            )
            #expect(
                prepared.outcome == .noTransferNeeded,
                "expected rejection for \(hostile.debugDescription), got \(prepared.outcome)"
            )
            #expect(prepared.urls.isEmpty)
        }
    }

    /// `..`-bearing desired names drop the file, matching the sender-supplied behaviour
    /// (`offendingFileIsDroppedWhileTheBatchSurvives`) rather than falling back to the original.
    @Test func traversalBearingDesiredNameDropsTheFileWhileTheBatchSurvives() async throws {
        let directory = makeStorageDirectory()
        let prepared = try await destinations(
            files: ["good": fileDto("good", "good.txt"), "evil": fileDto("evil", "evil.txt")],
            desiredNames: ["evil": "../../etc/passwd"],
            in: directory
        )
        #expect(prepared.response.files.keys.sorted() == ["good"])
        #expect(prepared.urls["evil"] == nil)
    }

    /// An absolute desired name is *sanitized* into a relative subpath, not rejected — identical to
    /// `benignShapesAreSanitizedRatherThanRejected` for a sender-supplied name.
    @Test func absoluteDesiredNameIsSanitizedIntoTheRootExactlyLikeASenderName() async throws {
        let directory = makeStorageDirectory()
        let prepared = try await destinations(
            files: ["f": fileDto("f", "safe.txt")],
            desiredNames: ["f": "/abs/path/file.txt"],
            in: directory
        )
        let resolved = try #require(prepared.urls["f"])
        #expect(resolved.path == directory.appendingPathComponent("abs/path/file.txt").path)
        #expect(
            resolved.path
                == ReceiveSession.resolveDestination(fileName: "/abs/path/file.txt", destinationDirectory: directory)?.path
        )
    }

    /// Illegal characters are legalized by the same replacement the sender path uses.
    @Test func illegalCharactersInDesiredNamesAreLegalizedNotRejected() async throws {
        let directory = makeStorageDirectory()
        let prepared = try await destinations(
            files: ["f": fileDto("f", "safe.txt")],
            desiredNames: ["f": "we:ird?name<x>.txt"],
            in: directory
        )
        #expect(prepared.urls["f"]?.lastPathComponent == "we_ird_name_x_.txt")
    }

    @Test func desiredNamesGetTheSameNameMaxTruncation() async throws {
        let directory = makeStorageDirectory()
        let longName = String(repeating: "é", count: 400) + ".txt"
        let prepared = try await destinations(
            files: ["f": fileDto("f", "short.txt")],
            desiredNames: ["f": longName],
            in: directory
        )
        let component = try #require(prepared.urls["f"]).lastPathComponent
        #expect(component.decomposedStringWithCanonicalMapping.utf8.count <= 255)
        #expect(component.hasSuffix(".txt"))
        #expect(
            component
                == ReceiveSession.resolveDestination(fileName: longName, destinationDirectory: directory)?.lastPathComponent
        )
    }

    @Test func desiredNameCollidingWithSomethingOnDiskIsSuffixed() async throws {
        let directory = makeStorageDirectory()
        try Data("existing".utf8).write(to: directory.appendingPathComponent("report.pdf"))
        let prepared = try await destinations(
            files: ["f": fileDto("f", "whatever.bin")],
            desiredNames: ["f": "report.pdf"],
            in: directory
        )
        #expect(prepared.urls["f"]?.lastPathComponent == "report (2).pdf")
    }

    /// The rename must not silently drop a file when the user picks a name another accepted file in
    /// the same batch already owns.
    @Test func desiredNameCollidingWithinTheBatchIsSuffixedNotDropped() async throws {
        let directory = makeStorageDirectory()
        let prepared = try await destinations(
            files: ["a": fileDto("a", "report.pdf"), "b": fileDto("b", "other.pdf")],
            desiredNames: ["b": "report.pdf"],
            in: directory
        )
        #expect(prepared.response.files.keys.sorted() == ["a", "b"])
        let names = Set(prepared.urls.values.map(\.lastPathComponent))
        #expect(names == ["report.pdf", "report (2).pdf"])
    }

    /// A rename that collides with a *directory* the same batch needs yields, as a sender-supplied
    /// name would: directories keep their name.
    @Test func desiredNameCollidingWithABatchDirectoryIsSuffixed() async throws {
        let directory = makeStorageDirectory()
        let prepared = try await destinations(
            files: ["plain": fileDto("plain", "plain.bin"), "nested": fileDto("nested", "a/b.txt")],
            desiredNames: ["plain": "a"],
            in: directory
        )
        #expect(prepared.urls["plain"]?.lastPathComponent == "a (2)")
        #expect(prepared.urls["nested"]?.lastPathComponent == "b.txt")
    }

    @Test func emptyOrWhitespaceOnlyDesiredNameFallsBackToTheSenderName() async throws {
        for blank in ["", " ", "\t", "\n", "   \n "] {
            let directory = makeStorageDirectory()
            let prepared = try await destinations(
                files: ["f": fileDto("f", "original.txt")],
                desiredNames: ["f": blank],
                in: directory
            )
            #expect(
                prepared.urls["f"]?.lastPathComponent == "original.txt",
                "expected fallback for \(blank.debugDescription)"
            )
        }
    }

    /// Regression guard: with no rename map at all, nothing about the existing behaviour moves.
    @Test func noDesiredNamesBehavesExactlyAsBefore() async throws {
        let directory = makeStorageDirectory()
        let files = [
            "a": fileDto("a", "docs/report.pdf"),
            "b": fileDto("b", "report.pdf"),
            "c": fileDto("c", "report.pdf")
        ]
        let withEmptyMap = try await destinations(files: files, in: makeStorageDirectory())
        let prepared = try await destinations(files: files, desiredNames: [:], in: directory)
        #expect(prepared.response.files.keys.sorted() == ["a", "b", "c"])
        #expect(
            prepared.urls.mapValues(\.lastPathComponent)
                == withEmptyMap.urls.mapValues(\.lastPathComponent)
        )
        #expect(Set(prepared.urls.values.map(\.lastPathComponent)) == ["report.pdf", "report (2).pdf"])
    }

    /// A rename aimed at a fileID that is not being accepted is ignored rather than applied to
    /// someone else.
    @Test func desiredNamesForUnacceptedFileIDsAreIgnored() async throws {
        let directory = makeStorageDirectory()
        let prepared = try await prepare(
            files: ["keep": fileDto("keep", "keep.txt"), "skip": fileDto("skip", "skip.txt")],
            decision: .acceptOnly(["keep"], desiredNames: ["skip": "hijacked.txt", "keep": "kept.txt"]),
            in: directory
        )
        guard case .accepted(let response) = prepared.outcome else {
            Issue.record("expected acceptance, got \(prepared.outcome)")
            return
        }
        #expect(response.files.keys.sorted() == ["keep"])
        #expect(prepared.urls["keep"]?.lastPathComponent == "kept.txt")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("hijacked.txt").path) == false)
    }
}

private enum DesiredNameTestFailure: Error {
    case notAccepted(PrepareUploadOutcome)
}
