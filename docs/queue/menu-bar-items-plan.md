# Menu Bar Items Plan — LocalDrop

## 1. Current state (from code audit)

- `LocalDropApp.swift`: `MenuBarExtra("LocalDrop", systemImage: "paperplane") { EmptyView() }` — icon exists, menu content empty.
- No `.commands {}` block anywhere → app menu (LocalDrop/File/Edit/View/Window/Help) is stock SwiftUI default, no custom items.
- No `LSUIElement` in Info.plist → regular Dock app, not menu-bar-only. Settings has "Minimize to menu bar on close" toggle (UI exists, unwired).
- Store (`TransferFeatureStore`) already exposes: `refreshNearbyPeers`, `stageDroppedItems`, `send(to:)`, `acceptIncomingRequest`/`declineIncomingRequest`, `cancelActiveTransfer`, `clearHistory`, `persistSettings`, `nearbyPeers`, `historyEntries`, `activeTransfer`, `incomingRequest`.
- Gaps: no pause/resume, no "show in Finder"/open received file, no favorites/trusted-devices list, Choose-save-location is a stub, Device name is read-only.

## 2. Precedent scan — other macOS apps

| App | Pattern relevant to LocalDrop |
|---|---|
| **AirDrop** (Finder) | Not a menu bar item itself, but the UX target: nearby-device grid, drag-to-send, receiving toggle (Everyone/Contacts/No one). LocalDrop's status-item menu should mirror "nearby devices + quick send" more than AirDrop's window. |
| **Bluetooth / Wi-Fi menu bar** (macOS) | Status icon reflects live state (idle/searching/transferring). Click → short list of "devices," each row itself actionable. "Open Bluetooth Settings…" at bottom → maps to "Open LocalDrop Preferences…". |
| **Dropbox / Google Drive** | Menu bar icon + popover (not menu): recent activity list, sync status, quick "pause syncing," gear icon → preferences, "Open folder." Maps to: recent transfers, pause/queue, "Open Downloads folder." |
| **Transmission** (torrent client) | Menu bar extra shows aggregate up/down speed; dropdown lists active transfers each with a mini progress bar and per-item pause/cancel. Direct analog for LocalDrop's in-progress transfers submenu. |
| **1Password mini / Bartender** | Global keyboard shortcut to summon the menu bar popover even when app isn't frontmost — worth exposing as a Settings toggle later. |
| **Software Update / Time Machine** menu bar item | Icon itself changes glyph/badge based on state (spinning, checkmark, exclamation) — LocalDrop icon should badge on incoming request / active transfer / error. |
| **Fantastical / Things** quick-entry | Menu bar dropdown doubles as a fast-path input (quick add) without opening main window — maps to "Send Text/Clipboard…" from the menu bar directly. |
| **Apple's own File/Edit/View/Window/Help convention** | Every document/utility app keeps this even with a menu bar extra — used for full commands (⌘, for Preferences, ⌘Q Quit, ⌘N new send, ⌘1-4 view switch, Window list, Help). LocalDrop currently has none of this wired. |

Takeaway: LocalDrop needs **two separate menu surfaces**, both currently missing:
- **A. Status item menu** (`MenuBarExtra`) — for menu-bar-only / background usage (send/receive without opening the window).
- **B. App menu bar commands** (`.commands {}`) — standard app menu, File, View, Window, Help, for when the window is open.

## 3. Proposed structure

### A. Status item menu (MenuBarExtra, `.menu` style)

Icon: `paperplane` idle → filled/badge variant while `activeTransfer != nil`, badge dot while `incomingRequest != nil`.

```
LocalDrop                              (header, disabled, shows device name + status text)
─────────────────────────
Send File…                             ⌘⇧S    → open file picker, stage, then device picker
Send Folder…                                  → folder picker, stage
Send Text / Clipboard…                        → send current pasteboard text
─────────────────────────
Nearby Devices                        ▸        (submenu, one row per store.nearbyPeers)
  ├─ MacBook Pro (192.168.1.12)                → tap = send staged items to this peer
  ├─ Pixel 8                                    → disabled/greyed if nothing staged
  └─ Refresh                              ⌘R   → store.refreshNearbyPeers()
─────────────────────────
Receiving: On                         ▸        (submenu or toggle)
  ├─ Quick Save: Ask each time / Downloads / Choose folder…
  └─ Pause Receiving                            → new capability (see gap notes)
─────────────────────────
Active Transfer: sending 3 files… 42%          (only shown if activeTransfer != nil)
  └─ Cancel                                     → store.cancelActiveTransfer()
Incoming Request: "MacBook wants to send…"     (only shown if incomingRequest != nil)
  ├─ Accept                                     → store.acceptIncomingRequest()
  └─ Decline                                    → store.declineIncomingRequest()
─────────────────────────
Recent Transfers                       ▸        (submenu, last 5 store.historyEntries)
  ├─ report.pdf — received 2m ago               → click = reveal in Finder (new capability)
  └─ Show All in History…                       → open window, select .history
─────────────────────────
Open LocalDrop                         ⌘O       → bring main window front
Preferences…                           ⌘,       → open window, select .settings
─────────────────────────
Quit LocalDrop                         ⌘Q
```

### B. App menu bar (`.commands {}`) — active when window is open

