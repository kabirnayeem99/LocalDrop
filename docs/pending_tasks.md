# LocalDrop Pending Tasks

Last audited: July 12, 2026

This document captures the current feature and UX gaps found from a code audit of the app. Items are ordered by recommended implementation approach, balancing blocker impact, user importance, and implementation complexity.

## Recommended Approach Order

1. Improve error surfacing.
   - The store captures `lastErrorMessage` for runtime start, import, send, and settings-update failures.
   - The UI only shows transient feedback banners and does not present a persistent error panel or alert tied to those stored failures.

2. Allow editing the device name from the app.
   - The device name is shown in settings as read-only text.
   - The protocol settings already carry a device name, but the app does not expose an editing flow.

3. Implement favorites / trusted devices as a real concept.
   - `QuickSaveMode.favorites` exists.
   - `Auto-accept from favorites` exists in settings.
   - There is no favorites model, no favorite-device management UI, and no runtime logic that enforces trusted senders.
   - This is conceptually larger and depends on product/runtime decisions, so it should follow the core workflow fixes.

4. Implement pause receiving.
   - `Pause Receiving` exists in the menu bar extra but is disabled.
   - There is no store/runtime API for pausing discovery or inbound acceptance without fully stopping the runtime.

## Code Areas

- App shell and import commands: `App/LocalDropApp/LocalDropApp.swift`
- Send flow and staged item presentation: `Modules/FeatureTransfer/Sources/FeatureTransfer/SendView.swift`
- Transfer state, history, and settings persistence: `Modules/FeatureTransfer/Sources/FeatureTransfer/Application/TransferFeatureStore.swift`
- Menu bar extra gaps: `Modules/FeatureTransfer/Sources/FeatureTransfer/MenuBarExtraView.swift`
- Settings UI and stored toggles: `Modules/FeatureTransfer/Sources/FeatureTransfer/SettingsView.swift`
- History sample data and settings models: `Modules/FeatureTransfer/Sources/FeatureTransfer/Models/FeatureTransferModels.swift`
- Shared screen and quick-save enums: `Modules/FeatureTransfer/Sources/FeatureTransfer/TransferViewState.swift`
