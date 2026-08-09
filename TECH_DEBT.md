# LocalDrop — Tech Debt Log

Maintained by the `tech-debt-tracker` agent (see `.claude/agents/tech-debt-tracker.md`). Entries grouped by category, most severe first within each.

Protocol deviations discovered in the LocalSend reference comparison are tracked as numbered
work items in `docs/todo.txt` (items 11-41) rather than duplicated here. This file records debt
that is structural rather than a discrete deviation, plus anything found while implementing.

## Protocol Deviations

### PIN check ordering deviates from the reference (busy receiver returns 401/429 instead of 409)
Severity: notable
`Modules/LocalSendKit/Sources/LocalSendKit/HTTP/Server/LocalSendServer.swift` validates the PIN
BEFORE the session-busy check; the Dart reference (`receive_controller.dart`) checks
`session != null` -> 409 FIRST, then the PIN. Consequence: when LocalDrop is busy AND has a PIN
set, a peer gets 401/429 rather than 409, and a wrong-PIN probe burns attempts against a receiver
that was never going to accept. Found during senior review of item 11 (sender PIN support). Route
to `networking-protocol` when revisited.

### Empty-string configured PIN behaves differently from the reference
Severity: minor
`Modules/LocalSendKit/Sources/LocalSendKit/Session/PinAttemptTracker.swift` guards
`expectedPIN.isEmpty == false` (an empty configured PIN means "no PIN"), where the reference only
checks `pin != null` and would enforce an empty string literally. Cosmetic unless the settings UI
can persist "".

### No client-certificate verification
Severity: low (forward-looking)
The reference has `core/src/http/server/client_cert_verifier.rs` for protocol v3, which moves
toward mandatory client-cert TLS. We neither request nor verify client certificates. Not a
defect against v2, but it is the gap that protocol v3 will turn into a blocker. See
`docs/todo.txt` item 41.

### IPv6 link-local discovery is not implemented (zone-id handling itself is resolved)
Severity: low (IPv6 link-local only)
The zone-id half of this entry is fixed. `NetworkEndpointAddress.canonicalHost(from:)` now
preserves a well-formed `%interface` zone instead of truncating it, applied together in
`Discovery.swift` `remoteHost(from:)` and `LocalSendServerRuntime.swift` `remoteAddress(from:)`.
Measured on macOS (Darwin 25.5.0): `URLComponents` does not reject `%` — it percent-encodes to
RFC 6874 `%25en0` — and `URLSession` honours the zone, so a zoned URL reaches a link-local
listener while the same URL with the zone stripped fails with `NSURLErrorDomain -1009`. Covered
by a live round-trip test in `EndpointHostParsingTests` that asserts both halves. Preserving the
zone on the server side also narrowed the `snapshot.senderIP == senderIP` session-owner check,
which previously collapsed two peers on two interfaces into one identity.

What remains is a missing feature rather than a deviation: discovery joins an IPv4 multicast
group only (`MulticastListenerRuntime.init` / `MulticastAnnouncerRuntime.init` both guard on
`IPv4Address`), so the `.ipv6` branch of `remoteHost(from:)` is not exercised today. Link-local
peers therefore still are not *discovered*, even though a link-local host obtained by other means
is now correctly reachable. Adding the IPv6 multicast join is the follow-up.

One constraint to respect: a zoned host is kernel- and boot-local and does not survive interface
renumbering, so it must never be persisted. `FavoriteDevice` stores no host today; keep it that
way if a peer store is ever added.

## SwiftUI Workarounds

_None logged yet._

## General Debt

