# UI ↔ LocalSendKit Integration Plan

## Goal

Link the current SwiftUI `FeatureTransfer` shell to the real LocalSend protocol runtime in `LocalSendKit` without collapsing module boundaries or pushing protocol concerns into the view layer.

## Why this plan exists

- `LocalSendKit` already implements discovery, HTTP client/server, crypto, session state, and the runtime facade (`LocalSendNode`).
- `FeatureTransfer` already renders the app shell, but it is still driven by placeholder state, sample peers, and timer-based progress.
- The existing UI port plan explicitly left protocol hookup out of scope; this document is the next step that closes that gap.

## Approved architecture

### Module roles

- `Modules/LocalSendKit`
  - Remains the protocol/infrastructure boundary.
  - Owns discovery, TLS identity, LocalSend wire format, session/token generation, upload/download/cancel, and request validation.
  - Stays SwiftUI-free.
- `Modules/FeatureTransfer`
  - Becomes the feature-level application + presentation layer for send/receive.
  - Owns screen state, UI-facing use cases, view models/stores, protocol-to-UI mapping, and sheet presentation logic.
  - May depend on `LocalSendKit` and `DesignSystem`, but SwiftUI views must depend on feature-facing abstractions, not raw protocol/runtime types.
- `App/LocalDropApp`
  - Owns app-scoped lifecycle only.
  - Creates one long-lived transfer container/store at launch, starts it once, and injects it into `RootView`.
  - Does not host transfer business logic.

### Clean-architecture boundary

- Views talk to a feature store/coordinator API.
- The feature store talks to feature use cases.
- Feature use cases talk to `LocalSendKit` adapters/protocols.
- `LocalSendKit` never calls SwiftUI directly.
- Interactive receive decisions flow back into the protocol layer through an async approval bridge rather than by mutating protocol state inside a sheet.

## Required structural changes

### 1. Replace `TransferViewState` with injected feature state

Current `TransferViewState` is mock UI state. It is too narrow for real LocalSend behavior because the protocol needs:

- a collection of staged items with stable IDs and metadata
- real discovered peers
- active inbound request state
- transfer/session progress for multi-file and parallel upload flows
- protocol-backed error/auth/busy states
- persisted protocol settings separate from cosmetic preferences

Planned split inside `FeatureTransfer`:

- `Presentation/`
  - `RootView`, `ReceiveView`, `SendView`, `HistoryView`, `SettingsView`, sheets, rows
- `Application/`
  - `TransferFeatureStore`
  - `TransferFeatureContainer`
  - `SendFlowCoordinator`
  - `ReceiveFlowCoordinator`
  - `SettingsCoordinator`
- `Application/Models/`
  - `NearbyPeerItem`
  - `StagedTransferItem`
  - `IncomingTransferRequest`
  - `ActiveTransferProgress`
  - `TransferFailureState`
- `Infrastructure/`
  - `LocalSendRuntimeAdapter`
  - `SettingsPersistenceAdapter`
  - `HistoryAdapter` as a stub boundary only

### 2. Move runtime ownership to app scope

`LocalSendNode` must not be created inside a leaf view lifecycle. The app must own one long-lived runtime/container and inject it downward.

Planned app composition:

1. `LocalDropApp` creates `TransferFeatureContainer.live(...)`.
2. `LocalDropApp` passes `container.store` into `RootView`.
3. `LocalDropApp` starts the container once via a scene-level task.
4. The container boots `LocalSendNode`, waits for listener readiness, then announces.
5. Screen switches never recreate the runtime.

This preserves the current package graph while making startup/discovery protocol-correct.

### 3. Add an async receive-approval seam

The protocol requires an accept/reject decision at `prepare-upload`, while the UI already implies an incoming-request sheet.

Planned rule:

- `LocalSendKit` emits an inbound transfer request event containing sender info and proposed files.
- `FeatureTransfer` presents that event as `IncomingRequestSheet`.
- The user decision returns one of:
  - reject
  - accept all
  - accept subset
  - no transfer needed
- `LocalSendKit` keeps session IDs, file tokens, IP pinning, and status transitions internal.

This avoids duplicating session logic in SwiftUI.

## Runtime contracts

### Feature-facing runtime protocol

`FeatureTransfer` should depend on a small protocol, implemented by a `LocalSendKit` adapter:

```swift
protocol TransferRuntime {
    func start() async throws
    func stop() async
    func refreshDiscovery() async
    func discoveredPeers() -> AsyncStream<[NearbyPeerItem]>
    func inboundRequests() -> AsyncStream<IncomingTransferRequest>
    func progressEvents() -> AsyncStream<ActiveTransferProgress>
    func updateSettings(_ settings: TransferProtocolSettings) async throws
    func stage(_ items: [StagedTransferItem])
    func sendStagedItems(to peerID: NearbyPeerItem.ID, pin: String?) async throws
    func respondToIncomingRequest(_ response: IncomingTransferDecision) async throws
    func cancelActiveTransfer(_ id: ActiveTransferProgress.ID) async throws
}
```

Notes:

- The exact type names can change.
- The boundary shape should not: lists/events in, user intents out, no SwiftUI, no raw `LocalSendNode` in views.

