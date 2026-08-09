# Performance + Deferred-UI Fixes — Implementation Plan (phase 2)

Status: **IN PROGRESS**
Owner: team_lead (main session)
Scope: `docs/todo.txt` section "1. PERFORMANCE" (items 37, 38, 39) and the decision-blocked
entries in section "2. DEFERRED" (items 50, 51, the sidebar-accent entry, and item 27).

Resumability contract: a future session with no conversation history must be able to resume from
this file alone. Keep the per-item Status lines current.

Process note: phase 1 (discovery + protocol completeness, 8 items) is complete and committed.
Per an explicit instruction from the coordinator, this phase must use **plain sequential local
commits only** — no `git rebase`, no squashing of my own commits, no reuse of an older commit's
message, and **no pushing** without asking first.

---

## Cluster A — Performance (items 37, 38, 39)

These three all sit on the same transfer/progress pipeline and are done together.

**Global constraint carried from todo item 37:** do NOT regress the existing progress model.
Byte-accurate totals, EWMA speed and ETA are deliberately better than the reference's bare
fraction. Coalescing may drop *intermediate* samples; it must never make the *final* number wrong.

### Item 39 — per-file receive status must be tracked, not stat-ed
Status: **DONE**

Problem: completion is inferred by synchronously `stat`-ing every destination path
(`ReceiveSession.regularFileExists`), which is blocking I/O inside an actor and misreports if a
destination is deleted underneath us.

Design:
1. New `public enum ReceivedFileStatus { case queued, transferring, completed, failed }`.
2. `ReceivedFileRecord` gains `var status: ReceivedFileStatus = .queued`.
3. `ReceiveSessionSnapshot.failedFileIDs` becomes a **computed** property derived from the
   per-file statuses, so there is exactly one source of truth. (It was stored, added in phase 1
   for item 19; the memberwise-init parameter goes away and phase-1 tests that passed it are
   updated.)
4. Every `regularFileExists`-driven decision is replaced by a status check:
   - `upload()`'s "all files present" -> all records `.completed`
   - the `finishedWithErrors` re-derivation
   - `failUpload`'s succeeded/pending counts
   - `completedBytesExcludingCurrentFile` -> sum of `.completed` record sizes
5. `regularFileExists` survives ONLY where it is genuinely a filesystem question:
   `resolveDestination`'s collision probe and `stage`'s clobber fallback. It is no longer used to
   infer session state.

### Item 37 — coalesce receive-side progress updates
Status: **DONE**

Problem: `stageUploadBody`'s `progressObserver` fires per 64 KiB chunk, each one an actor hop plus
a full snapshot recompute and a state-observer broadcast — ~16,000 for a 1 GB file.

Design: a shared `ProgressCoalescer` value in LocalSendKit that answers "should this sample be
reported?" from a byte threshold OR a time threshold, whichever trips first. Applied in
`LocalSendServerRuntime` where the observer closure is built. Thresholds: **256 KiB or 100 ms**.
The terminal value is never dropped — `ReceiveSession.upload` independently sets
`bytesReceived = file.size` on completion, so the final total stays exact regardless of coalescing.

### Item 38 — one serial progress consumer per upload, not a Task per callback
Status: **DONE**

Problem: `LocalSendRuntimeAdapter.uploadOneFile` spawns a `Task { }` inside the
`didSendBodyData` callback, so task creation is unbounded and unordered.

Design: replace it with an `AsyncStream<Int64>` created per file, with buffering policy
`.bufferingNewest(1)`, consumed by exactly ONE task per file. The URLSession callback becomes a
synchronous `continuation.yield(bytes)` — no task, no allocation storm. `.bufferingNewest(1)`
does the coalescing for free: a consumer that falls behind sees only the most recent byte count,
which is exactly the right semantics for a monotonic progress counter. The stream is finished in
a `defer` so the consumer task always terminates. Task count per file goes from O(number of
callbacks) to exactly 1, and the pool already bounds files in flight to 3.

Ordering: `recordUploadProgress` already ignores a sample lower than the one recorded
(`guard transferredBytes > previous`), so a dropped or reordered sample can never walk progress
backwards.

## Cluster B — Deferred / decision-blocked items

Items 51, the sidebar-accent entry, and 27 were all explicitly marked "blocked on a decision" in
`todo.txt`, so `product_manager` was consulted before any code was written. Item 50 is unblocked
and needs no decision.

### Item 50 — `FavoriteDevice.aliasOverride` is unreachable
Status: **PENDING**
Add a rename affordance to the existing favorites list in `SettingsView.swift` and wire it to
`aliasOverride`; also refresh `lastKnownAlias`. SwiftUI only.

### Item 51 — `QuickSaveMode` consent copy
Status: **PENDING product_manager decision** (17-locale cost is the crux)

### Sidebar accent selection
Status: **PENDING product_manager decision** (may be closed as "won't do")

### Item 27 — advertised protocol version
Status: **PENDING product_manager decision** (bump to "2.1" only if 2.1 behaviours are supported)

---

## Verification

- `swift build` + `swift test` for `LocalSendKit` and `FeatureTransfer`.
- `xcodebuild -scheme LocalDrop -destination 'platform=macOS' build`.
- Known pre-existing flakiness: the `makeLiveReceiveFixture` group in `FeatureTransferTests`
  is order-dependent and fails intermittently on the *unmodified* baseline too — see the
  TECH_DEBT.md entry "Live-runtime receive-cancel tests are order-dependent and flaky". Judge
  regressions against that, not against a green run.

## Definition of done

- [ ] Items 37, 38, 39 implemented + tested.
- [ ] Items 50, 51, sidebar, 27 resolved (implemented or explicitly closed per PM).
- [ ] Builds and suites verified.
- [ ] `docs/todo.txt` updated: performance section removed, resolved deferred entries removed.
- [ ] This plan file deleted.
- [ ] Committed locally, sequential commits, **no push**.
