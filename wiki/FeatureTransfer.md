# FeatureTransfer

FeatureTransfer is the SwiftUI feature that users interact with. It wraps LocalSendKit and provides the send, receive, history, and settings screens. It targets macOS 14+ and depends on LocalSendKit, DesignSystem, and AppLogging.

See also: [LocalSendKit](./LocalSendKit.md), [DesignSystem](./DesignSystem.md), [AppLogging](./AppLogging.md).

## Responsibilities

- Own the UI state for the entire transfer flow.
- Start and stop the LocalSend runtime.
- Discover and display nearby devices.
- Stage files, folders, and text for sending.
- Send files to a selected peer.
- Present incoming transfer requests and route user decisions back to LocalSendKit.
- Show transfer progress and completion.
- Persist settings and history.
- Expose the menu bar extra and menu actions.

## Architecture

The module uses a single `@MainActor @Observable` store at the center. Views bind to the store. Adapters hide LocalSendKit behind small protocols so the store can be tested with fake implementations.

```
Views -> TransferFeatureStore -> Adapters -> LocalSendKit
              |
              v
       Persistence (UserDefaults / Application Support)
```

## Key Types

### State Containers

- `TransferFeatureStore.swift`: the main store. Holds `screen`, `nearbyPeers`, `stagedItems`, `historyEntries`, `incomingRequest`, `activeTransfer`, `feedback`, and all settings fields. Starts/stops the runtime, handles discovery, sends files, accepts/rejects incoming transfers, and persists state.
- `TransferFeatureContainer.swift`: factory and owner of the store. `live()` builds the real runtime with LocalSendKit. `testing()` returns a no-op runtime container for previews and tests. Provides app-level helpers: `stageImportedItems`, `stagePastedText`, `stageClipboardTextIfAvailable`, `rootView`, and `menuBarExtraView`.
- `TransferViewState.swift`: small enums and helpers: `Screen` (receive, send, history, settings), `QuickSaveMode`, `AppearanceSetting`, `LanguageSetting`, `ActiveSheet`, and `View.applyingLanguageOverride`.
- `FeatureTransferModels.swift`: all domain models. Includes `NearbyPeerItem`, `IncomingTransferRequest`, `StagedTransferItem`, `ActiveTransferProgress`, `HistoryEntry`, `TransferSettingsSnapshot`, and others.

### Adapters

- `TransferRuntime.swift`: protocols the store depends on. `TransferRuntime`, `TransferSettingsPersisting`, `HistoryPersisting`.
- `LocalSendRuntimeAdapter.swift`: concrete `TransferRuntime` actor. Bridges LocalSendKit to the module. Starts/stops `LocalSendNode`, announces/refresh discovery, maps `DiscoveredPeer` to `NearbyPeerItem`, sends files via `prepareUpload` + `upload`, responds to incoming requests, and observes runtime progress via `AsyncStream`.
- `SettingsPersistenceAdapter.swift`: stores `TransferSettingsSnapshot` as JSON in `UserDefaults` under key `FeatureTransfer.settings`.
- `HistoryPersistenceAdapter.swift`: stores `[HistoryEntry]` as JSON in `history.json` under Application Support.
- `LoginItemManaging.swift`: `LoginItemManaging` protocol and `SMAppServiceLoginItemManager` implementation using `ServiceManagement`/`SMAppService` for launch-at-login.
- `SendEntryActions.swift`: closure bag for send entry points. `SendEntryKind` enumerates file, folder, text, and clipboard.
- `MenuBarExtraView.swift`: `TransferMenuActions` closure bag and `TransferMenuBarExtraView`, which builds the macOS menu bar extra from the store.

### Views

- `RootView.swift`: main app shell. `NavigationSplitView` with sidebar, detail screen selection, feedback banner, toolbar, and sheet presentation for incoming requests and progress.
- `ReceiveView.swift`: discoverable receive screen with animated hero, device name, and Quick Save control.
- `SendView.swift`: send screen with entry-type buttons, staged item grid, nearby device grid, refresh/scan buttons, and drop zone.
- `HistoryView.swift`: recent transfers list with clear-all confirmation and empty state.
- `SettingsView.swift`: grouped settings form for appearance, language, menu bar, save location, incoming PIN, auto-accept favorites, and network toggles.
- `DeviceCardView.swift`: card for a nearby peer with hover effects, availability pulse, and send affordance.
- `HistoryRowView.swift`: row for a history entry with direction icon, file name, subtitle, timestamp, outcome, and actions menu.
- `IncomingRequestSheet.swift`: sheet for incoming file requests with selectable file list and accept/decline actions.
- `TransferProgressSheet.swift`: sheet showing active transfer progress with cancel and completion UI.
- `SendTextEntrySheet.swift`: modal text editor for composing text to be staged as a temporary `.txt` file.
- `LocalizationSupport.swift`: `FeatureTransferLocalization` helper that wraps `String(localized:bundle:)` with fallback to the English catalog.

## Screen Flow

1. The app opens on `ReceiveView`. The runtime is running and announcing the device.
2. The user selects a screen from the sidebar or uses a keyboard shortcut.
3. On `SendView`, the user stages files/folders/text and picks a nearby device.
4. The store calls `LocalSendRuntimeAdapter.send(items:to:)` which prepares the upload and uploads each file.
5. On the receiver, LocalSendKit raises an `IncomingTransferRequest`. The store presents `IncomingRequestSheet`.
6. The user accepts or rejects. The decision flows back to LocalSendKit through `respondToIncomingTransfer`.
7. During transfer, `TransferProgressSheet` shows progress. When done, a `HistoryEntry` is recorded.

## Settings

Settings are stored in `TransferSettingsSnapshot` and persisted to `UserDefaults`. Changing network-related settings (device name, port, HTTPS, PIN, allow downloads) triggers `LocalSendRuntimeAdapter.updateSettings`, which stops and restarts the LocalSend node.

| Setting | Storage | Notes |
|---------|---------|-------|
| Device name | Snapshot | Used in `RegisterInfo` for announcements. |
| Appearance | Snapshot | System / light / dark. |
| Accent color | Snapshot | One of several preset accent choices. |
| Language | Snapshot | System default or one of 17 supported languages. |
| Menu bar extra | Snapshot | Shows or hides the menu bar icon. |
| Launch at login | Snapshot | Backed by `SMAppService`. |
| Save location | Snapshot | Default download folder for received files. |
| Incoming PIN | Snapshot | Optional PIN required by LocalSendKit. |
| Auto-accept favorites | Snapshot | Automatically accept transfers from favorite peers. |
| Allow downloads | Snapshot | Enables the reverse transfer API in LocalSendKit. |
| HTTPS | Snapshot | Toggles TLS in LocalSendKit. |
| Port | Snapshot | TCP and UDP port for LocalSendKit. |

## Localization

- Catalog: `Resources/Localizable.xcstrings`.
- Default language: English.
- Supported languages: Arabic, Indonesian, Urdu, Bengali, Hindi, Turkish, English, French, Russian, Uyghur, Simplified Chinese, Spanish, Brazilian Portuguese, German, Vietnamese, Korean, Japanese, and system default.
- `LanguageSetting` stores the chosen language. `View.applyingLanguageOverride` injects the matching `Locale` into the SwiftUI environment for non-system choices.
- All user-facing strings, accessibility labels, and feedback messages are keyed through the catalog.
