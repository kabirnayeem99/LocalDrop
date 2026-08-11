# LocalDrop — Tech Debt Log

Maintained by the `tech-debt-tracker` agent (see `.claude/agents/tech-debt-tracker.md`). Entries grouped by category, most severe first within each.

Protocol deviations discovered in the LocalSend reference comparison are tracked as numbered
work items in `docs/todo.txt` (items 11-41) rather than duplicated here. This file records debt
that is structural rather than a discrete deviation, plus anything found while implementing.

## Protocol Deviations

## SwiftUI Workarounds

_None logged yet._

## General Debt

### Incoming-request/withdrawal ordering is compensated for, not guaranteed
Severity: minor
The request stream and withdrawal stream are consumed by two independent `Task`s. Ordering is
handled by a bounded set of withdrawn request IDs consulted in `handleIncomingRequest`, which is
correct, but the two race tests drive it with `Task.yield()` loops because there is no
observable "withdrawal recorded" state to await. The structurally clean fix is merging both into
one enum-tagged stream so ordering is real rather than compensated. Found during senior review
of backlog item 13. Files: `Application/TransferFeatureStore.swift`,
`Infrastructure/LocalSendRuntimeAdapter.swift`.

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
