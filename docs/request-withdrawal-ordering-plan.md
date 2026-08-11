# Plan: make incoming-request / withdrawal ordering structural

Closes `docs/todo.txt` item 48 and the matching `TECH_DEBT.md` entry
("Incoming-request/withdrawal ordering is compensated for, not guaranteed").

## 1. Problem restated precisely

Three hops carry "a request arrived" and "that request was withdrawn" from the HTTP server to
the UI, and **every** hop fans the two facts out over two independent `AsyncStream`s consumed by
two independent `Task`s:

| Hop | Request path | Withdrawal path |
| --- | --- | --- |
| `IncomingTransferRequestBridgeState` | `requestContinuations` | `withdrawalContinuations` |
| `LocalSendNode` | `incomingTransferRequests()` | `incomingTransferRequestWithdrawals()` |
| `LocalSendRuntimeAdapter` | `incomingObservationTask` → `incomingBroadcaster` | `withdrawalObservationTask` → `withdrawalBroadcaster` |
| `TransferFeatureStore` | `observationTasks[1]` → `handleIncomingRequest` | `observationTasks[2]` → `withdrawIncomingRequest` |

Ordering is then reconstructed at the last hop by a bounded side table
(`withdrawnRequestIDs`, `maxTrackedWithdrawnRequestIDs = 32`, `rememberWithdrawal` /
`consumeWithdrawal`). It works, but it is a compensation, and it is untestable without
`Task.yield()` spin loops because no observable state says "the withdrawal has been recorded".

### The key structural fact (source ordering is already total)

At the origin the two events are **already** strictly ordered, and cannot be otherwise:

- `IncomingTransferRequestBridgeState.awaitDecision(for:)` yields the request to
  `requestContinuations` and *then*, in the same actor-isolated step with no suspension in
  between, registers `decisionContinuations[request.id]`.
- `withdraw(requestID:)` is a no-op returning `false` unless
  `decisionContinuations.removeValue(forKey: requestID)` finds that entry.
- One layer up, `TransferSessions.withdrawPendingRequest(senderIP:incomingRequestBridge:)`
  additionally requires a non-nil `pendingRequest` whose `senderIP` matches, and that
  `pendingRequest` is only set by the `/prepare-upload` path that produced the request.

So a withdrawal for request `X` can only ever be emitted *after* `X` was emitted. **There is no
genuine out-of-order source event.** The only reordering in the system is the artificial one
introduced by the two-stream fan-out. That makes this a pure plumbing fix, not a semantics fix,
and it is why the side table can be deleted rather than merely hidden.

## 2. Reference implementation (LocalSend Dart/Flutter)

Findings from the `networking-protocol` specialist's reading of `localsend-main-app`. The Dart
`ReceiveController` is the authoritative receiver behaviour (the newer Rust core server mis-wires
`POST /v2/cancel` to `controller::v2::register` at `core/src/http/server/mod.rs:290-300` and is
not a source of truth).

**There is no distinct "withdraw" message.** One route does double duty:
`POST /api/localsend/{v1,v2}/cancel?sessionId=<id>`, no body, response ignored
(`common/lib/api_route_builder.dart:11`, `core/src/http/client/v2.rs:252-272`). No cancel DTO
exists anywhere in `common/lib/model/dto/` — the query string is the whole message.

**Cancel does explicitly cover the still-pending case.** `_cancelHandler`
(`app/lib/provider/network/server/controller/receive_controller.dart:638-715`) permits
`SessionStatus.waiting`, and for v2 deliberately *waives* the `sessionId` match while waiting
(`:657`, comment: "require session id for v2 / don't require it when during waiting state"),
because a sender still blocked on the prepare-upload response does not know the sessionId yet.
Identity then rests on source IP alone (`:651`). Unmatched cancels get `403 No permission` and are
**silently forgotten** — no tombstone, no pending-withdrawal set. LocalDrop already mirrors all of
this in `LocalSendServer`'s cancel route and `TransferSessions.withdrawPendingRequest`, whose
comments cite the same line numbers.

