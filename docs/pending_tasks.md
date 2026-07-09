# LocalDrop Pending Tasks

Last audited: July 9, 2026

This document captures the current feature and UX gaps found from a code audit of the app. It is scoped to missing, partial, or misleading user-facing behavior that should be tracked as pending work.

## Priority 0

- Implement working in-window send pickers on the Send screen.
  - The main window exposes File / Folder / Text / Paste selection tiles, but those buttons only update local selection state and do not trigger any action in `SendView`.
  - Current app-level file and folder import only exist in `LocalDropApp.swift` via `.fileImporter`, so the primary send workflow still depends on drag and drop or app/menu commands.

- Implement clipboard and plain-text sending.
  - `Send Text…` is present but disabled in the app command menu.
  - `Send Text / Clipboard…` is present but disabled in the menu bar extra.
  - The Send screen shows a `Paste` tile, but there is no pasteboard integration in the app code.

- Replace sample transfer history with real persisted history.
  - `TransferFeatureStore` initializes `historyEntries` from `HistoryEntry.samples`.
  - The current code does not append completed, declined, sent, or received transfers into history.
  - `clearHistory()` only clears the current in-memory array.

## Priority 1

- Support multi-item staged send UI.
  - The store stages every dropped or imported URL.
  - The Send screen only renders `store.stagedItems.first`, so users cannot review or manage the full staged batch.

- Implement favorites / trusted devices as a real concept.
  - `QuickSaveMode.favorites` exists.
  - `Auto-accept from favorites` exists in settings.
  - There is no favorites model, no favorite-device management UI, and no runtime logic that enforces trusted senders.

- Implement pause receiving.
  - `Pause Receiving` exists in the menu bar extra but is disabled.
  - There is no store/runtime API for pausing discovery or inbound acceptance without fully stopping the runtime.

- Add actions to open or reveal received items.
  - History rows are display-only.
  - There are no Finder reveal or open-file actions wired from history or receive flows.

- Allow editing the device name from the app.
  - The device name is shown in settings as read-only text.
  - The protocol settings already carry a device name, but the app does not expose an editing flow.

## Priority 2

- Wire settings that are currently stored but not connected to platform behavior.
  - `launchAtLogin` is persisted but has no login-item integration.
  - `minimizeToMenuBar` is persisted but has no window-close behavior.
  - `language` is persisted but has no localization wiring.
  - `accentColor` is editable in settings but is not applied broadly as a dynamic app-wide theme choice.

- Improve error surfacing.
  - The store captures `lastErrorMessage` for runtime start, import, send, and settings-update failures.
  - The UI only shows transient feedback banners and does not present a persistent error panel or alert tied to those stored failures.

## Code Areas

- App shell and import commands: `App/LocalDropApp/LocalDropApp.swift`
- Send flow and staged item presentation: `Modules/FeatureTransfer/Sources/FeatureTransfer/SendView.swift`
- Transfer state, history, and settings persistence: `Modules/FeatureTransfer/Sources/FeatureTransfer/Application/TransferFeatureStore.swift`
- Menu bar extra gaps: `Modules/FeatureTransfer/Sources/FeatureTransfer/MenuBarExtraView.swift`
- Settings UI and stored toggles: `Modules/FeatureTransfer/Sources/FeatureTransfer/SettingsView.swift`
- History sample data and settings models: `Modules/FeatureTransfer/Sources/FeatureTransfer/Models/FeatureTransferModels.swift`
- Shared screen and quick-save enums: `Modules/FeatureTransfer/Sources/FeatureTransfer/TransferViewState.swift`
