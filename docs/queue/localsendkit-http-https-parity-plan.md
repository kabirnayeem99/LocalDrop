# LocalSendKit HTTP/HTTPS Parity Plan

## Goal

Add upstream-compatible HTTP/HTTPS runtime selection to `LocalSendKit`, then expose it safely through LocalDrop settings only after the runtime is fully implemented and covered by tests.

## Upstream verification

This feature exists in `localsend-main-app` and is not just copy or placeholder UI.

- `SettingsState` persists `https` in `app/lib/model/state/settings_state.dart`.
- `settingsProvider.setHttps(...)` updates it in `app/lib/provider/settings_provider.dart`.
- The settings UI toggles it in `app/lib/pages/tabs/settings_tab.dart`.
- The server runtime switches between `ProtocolType.https` and `ProtocolType.http`, and binds either `HttpServer.bindSecure` or `HttpServer.bind`.

Conclusion:

- Do not skip this feature on “missing upstream support” grounds.
- Do treat this as a `LocalSendKit` runtime project first, not a `FeatureTransfer` UI task.

## Compatibility constraint

The LocalDrop implementation must match upstream behavior closely enough that:

- discovery advertises the selected protocol correctly,
- server lifecycle responds to protocol changes,
- send/download clients select the correct transport,
- mixed-protocol device behavior is explicit and tested,
- disabling encryption does not silently keep TLS active anywhere in the stack.

The plan should follow upstream behavior, but only where it maps coherently to this Swift runtime. If an upstream behavior depends on Flutter/Dart-specific infrastructure, re-express the behavior at the protocol/runtime level rather than mirroring implementation details.

## Current LocalDrop blocker state

`FeatureTransfer` already stores `endToEndEncryption`, but `LocalSendKit` is effectively HTTPS-only:

- `TransferFeatureContainer` hardcodes `protocolType: .https`.
- `LocalSendNode` always builds `LocalSendServerRuntime` with `LocalSendTLSConfiguration`.
- `LocalSendServerRuntime` always reports `.https` from its bound endpoint.
- certificate and fingerprint handling assume TLS is always present.

Because of that, enabling the setting in UI without runtime work would still be misleading.

## Scope

### In scope

- `LocalSendKit` runtime protocol selection
- HTTP-mode listener/client support
- discovery/register-info protocol parity
- compatibility with the checked-in `localsend-main-app` behavior
- app-layer wiring from `TransferProtocolSettings` to runtime selection
- test expansion to full coverage for the runtime module

### Out of scope

- changing unrelated `FeatureTransfer` UX beyond the encryption setting flow
- inventing a new security model different from upstream unless the Swift runtime makes it necessary
- reducing coverage goals or excluding branches to make the work easier

## Implementation plan

### Phase 1: Define the runtime configuration surface

Add explicit protocol selection to `LocalSendRuntimeConfiguration`.

Recommended shape:

- add `protocolType: ProtocolType`
- derive TLS behavior from `protocolType == .https`

Why:

- `ProtocolType` already exists in `ProtocolModels.swift`
- upstream models this as a first-class settings value
- this keeps the runtime API aligned with discovery, peer transport, and server startup

Files:

- `Modules/LocalSendKit/Sources/LocalSendKit/NetworkRuntime/LocalSendNode.swift`
- `Modules/LocalSendKit/Sources/LocalSendKit/NetworkRuntime/LocalSendRuntimeTypes.swift` if shared runtime state/errors need expansion

### Phase 2: Split secure and insecure server startup paths

Refactor `LocalSendServerRuntime` so it can bind either:

- TLS listener parameters for `.https`
- plain TCP parameters for `.http`

Required changes:

- carry selected protocol into `LocalSendServerRuntime`
- stop hardcoding `.https` in `resolvedEndpoint(...)`
- introduce a plain listener-parameter builder
- keep the existing TLS codepath intact for `.https`

Design note:

- avoid bolting conditional branches everywhere onto `LocalSendTLSConfiguration`
- keep a clean runtime abstraction such as:
  - `makeListenerParameters(for: protocolType)`
  - or a small strategy wrapper for secure vs insecure transport

Files:

- `Modules/LocalSendKit/Sources/LocalSendKit/NetworkRuntime/LocalSendServerRuntime.swift`
- `Modules/LocalSendKit/Sources/LocalSendKit/NetworkRuntime/LocalSendTLSConfiguration.swift`

### Phase 3: Make client transport work for both protocols

Verify and adjust `LocalSendClient` / transport behavior so:

- `.https` uses the current certificate-validation path
- `.http` skips TLS setup and fingerprint trust enforcement appropriately

Key decision:

- in HTTP mode, fingerprint cannot be a TLS trust primitive
- decide whether it remains only an identity field from protocol metadata or is ignored for transport validation

Recommended compatibility rule:

- preserve upstream semantics: HTTP mode disables transport encryption and certificate trust
- keep fingerprint in discovery/register payloads if protocol requires it, but do not treat it as a transport-level verifier in HTTP mode

Files:

- `Modules/LocalSendKit/Sources/LocalSendKit/HTTP/Client/LocalSendClient.swift`
- any URL/session transport implementation used by `LocalSendClient`
- `Modules/LocalSendKit/Sources/LocalSendKit/NetworkRuntime/LocalSendNode.swift`

### Phase 4: Align discovery and runtime state with selected protocol

Ensure the chosen protocol flows through:

- `RegisterInfo.protocolType`
- multicast announcements
- discovered peer records
- runtime snapshots and bound endpoints

Required outcomes:

- HTTP server announces `.http`
- HTTPS server announces `.https`
- callers consuming `DiscoveredPeer` receive the correct protocol for client creation

Files:

- `Modules/LocalSendKit/Sources/LocalSendKit/Discovery/Discovery.swift`
- `Modules/LocalSendKit/Sources/LocalSendKit/NetworkRuntime/LocalSendNode.swift`
- `Modules/LocalSendKit/Sources/LocalSendKit/Model/ProtocolModels.swift`

### Phase 5: Port the upstream behavior into app-layer settings

Only after runtime support is complete:

- rename or remap `endToEndEncryption` to an explicit protocol/HTTPS setting at app level
- wire `TransferProtocolSettings` through `TransferFeatureContainer`
- update `SettingsView` copy to match upstream semantics more precisely

Recommended direction:

- replace `endToEndEncryption: Bool` with a protocol-facing setting name that matches reality, such as `useHTTPS` or `transportEncryptionEnabled`
- keep migration compatibility for already-saved settings

Files:

- `Modules/FeatureTransfer/Sources/FeatureTransfer/Models/FeatureTransferModels.swift`
- `Modules/FeatureTransfer/Sources/FeatureTransfer/Application/TransferFeatureStore.swift`
- `Modules/FeatureTransfer/Sources/FeatureTransfer/Application/TransferFeatureContainer.swift`
- `Modules/FeatureTransfer/Sources/FeatureTransfer/SettingsView.swift`

### Phase 6: Define mixed-protocol behavior explicitly

Add and document compatibility rules for:

- HTTP sender -> HTTP receiver
- HTTPS sender -> HTTPS receiver
- HTTP sender -> HTTPS receiver
- HTTPS sender -> HTTP receiver

Recommended rule set:

- same-protocol peers are supported
- mixed-protocol peers are either:
  - filtered out during connection attempts with deterministic errors, or
  - supported only if the protocol payload and client/server logic genuinely allow it

Do not leave this implicit.

### Phase 7: Reach 100 percent test coverage for `LocalSendKit`

Assumption:

- the user’s `@LocalDropKit` reference means the runtime module here, which is `LocalSendKit`

Coverage target:

- 100 percent line coverage for `Modules/LocalSendKit`

Required work:

- enable code coverage in the package test run
- measure current gaps before adding tests
- port upstream-relevant encryption/protocol tests into Swift equivalents
- add direct unit tests for any remaining uncovered branches instead of weakening logic