**The receiving side is one serialized state holder, not two listeners.**
`ServerUtils.setState` is a synchronous closure over a single nullable `session` field
(`app/lib/provider/network/server/server_provider.dart:64`), and `SimpleServer` dispatches every
request on one Dart isolate (`app/lib/util/simple_server.dart:15-23`). Registration
(`receive_controller.dart:232-260`) and withdrawal (`:851`) are two synchronous mutations of that
same field. "Awaiting user decision" is not a separate machine — it is a suspended `await` on
`session.responseHandler` inside the prepare-upload handler (`:231`, awaited `:346`). The UI is a
derived provider watching that one field.

**Can a withdrawal precede its request there?** Not as a processable event. Two independent
reasons: (a) the reference *sender* never emits one — `remoteSessionId` is only set from the
prepare-upload response, and `cancelSession` returns early with a local-only close when it is nil
(`send_provider.dart:508-519`), so cancelling while the peer's dialog is up produces zero wire
traffic; (b) if some other client does send one early, it sees `session == null`, falls through to
the send-session branch, and is dropped with 403. After registration, ordering is structural
because `setState` is synchronous and single-isolate.

**No protocol-level ordering requirement.** `wiki/LocalSend-Protocol.md` §4.3 specifies only the
route, the sessionId source, and an empty body. Everything above is reference *implementation
convention*, not spec.

### What this settles for our design

1. The reference's guarantee comes from **single state, single serialized consumer** — exactly the
   shape the tech-debt log proposes and the opposite of a compensating side table. The enum-tagged
   stream is the reference-aligned fix; no better alternative surfaced.
2. Our source-ordering argument in §1 is the same argument that holds in the reference, arrived at
   independently. The side table compensates for a case neither implementation can produce.
3. The specialist flags the interop risk in the *current* design directly: modelling the two facts
   as independent async consumers manufactures an out-of-order case the reference never has to
   survive, and whose correct handling the spec does not define. Removing the two-consumer split
   removes an unspecified behaviour, it does not add one.
4. Explicitly **out of scope** here (noted, not fixed): the reference leaves the pending
   prepare-upload request dangling on a withdrawal (its own
   `// TODO: cancel incoming requests`, `receive_controller.dart:820`). Our `withdraw` resolves
   the awaiting decision with `.reject` and answers 403, which is already better and is unchanged
   by this plan.

## 3. Design

One ordered event stream per hop, all the way down. The enum lives in `LocalSendKit` next to the
bridge, because the ordering guarantee has to start where the events are produced — merging only
at the store or only at the adapter leaves an unordered hop above it and fixes nothing.

### 3.1 `LocalSendKit` — the bridge

Add to `NetworkRuntime/LocalSendRuntimeTypes.swift`:

```swift
public enum IncomingTransferRequestEvent: Sendable {
    case request(IncomingTransferRequest)
    case withdrawal(requestID: String)
}
```

`IncomingTransferRequestBridgeState` collapses `requestContinuations` and
`withdrawalContinuations` into a single `eventContinuations: [UUID: AsyncStream<IncomingTransferRequestEvent>.Continuation]`.

- `events()` replaces `requests()` and `withdrawals()`. Replay behaviour is preserved exactly:
  a new subscriber still receives `activeRequest` (as `.request`) if one is pending, and
  withdrawals are still never replayed — which falls out naturally, since only `activeRequest`
  is retained.
- `awaitDecision(for:)` yields `.request(request)`; `withdraw(requestID:)` yields
  `.withdrawal(requestID:)` — same call sites, same order, now the same continuation set, so the
  order is preserved for every subscriber.
- `finishPending(decision:)` finishes and clears the one set instead of two. The existing
  invariant that `withdraw` must **not** touch the event continuations (documented at
  `withdraw`) is unchanged and load-bearing: finishing them would permanently kill the app's
  prompt stream.

