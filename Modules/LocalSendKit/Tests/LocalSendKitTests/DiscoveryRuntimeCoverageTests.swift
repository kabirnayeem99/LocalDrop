import AppLogging
import Foundation
import Network
import Testing
@testable import LocalSendKit

// MARK: - Coverage gaps owned by this file
//
// This file exists solely to raise coverage on:
//   - Discovery/Discovery.swift: MulticastListenerRuntime, MulticastAnnouncerRuntime,
//     DiscoveryService (the real-socket runtime classes, which had 0% coverage before
//     this file existed).
//   - A handful of 1-9 line gaps in HTTP/Client/LocalSendClient.swift,
//     Session/TransferSessions.swift, Session/PinAttemptTracker.swift, and
//     Crypto/CertificateAuthority.swift.
//
// Per team instructions, all new @Test functions live here even when the subject
// under test is defined in another file's test suite area, to avoid touching files
// owned by a concurrently-running coverage agent.
//
// NOTE on .serialized: this sandbox was observed to crash the whole test binary with
// signal 5 (abort) when several tests each stood up their own real NWConnectionGroup /
// NWMulticastGroup / NWConnection concurrently (Swift Testing's default parallel
// execution). A single multicast round trip in isolation reliably passes in well under
// a second once the very first multicast join on the machine "warms up" (that first
// join alone took ~150s in this sandbox, apparently one-time mDNSResponder/multicast
// route setup latency, not a per-test cost). Serializing this suite avoids the
// concurrent-socket-creation contention while keeping every test's own bounded
// timeouts intact, at the cost of the suite taking longer wall-clock time to run.
@Suite(.serialized)
struct DiscoveryRuntimeCoverageTests {

    // MARK: - Real multicast socket runtime

    // These tests bind real UDP sockets via Network.framework. To avoid colliding with
    // any real LocalSend traffic on the host running the test suite, we do NOT use the
    // production multicast group/port (224.0.0.167:53317). Instead we reuse the same
    // multicast address (it is a valid, reserved multicast group) but bind to distinct
    // high ephemeral ports per test so concurrent test runs / xdist workers don't collide
    // with each other either.
    //
    // Multicast loopback on macOS works without special entitlements for a plain SPM
    // test binary (proven out by IntegrationTests.swift already exercising real
    // Network.framework TLS sockets in this same environment). If multicast loopback
    // were unavailable in a given sandbox, `NWConnectionGroup`/`NWConnection` would never
    // reach `.ready`, and these tests would time out against the explicit deadlines below
    // rather than hang indefinitely.

    private static let testMulticastGroup = "224.0.0.167"

    private func makeTestPort() -> UInt16 {
        // Spread test ports well above the well-known LocalSend port (53317) and
        // above the ephemeral range collision zone used by other test files, and
        // randomize per-call so repeated runs / parallel tests don't collide.
        UInt16.random(in: 53418...54417)
    }

    @Test func multicastAnnouncerAndListenerRoundTripOverRealSockets() async throws {
        let port = makeTestPort()
        let message = MulticastMessage(
            alias: "RuntimeSender",
            fingerprint: "RUNTIME-SENDER",
            port: 53317,
            protocolType: .https,
            announce: true
        )

        let receivedBox = ReceivedPeerBox()

        let listener = try MulticastListenerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: port,
            selfFingerprint: "RUNTIME-LISTENER-SELF"
        ) { peer in
            Task { await receivedBox.set(peer) }
        }
        listener.start()
        defer { listener.stop() }

        // Give the listener a brief moment to finish joining the multicast group
        // before we start sending, to reduce flakiness from the announcer's first
        // packet racing the listener's group-join.
        try await Task.sleep(for: .milliseconds(200))

