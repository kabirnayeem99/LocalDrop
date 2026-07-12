# LocalSendKit

LocalSendKit is a pure-Swift package that implements the LocalSend protocol v2.1. It handles identity, discovery, HTTP server, HTTP client, transfer sessions, and TLS. It has no UI dependency and targets macOS 14+.

See the protocol spec: [LocalSend Protocol v2.1](./LocalSend-Protocol.md).

## Responsibilities

- Generate and store a self-signed P-256 identity.
- Compute the device fingerprint from the certificate.
- Discover peers on the local network with UDP multicast.
- Run an HTTP or HTTPS server on a TCP port.
- Call the LocalSend HTTP API on remote peers.
- Manage upload and download sessions, file tokens, and PIN gating.
- Stream files to and from disk without loading them entirely in memory.

## Architecture

LocalSendKit is organized into six layers.

| Layer | Directory | Purpose |
|-------|-----------|---------|
| Constants | `Sources/LocalSendKit` | Protocol version and API prefix. |
| Models | `Sources/LocalSendKit/Model` | Codable DTOs exchanged with peers. |
| Crypto | `Sources/LocalSendKit/Crypto` | Identity generation, certificate storage, fingerprint, validation. |
| Discovery | `Sources/LocalSendKit/Discovery` | UDP multicast beaconing and listening. |
| HTTP | `Sources/LocalSendKit/HTTP` | HTTP types, parser, writer, server, and client. |
| Network Runtime | `Sources/LocalSendKit/NetworkRuntime` | TCP/TLS listener, TLS configuration, and the orchestrator node. |
| Session | `Sources/LocalSendKit/Session` | Transfer session state machines and PIN rate limiting. |

## Entry Point

`LocalSendNode` is the public facade. Construct it with a runtime configuration, certificate store, and optional logger, then call `start()`.

```swift
let node = LocalSendNode(
    runtimeConfiguration: configuration,
    certificateStore: FileCertificateStore(...),
    logger: logger
)
await node.start()
```

Key methods:

- `start()` / `stop()`
- `announce()`
- `discoverPeers()` -> `AsyncStream<DiscoveredPeer>`
- `observeRuntime()` -> `AsyncStream<LocalSendRuntimeSnapshot>`
- `incomingTransferRequests()` -> `AsyncStream<IncomingTransferRequest>`
- `respondToIncomingTransfer(requestID:decision:)`
- `makeClient(host:port:protocolType:fingerprint:)` -> `LocalSendClient`

## File Reference

### Constants

- `LocalSendKit.swift`: exposes `protocolVersion` (`"2.0"`) and `apiPrefix` (`"/api/localsend/v2"`).

### Models

- `ProtocolModels.swift`: all Codable DTOs.
  - `DeviceType`, `ProtocolType`
  - `RegisterInfo`: device identity returned by `/register` and `/info`.
  - `MulticastMessage`: UDP beacon payload.
  - `FileDto`, `FileMetadata`: file metadata used in preparation requests.
  - `PrepareUploadRequest`, `PrepareUploadResponse`: upload handshake.
  - `PrepareDownloadResponse`: download handshake.
  - `InfoResponse`: legacy debug info response.

### Crypto

- `CertificateAuthority.swift`: generates and stores the P-256 self-signed X.509 identity. `CertificateAuthority.loadOrCreateIdentity()` returns a `LocalIdentity`. `FileCertificateStore` persists the identity on disk. `CertificateAuthority.validate(...)` checks certificate validity and self-signature.
- `Fingerprint.swift`: computes the device fingerprint as the upper-case hex SHA-256 hash of the certificate DER.

### Discovery

- `Discovery.swift`: contains every discovery primitive.
  - `MulticastListenerRuntime`: joins `224.0.0.167:53317` and decodes incoming UDP beacons.
  - `MulticastAnnouncerRuntime`: sends UDP beacons with retries.
  - `LegacyHTTPScanner`: scans a list of IP addresses by calling `POST /api/localsend/v2/register`.
  - `DiscoveryService`: combines listener, announcer, and scanner. Deduplicates peers by fingerprint and exposes an `AsyncStream<DiscoveredPeer>`.