`IncomingTransferRequestBridge.requests()` / `.withdrawals()` are **removed** rather than kept as
derived filters. A derived `requests()` would have to be a second continuation set or a filtered
wrapper consumed by its own task — either way reintroducing exactly the hop we are deleting. Both
are internal-to-repo API with four call sites (`LocalSendNode.swift:344`, `:356`;
`InteropFixesTests.swift:240`, `:326`), so there is no external contract to preserve.

One property to be precise about: the merge guarantees **ordering**, not **delivery**. With
`cache: false`, an event yielded while no subscriber is attached is dropped (§5.6). That does not
resurrect the reordering case — a dropped `.request` paired with a delivered `.withdrawal` is
benign, since a withdrawal with no matching displayed prompt is ignored by design.

### 3.2 `LocalSendKit` — the node

`LocalSendNode.incomingTransferRequests()` and `incomingTransferRequestWithdrawals()` are
replaced by:

```swift
public func incomingTransferRequestEvents() async -> AsyncStream<IncomingTransferRequestEvent>
```

Same nil-bridge fallback (an immediately-finished stream).

### 3.3 `FeatureTransfer` — the runtime protocol

`Infrastructure/TransferRuntime.swift`: replace the two requirements

```swift
func inboundRequests() async -> AsyncStream<IncomingTransferRequest>
func inboundRequestWithdrawals() async -> AsyncStream<String>
```

with

```swift
func inboundRequestEvents() async -> AsyncStream<InboundRequestEvent>
```