        let announcer = try MulticastAnnouncerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: port
        )
        announcer.start()
        defer { announcer.stop() }

        try await announcer.respond(to: message)

        let peer = await waitFor(timeoutSeconds: 20) {
            await receivedBox.get()
        }

        let unwrapped = try #require(peer, "Listener never received the announcement over the real multicast socket within the timeout")
        #expect(unwrapped.info.alias == "RuntimeSender")
        #expect(unwrapped.info.fingerprint == "RUNTIME-SENDER")
        #expect(unwrapped.shouldReplyViaRegister == true)
    }

    @Test func multicastAnnouncerRuntimeRunsFullRetrySchedule() async throws {
        // Exercises MulticastAnnouncerRuntime.announce(_:), which walks the three
        // scheduled attempts from MulticastAnnouncer.makeAttempts (100ms/500ms/2000ms
        // delays) and sends each over a real socket.
        let port = makeTestPort()
        let message = MulticastMessage(
            alias: "Retrier",
            fingerprint: "RETRY-FINGERPRINT",
            port: 53317,
            protocolType: .https,
            announce: true
        )

        let receiveCountBox = ReceiveCountBox()
        let listener = try MulticastListenerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: port,
            selfFingerprint: "RETRY-LISTENER-SELF"
        ) { _ in
            Task { await receiveCountBox.increment() }
        }
        listener.start()
        defer { listener.stop() }

        try await Task.sleep(for: .milliseconds(200))

        let announcer = try MulticastAnnouncerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: port
        )
        announcer.start()
        defer { announcer.stop() }

        try await announcer.announce(message)

        // All three scheduled attempts (100ms + 500ms + 2000ms delays, ~2.6s total)
        // should have fired by now; poll briefly afterwards to let the last UDP
        // datagram get delivered and processed.
        let finalCount = await waitFor(timeoutSeconds: 20) {
            let count = await receiveCountBox.get()
            return count >= 3 ? count : nil
        }
        #expect((finalCount ?? 0) >= 3, "Expected all three retry attempts to be received, got \(finalCount ?? 0)")
    }

    @Test func multicastListenerRuntimeIgnoresUndecodablePayloads() async throws {
        // Exercises the `try?` failure branch inside MulticastListenerRuntime.start()'s
        // receive handler: a payload that fails to decode as MulticastMessage must be
        // silently dropped rather than crash or invoke the callback.
        //
        // Note: we intentionally do not assert an exact receive *count* here. Hosts
        // with multiple multicast-capable interfaces (as this sandbox has: lo0 plus
        // several en* interfaces) can legitimately deliver the same valid UDP
        // multicast datagram to a single NWConnectionGroup receive handler more than
        // once; that duplication is a property of IP multicast, not a bug in
        // MulticastListenerRuntime. What we actually care about is that garbage never
        // produces a callback invocation with garbage-shaped content — every peer the
        // callback *does* receive must be the valid, well-formed message.
        let port = makeTestPort()
        let receivedFingerprintsBox = FingerprintsBox()

        let listener = try MulticastListenerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: port,
            selfFingerprint: "GARBAGE-LISTENER-SELF"
        ) { peer in
            Task { await receivedFingerprintsBox.append(peer.info.fingerprint) }
        }
        listener.start()
        defer { listener.stop() }

        try await Task.sleep(for: .milliseconds(200))

        // Send raw garbage that is not valid JSON / not a MulticastMessage, using a
        // bare NWConnection bound at the exact same multicast host/port as the
        // listener under test.
        try await sendRawGarbage(host: Self.testMulticastGroup, port: port)

        // Then send a real, valid message via the production announcer so we have
        // positive confirmation the listener is alive and would have reported a
        // receipt if one were valid.
        let announcer = try MulticastAnnouncerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: port
        )
        announcer.start()
        defer { announcer.stop() }

        let validMessage = MulticastMessage(
            alias: "AfterGarbage",
            fingerprint: "AFTER-GARBAGE",
            port: 53317,
            protocolType: .https,
            announce: true
        )
        try await announcer.respond(to: validMessage)

        let fingerprints = await waitFor(timeoutSeconds: 20) {
            let fingerprints = await receivedFingerprintsBox.get()
            return fingerprints.isEmpty ? nil : fingerprints
        }
        let unwrapped = try #require(fingerprints, "Expected at least one decoded callback invocation for the valid follow-up message")
        #expect(unwrapped.allSatisfy { $0 == "AFTER-GARBAGE" }, "Every decoded callback invocation must be the valid message; garbage must never decode to a peer: \(unwrapped)")
    }

    /// Sends one raw, non-JSON UDP datagram to `host:port` using a bare NWConnection,
    /// mirroring exactly what MulticastAnnouncerRuntime.send(payload:) does internally,
    /// but with a payload that cannot possibly decode as a MulticastMessage.
    private func sendRawGarbage(host: String, port: UInt16) async throws {
        guard let ipv4 = IPv4Address(host) else {
            throw LocalSendRuntimeError.multicastJoinFailed
        }
        let queue = DispatchQueue(label: "sendRawGarbage")
        let connection = NWConnection(
            host: .ipv4(ipv4),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp
        )
        connection.start(queue: queue)
        defer { connection.cancel() }

        // Give the connection a brief moment to reach .ready before sending, since
        // there is no readiness callback plumbed through here.
        try await Task.sleep(for: .milliseconds(100))

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data("not-valid-json-{{{".utf8),
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            )
        }
    }

    @Test func discoveryServiceStreamFansOutToMultipleSubscribers() async throws {
        let port = makeTestPort()
        let listener = try MulticastListenerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: port,
            selfFingerprint: "SVC-SELF"
        ) { _ in }
        let announcer = try MulticastAnnouncerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: port
        )

        let service = DiscoveryService(
            listener: listener,
            announcer: announcer,
            registerResponder: { _ in true }
        )
        service.start()
        defer { service.stop() }

        let stream1 = service.stream()
        let stream2 = service.stream()

        let peer = DiscoveredPeer(
            host: "127.0.0.1",
            info: RegisterInfo(alias: "FanOut", fingerprint: "FANOUT-FP"),
            shouldReplyViaRegister: false
        )

        async let first = firstElement(of: stream1)
        async let second = firstElement(of: stream2)

        // Yield the same peer to every current subscriber via handle(peer:localInfo:).
        await service.handle(
            peer: peer,
            localInfo: RegisterInfo(alias: "Local", fingerprint: "LOCAL-FP")
        )

        let (result1, result2) = await (first, second)
        #expect(result1?.info.fingerprint == "FANOUT-FP")
        #expect(result2?.info.fingerprint == "FANOUT-FP")
    }

    @Test func discoveryServiceStopFinishesAllContinuations() async throws {
        let port = makeTestPort()
        let listener = try MulticastListenerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: port,
            selfFingerprint: "STOP-SELF"
        ) { _ in }
        let announcer = try MulticastAnnouncerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: port
        )

        let service = DiscoveryService(
            listener: listener,
            announcer: announcer,
            registerResponder: { _ in true }
        )
        service.start()

        // Two independent subscribers, proving stop() finishes every continuation it
        // is tracking, not just the first one registered.
        let streamA = service.stream()
        let streamB = service.stream()

        service.stop()

        // Draining each stream to completion proves its continuation was finished by
        // stop(): an unfinished AsyncStream would hang the `for await` loop instead of
        // returning, so we race against a timeout to keep the suite from hanging if
        // this regresses.
        let drainedA = await withTimeout(seconds: 5) {
            for await _ in streamA {}
            return true
        }
        let drainedB = await withTimeout(seconds: 5) {
            for await _ in streamB {}
            return true
        }

        #expect(drainedA == true, "stream() subscriber A did not terminate after stop()")
        #expect(drainedB == true, "stream() subscriber B did not terminate after stop()")
    }

    @Test func discoveryServiceHandleSkipsMulticastReplyWhenRegisterResponderSucceeds() async throws {
        let port = makeTestPort()
        let listener = try MulticastListenerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: port,
            selfFingerprint: "REGISTER-TRUE-SELF"
        ) { _ in }

        let replyReceivedBox = ReceivedPeerBox()
        let replyListenerPort = makeTestPort()
        let replyListener = try MulticastListenerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: replyListenerPort,
            selfFingerprint: "REPLY-WATCHER-SELF"
        ) { peer in
            Task { await replyReceivedBox.set(peer) }
        }
        replyListener.start()
        defer { replyListener.stop() }

        let announcer = try MulticastAnnouncerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: replyListenerPort
        )

        let responderWasCalledBox = BoolBox()
        let service = DiscoveryService(
            listener: listener,
            announcer: announcer,
            registerResponder: { _ in
                await responderWasCalledBox.set(true)
                return true
            }
        )
        service.start()
        defer { service.stop() }

        try await Task.sleep(for: .milliseconds(200))

        let peer = DiscoveredPeer(
            host: "127.0.0.1",
            info: RegisterInfo(alias: "Sender", fingerprint: "SENDER-FP", port: 53317, protocolType: .https),
            shouldReplyViaRegister: true
        )
        await service.handle(
            peer: peer,
            localInfo: RegisterInfo(alias: "Local", fingerprint: "LOCAL-FP", port: 53317, protocolType: .https)
        )

        // Give a reasonable window for a multicast reply to have arrived if one had
        // been (incorrectly) sent.
        try await Task.sleep(for: .milliseconds(600))

        #expect(await responderWasCalledBox.get() == true)
        #expect(await replyReceivedBox.get() == nil, "No multicast reply should be sent when registerResponder returns true")
    }

    @Test func discoveryServiceHandleSendsMulticastReplyWhenRegisterResponderFails() async throws {
        let listenPort = makeTestPort()
        let listener = try MulticastListenerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: listenPort,
            selfFingerprint: "REGISTER-FALSE-SELF"
        ) { _ in }

        // The service's announcer both sends outbound announces and responds; bind a
        // second listener on the *same* port to observe the reply the service sends
        // via announcer.respond(to:).
        let replyReceivedBox = ReceivedPeerBox()
        let observerListener = try MulticastListenerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: listenPort,
            selfFingerprint: "OBSERVER-SELF"
        ) { peer in
            Task { await replyReceivedBox.set(peer) }
        }
        observerListener.start()
        defer { observerListener.stop() }

        let announcer = try MulticastAnnouncerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: listenPort
        )

        let service = DiscoveryService(
            listener: listener,
            announcer: announcer,
            registerResponder: { _ in false }
        )
        service.start()
        defer { service.stop() }

        try await Task.sleep(for: .milliseconds(200))

        let localInfo = RegisterInfo(
            alias: "Local",
            deviceModel: "Mac",
            deviceType: .desktop,
            fingerprint: "LOCAL-FP",
            port: 53317,
            protocolType: .https,
            download: true
        )
        let peer = DiscoveredPeer(
            host: "127.0.0.1",
            info: RegisterInfo(alias: "Sender", fingerprint: "SENDER-FP", port: 53317, protocolType: .https),
            shouldReplyViaRegister: true
        )
        await service.handle(peer: peer, localInfo: localInfo)

        let reply = await waitFor(timeoutSeconds: 20) {
            await replyReceivedBox.get()
        }
        let unwrapped = try #require(reply, "Expected a multicast reply to be sent when registerResponder returns false")
        #expect(unwrapped.info.alias == "Local")
        #expect(unwrapped.info.fingerprint == "LOCAL-FP")
        // The service builds its reply with announce: false, so shouldReplyViaRegister
        // (announce || announcement) must be false on the decoded reply.
        #expect(unwrapped.shouldReplyViaRegister == false)
    }

    @Test func discoveryServiceHandleWithNoReplyNeededDoesNotCallResponder() async throws {
        let port = makeTestPort()
        let listener = try MulticastListenerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: port,
            selfFingerprint: "NOOP-SELF"
        ) { _ in }
        let announcer = try MulticastAnnouncerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: port
        )

        let responderCallCountBox = ReceiveCountBox()
        let service = DiscoveryService(
            listener: listener,
            announcer: announcer,
            registerResponder: { _ in
                await responderCallCountBox.increment()
                return true
            }
        )
        service.start()
        defer { service.stop() }

        let peer = DiscoveredPeer(
            host: "127.0.0.1",
            info: RegisterInfo(alias: "Quiet", fingerprint: "QUIET-FP"),
            shouldReplyViaRegister: false
        )
        await service.handle(
            peer: peer,
            localInfo: RegisterInfo(alias: "Local", fingerprint: "LOCAL-FP")
        )

        #expect(await responderCallCountBox.get() == 0)
    }

    @Test func discoveryServiceAnnounceDelegatesToAnnouncer() async throws {
        let port = makeTestPort()
        let listenerPeerBox = ReceivedPeerBox()
        let listener = try MulticastListenerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: port,
            selfFingerprint: "ANNOUNCE-DELEGATE-OBSERVER"
        ) { peer in
            Task { await listenerPeerBox.set(peer) }
        }
        listener.start()
        defer { listener.stop() }

        let serviceOwnListener = try MulticastListenerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: port,
            selfFingerprint: "ANNOUNCE-DELEGATE-SELF"
        ) { _ in }
        let announcer = try MulticastAnnouncerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: port
        )
        let service = DiscoveryService(
            listener: serviceOwnListener,
            announcer: announcer,
            registerResponder: { _ in true }
        )
        service.start()
        defer { service.stop() }

        try await Task.sleep(for: .milliseconds(200))

        try await service.announce(
            MulticastMessage(alias: "Delegated", fingerprint: "DELEGATED-FP", port: 53317, protocolType: .https, announce: true)
        )

        let peer = await waitFor(timeoutSeconds: 20) {
            await listenerPeerBox.get()
        }
        #expect(peer?.info.fingerprint == "DELEGATED-FP")
    }

    @Test func discoveryServiceEmitsStructuredPeerLifecycleLogs() async throws {
        let port = makeTestPort()
        let sink = RecordingLogSink()
        let logger = AppLogger(
            configuration: AppLoggerConfiguration(minimumLevel: .debug, redactSensitiveValues: true),
            sinks: [sink]
        )
        let listener = try MulticastListenerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: port,
            selfFingerprint: "LOG-SELF",
            logger: logger
        ) { _ in }
        let announcer = try MulticastAnnouncerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: port,
            logger: logger
        )

        let service = DiscoveryService(
            listener: listener,
            announcer: announcer,
            registerResponder: { _ in true },
            logger: logger
        )
        service.start()
        defer { service.stop() }

        await service.handle(
            peer: DiscoveredPeer(
                host: "127.0.0.1",
                info: RegisterInfo(alias: "Peer A", fingerprint: "PEER-A", port: 53317, protocolType: .https),
                shouldReplyViaRegister: false
            ),
            localInfo: RegisterInfo(alias: "Local", fingerprint: "LOCAL")
        )
        await service.handle(
            peer: DiscoveredPeer(
                host: "127.0.0.2",
                info: RegisterInfo(alias: "Peer A Updated", fingerprint: "PEER-A", port: 53317, protocolType: .https),
                shouldReplyViaRegister: false
            ),
            localInfo: RegisterInfo(alias: "Local", fingerprint: "LOCAL")
        )

        try await Task.sleep(for: .milliseconds(50))
        await logger.flush()
        let records = await sink.records()
        #expect(records.contains(where: { $0.attributes["event.name"] == .string("discovery.peer.discovered") }))
        #expect(records.contains(where: { $0.attributes["event.name"] == .string("discovery.peer.updated") }))
        #expect(records.contains(where: { $0.attributes["event.name"] == .string("discovery.peer.snapshot") }))
    }

    @Test func multicastListenerRuntimeInitThrowsForInvalidHost() {
        // Exercises `guard let host = IPv4Address(multicastHost) else { throw
        // LocalSendRuntimeError.multicastJoinFailed }` inside MulticastListenerRuntime.init.
        #expect(throws: LocalSendRuntimeError.multicastJoinFailed) {
            _ = try MulticastListenerRuntime(
                multicastHost: "not-an-ip-address",
                port: makeTestPort(),
                selfFingerprint: "INVALID-HOST-SELF"
            ) { _ in }
        }
    }

    @Test func multicastAnnouncerRuntimeInitThrowsForInvalidHost() {
        // Exercises the equivalent guard inside MulticastAnnouncerRuntime.init.
        #expect(throws: LocalSendRuntimeError.multicastJoinFailed) {
            _ = try MulticastAnnouncerRuntime(
                multicastHost: "also-not-an-ip-address",
                port: makeTestPort()
            )
        }
    }

    @Test func multicastAnnouncerRuntimeInvokesLogErrorWhenSendFails() async throws {
        // Exercises the `self.logError(error)` branch inside
        // MulticastAnnouncerRuntime.send(payload:), which fires when the underlying
        // NWConnection.send completion reports an error. We force a send failure by
        // never calling start() on the connection (so it never reaches .ready) and
        // instead cancel it immediately before sending, which causes the completion
        // handler to be invoked with a "connection cancelled"-style error rather than
        // hanging indefinitely.
        let loggedErrorBox = BoolBox()
        let announcer = try MulticastAnnouncerRuntime(
            multicastHost: Self.testMulticastGroup,
            port: makeTestPort(),
            logError: { _ in
                Task { await loggedErrorBox.set(true) }
            }
        )
        announcer.start()
        announcer.stop()

        // Sending after stop() (the underlying NWConnection has been canceled) should
        // fail and route through the logError closure before rethrowing.
        await #expect(throws: Error.self) {
            try await announcer.respond(
                to: MulticastMessage(alias: "PostStop", fingerprint: "POST-STOP-FP", port: 53317, protocolType: .https, announce: true)
            )
        }

        let logged = await waitFor(timeoutSeconds: 20) {
            let value = await loggedErrorBox.get()
            return value ? true : nil
        }
        #expect(logged == true, "Expected logError to be invoked when send fails after the connection was canceled")
    }

    // MARK: - LocalSendClient / URLSessionTransport gaps

    @Test func clientMissingPeerThrowsWhenNoDefaultPeerConfigured() async throws {
        // Exercises resolvePeer(_:)'s `throw LocalSendClientError.missingPeer` branch:
        // a client built without a default peer, called without an explicit peer.
        let client = LocalSendClient(transport: InProcessTransport { _ in
            HTTPResponse(statusCode: 200, body: Data())
        })

        await #expect(throws: LocalSendClientError.missingPeer) {
            _ = try await client.info(from: nil)
        }
    }

    @Test func clientUploadFileAtURLConvenienceOverloadDelegatesCorrectly() async throws {
        // Exercises the public upload(fileAt:byteCount:sessionId:fileId:token:to:)
        // overload, which just forwards to the private upload(_:sessionId:...) with a
        // .file(_:byteCount:) body.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("payload.bin")
        let payload = Data("convenience-overload-payload".utf8)
        try payload.write(to: fileURL)

        let receivedBodyBox = DataBox()
        let transport = InProcessTransport { request in
            if case .file(let url, let byteCount) = request.body {
                let data = try Data(contentsOf: url)
                await receivedBodyBox.set(data)
                #expect(byteCount == Int64(payload.count))
            }
            return HTTPResponse(statusCode: 200, body: Data())
        }
        let client = LocalSendClient(transport: transport)
        let peer = RemotePeer(host: "127.0.0.1", port: 1, protocolType: .https)

        try await client.upload(
            fileAt: fileURL,
            byteCount: Int64(payload.count),
            sessionId: "session",
            fileId: "file1",
            token: "token1",
            to: peer
        )

        #expect(await receivedBodyBox.get() == payload)
    }

    @Test func urlSessionTransportSendsHeadersAndUploadsFileOverRealTLS() async throws {
        // Exercises URLSessionTransport.send(_:to:)'s header-copy loop (only non-empty
        // for requests that set headers, e.g. register/prepare-upload/upload — not the
        // bare GET /info used elsewhere), the .file(...) branch of the request body
        // switch (session.upload(for:fromFile:)), and the HTTPURLResponse success path,
        // all against a real TLS server via LocalSendServerRuntime.
        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        let authority = CertificateAuthority(store: FileCertificateStore(identityURL: storeURL))
        let identity = try authority.loadOrCreateIdentity()

        let storageDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
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
                uploadPolicy: .acceptAll,
                storageDirectory: storageDirectory
            )
        )
        // LocalSendServerRuntime.stageUploadBody(...) writes incoming upload bytes to
        // `temporaryDirectory.appendingPathComponent(UUID().uuidString)` without ever
        // creating the parent directory itself — it is the caller's responsibility to
        // provide an existing directory, same contract as storageDirectory above.
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let runtime = LocalSendServerRuntime(
            server: server,
            tlsConfiguration: LocalSendTLSConfiguration(identity: identity),
            port: 0,
            temporaryDirectory: temporaryDirectory
        )
        try await runtime.start()
        let endpoint = try await runtime.waitUntilReady()
        defer { Task { await runtime.stop() } }

        let client = LocalSendClient(
            peer: RemotePeer(host: endpoint.host, port: endpoint.port, protocolType: endpoint.protocolType),
            expectedFingerprint: identity.fingerprint
        )

        // register(with:) goes through jsonRequest, which sets Content-Type and
        // Content-Length headers, exercising URLSessionTransport's header-copy loop.
        let registered = try await client.register(with: RegisterInfo(alias: "Sender", fingerprint: "SENDER-FP"))
        #expect(registered.alias == "Receiver")

        // Now drive a full upload of a real file through the real TLS runtime to
        // exercise the .file(...) branch of URLSessionTransport's body switch.
        let prepareRequest = PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", fingerprint: "SENDER-FP", port: 53317, protocolType: .https),
            files: ["f1": FileDto(id: "f1", fileName: "upload.bin", size: 4, fileType: "application/octet-stream")]
        )
        let prepared = try #require(try await client.prepareUpload(prepareRequest))

        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("upload.bin")
        let payload = Data("real".utf8)
        try payload.write(to: fileURL)

        try await client.upload(
            fileAt: fileURL,
            byteCount: Int64(payload.count),
            sessionId: prepared.sessionId,
            fileId: "f1",
            token: prepared.files["f1"]!
        )

        let snapshot = try #require(await server.receiveSnapshot())
        #expect(snapshot.status == .finished)
    }

    @Test func urlSessionTransportReportsMonotonicUploadProgress() async throws {
        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        let authority = CertificateAuthority(store: FileCertificateStore(identityURL: storeURL))
        let identity = try authority.loadOrCreateIdentity()

        let storageDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
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
                uploadPolicy: .acceptAll,
                storageDirectory: storageDirectory
            )
        )
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let runtime = LocalSendServerRuntime(
            server: server,
            tlsConfiguration: LocalSendTLSConfiguration(identity: identity),
            port: 0,
            temporaryDirectory: temporaryDirectory
        )
        try await runtime.start()
        let endpoint = try await runtime.waitUntilReady()
        defer { Task { await runtime.stop() } }

        let client = LocalSendClient(
            peer: RemotePeer(host: endpoint.host, port: endpoint.port, protocolType: endpoint.protocolType),
            expectedFingerprint: identity.fingerprint
        )
        let payload = Data(repeating: 0x5A, count: 8 * 1024 * 1024)
        let prepareRequest = PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", fingerprint: "SENDER-FP", port: 53317, protocolType: .https),
            files: ["f1": FileDto(id: "f1", fileName: "large.bin", size: Int64(payload.count), fileType: "application/octet-stream")]
        )
        let prepared = try #require(try await client.prepareUpload(prepareRequest))

        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("large.bin")
        try payload.write(to: fileURL)

        let samples = ProgressSamplesBox()
        try await client.upload(
            fileAt: fileURL,
            byteCount: Int64(payload.count),
            sessionId: prepared.sessionId,
            fileId: "f1",
            token: prepared.files["f1"]!,
            progress: { progress in
                Task { await samples.append(progress.bytesTransferred) }
            }
        )

        let recorded: [Int64] = await waitFor(timeoutSeconds: 5) {
            let values = await samples.get()
            return values.isEmpty ? nil : values
        } ?? []
        #expect(recorded.isEmpty == false)
        #expect(recorded.last == Int64(payload.count))
        #expect(zip(recorded, recorded.dropFirst()).allSatisfy { $0 <= $1 })
    }

    // MARK: - Session/TransferSessions.swift gaps

    @Test func receiveSessionPrepareRejectPolicyReturnsRejected() async throws {
        let session = ReceiveSession()
        let request = PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", fingerprint: "SENDER-FP"),
            files: ["f1": FileDto(id: "f1", fileName: "a.txt", size: 1, fileType: "text/plain")]
        )
        let outcome = try await session.prepare(
            request: request,
            senderIP: "10.0.0.1",
            policy: .reject,
            destinationDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString),
            sessionIdFactory: { "session" },
            tokenFactory: { _ in "token" }
        )
        #expect(outcome == .rejected)
    }

    @Test func receiveSessionPrepareAcceptOnlyWithNoMatchingIDsReturnsNoTransferNeeded() async throws {
        // Exercises the `.acceptOnly` branch of the *second* switch (computing
        // acceptedIDs), specifically the case where the intersection with the
        // requested files is empty, hitting `acceptedIDs.isEmpty` -> .noTransferNeeded.
        let session = ReceiveSession()
        let request = PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", fingerprint: "SENDER-FP"),
            files: ["f1": FileDto(id: "f1", fileName: "a.txt", size: 1, fileType: "text/plain")]
        )
        let outcome = try await session.prepare(
            request: request,
            senderIP: "10.0.0.1",
            policy: .acceptOnly(["not-present"]),
            destinationDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString),
            sessionIdFactory: { "session" },
            tokenFactory: { _ in "token" }
        )
        #expect(outcome == .noTransferNeeded)
    }

    @Test func receiveSessionUploadAfterFinishReturnsBlocked() async throws {
        // Exercises `guard snapshot.status == .waiting || .transferring else { return .blocked }`
        // for the upload(...) entrypoint by driving a session to .finished and then
        // attempting a second upload call against the exhausted session.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let session = ReceiveSession()
        let request = PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", fingerprint: "SENDER-FP"),
            files: ["f1": FileDto(id: "f1", fileName: "a.txt", size: 1, fileType: "text/plain")]
        )
        guard case .accepted(let response) = try await session.prepare(
            request: request,
            senderIP: "10.0.0.1",
            policy: .acceptAll,
            destinationDirectory: directory,
            sessionIdFactory: { "session-1" },
            tokenFactory: { fileID in "token-\(fileID)" }
        ) else {
            Issue.record("expected accepted outcome")
            return
        }

        let firstResult = try await session.upload(
            sessionId: response.sessionId,
            fileId: "f1",
            token: response.files["f1"],
            senderIP: "10.0.0.1",
            body: Data("x".utf8)
        )
        #expect(firstResult == .success)

        let snapshot = try #require(await session.snapshot())
        #expect(snapshot.status == .finished)

        // The session is now finished and `current` has been cleared, so a further
        // upload call must report .blocked via the `guard var snapshot = current`
        // branch (current is nil after finishing).
        let secondResult = try await session.upload(
            sessionId: response.sessionId,
            fileId: "f1",
            token: response.files["f1"],
            senderIP: "10.0.0.1",
            body: Data("y".utf8)
        )
        #expect(secondResult == .blocked)
    }

    @Test func receiveSessionUploadOverwritesExistingStagedFile() async throws {
        // Exercises the FileManager.fileExists -> removeItem -> copyItem branch inside
        // ReceiveSession.stage(body:to:) for the .file(...) HTTPRequestBody case, which
        // only triggers when the destination already exists (e.g. a retried chunk of a
        // multi-file transfer where a previous file happened to already occupy that
        // exact destination path).
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let session = ReceiveSession()
        let request = PrepareUploadRequest(
            info: RegisterInfo(alias: "Sender", fingerprint: "SENDER-FP"),
            files: [
                "f1": FileDto(id: "f1", fileName: "a.txt", size: 1, fileType: "text/plain"),
                "f2": FileDto(id: "f2", fileName: "b.txt", size: 1, fileType: "text/plain")
            ]
        )
        guard case .accepted(let response) = try await session.prepare(
            request: request,
            senderIP: "10.0.0.1",
            policy: .acceptAll,
            destinationDirectory: directory,
            sessionIdFactory: { "session-collide" },
            tokenFactory: { fileID in "token-\(fileID)" }
        ) else {
            Issue.record("expected accepted outcome")
            return
        }

        let snapshotBefore = try #require(await session.snapshot())
        let destinationURL = try #require(snapshotBefore.files["f1"]?.destinationURL)

        // Pre-create a file at the exact destination path so the .file(...) staging
        // path must remove it before copying over it.
        try Data("stale-placeholder".utf8).write(to: destinationURL)
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))

        let sourceDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceURL = sourceDirectory.appendingPathComponent("source.txt")
        let freshPayload = Data("fresh-content".utf8)
        try freshPayload.write(to: sourceURL)

        let result = try await session.upload(
            sessionId: response.sessionId,
            fileId: "f1",
            token: response.files["f1"],
            senderIP: "10.0.0.1",
            body: .file(sourceURL, byteCount: Int64(freshPayload.count))
        )
        // Only f1 has been uploaded; f2 has not, so the session should still be
        // .transferring (not yet .finished) — this also exercises the `allExist ==
        // false` branch (`else { current = snapshot }`).
        #expect(result == .success)

        let midSnapshot = try #require(await session.snapshot())
        #expect(midSnapshot.status == .transferring)

        let overwritten = try Data(contentsOf: destinationURL)
        #expect(overwritten == freshPayload, "Existing file at destination should have been replaced by the new upload")
    }

    @Test func sendSessionCancelBranches() async throws {
        // Exercises SendSession.cancel(sessionId:requesterIP:)'s two false-returning
        // guards: unknown session/requester pair, and a session that is no longer
        // .waiting.
        let session = SendSession()
        let sharedFile = LocalSharedFile(
            file: FileDto(id: "d1", fileName: "download.bin", size: 4, fileType: "application/octet-stream"),
            source: .file(URL(fileURLWithPath: "/dev/null"), byteCount: 4)
        )

        // Unknown session/requester -> false.
        #expect(await session.cancel(sessionId: "missing", requesterIP: "10.0.0.9") == false)

        guard case .accepted(let response) = await session.prepare(
            requesterIP: "10.0.0.9",
            localInfo: InfoResponse(alias: "Local", fingerprint: "LOCAL-FP"),
            files: ["d1": sharedFile],
            allow: true
        ) else {
            Issue.record("expected accepted outcome")
            return
        }

        // Download transitions status to .finished.
        _ = try await session.download(sessionId: response.sessionId, fileId: "d1", requesterIP: "10.0.0.9")

        // Cancel on a .finished (non-.waiting) session -> false via the second guard,
        // and this also exercises LocalSharedFile.responseBody's .file(...) case and
        // loadData()'s .file(...) case indirectly through the download DTO construction.
        #expect(await session.cancel(sessionId: response.sessionId, requesterIP: "10.0.0.9") == false)
    }

    @Test func localSharedFileFileSourceLoadDataAndResponseBody() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("shared.bin")
        let payload = Data("shared-file-contents".utf8)
        try payload.write(to: fileURL)

        let sharedFile = LocalSharedFile(
            file: FileDto(id: "d1", fileName: "shared.bin", size: Int64(payload.count), fileType: "application/octet-stream"),
            source: .file(fileURL, byteCount: Int64(payload.count))
        )

        #expect(try sharedFile.loadData() == payload)
        if case .file(let url, let byteCount) = sharedFile.responseBody {
            #expect(url == fileURL)
            #expect(byteCount == Int64(payload.count))
        } else {
            Issue.record("expected .file(...) response body")
        }
    }

    @Test func localSharedFileDataSourceLoadDataReturnsUnderlyingBytes() throws {
        // Exercises LocalSharedFile.loadData()'s `.data(let data): return data` case.
        // Existing tests only ever exercise loadData() through the .file(...) source
        // (this file's own localSharedFileFileSourceLoadDataAndResponseBody test), or
        // exercise a .data(...)-sourced LocalSharedFile only through the server's
        // download flow (which reads `responseBody`, never calling loadData() at all).
        let payload = Data("in-memory-shared-bytes".utf8)
        let sharedFile = LocalSharedFile(
            file: FileDto(id: "d1", fileName: "memory.bin", size: Int64(payload.count), fileType: "application/octet-stream"),
            source: .data(payload)
        )

        #expect(try sharedFile.loadData() == payload)
        if case .data(let data) = sharedFile.responseBody {
            #expect(data == payload)
        } else {
            Issue.record("expected .data(...) response body")
        }
    }

    // MARK: - Session/PinAttemptTracker.swift gap

    @Test func pinAttemptTrackerAttemptsForUnknownIPDefaultsToZero() async throws {
        // Exercises the `default: 0` autoclosure inside attempts(for:), which is only
        // invoked when the IP address has never been recorded in attemptsByIP. All
        // existing tests only ever call attempts(for:) after validate(...) already
        // inserted the IP, so the default-value path was previously never taken.
        let tracker = PinAttemptTracker()
        #expect(await tracker.attempts(for: "203.0.113.5") == 0)
    }

    // MARK: - Crypto/CertificateAuthority.swift gap

    @Test func validateFailsWhenSignatureIsTamperedButStructureRemainsParsable() throws {
        // Exercises the `guard parsedCertificate.publicKey.isValidSignature(...) else`
        // branch specifically: the existing tamperedCertificateFailsValidation test
        // (in CryptoTests.swift) flips the very first DER byte, which breaks ASN.1
        // parsing itself and is caught by the earlier `catch { throw .invalidCertificate }`
        // block instead. Here we flip a byte deep inside the certificate (well past the
        // start of the structure) that is overwhelmingly likely to land inside the
        // signature bytes at the tail of the DER encoding, so the certificate still
        // parses successfully and is still within its validity window, but its
        // signature no longer verifies against its own public key.
        let authority = CertificateAuthority(store: FileCertificateStore(identityURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = try authority.generateIdentity(now: now)

        var tampered = identity.certificateDER
        // Flip the very last byte, which for an ECDSA-signed X.509 certificate falls
        // within the trailing signature BIT STRING, not the leading TBSCertificate
        // structure that ASN.1 parsing walks first.
        let lastIndex = tampered.index(before: tampered.endIndex)
        tampered[lastIndex] ^= 0xFF

        #expect(throws: CertificateAuthorityError.self) {
            try authority.validate(certificateDER: tampered, now: now)
        }
    }
}