- **LocalDrop** (app menu): About LocalDrop · Preferences… ⌘, · Services · Hide LocalDrop ⌘H · Hide Others · Quit LocalDrop ⌘Q *(About/Hide/Quit are free via `CommandGroup(replacing:)` defaults — only need to inject Preferences)*
- **File**: Send File… ⌘O · Send Folder… ⇧⌘O · Send Text… ⌘T · Clear History ⌘⌫ *(replace default New/Open items — no documents in this app)*
- **View**: Receive ⌘1 · Send ⌘2 · History ⌘3 · Settings ⌘4 *(maps to `Screen` enum in RootView — use `CommandGroup(after: .toolbar)` + `@FocusedValue` or a shared store binding)*
- **Window**: standard (Minimize, Zoom, Bring All to Front) — no custom items needed.
- **Help**: LocalDrop Help · LocalSend Protocol Docs (link) · Report an Issue (link)

## 4. Wiring approach

1. **Shared store access**: `LocalDropApp` already owns `container` (has `store`). Pass `store` into both `MenuBarExtra` content and `.commands {}` via `.environment(store)` on the `WindowGroup`'s scene content — `.commands` closures can read `container.store` directly since `LocalDropApp` holds it, no `@FocusedValue` needed unless multiple windows are added later.
2. **New `MenuBarExtraView.swift`** (place in `FeatureTransfer` or a small `FeatureMenuBar` target) — takes `store: TransferFeatureStore`, builds the menu tree in §3A using `Button`/`Menu` (SwiftUI `Menu` for submenus works natively inside `MenuBarExtra(.menu style)`).
3. **`MenuBarExtra` style**: use `.menu` (not `.window`) — gives native NSMenu look or matches other status-bar utilities in §2, and disabled items render correctly.
4. **Icon state**: computed `var statusSymbol: String` on the view driven by `store.activeTransfer`/`store.incomingRequest`/`store.isRuntimeAvailable`, passed to `MenuBarExtra(systemImage:)` (needs to become a `@ViewBuilder`/computed label, e.g. `MenuBarExtra { menuContent } label: { Image(systemName: statusSymbol) }`).
5. **Open main window from status item**: SwiftUI has no direct "focus window" API pre-macOS 15 `openWindow`/`@Environment(\.openWindow)`; simplest cross-version approach is `NSApp.activate(ignoringOtherApps: true)` + `NSApp.windows.first?.makeKeyAndOrderFront(nil)` inside an `AppKit`-import-free-violating call — since project is SwiftUI-only, prefer `@Environment(\.openWindow) private var openWindow` with a named `WindowGroup(id:)`, or keep the existing single `WindowGroup` and call `NSApplication.shared.activate` only from the App target (App target may use AppKit sparingly; `DesignSystem`/`FeatureTransfer` must stay AppKit-free per project convention — confirm with senior_engineer before adding any AppKit call outside `LocalDropApp.swift`).
6. **View switching (⌘1-4)**: add `CommandGroup` in `.commands {}` calling `store.screen = .receive` etc. — trivial since `TransferFeatureStore` already tracks `screen`.
7. **Preferences ⌘,**: `CommandGroup(replacing: .appSettings)` → sets `store.screen = .settings` + brings window front (same mechanism as #5).
8. **Send File/Folder/Text from menu bar**: reuse existing staging code path in `SendView`/`store.stageDroppedItems` — needs a non-drag-and-drop entry point (`NSOpenPanel` via a small helper, or `fileImporter`/`fileExporter` modifiers attached to a hidden view, since `.fileImporter` requires a SwiftUI view context — attach it to the `MenuBarExtra` content view or a top-level modifier on `WindowGroup` triggered by a `@State` flag toggled from the menu action).
9. **"Reveal in Finder" / "Pause Receiving"**: **not implemented today** — flag as new capability needed in `LocalSendKit`/`TransferFeatureStore` before wiring (see gaps below). Don't block the rest of the menu bar work on these; ship with them omitted or disabled first pass.
10. **Badge on icon for incoming/active state**: no code change needed beyond #4 — purely reactive to existing `@Observable` store properties.

## 5. New capabilities required (blockers for specific items only)

| Menu item | Needs |
|---|---|
| Pause Receiving | New `TransferRuntime` method to stop advertising/accepting without full `stop()` |
| Reveal in Finder (history row) | Store the destination `URL` on `HistoryEntry` (currently may not retain it) + `NSWorkspace.activateFileViewerSelecting` (AppKit — confine to app target) |
| Choose save folder (already stubbed in Settings) | Wire existing no-op `Choose…` button — same `NSOpenPanel`/`fileImporter` question as #8 above |
| Quick Save mode from menu bar submenu | Already modeled as `QuickSaveMode` in `ReceiveView` — just needs a shared binding exposed via store, likely already there, confirm during implementation |

## 6. Suggested implementation order

1. Wire `.commands {}` app menu (View switch ⌘1-4, Preferences ⌘,) — no new capability needed, pure store wiring.
2. Build status item menu tree (§3A) using only existing store actions (Send is disabled until staging works from menu bar; Nearby Devices, Active Transfer, Incoming Request, Recent Transfers, Quit all wire directly).
3. Add `fileImporter`-based Send File/Folder from both menu bar and File menu (shared helper).
4. Add icon badge state (#4/#10).
5. Defer Pause Receiving, Reveal in Finder, Choose save folder wiring to a follow-up once `TransferRuntime`/`HistoryEntry` gaps are closed (separate task — flag via tech-debt-tracker or product_manager for scope confirmation).
