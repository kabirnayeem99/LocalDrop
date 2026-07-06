# LocalSend v2.1 Protocol — LocalSendKit Implementation Plan

## Context

LocalDrop needs wire-compatible LocalSend protocol support. `wiki/LocalSend-Protocol.md` covers the public spec; `Modules/LocalSendKit` already exists as the designated module (per `.claude/agents/team_lead.md`: "protocol: discovery, HTTP server/client, crypto, transfer engine, DTOs — no SwiftUI import"). No new SPM package needed.

**Status update**: Model/Crypto/HTTP(client+server)/Session/Discovery layers plus a `NetworkRuntime/` layer wiring everything to real sockets are implemented (not a stub). This doc's "full Network.framework socket stack" section documents the actual wiring below (`NWListener` server, `NWConnectionGroup`+`NWMulticastGroup` multicast, TLS server identity) so it stays authoritative alongside the code.

Reference research (`localsend-main-app/`) found the Rust `core/` crate is a partial stub — no session mgmt, PIN, cert-gen, or 409 logic. The real production behavior lives in the Flutter app (`app/lib/`), which was read directly and is the ground truth used below. Deviations from `wiki/LocalSend-Protocol.md` are called out explicitly.

Goal: implement the protocol end-to-end in `LocalSendKit` using native macOS networking (Network.framework, Security framework), byte-for-byte wire compatible with real LocalSend clients, with unit + integration/e2e coverage mirroring and exceeding the reference test suites.

## Architecture decisions

