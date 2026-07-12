# LocalDrop Pending Tasks

Last audited: July 11, 2026

This document captures the current feature and UX gaps found from a code audit of the app. Items are ordered by recommended implementation approach, balancing blocker impact, user importance, and implementation complexity.

## Recommended Approach Order

1. Improve error surfacing.
   - The store captures `lastErrorMessage` for runtime start, import, send, and settings-update failures.
   - The UI only shows transient feedback banners and does not present a persistent error panel or alert tied to those stored failures.

2. Allow editing the device name from the app.
   - The device name is shown in settings as read-only text.
   - The protocol settings already carry a device name, but the app does not expose an editing flow.

3. ~~Wire remaining settings that are stored but not connected to platform behavior.~~
   - ~~`language` is persisted but has no localization wiring.~~
   - ~~`accentColor` is editable in settings but is not applied broadly as a dynamic app-wide theme choice.~~

4. Implement favorites / trusted devices as a real concept.
   - `QuickSaveMode.favorites` exists.
   - `Auto-accept from favorites` exists in settings.
   - There is no favorites model, no favorite-device management UI, and no runtime logic that enforces trusted senders.
   - This is conceptually larger and depends on product/runtime decisions, so it should follow the core workflow fixes.

5. Implement pause receiving.
   - `Pause Receiving` exists in the menu bar extra but is disabled.
   - There is no store/runtime API for pausing discovery or inbound acceptance without fully stopping the runtime.

6. Run the UI/UX motion polish pass after the functional seams are real.
   - Start with drop-zone drag feedback, device-card hover/press states, staged-file transitions, and transfer progress/completion polish.
   - Follow with the larger animation and semantic-color backlog once the underlying state changes are stable.

## Completed in this cycle

- Replaced sample transfer history with real persisted history using `HistoryPersistenceAdapter`.
- Added `Reveal in Finder` and `Open` actions to history rows.
- Wired `Launch at login` via `SMAppServiceLoginItemManager`.
- Wired `Minimize to menu bar on close` via the app delegate.
- Added app menu commands (File, View, Preferences, Help) and a full status-item menu.
- Added file/folder/text send entry points from the menu bar and app menu.
- Wired `language` to localized strings via `Localizable.xcstrings` and extended `LanguageSetting` to the v1 supported-language set plus Uyghur, with endonyms and RTL awareness.
- Wired `accentColor` to an environment-aware `AccentTheme` with system colors, eight named custom palettes, and a system-accent option; Medina Emerald is the default.

## Code Areas

- App shell and import commands: `App/LocalDropApp/LocalDropApp.swift`
- Send flow and staged item presentation: `Modules/FeatureTransfer/Sources/FeatureTransfer/SendView.swift`
- Transfer state, history, and settings persistence: `Modules/FeatureTransfer/Sources/FeatureTransfer/Application/TransferFeatureStore.swift`
- Menu bar extra gaps: `Modules/FeatureTransfer/Sources/FeatureTransfer/MenuBarExtraView.swift`
- Settings UI and stored toggles: `Modules/FeatureTransfer/Sources/FeatureTransfer/SettingsView.swift`
- History sample data and settings models: `Modules/FeatureTransfer/Sources/FeatureTransfer/Models/FeatureTransferModels.swift`
- Shared screen and quick-save enums: `Modules/FeatureTransfer/Sources/FeatureTransfer/TransferViewState.swift`