### Keychain identity uses the legacy keychain; `kSecAttrAccessible*` is ignored
Severity: notable
`Modules/LocalSendKit/Sources/LocalSendKit/Crypto/KeychainCertificateStore.swift`. The private
key is no longer plaintext JSON (that vulnerability is closed), but `kSecAttrAccessGroup`/
`keychain-access-groups` and `kSecUseDataProtectionKeychain` were deliberately omitted because
the project has no Developer ID Team ID and `project.yml` has no `CODE_SIGN_ENTITLEMENTS`. On the
legacy keychain macOS IGNORES the accessibility class, so the
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` present in the code is future-proofing only and
buys no at-rest guarantee today. Fix when a Team ID exists: add the entitlement +
`kSecUseDataProtectionKeychain`, then the accessibility class becomes enforceable. Also note
ad-hoc-signed local builds may prompt on rebuild because the keychain ACL binds to the signing
identity. Route to `packaging-signing` when revisited.

### Incoming-request/withdrawal ordering is compensated for, not guaranteed
Severity: minor
The request stream and withdrawal stream are consumed by two independent `Task`s. Ordering is
handled by a bounded set of withdrawn request IDs consulted in `handleIncomingRequest`, which is
correct, but the two race tests drive it with `Task.yield()` loops because there is no
observable "withdrawal recorded" state to await. The structurally clean fix is merging both into
one enum-tagged stream so ordering is real rather than compensated. Found during senior review
of backlog item 13. Files: `Application/TransferFeatureStore.swift`,
`Infrastructure/LocalSendRuntimeAdapter.swift`.

### `FavoriteDevice.aliasOverride` is still unreachable
Severity: minor
The model, persistence, and `TransferFeatureStore.displayName(for:)` render path all support an
alias override, but nothing can set it — `toggleFavorite` hardcodes `aliasOverride: nil` and
there is no rename UI. Related: `lastKnownAlias` is written once at star time and never
refreshed. Update: the favorites list this was blocked on now exists (`SettingsView.swift`
favorites section, added this pass) — an explicit product_manager scope decision kept renaming
out of that change as scope creep on a security fix. The only thing left blocking this entry is
the rename UI itself. Files:
`Modules/FeatureTransfer/Sources/FeatureTransfer/Models/FeatureTransferModels.swift`,
`Application/TransferFeatureStore.swift`.

### `QuickSaveMode` copy does not state consent explicitly
Severity: minor (UX)
`QuickSaveMode.menuLabel` English values are off = "Ask Each Time", favorites = "Favorites
Only", on = "Downloads". Since backlog item 13 these modes now control whether the accept prompt
appears at all, but "Downloads" reads as a destination rather than as consent, and "Favorites
Only" reads as a restriction rather than as auto-accept-for-favorites. The Receive screen picker
(`ReceiveView.swift` ~line 33) has no `.help()` and no explanatory footer, unlike
`settings.autoAcceptFavorites`, which has `settings.autoAcceptFavoritesHelp`. Rewriting this copy
means touching all 17 locales in `Localizable.xcstrings`; deferred for a product decision. Found
during senior review of backlog item 13.

### Quick-save / auto-accept help copy does not mention the message carve-out
Severity: minor (UX)
`settings.autoAcceptFavoritesHelp` and the two quick-save help strings in
`Modules/FeatureTransfer/Sources/FeatureTransfer/Resources/Localizable.xcstrings` describe the
toggles without saying that text/message payloads always prompt (see the now-closed "quick-save
does not exempt text/message payloads" fix). Users enabling any of them will see messages still
prompting and may read it as a bug. Copy decision across 3 strings x 17 locales — needs
`product_manager`.

### `ReceiveSession.upload` performs file I/O inside the actor
Severity: minor
`Modules/LocalSendKit/Sources/LocalSendKit/Session/TransferSessions.swift`. The stage step runs
inline in a synchronous actor method, blocking progress updates, `snapshot()`, and the state
observer for its duration. The same-volume atomic rename introduced by the staging-area fix makes
this near-instant in the normal case, so the severity dropped, but the pattern is still wrong.
Route to `performance-memory`.

### `loadOrCreateIdentity` throws on an expired certificate instead of regenerating
Severity: minor
`Modules/LocalSendKit/Sources/LocalSendKit/Crypto/CertificateAuthority.swift`. `validate` throws
`.expiredCertificate` and `LocalSendNode.init` propagates it, so the runtime fails to start with
no recovery path. Certs are issued for 10 years so this is far off, but there is no user-visible
recovery.

### Collision resolution is prepare-time only, with no cross-process guard
Severity: minor
`Modules/LocalSendKit/Sources/LocalSendKit/Session/TransferSessions.swift`. Sequential sessions
racing on the same filename are safe, but a second LocalDrop instance sharing the same save
folder has no guard. Out of scope for the mangled-filename and staging-junk fixes.

### Live-runtime receive-cancel tests are order-dependent and flaky
Severity: minor (test infrastructure, not product code)
`Modules/FeatureTransfer/Tests/FeatureTransferTests/FeatureTransferTests.swift`, the
`makeLiveReceiveFixture` group (`testUserCancelOfAnInboundTransfer…`,
`testCancelingTheSameInboundTransferTwice…`, `testFailingCancelNotification…`). Each fixture binds
a real loopback HTTP server and joins the real multicast group, so several fixtures alive in one
test process interfere: the sender-notification assertions (`sent.count == 1`) intermittently see
0, and the failing set changes between runs. Every one of them passes in isolation.
**Pre-existing** — verified by running the same filter and the full suite against the pre-change
baseline (`0e952c7`) in a separate worktree, where `testCancelingTheSameInboundTransferTwice…`
fails identically (alongside an unrelated `testSendViewResolvesDropZoneLabelText`). Not introduced
by the discovery/protocol backlog batch. Fix direction: give each fixture an isolated multicast
group/port (as `DiscoveryRuntimeCoverageTests.makeTestPort` already does) and tear the node down
deterministically before the next fixture starts, rather than relying on `defer`.

### Client-side v1 targeting is limited to the `/register` reply
Severity: minor (interop, sender side only)
`Modules/LocalSendKit/Sources/LocalSendKit/HTTP/Client/LocalSendClient.swift`. The v1 route work
made LocalDrop a correct v1 *server* (`send-request`/`send`/`cancel` are served), and
`register(with:to:apiVersion:)` targets the v1 path when replying to a v1 peer's announcement.
LocalDrop initiating a *transfer* to a v1-pinned peer still posts to the v2 paths and would 404.
The reference picks the path from `target.version` for every route (`ApiRoute.target`). Fix
direction: carry the peer's protocol version on `RemotePeer` and derive the prefix per request,
plus decode the bare `{fileId: token}` v1 prepare-upload response shape on the client side.