- **Multicast (discovery)**: `NWConnectionGroup` + `NWMulticastGroup` (macOS 14 supports this) for receive-and-join-all-interfaces; plain `NWConnection` (UDP, host=224.0.0.167:53317) for sending announces. Avoids raw BSD sockets.
- **HTTP server**: `NWListener` + a hand-rolled minimal HTTP/1.1 request parser/response writer. Payload shapes are simple (JSON bodies, raw binary upload/download, query params, no chunked-transfer requirement) — not worth pulling in SwiftNIO. TLS via `NWParameters(tls: ...)` with `sec_protocol_options_set_verify_block` for TOFU peer-cert acceptance (matches LocalSend's own trust model: accept any time-valid self-signed cert, no CA chain).
- **HTTP client**: `URLSession` with a custom `URLSessionDelegate` implementing `urlSession(_:didReceive:completionHandler:)` for the same TOFU cert handling (accept challenge, then compare peer cert SHA-256 against the fingerprint learned during discovery).
- **Cert/key generation**: `swift-certificates` + `swift-crypto` (Apple first-party SPM packages) — user-approved. Generate P-256 keypair, build a self-signed `Certificate` (Subject `CN=LocalDrop`, matching the spirit of the reference's `CN=LocalSend User`; validity ~10 years to match reference), export DER. LocalSend peers only check time-validity + self-signature + fingerprint match — key algorithm doesn't need to match the Dart app's RSA choice.
- **Fingerprint**: SHA-256 of DER-encoded cert, **hex-encoded** (uppercase, matching `security_helper_test.dart`'s reference constant format) — not base64. This is the wire-critical detail; the Rust core's base64url encoding is NOT what real clients use.
- **Session state**: model as `actor`s (`ReceiveSession`, `SendSession`, `WebSendState`-equivalent) to serialize concurrent HTTP request handling without manual locking. One active receive-session at a time (global), mirroring the reference's single-`session` model.
- **Cert persistence**: generate once, persist DER + key to `UserDefaults`/app support dir (not Keychain, to mirror reference simplicity) — regenerate only on explicit reset, not per-launch.

### Network.framework socket stack (implemented, `NetworkRuntime/`)

Everything above sits on real sockets via three concrete pieces — this section is the actual wiring, not the abstract intent:

- **`LocalSendServerRuntime`** (actor, `NetworkRuntime/LocalSendServerRuntime.swift`): owns one `NWListener` built with `tlsConfiguration.makeListenerParameters()`. `stateUpdateHandler` resolves a `waitUntilReady()` continuation on `.ready` (captures the OS-assigned port when `tcpPort == 0`) or throws `.listenerStartFailed` on `.failed`. `newConnectionHandler` spins a `Task.detached` per accepted `NWConnection`, tracked in `activeConnectionTasks: [UUID: Task]` so `stop()` can cancel every in-flight connection. Each connection is served with hand-rolled framing over `connection.receive`/`connection.send` continuations: header-then-body read loop respects `LocalSendRuntimeLimits` (max header bytes, max JSON body bytes), routes the `/upload` path to disk-streaming (`stageUploadBody` writes chunks straight to a temp `FileHandle` instead of buffering in memory) while every other route buffers the full body, and writes responses back the same way (`.data` body sent in one shot, `.file` body streamed in 64KB chunks via `FileHandle.read(upToCount:)`).
- **`LocalSendTLSConfiguration`** (`NetworkRuntime/LocalSendTLSConfiguration.swift`): builds the `NWParameters(tls:)` the listener uses. Pins `sec_protocol_options_set_min_tls_protocol_version(.TLSv12)`, installs the server's identity via `sec_protocol_options_set_local_identity`, and installs a `sec_protocol_options_set_verify_block` that calls the same `TLSCertificateValidator.validate` used by the client's TOFU delegate — server-side accepts any time-valid, correctly self-signed peer cert (no fingerprint pinning on accept; LocalSend has no client-cert requirement). Building the `sec_identity_t` from a `swift-crypto` `P256.Signing.PrivateKey` requires a hand-rolled PKCS#8 DER wrapper (`pkcs8PrivateKeyData` + `derSequence`/`derOctetString`/`derBitString`/`derOID` helpers) because `SecKeyCreateWithData` needs PKCS#8, not the raw 32-byte scalar swift-crypto exposes — flagged as a fragile spot (breaks silently if the key type ever changes from P-256) worth a `TECH_DEBT.md` entry if not already tracked.
- **`MulticastListenerRuntime` / `MulticastAnnouncerRuntime` / `DiscoveryService`** (`Discovery/Discovery.swift`): listener side joins `224.0.0.167:53317` via `NWMulticastGroup(for: [.hostPort(...)])` wrapped in `NWConnectionGroup(with:using:.udp)`, with `setReceiveHandler(maximumMessageSize:rejectOversizedMessages:)` decoding + self-fingerprint-filtering each datagram through `MulticastListener.decodeAnnouncement`. Announcer side is a plain `NWConnection(host:port:using:.udp)` that fires the 100/500/2000ms retry burst (`MulticastAnnouncer.makeAttempts`) for outbound announces and single-shot `respond(to:)` for unicast-style replies. `DiscoveryService` fans decoded peers out to `AsyncStream` subscribers and drives the register-fallback vs. multicast-reply branch (`registerResponder` closure decides whether a TCP `/register` already satisfied the peer before falling back to a UDP reply).
- **`LocalSendNode`** (`NetworkRuntime/LocalSendNode.swift`): top-level facade wiring `LocalSendServerRuntime` + `DiscoveryService` + `CertificateAuthority` + `LocalSendClientFactory` together — `start()` brings the listener up, waits for `waitUntilReady()`, then starts discovery; `announce()` reads the bound endpoint back to build the outbound `MulticastMessage`. This is the "phase 7 end-to-end wiring" from the phased order below — already done, not a future step.

## Source layout (`Modules/LocalSendKit/Sources/LocalSendKit/`) — actual, as implemented

```
Model/           ProtocolModels.swift — DeviceType, ProtocolType, FileDto, FileMetadata,
                 RegisterInfo, MulticastMessage, PrepareUploadRequest/Response,
                 PrepareDownloadResponse, InfoResponse — Codable w/ camelCase + enum
                 casing quirks (ProtocolType lowercase "http"/"https"; DeviceType
                 SCREAMING_SNAKE_CASE, unknown raw value -> .desktop)
Crypto/          CertificateAuthority.swift (LocalIdentity, CertificateStore protocol +
                 FileCertificateStore, keypair+self-signed cert gen via swift-certificates
                 X509, validate()), Fingerprint.swift (SHA-256 hex of DER)
Discovery/       Discovery.swift — MulticastListener/MulticastAnnouncer (pure decode/attempt
                 logic, unit-testable with no sockets), LegacyHTTPScanner (bounded-concurrency
                 subnet register POST fallback), plus the live socket runtime:
                 MulticastListenerRuntime (NWConnectionGroup+NWMulticastGroup),
                 MulticastAnnouncerRuntime (NWConnection/UDP, 100/500/2000ms retries),
                 DiscoveryService (fan-out AsyncStream + register-vs-multicast-reply logic)
HTTP/            HTTPTypes.swift, HTTPRequestParser.swift, HTTPResponseWriter.swift (transport-
                 agnostic parsing/framing — no Network import)
HTTP/Server/     LocalSendServer.swift (route dispatch: register/info/prepare-upload/upload/
                 cancel/prepare-download/download, PIN/session/token/IP validation) — pure
                 request-in/response-out, no socket code itself
HTTP/Client/     LocalSendClient.swift (URLSession-based), TOFUSessionDelegate.swift
NetworkRuntime/  LocalSendNode.swift (top-level facade: server+discovery+identity+client
                 factory), LocalSendServerRuntime.swift (actor; owns the NWListener, accepts
                 connections, frames requests/responses over Network.framework), 
                 LocalSendTLSConfiguration.swift (NWParameters(tls:) + sec_identity_t + TOFU
                 verify_block + hand-rolled PKCS8 DER wrapper), LocalSendRuntimeTypes.swift
                 (LocalSendRuntimeConfiguration, LocalSendRuntimeLimits, error enum)
Session/         TransferSessions.swift (receive/send session actors), PinAttemptTracker.swift
                 (actor, per-IP counter)
LocalSendKit.swift   public entry points / facade constants (e.g. apiPrefix)
```

`FeatureTransfer` consumes this via its existing dependency edge; no changes needed there for this plan's scope.

## Wire-format ground truth (from reference, not just the wiki doc)

- DTO fields per `dto_v2.rs`/Dart DTOs: `MulticastMessage{alias, version, deviceModel?, deviceType?, fingerprint, port, protocol, download=false, announce, announcement}` — **both** `announce` and `announcement` keys are sent (Dart checks `announcement == true || announce == true`); mirror both for interop safety.
- `PrepareUploadResponse.files` includes **only accepted files** (skipped files get no token/entry).
- `/cancel` has asymmetric logic per role (receiver being canceled vs. sender being canceled) — see below, richer than the wiki's flat description.
- Reverse-transfer (`/prepare-download`) uses **the requester's IP address string as `sessionId`**, not a UUID — enables resume-by-reconnect semantics (`?sessionId=` + IP match check).
- PIN check: plaintext string compare, per-IP attempt counter, `>=3` attempts → 429 before comparing; a mismatch that pushes attempts to exactly 3 also returns 429 (not 401) on that request.
- `/upload`: sender IP is pinned to the session at `/prepare-upload` time; any other IP gets 403 even with a valid token.

## Phased implementation order

All 7 phases below are implemented — kept for historical reference and as the checklist for the test plan.

1. **Model/** — DTOs + Codable, including enum fallback behavior. Fully unit-testable with no I/O. ✅
2. **Crypto/** — cert/keypair generation + fingerprint. Unit-testable standalone. ✅
3. **HTTP/Client/** — register, prepare-upload, upload, cancel, prepare-download, download, info — against a fake in-process server (or a scripted `NWListener` test double) before the real server exists. ✅
4. **HTTP/Server/** — same endpoints, request parsing, routing, PIN/session/token/IP validation. ✅
5. **Session/** — actor-based state machines wired into the server routes (currently stubbed in step 4). ✅
6. **Discovery/** — multicast listener + announcer, then legacy HTTP subnet-scan fallback. ✅
7. **End-to-end wiring** — client + server + discovery running together in-process on `127.0.0.1`/loopback multicast. ✅ (`NetworkRuntime/LocalSendNode.swift`)

## Test plan

### Unit — mirroring reference coverage
- DTO JSON round-trips: multicast message (both `announce`/`announcement`), register, prepare-upload request/response, prepare-download response, info.
- `ProtocolType` serializes lowercase; `DeviceType` serializes SCREAMING_SNAKE_CASE and **unknown raw value decodes to `.desktop`**.
- `FileDto` optional field omission (`sha256`, `preview`, `metadata`) round-trips correctly.
- Cert generation: valid self-signed cert, correct validity window, fingerprint = hex SHA-256 of DER.
- Cert verification: reject expired cert, reject tampered signature, reject pubkey mismatch (mirrors Rust `cert.rs` tests).
- URL building: http vs https, IPv4 vs IPv6 (bracketed) host, port, query param join.

### Unit — additional edge cases (beyond reference)
- PIN attempt counter: 0→1→2 attempts return 401; the request that makes it 3 returns 429; subsequent requests short-circuit to 429 without comparing the pin at all.
- `/upload` token/session/IP mismatch matrix: wrong fileId, wrong token, wrong sessionId, wrong sender IP, wrong session status (each independently → correct status code).
- `/cancel` role-asymmetric matrix: receiver-side (IP mismatch, sessionId mismatch outside `waiting`, wrong status) vs. sender-side (unresolvable sessionId, IP mismatch, wrong status) vs. v1-tolerant single-session case.
- `/prepare-upload`: empty `files` map → 400; already-in-session → 409; declined → 403 + session cleared; empty selection (message-only) → 204 + session cleared.
- Reverse-transfer: `sessionId` == requester IP; resume via `?sessionId=` only succeeds when IP matches and no pending responseHandler; `/download` computes `Content-Length` at download time, not prepare time.
- Multicast: self-announcement filtered by fingerprint match; TCP-register-first-then-UDP-fallback response path.
- `PinAttemptTracker`/session actors under concurrent access (no data races, verified via TSan or Swift Testing concurrency stress test).

### Integration / E2E
- Two `LocalSendKit` instances (server role + client role) in one XCTest/Swift Testing target, both bound to `127.0.0.1` with ephemeral ports:
  - Full handshake: register → prepare-upload → upload (small in-memory file) → verify bytes on disk match, session reaches `.finished`.
  - PIN-protected transfer: wrong PIN → 401 → correct PIN → success.
  - Cancel mid-transfer from both sender and receiver roles.
  - Reverse-transfer: prepare-download → download → verify byte-identical content + correct `Content-Disposition`/`Content-Length`.
  - Concurrent multi-file upload (parallel `/upload` calls against one session, per spec section 4.2).
- Multicast loopback test: two listeners on `127.0.0.1`-scoped interface (or loopback multicast if supported in CI sandbox — flag as a known CI constraint), verify announce → discover → TCP register response round-trip.
- Negative/adversarial: malformed JSON body → 400; blocked-by-session 409 while a session is active; oversized/garbage multipart-less binary body handling.

### Unit/Integration — Network.framework socket stack specifically

`IntegrationTests.swift` already covers real-socket TLS handshake + fingerprint-mismatch rejection (`realTLSRuntimeServesInfoOverLoopback`, `realTLSRuntimeRejectsFingerprintMismatch`) and the HTTP handshake/PIN/reverse-transfer/concurrent-upload flows over the runtime. Gaps still open: multicast-over-loopback (no test currently joins `NWConnectionGroup` for real), header/body size-limit rejection paths, and connection-task-leak-on-stop.

- `LocalSendServerRuntime`: bind on port 0 resolves the real OS-assigned port via `waitUntilReady()`; `.failed` listener state surfaces `listenerStartFailed` instead of hanging; `stop()` cancels every tracked `activeConnectionTasks` entry (no orphaned tasks/connections).
- Body framing: request larger than `maximumHeaderBytes` before headers terminate -> `headersTooLarge`; non-`/upload` body over `maximumJSONBodyBytes` -> `bodyTooLarge` before the body is even read; `/upload` streams to a temp file via `stageUploadBody` without buffering the whole payload in memory (assert peak memory or byte-for-byte written-file correctness, not just success).
- TLS: `LocalSendTLSConfiguration.makeSecIdentity()` round-trips a `swift-crypto` `P256.Signing.PrivateKey` through the hand-rolled PKCS#8 DER wrapper into a working `sec_identity_t` (handshake actually completes against a real `NWListener`); `TLSCertificateValidator.validate` accepts a valid self-signed time-valid cert and rejects an expired one and a tampered signature, exercised through the real `sec_protocol_options_set_verify_block` path, not just the underlying `CertificateAuthority.validate` unit test.
- Multicast: `MulticastListenerRuntime` actually joins `224.0.0.167:53317` via `NWConnectionGroup`/`NWMulticastGroup` on loopback and receives a datagram sent by a real `MulticastAnnouncerRuntime` (not just the pure `decodeAnnouncement`/`makeAttempts` unit tests) — flag as a known CI sandbox constraint if multicast loopback is unavailable in the sandbox, same caveat as the discovery E2E test above.
- Concurrency: fire N concurrent connections at one `LocalSendServerRuntime` and confirm no cross-request state leaks (each connection's `remoteAddress`/temp upload file stays isolated) and `activeConnectionTasks` correctly drains as each finishes.

Use **Swift Testing** (not XCTest) for new tests — fresh package, macOS 14+ target, no reason to inherit XCTest boilerplate; keep the existing stub XCTest file only if `swift-tools-version` requires it, otherwise migrate.

## Package.swift changes

Add dependencies to `Modules/LocalSendKit/Package.swift`: `apple/swift-certificates` and `apple/swift-crypto`. No other modules need dependency changes.

## Verification

- `swift build` and `swift test` inside `Modules/LocalSendKit` after each phase.
- `xcodegen generate` + `xcodebuild -scheme LocalDrop build` once wired into the app target (not required for this protocol-only plan, but confirm no regression).
- Manual interop smoke test against the real LocalSend app on the same LAN (per `.claude/agents/tester.md` charter) once phases 1–7 are code-complete — out of scope for this planning doc, tracked as a follow-up task for the `tester` agent.

## Next steps

Implementation follows `AGENT.md` role routing: dispatch to `team_lead`, which sequences `product_manager` (if any requirement gaps surface) → `engineer` (phases 1–7 above) → `senior_engineer` (review) → `tester` (test plan above, plus LAN interop). Not part of this planning commit.