### Settings split

Separate settings into:

- `TransferProtocolSettings`
  - device name
  - TCP port
  - require PIN
  - allow downloads
  - encryption mode if mutable
  - save location
- `AppAppearanceSettings`
  - appearance
  - language
  - accent choice
  - reduce motion
  - menu bar behavior

Protocol settings must be persisted outside `TransferViewState` and used to build `RegisterInfo`/runtime configuration.

## Screen wiring plan

### Receive

- Show real local identity from protocol settings/runtime.
- Replace static waiting badge with actual receive availability state.
- Keep `Quick Save` visible as a local UX policy only.
- Do not let `Quick Save` bypass protocol-required approval unless explicitly specified later.

### Send

- Replace sample peers with live discovery results.
- Replace one `stagedFile` with staged item collection.
- Refresh/Scan buttons call discovery refresh, not local mock actions.
- Selecting a peer triggers `prepare-upload`, then upload only accepted files.
- Progress sheet binds to active transfer state, not a timer.

### Incoming request sheet

- Present sender identity and requested files from live inbound request state.
- Accept/decline actions resolve the pending protocol decision.
- Extend later for partial accept if the first MVP keeps full accept/reject only.

### Progress sheet

- Bind to real transfer state.
- Support aggregated progress plus per-file detail when available.
- Cancel must hit the real `/cancel` flow and reconcile final state cleanly.

### Settings

- Protocol-backed controls update persisted transfer settings.
- Define restart/apply behavior explicitly:
  - live-update if safe
  - runtime restart if required for port/identity-affecting settings
- Cosmetic settings stay local to UI/app presentation.

## Delivery phases

### Phase 1. Application seam

- Introduce `TransferFeatureContainer` and `TransferFeatureStore`.
- Convert `RootView` to accept injected store/container-backed state.
- Remove direct construction of placeholder app state in `RootView`.

### Phase 2. App lifecycle ownership

- Have `LocalDropApp` own the live container.
- Start runtime once at scene scope.
- Add shutdown handling for app termination/window closure as needed.

### Phase 3. Discovery and peer list

- Map `DiscoveredPeer` to `NearbyPeerItem`.
- Bind Send peer list and Receive identity state to live runtime streams.
- Implement refresh/reannounce behavior.

### Phase 4. Send flow

- Introduce staged-item collection model.
- Wire selection/drop-zone staging into send use cases.
- Implement `prepare-upload`, accepted-file filtering, upload progress, and cancel.

### Phase 5. Receive flow

- Add inbound request mediation bridge.
- Present/resolve incoming request sheet from live runtime events.
- Handle reject, accept, partial accept, busy/409, and PIN states.

### Phase 6. Settings and persistence

- Add persisted transfer settings store.
- Rebuild runtime configuration from persisted settings.
- Define which changes restart the runtime.

### Phase 7. History and polish

- Keep history behind an adapter boundary first.
- Do not expand into favorites/trusted devices/browser-download UX in the same slice.

## Test plan

### FeatureTransfer tests

- `RootView` works with a fake runtime/store.
- Discovery stream updates peer list without recreating the runtime.
- Incoming request sheet opens from runtime events.
- Send flow handles accepted subset only.
- Progress sheet reflects real progress state and cancel intent.
- Busy/blocked, auth failure, and rate-limit states are visible.

### Integration tests

- App lifecycle: `start -> waitUntilReady -> announce` happens once per launch.
- Runtime survives screen changes.
- Incoming request mediation covers reject, accept all, partial accept, and busy session.
- Send flow covers multi-file staging, partial acceptance, parallel upload aggregation, and cancel.
- Settings persistence preserves certificate-backed identity and applies restart semantics correctly.

## Task routing

### Completed planning subagents

- `product_manager`
  - Defined scope, acceptance criteria, and protocol-visible UX rules.
- `senior_engineer`
  - Rejected the naive “data-source swap” approach and forced the lifecycle/injection/receive-mediation corrections above.

### Next implementation assignments

1. `engineer`
   - Phase 1 and Phase 2
   - Ownership: `App/LocalDropApp`, `Modules/FeatureTransfer/Sources/FeatureTransfer/Application/*`, `RootView` injection path
2. `engineer`
   - Phase 3 and Phase 4
   - Ownership: send/discovery state mapping, staged-item model, progress wiring
3. `engineer`
   - Phase 5 and Phase 6
   - Ownership: incoming request mediation, protocol settings persistence, restart/apply behavior
4. `tester`
   - Add fake-runtime feature tests and app lifecycle/integration coverage from the matrix above
5. `senior_engineer`
   - Single review pass after implementation; no fix loop unless explicitly requested

## Non-goals

- No AppKit-first UI rewrite.
- No new reverse-download browser UX in this slice.
- No favorites/trusted-device auto-accept implementation in this slice.
- No transfer-history persistence in this slice.

## Exit criteria

This plan is complete when:

- app-scoped runtime ownership is explicit
- `FeatureTransfer` has an injected application seam
- send/receive/progress/settings are defined against real protocol-backed state
- test requirements cover lifecycle, discovery, send, receive, cancel, and settings behavior