// MARK: - Test helpers

/// Polls `body` until it returns a non-nil value or the timeout elapses, whichever
/// comes first. Used to bound waits on real-socket / async-callback based tests so a
/// broken multicast path fails fast with a clear assertion instead of hanging the
/// suite.
private func waitFor<T>(
    timeoutSeconds: Double,
    pollIntervalMilliseconds: UInt64 = 50,
    _ body: @Sendable () async -> T?
) async -> T? {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if let value = await body() {
            return value
        }
        try? await Task.sleep(for: .milliseconds(pollIntervalMilliseconds))
    }
    return await body()
}

/// Races `body` against a timeout, returning nil if the timeout wins. Used to bound
/// waits on operations (like draining an AsyncStream) that should complete promptly
/// but would otherwise hang the suite forever if the behavior under test regressed.
private func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            await body()
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

private func firstElement<Element: Sendable>(of stream: AsyncStream<Element>, timeoutSeconds: Double = 5) async -> Element? {
    await withTaskGroup(of: Element?.self) { group in
        group.addTask {
            for await element in stream {
                return element
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

/// Thread-safe box for capturing a single DiscoveredPeer delivered from a `@Sendable`
/// callback closure invoked off the calling task.
private actor ReceivedPeerBox {
    private var peer: DiscoveredPeer?

    func set(_ peer: DiscoveredPeer) {
        self.peer = peer
    }

    func get() -> DiscoveredPeer? {
        peer
    }
}

private actor ReceiveCountBox {
    private var count = 0

    func increment() {
        count += 1
    }

    func get() -> Int {
        count
    }
}

private actor FingerprintsBox {
    private var fingerprints: [String] = []

    func append(_ fingerprint: String) {
        fingerprints.append(fingerprint)
    }

    func get() -> [String] {
        fingerprints
    }
}

private actor BoolBox {
    private var value = false

    func set(_ value: Bool) {
        self.value = value
    }

    func get() -> Bool {
        value
    }
}

private actor DataBox {
    private var data: Data?

    func set(_ data: Data) {
        self.data = data
    }

    func get() -> Data? {
        data
    }
}

private actor ProgressSamplesBox {
    private var values: [Int64] = []

    func append(_ value: Int64) {
        values.append(value)
    }

    func get() -> [Int64] {
        values
    }
}