Verification command baseline:

- `swift test --package-path Modules/LocalSendKit --enable-code-coverage`

Coverage inspection:

- use `xcrun llvm-cov` against the produced `.xctest` bundle to identify uncovered runtime branches

### Phase 8: Port upstream tests conceptually, not mechanically

“Add all tests from main app” should be interpreted as:

- port every upstream behavior relevant to the HTTP/HTTPS feature into Swift-runtime tests
- not copy Flutter widget/provider tests that are tied to Riverpod or Dart UI plumbing

Port these behavior groups:

- persisted protocol setting changes server protocol
- server restart/start logic reflects protocol changes
- discovery advertises HTTP vs HTTPS correctly
- send path chooses the right protocol for remote peers
- insecure mode works end to end without TLS
- secure mode still validates certificates/fingerprints
- disabling encryption triggers the expected warning semantics at app level

### Phase 9: Add new runtime tests for coverage gaps not present upstream

Expect new Swift-only tests for:

- `LocalSendServerRuntime` HTTP branch startup, ready-state, shutdown, and endpoint reporting
- `LocalSendNode` announce/discover in HTTP mode
- `LocalSendClient` HTTP transport behavior and no-TLS request path
- certificate-validation bypass behavior for HTTP mode
- mixed-protocol failure paths
- snapshot/state transitions after protocol changes
- any branch-specific guards in parser, runtime, and connection code that upstream tests do not touch

## Test plan by file

### Existing test files to extend

- `Modules/LocalSendKit/Tests/LocalSendKitTests/IntegrationTests.swift`
- `Modules/LocalSendKit/Tests/LocalSendKitTests/NetworkRuntimeCoverageTests.swift`
- `Modules/LocalSendKit/Tests/LocalSendKitTests/DiscoveryRuntimeCoverageTests.swift`
- `Modules/LocalSendKit/Tests/LocalSendKitTests/ClientAndSessionCoverageTests.swift`
- `Modules/LocalSendKit/Tests/LocalSendKitTests/ServerTests.swift`

### New test files likely needed

- `ProtocolSelectionTests.swift`
- `HTTPModeRuntimeTests.swift`
- `MixedProtocolCompatibilityTests.swift`
- `SettingsMigrationProtocolTests.swift` if app-layer migration expands significantly

## Suggested implementation order

1. Add runtime protocol selection to `LocalSendRuntimeConfiguration`.
2. Refactor `LocalSendServerRuntime` to support HTTP and HTTPS binding.
3. Adjust `LocalSendClient` / transport behavior for HTTP mode.
4. Thread selected protocol through discovery, announce, and discovered peers.
5. Add same-protocol and mixed-protocol runtime tests.
6. Port upstream behavior-level tests related to the encryption toggle.
7. Run coverage, identify gaps, and add direct branch tests until `LocalSendKit` reaches 100 percent.
8. Only then wire the app-level setting in `FeatureTransfer`.
9. Add final app integration tests for settings -> runtime restart -> protocol behavior.

## Risks

- fingerprint and certificate assumptions are currently intertwined; HTTP mode must not accidentally keep partial TLS-only invariants
- discovery and peer state may appear compatible before actual request transport is compatible
- mixed-protocol support can silently fail if connection attempts do not surface deterministic errors
- 100 percent coverage may require targeted tests for obscure error branches in network code and parser/runtime glue

## Definition of done

- `localsend-main-app` parity for the encryption/HTTPS feature is represented at the protocol/runtime level
- `LocalSendKit` can run in both `.http` and `.https` modes intentionally
- app settings no longer present a no-op toggle
- `LocalSendKit` reaches 100 percent coverage with package tests
- app-level tests prove the setting changes effective runtime behavior

## Verification

- `swift test --package-path Modules/LocalSendKit --enable-code-coverage`
- coverage report inspection with `xcrun llvm-cov`
- `swift test --package-path Modules/FeatureTransfer`
- `xcodegen generate`
- targeted `xcodebuild` app/UI tests once the setting is wired through