where `InboundRequestEvent` is the FeatureTransfer-level enum (declared next to
`IncomingTransferRequest` in the feature's model file, since it carries the *feature's*
`IncomingTransferRequest`, which is a different type that merely shares the name with the kit's):

```swift
enum InboundRequestEvent: Sendable {
    case request(IncomingTransferRequest)
    case withdrawal(requestID: String)
}
```

The enum is declared **`Equatable`** as well as `Sendable` (every neighbouring type in both files
is), so tests can assert on whole events with `XCTAssertEqual` / `#expect` instead of unwrapping
associated values. Both enums synthesize `Sendable` automatically because
`IncomingTransferRequest` is already `Sendable` on both sides (`LocalSendRuntimeTypes.swift:59`,
`Models/FeatureTransferModels.swift:179`).

The FeatureTransfer-level enum is **not** a gratuitous duplicate: the adapter maps kit types to
feature types at `LocalSendRuntimeAdapter.swift:1036-1046`, and the two modules have different
types that merely share the name `IncomingTransferRequest`, so the feature-side stream must carry
the feature's type. It lives in `Models/FeatureTransferModels.swift` next to
`IncomingTransferRequest` (not in `TransferRuntime.swift` — it is a model, and the protocol file
only references it).

Conformances to update — all four, exhaustively:

1. `LocalSendRuntimeAdapter` (`Infrastructure/LocalSendRuntimeAdapter.swift:23`)
2. `NoopTransferRuntime` (`Application/TransferFeatureContainer.swift:593`)
3. `FakeTransferRuntime` (`Tests/.../FeatureTransferTests.swift:4858`)
4. **`makeLiveReceiveFixture`'s `acceptTask`** (`Tests/.../FeatureTransferTests.swift:2265`) — not a
   conformance but a direct consumer of `adapter.inboundRequests()`. It currently blind-accepts
   every element it receives. After the merge it **must** switch on the case and accept only
   `.request`, ignoring `.withdrawal`; otherwise it would call
   `respondToIncomingRequest(.acceptAll(requestID:))` with a withdrawn request's ID. Missing this
   both fails to compile and, if ported naively, silently corrupts the live receive-cancel
   fixtures.

### 3.4 `FeatureTransfer` — the adapter

`LocalSendRuntimeAdapter`:

- `incomingBroadcaster` + `withdrawalBroadcaster` → one
  `StreamBroadcaster<InboundRequestEvent>`; `withdrawalObservationTask` is deleted and
  `incomingObservationTask` becomes the single `inboundEventObservationTask` iterating
  `node.incomingTransferRequestEvents()` and switching on the case.
- Both cases keep `cache: false`. This is why the existing `cache: false` comment matters: a
  cached event replayed to a later subscriber would re-accept an already-resolved request. Same
  reasoning, unchanged.
- Both existing log lines are preserved verbatim — `transfer.incoming.request_received` on
  `.request`, `transfer.incoming.request_withdrawn` on `.withdrawal` — including their
  attributes, so log-shape assertions and field names do not move.
- `stop()`/teardown loses one `cancel()`/`nil` assignment; nothing else changes.

### 3.5 `FeatureTransfer` — the store

`bindRuntimeStreamsIfNeeded()` collapses its two request-related tasks into one:

```swift
Task { [weak self] in
    guard let self else { return }
    let stream = await self.runtime.inboundRequestEvents()
    for await event in stream {
        switch event {
        case .request(let request):    self.handleIncomingRequest(request)
        case .withdrawal(let id):      self.withdrawIncomingRequest(id: id)
        }
    }
}
```

Deletions, now that ordering is structural:

- `withdrawnRequestIDs`, `maxTrackedWithdrawnRequestIDs`, `rememberWithdrawal(id:)`,
  `consumeWithdrawal(id:)` and the `consumeWithdrawal` early-return block at the top of
  `handleIncomingRequest`.
- The `transfer.incoming.withdrawn_before_arrival` log event, which becomes unreachable.

`withdrawIncomingRequest(id:)` keeps its `guard incomingRequest?.id == id else { return }`, but
the `else` branch is now a plain ignore instead of `rememberWithdrawal(id:)`. That guard is still
required and is *not* a compensation — it is the legitimate "withdrawal for a request that is no
longer the displayed one" case, covered by the existing
`testWithdrawalForAStalePromptIsIgnored`, and it also covers a withdrawal arriving for a request
that was auto-accepted (never displayed).

**No bounded fallback is retained.** Keeping one would keep the debt while adding dead code: with
a single ordered stream a withdrawal cannot precede its request, so the table could only ever be
written and never read.

### 3.6 Stale comments that must be rewritten, not just deleted

Three comment blocks currently argue *against* this change and would otherwise leave the codebase
asserting the opposite of its own design:

- `LocalSendRuntimeTypes.swift:146-152` — "deliberately a *second, additive* stream rather than an
  event enum on `requests()`". Replace with the ordering rationale: one continuation set is what
  makes request-before-withdrawal hold for every subscriber.
- `LocalSendNode.swift:351-353` — "Additive to `incomingTransferRequests()` so that stream's
  element type — and every consumer of it — is untouched."
- `TransferRuntime.swift:73-76` — same "Additive to `inboundRequests()`" claim.

The `withdraw(requestID:)` comment at `LocalSendRuntimeTypes.swift:221-229` **stays** (adjusted for
one set instead of two): it documents the still-load-bearing invariant that `withdraw` must not
*finish* the event continuations.

### 3.7 Scope guard

Untouched: everything else in both files, all UI, all of `DesignSystem`, the send path, the
progress pipeline, discovery. No SwiftUI change is needed (the sheet is already derived from
`incomingRequest`) and no AppKit is introduced. `LocalSendKit` stays UI-framework-free — the new
enum imports nothing beyond what the file already imports.

## 4. Tests

### 4.0 Two fixture facts that dictate the whole test design

Both were established by adversarial review of an earlier draft of this plan, which got them
wrong. They are the reason the tests below look the way they do.

**(a) `start()` does not attach the subscriber.** `TransferFeatureStore.start()` (`:227`) calls
`bindRuntimeStreamsIfNeeded()`, which only *creates* the tasks (`:1206-1243`); each subscription
happens asynchronously inside its task body. The suite already documents this at
`FeatureTransferTests.swift:39-41` ("Let every observer actually reach its `for await` …"). So
after `await store.start()` the store is **not** yet listening.

**(b) `TestBroadcaster` always caches and replays only the last value**
(`FeatureTransferTests.swift:5074-5094`), while production passes `cache: false` for both event
kinds (`LocalSendRuntimeAdapter.swift:1045`, `:1070`).

Together these make a naive "emit `.request` then `.withdrawal` back-to-back before attach" test
**vacuous**: both yields hit zero continuations, only `.withdrawal` survives as the cached last
value, the late subscriber receives *only* the withdrawal, and every "nothing was prompted /
nothing was accepted" assertion passes without the request ever being delivered. That test would
pass for the wrong reason and prove nothing about ordering.

**Decision on fake caching semantics.** `TestBroadcaster.yield` gains a `cache: Bool = true`
parameter, mirroring the production `StreamBroadcaster` signature. The inbound-event emitters use
it as follows:

- `.request` emissions keep `cache: true`. Several existing tests deliberately emit before
  `start()` and rely on replay — `testActiveSheetPrefersIncomingRequestOverProgress`
  (`:95-121`, emits at `:106` before `start()`) and `testRestartAfterStopRebindsRuntimeStreams`
  (`:77-82`). Changing this would cascade into unrelated tests for no benefit. The divergence from
  production's `cache: false` is pre-existing test-fixture convenience and is documented as such.
- `.withdrawal` emissions use **`cache: false`**. This matches production exactly and removes the
  new hazard the merge would otherwise introduce: a withdrawal becoming the replayed last value
  for a late or re-subscribing store.

The ordering tests below do not depend on replay at all — they attach first, then observe a
positive intermediate state.

### 4.1 The two `Task.yield()` race tests

`Modules/FeatureTransfer/Tests/FeatureTransferTests/FeatureTransferTests.swift`.

`testWithdrawalArrivingBeforeTheRequestSuppressesIt` asserted a scenario the new design makes
**unrepresentable** — on one ordered stream you cannot emit a withdrawal "before" its request, and
§1/§2 establish the source can never produce that sequence either. Writing a merged-stream version
of it would be testing an impossible input. It is replaced by three tests that between them cover
strictly more than it did:

1. **`testInboundRequestThenWithdrawalDismissesThePromptInOrder`** — the positive-intermediate
   version. Attach barrier after `start()`; emit `.request("racy")`; `await waitUntil {
   store.incomingRequest?.id == "racy" }` — this is the assertion the old draft lacked, and it
   proves the request really was delivered; then emit `.withdrawal("racy")`; then
   `await waitUntil { store.incomingRequest == nil }` and assert `store.activeSheet == nil` and
   `responses.isEmpty`. Both halves are now load-bearing.
2. **`testInboundRequestEventsAreObservedInEmissionOrder`** — asserts ordering *directly* rather
   than inferring it from end state, using the recording fake from §4.2: emit
   `.request(x)`, `.withdrawal(x.id)`, `.request(y)` with no yields in between, then assert the
   store's observed sequence equals exactly that. This is the test that would fail if anyone
   reintroduces a second consumer.
3. **`testWithdrawalAfterAutoAcceptIsIgnored`** — keeps the `quickSave = .on` "worst case" the old
   test used. Behaviour is stated explicitly rather than left as "nothing crashes": the request is
   auto-accepted (`autoAcceptIncomingRequest`, `:776-818`), so a subsequent withdrawal finds no
   displayed prompt and is ignored — `incomingRequest` stays `nil`, no `.declined` history entry is
   written, and the pre-existing auto-accept-then-fail path
   (`respondToIncomingRequest` rejected by the bridge with
   `incomingTransferRequestNotPending`, logged as `transfer.incoming.auto_accept_failed` at `:805`)
   is asserted as-is. This behaviour is **pre-existing and unchanged** — the side table only ever
   helped in the impossible out-of-order case, never here — but without this test the interaction
   would lose its only coverage.

`testWithdrawalDoesNotSuppressALaterDistinctRequest` is kept, but **the `Task.yield()` loop after
the withdrawal is replaced by an attach barrier before it, not simply deleted.** Per §4.0 that loop
is doing double duty as the subscriber-attach barrier; deleting it would leave the test relying on
cache replay of `.request("fresh")` while `.withdrawal("gone")` might never be delivered at all —
it would stop proving that a stale withdrawal is inert. Corrected shape: `start()` → attach barrier
→ emit `.withdrawal("gone")` → emit `.request("fresh")` →
`await waitUntil { store.incomingRequest?.id == "fresh" }`.

### 4.2 Observability instead of spinning

`FakeTransferRuntime` collapses `incomingBroadcaster` + `withdrawalBroadcaster` into one
`TestBroadcaster<InboundRequestEvent>`, with `emitIncomingRequest` / `emitWithdrawal` retained as
the emit helpers (caching per §4.0) so unrelated call sites do not churn.

Add a recording fake for test 2 above — a `FakeTransferRuntime` that appends every event it hands
out to an actor-isolated `observedEvents: [InboundRequestEvent]`, or equivalently a store-side
recording hook. This is the "observable state to await" that item 48 says is missing: ordering
becomes an assertable value instead of a scheduler artifact.

`waitUntil` stays. It is `Task.yield()`-based, but it awaits an *observable predicate* and fails
loudly if the predicate never holds — that is legitimate state-settling. What item 48 objects to,
and what goes away entirely, is bare `for _ in 0..<20 { await Task.yield() }` used to *impose an
ordering between two independent streams*. Attach barriers are a different, honest use of the same
primitive and are labelled as such wherever they remain.

### 4.3 `LocalSendKit` tests

`Modules/LocalSendKit/Tests/LocalSendKitTests/InteropFixesTests.swift`:

- `cancelWithdrawsThePromptAndLeavesTheReceiverReusable` (`:237-258`) — the `bridge.withdrawals()`
  iterator (`:240`) becomes a `bridge.events()` iterator. `withdrawals.next() == prompt.id`
  becomes: consume the preceding `.request`, then assert the next event is exactly
  `.withdrawal(requestID: prompt.id)`. The test gets *stronger* — it now pins the relative order,
  not just the fact of a withdrawal. Note the iterator is created **before** the first request, so
  the second transfer at `:255-258` also lands in it; any assertion added there must account for
  the extra `.request`.
- `withdrawalKeepsTheRequestStreamAlive` (`:323-337`) — `bridge.requests()` (`:326`) becomes
  `events()`. This needs a **bounded skip loop** over `.withdrawal` (e.g. a
  `nextRequest(from:)` helper that pulls at most N events and fails the test if no `.request`
  arrives), not a bare `next()` that would trip over the interleaved withdrawal. Its point — the
  stream survives a withdrawal instead of being finished by it — is unchanged.
- **New kit-level ordering test** (this is where the guarantee actually lives, so it is asserted at
  the source, not only three hops downstream): `bridge.events()` delivers `.request(x)` immediately
  followed by `.withdrawal(requestID: x.id)` with nothing in between — asserted for a subscriber
  attached *before* the request, and for one attached *between* the request and the cancel, which
  exercises the `activeRequest` replay path.
- `EndpointHostParsingTests.pendingRequestWithdrawalIsAlsoScopedToTheInterface` (`:203-204`) passes
  `incomingRequestBridge: nil` and needs no change.

### 4.4 Verification

`swift build` + `swift test` in `Modules/LocalSendKit` and `Modules/FeatureTransfer`, then
`xcodebuild -scheme LocalDrop build`. Note the pre-existing, separately logged flakiness in the
`makeLiveReceiveFixture` group (`TECH_DEBT.md`, "Live-runtime receive-cancel tests are
order-dependent and flaky") — those failures must be compared against baseline rather than
attributed to this change.

## 5. Risks

1. **Dropped events during the swap.** One broadcaster now carries two event kinds; if `cache:`
   were flipped to `true` for either, a late subscriber would replay a resolved request. Both
   stay `cache: false`.
2. **Replay semantics of `events()`.** Only `activeRequest` is replayed. A subscriber attaching
   between `withdraw` and the next request sees nothing stale, because `withdraw` clears
   `activeRequest` before yielding.
3. **`finishPending` fan-out.** Collapsing to one continuation set must not make `withdraw`
   start finishing continuations; the existing comment on `withdraw` documents why. Preserved.
4. **Actor isolation and head-of-line blocking.** The store's handlers are `@MainActor`; one task
   instead of two means strictly fewer interleaving points for *correctness*. The honest other half:
   a withdrawal now queues **behind** request handling instead of being able to overtake it while
   the request handler is suspended at an `await` — including behind `handleIncomingRequest` on the
   MainActor. Nothing on either path blocks long enough for this to matter today (both handlers are
   short and synchronous apart from logging), and serialization is the entire point of the change,
   but it is a real trade and is recorded here rather than glossed.
5. **Teardown order — the earlier draft of this plan had this backwards.** `LocalSendRuntimeAdapter`
   `stop()` cancels `stateObservationTask` / `incomingObservationTask` /
   `withdrawalObservationTask` **first** (`:172-174`) and awaits `components.node.stop()` **last**
   (`:181`) — the opposite of the store's `stop()`, which shuts the runtime down before cancelling
   observers (`TransferFeatureStore.swift:279-283`). So post-merge, cancelling the single task can
   discard whatever is buffered in the merged stream. This is **not** a mitigation this plan can
   claim. It is also not a live defect: `LocalSendNode.stop()` routes through
   `bridge.finishPending()` (`LocalSendNode.swift:284`), which emits **no** withdrawal at all, so
   there is no terminal withdrawal event to drop. Action: do **not** reorder `stop()` as part of
   this change (out of scope, and the store's own ordering comment explains why that ordering
   matters there); instead correct the comment so it states what is actually true, and log the
   underlying gap (§6).
6. **Attach-window drops (pre-existing, out of scope).** `bindNodeObservers()` runs *after*
   `node.start()` (`LocalSendRuntimeAdapter.swift:110-112`) and both yields are `cache: false`, so a
   prompt arriving in that window can be dropped. Unchanged by this plan — one merged stream has
   exactly the same window as the two it replaces — but it is now the only remaining ordering-ish
   hazard in this area, so it gets logged rather than forgotten (§6).

## 6. Debt records to update when this lands

Only after build + tests are green and the diff is reviewed:

1. Delete `docs/todo.txt` item 48 ("Incoming-request/withdrawal ordering is compensated for, not
   guaranteed", the block under "1. DEFERRED / BLOCKED ON A DECISION"). Touch nothing else in that
   file.
2. Delete the `TECH_DEBT.md` "General Debt" entry
   `### Incoming-request/withdrawal ordering is compensated for, not guaranteed` (`:17-25`). The fix
   is landing, so the entry is stale, not merely a cross-reference. Leave every other entry —
   notably "Live-runtime receive-cancel tests are order-dependent and flaky" (`:27-40`) — untouched.
3. Delete this plan file.
4. Log two **pre-existing, deliberately out-of-scope** issues surfaced during review, via
   `tech-debt-tracker`: (a) the `cache: false` + late-`bindNodeObservers()` attach window above;
   (b) `finishPending()` on runtime teardown emits no withdrawal, so a displayed prompt is never
   explicitly dismissed on stop.
