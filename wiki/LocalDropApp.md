# LocalDropApp

LocalDropApp is the thin macOS app target. It owns the `App` protocol, the main window, the menu bar extra, and system integrations. It delegates all business logic to FeatureTransfer.

See also: [FeatureTransfer](./FeatureTransfer.md).

## Files

- `LocalDropApp.swift`: the `@main` app struct.
- `SendEntryPresentationState.swift`: helper struct tracking presentation flags for file, folder, and text importers.
- `Info.plist`: app metadata and entitlements reference.
- `Assets.xcassets/`: app icons and accent color.

## LocalDropApp.swift

`LocalDropApp` conforms to `App` and creates a single `TransferFeatureContainer` instance.

### Launch Behavior

The `init()` method inspects `ProcessInfo.processInfo.arguments` to choose between live and testing containers:

- `--ui-testing`: uses `TransferFeatureContainer.testing(requirePIN:)`.
- `--ui-testing-incoming-pin-enabled`: enables the incoming PIN in the testing container.
- `--ui-testing-seed-staged-batch`: pre-stages sample files after creating the testing container.

It records the launch mode via `recordLaunchStarted(mode:)`.

### Main Window

- `WindowGroup(id: "main")` hosts `container.rootView(sendEntryActions:)`.
- Default size: 1120 by 704 points.
- Window resizability uses `.contentMinSize`.
- Toolbar style is unified.
- The view attaches file importers, folder importers, and the text entry sheet.
- A `.task` starts the runtime if needed and wires the AppDelegate's menu-bar minimize provider.

### Menu Commands

The `.commands` block replaces and extends standard macOS menus:

- **File / New Item replacement**: Send File (Cmd+O), Send Folder (Cmd+Shift+O), Send Text (Cmd+T), Clear History (Cmd+Delete).
- **App Settings replacement**: Preferences (Cmd+,).
- **View menu**: Receive (Cmd+1), Send (Cmd+2), History (Cmd+3), Settings (Cmd+4).
- **Help menu**: LocalDrop Help, LocalSend Protocol Docs, Report an Issue.

### Menu Bar Extra

A `MenuBarExtra` scene renders `container.menuBarExtraView(actions:)` using a symbol chosen by `container.menuStatusSymbol`. The style is `.menu`.

### AppDelegate

`AppDelegate` conforms to `NSApplicationDelegate` and implements `applicationShouldTerminateAfterLastWindowClosed`. When the user enabled minimize-to-menu-bar, the app keeps running after the last window closes. Otherwise it terminates normally.

## SendEntryPresentationState.swift

A simple mutable struct with flags for the file importer, folder importer, and text entry sheet. Provides methods to begin and finish each flow. The app target does not use this struct directly in the current build; it manages state inline with `@State` properties instead.

## System Integration

- The app uses `openWindow(id:)` to bring the main window forward.
- File and folder importers use SwiftUI's `fileImporter` with `UniformTypeIdentifiers`.
- The text entry sheet is a SwiftUI `.sheet`.
- Help links open in the default browser.

## Configuration

The app target is configured in `project.yml`:

- Bundle identifier prefix: `com.localdrop`
- Product bundle identifier: `com.localdrop.LocalDrop`
- Deployment target: macOS 14.0
- Hardened runtime enabled.
- Marketing version: 1.0
- Current project version: 1
