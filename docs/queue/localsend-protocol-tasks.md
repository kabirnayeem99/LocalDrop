# LocalSend Protocol — Task Breakdown

Phased tasks tracking `docs/queue/localsend-protocol-implementation-plan.md`. Each phase blocked by the previous (sequential dependency chain in the task tracker: #1→#2→#3→#4→#5→#6→#7).

## Task #1 — Phase 1: LocalSendKit Model/ DTOs

Implement Codable DTOs in `Modules/LocalSendKit/Sources/LocalSendKit/Model/`: `DeviceType`, `ProtocolType`, `FileDto`, `FileMetadata`, `RegisterInfo`, `MulticastMessage` (both `announce`+`announcement` keys), `PrepareUploadRequest`/`Response`, `PrepareDownloadResponse`, `InfoResponse`. Custom `CodingKeys`/`RawRepresentable` for camelCase + casing quirks: `ProtocolType` lowercase `"http"`/`"https"`; `DeviceType` SCREAMING_SNAKE_CASE with unknown-value fallback to `.desktop`.

Unit tests: JSON round-trips for all DTOs, enum casing, `FileDto` optional field omission.

**Blocks:** #2

## Task #2 — Phase 2: LocalSendKit Crypto/ cert + fingerprint

Implement `Modules/LocalSendKit/Sources/LocalSendKit/Crypto/`: `CertificateAuthority` (P-256 keypair + self-signed X.509 cert via swift-certificates/swift-crypto, Subject `CN=LocalDrop`, ~10yr validity, DER export), `Fingerprint` (SHA-256 hex of DER, uppercase). Add `swift-certificates` + `swift-crypto` deps to `Modules/LocalSendKit/Package.swift`. Persist cert/key to UserDefaults/app support dir, regenerate only on explicit reset.

Unit tests: valid cert generation, validity window, fingerprint format, reject expired/tampered/pubkey-mismatch certs.

**Blocked by:** #1 · **Blocks:** #3

## Task #3 — Phase 3: LocalSendKit HTTP/Client/

Implement `Modules/LocalSendKit/Sources/LocalSendKit/HTTP/Client/`: `LocalSendClient` (URLSession-based) covering register, prepare-upload, upload, cancel, prepare-download, download, info; `TOFUSessionDelegate` for cert-challenge handling (accept then compare peer cert SHA-256 fingerprint). Build against a fake in-process server/test double since the real server doesn't exist yet.

Unit tests: URL building (http/https, IPv4/IPv6 bracketed host, query param join).

**Blocked by:** #2 · **Blocks:** #4

## Task #4 — Phase 4: LocalSendKit HTTP/Server/

Implement `Modules/LocalSendKit/Sources/LocalSendKit/HTTP/Server/`: `LocalSendServer` (`NWListener` + TLS via `NWParameters` with `sec_protocol_options_set_verify_block` for TOFU), `HTTPRequestParser`, `HTTPResponseWriter`, `Routes/` for register/info/prepare-upload/upload/cancel/prepare-download/download. Wire PIN check, session/token/IP validation per wire-format ground truth in the plan doc (sender IP pinned at prepare-upload, PIN lockout at 3 attempts/IP with 429 boundary behavior, cancel role-asymmetry, reverse-transfer `sessionId`=requester IP).

Unit tests: full edge-case matrix from the plan (upload token/session/IP mismatches, cancel receiver vs sender side, prepare-upload empty/409/403/204 cases, PIN attempt counter boundary, malformed JSON 400).

**Blocked by:** #3 · **Blocks:** #5

## Task #5 — Phase 5: LocalSendKit Session/ state machines

Implement `Modules/LocalSendKit/Sources/LocalSendKit/Session/`: `ReceiveSession` (actor), `SendSession` (actor), `PinAttemptTracker` (actor, per-IP counter). Wire into HTTP/Server routes from Phase 4 (replacing any stubbed state). One active receive-session at a time, mirroring reference.

Unit tests: concurrent access to session/`PinAttemptTracker` actors (no data races, TSan or Swift Testing concurrency stress test).

**Blocked by:** #4 · **Blocks:** #6

## Task #6 — Phase 6: LocalSendKit Discovery/

Implement `Modules/LocalSendKit/Sources/LocalSendKit/Discovery/`: `MulticastListener` (`NWConnectionGroup` + `NWMulticastGroup`, 224.0.0.167:53317), `MulticastAnnouncer` (`NWConnection`, 3x retry at 100/500/2000ms), `LegacyHTTPScanner` (bounded-concurrency subnet register POST fallback).

Unit tests: self-announcement filtered by fingerprint match, TCP-register-first-then-UDP-fallback response path.

**Blocked by:** #5 · **Blocks:** #7

## Task #7 — Phase 7: End-to-end wiring + integration tests

Wire client + server + discovery together in-process on 127.0.0.1/loopback multicast. Integration/e2e tests per plan: full handshake (register→prepare-upload→upload→verify bytes+finished state), PIN-protected transfer (401 then success), cancel mid-transfer both roles, reverse-transfer download with Content-Disposition/Content-Length checks, concurrent multi-file upload, multicast loopback announce/discover round-trip, adversarial malformed-body/409-blocked cases. Run `swift build`/`swift test` in `Modules/LocalSendKit`, then `xcodegen generate` + `xcodebuild -scheme LocalDrop build` to confirm no regression.

**Blocked by:** #6