The default multicast address is `224.0.0.167` and the default port is `53317`. Both are configurable through `LocalSendRuntimeConfiguration`.

### HTTP

- `HTTPTypes.swift`: generic request/response model. `HTTPRequestBody` can be `Data` or a file `URL` for streaming.
- `HTTPRequestParser.swift`: parses HTTP/1.1 request lines, headers, and query parameters. Supports keep-alive and content-length framing.
- `HTTPResponseWriter.swift`: serializes responses into HTTP/1.1 wire format.
- `Server/LocalSendServer.swift`: routes LocalSend HTTP requests.
  - `POST /register`
  - `GET /info`
  - `POST /prepare-upload`
  - `POST /upload`
  - `POST /cancel`
  - `POST /prepare-download`
  - `GET /download`
  - PIN checks via `PinAttemptTracker`.
- `Client/LocalSendClient.swift`: high-level API caller. Builds URLs, encodes JSON, sends bodies, and decodes responses.
- `Client/TOFUSessionDelegate.swift`: `URLSessionDelegate` that implements Trust-On-First-Use TLS validation. It accepts any self-signed certificate whose fingerprint matches the expected peer fingerprint.

### Network Runtime

- `LocalSendNode.swift`: composes identity, server, server runtime, discovery service, and client factory. Owns `LocalSendRuntimeStateStore`.
- `LocalSendServerRuntime.swift`: TCP/TLS listener using `Network.framework`. Accepts connections, parses HTTP requests with `HTTPRequestParser`, dispatches to `LocalSendServer`, and writes responses with `HTTPResponseWriter`.
- `LocalSendTLSConfiguration.swift`: builds `NWParameters` for TLS 1.2+ and converts the P-256 private key into the format `SecKeyCreateWithData` expects.
- `LocalSendRuntimeTypes.swift`: shared runtime types, including `IncomingTransferRequestBridge`. This bridge lets the app present an incoming transfer to the user and await a decision asynchronously.

### Session

- `TransferSessions.swift`: state machines for active transfers.
  - `ReceiveSession`: handles one active receive flow. Generates `sessionId` and per-file tokens, stages files to disk, and can defer to `IncomingTransferRequestBridge` for user approval.
  - `SendSession`: handles `/prepare-download` and `/download` for an inventory of `LocalSharedFile`.
- `PinAttemptTracker.swift`: rate-limits PIN attempts per IP. Three failures block further attempts until reset.

## Client Transport

`LocalSendClient` depends on a `LocalSendTransport` protocol.

- `URLSessionTransport`: used in production. Uses `URLSession` with per-request `TOFUSessionDelegate`.
- `InProcessTransport`: used in tests. Routes requests directly to a `LocalSendServer` without network I/O.

## File Streaming

Uploads and downloads are streamed in chunks. Large files are not held entirely in memory. Staged uploads land in the configured `storageDirectory` until the session completes. Downloads are read from disk in 64KB chunks.

## Security Model

- Each device generates a self-signed P-256 certificate with a 10-year validity window.
- The fingerprint is the SHA-256 of the certificate DER.
- HTTPS mode uses TLS 1.2+ with the self-signed certificate.
- The client validates the peer certificate with TOFU: it accepts the certificate if the fingerprint matches and the certificate is self-signed and valid.
- HTTP mode skips TLS. The fingerprint is a random string and is only used to avoid self-discovery.

## Configuration

`LocalSendRuntimeConfiguration` controls runtime behavior:

- `registerInfo`: alias, device model, device type, port, protocol, and download flag.
- `protocolType`: `http` or `https`.
- `tcpPort`, `multicastPort`, `multicastHost`.
- `storageDirectory`: where received files are staged.
- `pin`: optional incoming PIN.
- `uploadPolicy`: auto-accept, ask, or reject.
- `incomingRequestBridge`: async bridge for user approval.
- `downloadInventoryProvider`: supplies files for the download API.
- `allowDownloads`: enables the reverse transfer API.
- `limits`: timeouts and size constraints.
