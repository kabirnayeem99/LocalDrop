# AGENT.md — LocalDrop Agent Orchestration

Single agent-agnostic entry point — works for Claude Code, Codex, Cursor, or any other coding agent reading this repo. Tool-specific subagent definitions (Claude Code's subagent format) live under `.claude/agents/`; this file is the routing/orchestration guide any agent should read first.

LocalDrop is a **native macOS app, SwiftUI + Swift only — no AppKit, no Catalyst.** This constraint is enforced by every agent below; see `.claude/agents/team_lead.md` for the full rule.

5 role agents + 6 specialist agents ready. **Use role agents for orchestration; specialists for deep-domain work.**

## When to Use Agents

- ✅ New features/screens (uncertainty about architecture)
- ✅ Protocol/wire-format work (must stay interoperable with real LocalSend apps)
- ✅ SwiftUI UI patterns without AppKit
- ✅ Performance/memory issues (transfer engine, main-thread hygiene)
- ✅ Packaging/signing/notarization
- ❌ Small bug fixes (skip agent)

## Role Agents

| Role                | Agent                               | When                                                            |
| ------------------- | ----------------------------------- | --------------------------------------------------------------- |
| **Team Lead**       | `.claude/agents/team_lead.md`       | Decompose work, own architecture, verify build                  |
| **Product Manager** | `.claude/agents/product_manager.md` | Requirements, acceptance criteria, scope, protocol/UX questions |
| **Engineer**        | `.claude/agents/engineer.md`        | Implement code to plan (Core networking + SwiftUI UI)           |
| **Senior Engineer** | `.claude/agents/senior_engineer.md` | Critique plans/code (one-way critic)                            |
| **Tester**          | `.claude/agents/tester.md`          | Write/run unit, UI, and interop tests                           |

## Specialist Agents

| Task                    | Agent                                   | When                                                                                 |
| ----------------------- | --------------------------------------- | ------------------------------------------------------------------------------------ |
| **Protocol/networking** | `.claude/agents/networking-protocol.md` | Discovery, HTTP endpoints, TLS/crypto, transfer state machine — wire-format fidelity |
| **SwiftUI UI**          | `.claude/agents/swiftui-ui.md`          | Views/`@Observable` state, `List`/`Table`, drag-and-drop, menu bar scene             |
| **Swift language**      | `.claude/agents/swift-language.md`      | Concurrency, generics, Codable edge cases, struct-vs-class                           |
| **Performance/memory**  | `.claude/agents/performance-memory.md`  | Main-thread hygiene, streaming large files, Instruments findings                     |
| **Packaging/signing**   | `.claude/agents/packaging-signing.md`   | Entitlements, code signing, notarization, DMG, Homebrew cask                         |
| **Tech debt**           | `.claude/agents/tech-debt-tracker.md`   | Protocol deviations, SwiftUI workarounds, dead code                                  |

## Operating Mode

**Default: dispatch to `team_lead`.** For any major work (new features/screens, protocol/wire-format changes, refactors touching more than one module, anything in "When to Use Agents" above), invoke `.claude/agents/team_lead.md` as a subagent via the Agent tool — do not emulate the team-lead playbook inline in the main session. `team_lead` decomposes the request, sequences `product_manager` → `engineer` → `senior_engineer` → `tester`, and returns the integrated result. The `senior_engineer` is a one-way critic — findings are resolved by `team_lead` (plans) or `engineer` (code), not bounced back.

**Skip `team_lead`** only for small, well-scoped work that doesn't need decomposition (see ❌ in "When to Use Agents") — handle it directly, or call a single role/specialist agent if one clearly fits.

**For big features:** A Workflow script can encode the pipeline deterministically (PM → plan → critique → implement → review → test).

## Reference Material

- **Protocol doc:** `wiki/LocalSend-Protocol.md` — discovery, defaults, DTOs, endpoint map, trust model. Read this always, not a skill.
- **Networking skill:** `.claude/skills/macos-networking.md` — core transport implementation rules for LocalDropCore.
- **Protocol wire format:** `localsend-main-app/core/src/{http,crypto,model,webrtc}` — Dart reference implementation. This is the source of truth for interop; mirror it, don't reinterpret it.
- **User-facing behavior parity:** `localsend-main-app/README.md` — ports (53317 TCP/UDP), firewall, AP isolation, portable mode, hidden start.
- **Tech debt log:** `TECH_DEBT.md` at project root.
- Global skill `macos-development` covers Swift/SwiftUI conventions — use the SwiftUI-relevant sections only, skip AppKit-only guidance.

## Invoke

**Major work** — dispatch to `team_lead` as a subagent:

```
Agent(subagent_type: "team_lead", description: "[short task summary]",
      prompt: "[full task description, plus any constraints/context the main
      session already knows: relevant files, prior decisions]")
```

`team_lead` reads `wiki/LocalSend-Protocol.md`, the protocol reference, and existing Swift code itself, then sequences the role agents. The main session should not pre-empt that by doing the decomposition itself.

**Single specialist question** (scoped, no decomposition needed):

```
I'll use the [AGENT] agent to [task].

Before I start, I'll read:
1. wiki/LocalSend-Protocol.md (always) or .claude/skills/macos-networking.md when protocol/networking work is involved
2. localsend-main-app/core/src/... (protocol reference, if relevant)
3. Similar existing Swift code

Task: [description]
```

## Each Agent

- Knows the LocalDrop architecture and the SwiftUI-only constraint.
- Specifies required reading before changes.
- Self-reports build/test status after modifications.

See: `.claude/agents/team_lead.md` for the full architecture notes (module layout, UI framework rule).
