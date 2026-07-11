# LocalDrop Pending Tasks

Last audited: July 11, 2026

This document captures the current feature and UX gaps found from a code audit of the app. Items are ordered by recommended implementation approach, balancing blocker impact, user importance, and implementation complexity.

## Recommended Approach Order

1. Replace sample transfer history with real persisted history.
   - `TransferFeatureStore` initializes `historyEntries` from `HistoryEntry.samples`.
   - The current code does not append completed, declined, sent, or received transfers into history.
   - `clearHistory()` only clears the current in-memory array.
   - This is a trust and correctness gap, but it should follow the core send-flow fixes so history attaches to real lifecycle events.

2. Add actions to open or reveal received items.
   - History rows are display-only.
   - There are no Finder reveal or open-file actions wired from history or receive flows.
   - This depends on real persisted history and reliable destination URL storage.

3. Wire settings that are stored but not connected to platform behavior.
   - `launchAtLogin` is persisted but has no login-item integration.
   - `minimizeToMenuBar` is persisted but has no window-close behavior.
   - `language` is persisted but has no localization wiring.
   - `accentColor` is editable in settings but is not applied broadly as a dynamic app-wide theme choice.
   - These are misleading settings and should be fixed after the core transfer workflow is trustworthy.

4. Improve error surfacing.
   - The store captures `lastErrorMessage` for runtime start, import, send, and settings-update failures.
   - The UI only shows transient feedback banners and does not present a persistent error panel or alert tied to those stored failures.
   - This is broadly useful, but more effective once the main app flows above are fully wired.

5. Allow editing the device name from the app.
   - The device name is shown in settings as read-only text.
   - The protocol settings already carry a device name, but the app does not expose an editing flow.
   - This is useful and relatively contained, but it does not block the core workflow.

6. Implement favorites / trusted devices as a real concept.
    - `QuickSaveMode.favorites` exists.
    - `Auto-accept from favorites` exists in settings.
    - There is no favorites model, no favorite-device management UI, and no runtime logic that enforces trusted senders.
    - This is conceptually larger and depends on product/runtime decisions, so it should follow the core workflow fixes.

7. Implement pause receiving.
    - `Pause Receiving` exists in the menu bar extra but is disabled.
    - There is no store/runtime API for pausing discovery or inbound acceptance without fully stopping the runtime.
    - This is explicitly blocked by missing runtime capability and should stay behind higher-value workflow work.

8. Run the UI/UX motion polish pass after the functional seams are real.
    - Start with drop-zone drag feedback, device-card hover/press states, staged-file transitions, and transfer progress/completion polish.
    - Follow with the larger animation and semantic-color backlog once the underlying state changes are stable.
    - This work is valuable, but it should attach to true behaviors rather than placeholders.

## Code Areas

- App shell and import commands: `App/LocalDropApp/LocalDropApp.swift`
- Send flow and staged item presentation: `Modules/FeatureTransfer/Sources/FeatureTransfer/SendView.swift`
- Transfer state, history, and settings persistence: `Modules/FeatureTransfer/Sources/FeatureTransfer/Application/TransferFeatureStore.swift`
- Menu bar extra gaps: `Modules/FeatureTransfer/Sources/FeatureTransfer/MenuBarExtraView.swift`
- Settings UI and stored toggles: `Modules/FeatureTransfer/Sources/FeatureTransfer/SettingsView.swift`
- History sample data and settings models: `Modules/FeatureTransfer/Sources/FeatureTransfer/Models/FeatureTransferModels.swift`
- Shared screen and quick-save enums: `Modules/FeatureTransfer/Sources/FeatureTransfer/TransferViewState.swift`
