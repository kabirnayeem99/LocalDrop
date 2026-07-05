# LocalDrop AI Agent Plan: Native macOS AppKit Client for LocalSend

## Goal

Build **LocalDrop**, a native macOS AppKit application that implements the LocalSend protocol for local-network file transfer.

The AI agent may search online when needed. Prefer official Apple documentation, LocalSend protocol documentation, and current macOS development references.

LocalDrop should feel like a native macOS utility: lightweight, polished, fast, and deeply integrated with Finder, drag-and-drop, menu bar workflows, and macOS Human Interface Guidelines.

## Core Product Direction

LocalDrop is not an Electron, Flutter, or web-style clone. It should feel like:

```text
AirDrop + Finder + simple transfer queue
```

The first priority is **LocalSend protocol compatibility**. The second priority is **native macOS polish**.

## Main Agent Rule

```text
Build LocalDrop as a native macOS AppKit app. Prefer AppKit-native controls, system spacing, sheets, toolbars, menus, SF Symbols, and macOS Human Interface Guidelines. Keep protocol, networking, and transfer logic separate from UI. Never block the main thread. All file transfer operations must stream data and report cancellable progress. Design for LocalSend protocol compatibility first, then macOS polish.
```

---

# 1. Required Knowledge Areas

The agent should be able to work across these areas:

```text
AppKit UI
macOS Human Interface Guidelines
Drag and drop
File system and sandboxing
Local network permissions
Networking and transfer progress
TLS, certificates, and trusted devices
Menu bar utilities
Finder integration
Notifications
Preferences and persistence
Packaging and distribution
Testing
Visual polish and accessibility
```

---

# 2. Native AppKit UI Skill

The agent should know how to build and maintain native AppKit components.

Important AppKit types:

```text
NSApplication
NSApplicationDelegate
NSWindow
NSWindowController
NSViewController
NSView
NSStackView
NSTableView
NSCollectionView
NSButton
NSTextField
NSProgressIndicator
NSVisualEffectView
NSPopover
NSMenu
NSStatusItem
NSToolbar
NSSplitViewController
```

For LocalDrop, this should support:

```text
Main window
Nearby devices list
Drop zone
Transfer progress panel
Settings window
Menu bar item
Receive request dialog
Transfer history screen
Trusted devices screen
```

Implementation expectations:

```text
Use programmatic AppKit where practical.
Avoid unnecessary storyboard complexity.
Separate UI controllers from transfer/protocol logic.
Do not block the main thread.
Update UI on the main actor/main thread only.
Use native AppKit controls before creating custom controls.
```

---

# 3. macOS Human Interface Skill

The agent should follow macOS Human Interface Guidelines.

The app should understand and use:

```text
Toolbar layout
Sidebar/list-detail layout
Native titlebar behavior
Vibrancy
System icons
Keyboard shortcuts
Context menus
Sheets
Native spacing
Native button order
Destructive button styling
Focus rings
Standard app menus
```

Important UX rule:

```text
Use sheets for window-attached decisions.
Do not use random custom web-style modal popups.
```

Example:

```text
File receive confirmation should appear as a sheet attached to the active LocalDrop window.
```

LocalDrop should feel like a real macOS app, not a cross-platform port.

---

# 4. Drag-and-Drop Skill

Drag-and-drop is a core LocalDrop feature.

The agent should understand:

```text
NSDraggingDestination
NSDraggingInfo
NSPasteboard
NSPasteboard.PasteboardType.fileURL
registerForDraggedTypes
draggingEntered
draggingUpdated
prepareForDragOperation
performDragOperation
concludeDragOperation
```

Required use cases:

```text
Drag files into LocalDrop window.
Drag folders into LocalDrop window.
Drag files directly onto a nearby device row.
Drag files onto the menu bar item if supported later.
Drag received files out of LocalDrop later.
```

Expected behavior:

```text
Highlight the drop zone on valid drag.
Reject unsupported pasteboard contents.
Support multiple files.
Support folders.
Resolve file URLs safely.
Validate file existence before transfer.
Show a clear transfer preview before sending.
```

---

# 5. File System and Sandbox Skill

The agent should handle macOS file access correctly.

Important APIs and concepts:

```text
NSOpenPanel
NSSavePanel
FileManager
URL resource values
security-scoped bookmarks
Downloads folder access
Application Support folder
temporary files
folder traversal
file permissions
quarantine attributes
large file streaming
```

LocalDrop requirements:

```text
Let user choose files/folders.
Let user choose default download location.
Store received files safely.
Avoid loading entire large files into memory.
Stream file transfers.
Handle duplicate filenames.
Handle unavailable or deleted source files.
Handle permission errors gracefully.
```

For a possible Mac App Store release, sandboxing must be considered early.

---

# 6. Local Network Permission Skill

Modern macOS apps must handle local-network access carefully.

The agent should know how to configure:

```text
Info.plist
NSLocalNetworkUsageDescription
Bonjour service declarations when required
Network.framework
NWBrowser
NWConnection
URLSession
local HTTPS requests
firewall-friendly behavior
```

LocalDrop requirements:

```text
Discover nearby LocalSend-compatible devices.
Handle missing local-network permission.
Show useful error messages when discovery fails.
Handle devices appearing and disappearing.
Avoid assuming all devices remain reachable.
```

The agent should search current Apple documentation before finalizing local network permission keys or Bonjour service configuration.

---

# 7. Networking and Transfer Integration Skill

The agent must ensure networking does not block AppKit UI.

Preferred tools:

```text
Swift async/await
URLSession
Network.framework
OperationQueue
DispatchQueue
Progress
NotificationCenter
Combine, if useful
MainActor for UI updates
```

LocalDrop architecture expectations:

```text
DiscoveryService runs in the background.
TransferSession reports progress.
TransferQueue manages multiple transfers.
UI observes transfer state.
Cancel and retry work cleanly.
Network errors are surfaced clearly.
```

Required transfer states:

```text
pending
waitingForReceiver
accepted
rejected
transferring
paused, if supported later
cancelled
failed
completed
```

The agent should never perform heavy file or network work on the main thread.

---

# 8. Security, TLS, and Certificate Skill

The agent should understand LocalSend-style local HTTPS behavior and device trust.

Important concepts:

```text
TLS certificate handling
self-signed certificates
certificate pinning
device fingerprinting
Keychain storage
trust-on-first-use model
secure random token/session generation
local-only threat model
```

LocalDrop security expectations:

```text
Do not blindly trust every device forever.
Store trusted device fingerprints.
Use Keychain for sensitive trust data where appropriate.
Show device identity clearly.
Warn if a known device fingerprint changes.
Avoid logging sensitive transfer tokens.
Avoid exposing local file paths unnecessarily.
```

Trusted device behavior:

```text
First transfer: ask user to trust/allow as needed.
Known trusted device: allow smoother workflow.
Fingerprint changed: show warning and require confirmation.
```

---

# 9. Menu Bar App Skill

LocalDrop should become a menu bar utility after the MVP.

The agent should understand:

```text
NSStatusBar
NSStatusItem
NSMenu
NSPopover
activation policy
launch at login
background helper behavior
menu bar icon states
```

Possible menu bar UX:

```text
Nearby devices submenu
Drop files onto menu bar item
Recent transfers
Receive on/off toggle
Open LocalDrop
Open Downloads folder
Quit
```

Expected behavior:

```text
Menu bar mode should not feel like a second app.
Main window and menu bar should share the same transfer engine.
Menu bar should show active transfer status.
```

---

# 10. Finder Integration Skill

Finder integration is not required for the first MVP, but should be planned.

The agent should understand:

```text
Finder Sync Extension
Share Extension
Services
Quick Actions
NSSharingService
right-click context menu integration
```

Future feature:

```text
Right click file > Send with LocalDrop > Choose device
```

Possible Finder workflows:

```text
Send selected files to nearby device.
Send current folder.
Open received file in Finder.
Reveal transfer destination.
```

Finder integration should be added only after the core protocol and transfer engine are stable.

---

# 11. Notifications Skill

The agent should support native macOS notifications.

Important APIs:

```text
UserNotifications
UNUserNotificationCenter
notification authorization
notification actions
click-to-open behavior
```

Use cases:

```text
File received.
Transfer completed.
Transfer failed.
Device request waiting.
Receiver rejected transfer.
Sender cancelled transfer.
```

Expected behavior:

```text
Ask notification permission at an appropriate time.
Do not spam notifications while the app is foregrounded.
Clicking a notification should open LocalDrop or reveal the file.
```

---

# 12. Preferences and Persistence Skill

The agent should persist user preferences cleanly.

Important storage tools:

```text
UserDefaults
Keychain
Application Support folder
Codable settings files
settings migration
recent devices storage
trusted devices storage
```

LocalDrop settings:

```text
Device name
Download folder
Auto-accept from trusted devices
Show in menu bar
Start at login
Protocol port
Trusted devices
Transfer history
Discovery visibility
Notification preferences
```

Expected behavior:

```text
Settings should be versioned or safely migratable.
Invalid saved paths should be handled gracefully.
Trusted devices should be editable/removable.
```

---

# 13. Packaging and Distribution Skill

The agent should understand macOS app shipping.

Important concepts:

```text
Xcode project setup
code signing
hardened runtime
notarization
DMG generation
Sparkle auto-update
Homebrew cask
Mac App Store limitations
entitlements
sandboxing
```

Recommended early distribution target:

```text
GitHub release .dmg
Signed and notarized app
Sparkle updater
Later: Homebrew cask
```

The agent should search current Apple documentation before implementing final signing, notarization, or sandbox entitlements.

---

# 14. Testing Skill

The agent should write tests from the beginning.

Important testing areas:

```text
XCTest for protocol models
unit tests for file payload creation
mock LocalSend device server
UI tests for drag-and-drop basics
integration tests with official LocalSend app
large file transfer tests
network interruption tests
certificate/fingerprint tests
```

Critical test cases:

```text
Send one small file.
Send one large file.
Send a folder.
Cancel midway.
Receiver rejects transfer.
Receiver disappears during transfer.
Duplicate filename on receive.
No local network permission.
Invalid certificate.
Known device fingerprint changed.
App relaunched during/after transfer.
```

Mocking expectations:

```text
Use mock device discovery.
Use mock receiver server.
Use temporary directories for file tests.
Avoid requiring real LAN devices for unit tests.
Keep real LocalSend compatibility tests as integration tests.
```

---

# 15. AppKit Visual Polish Skill

The agent should know native macOS visual details.

Important UI concepts:

```text
NSVisualEffectView
SF Symbols
NSToolbar
sidebar-style source list
hover states
focus ring
accessibility labels
dark mode
reduced motion
high contrast
empty states
error states
```

LocalDrop visual direction:

```text
Simple.
Native.
Fast.
Calm.
Finder-like.
AirDrop-inspired, but not a clone.
```

Avoid:

```text
Web-style cards everywhere.
Overly custom buttons.
Fake titlebars.
Non-native spacing.
Heavy animations.
Electron-like layouts.
```

---

# 16. Recommended Skill File Structure

If creating repo-local skill guidance, organize it like this:

```text
skills/
├── appkit-ui.md
├── appkit-drag-drop.md
├── appkit-windowing.md
├── appkit-menu-bar.md
├── macos-networking.md
├── macos-filesystem-sandbox.md
├── macos-security-keychain.md
├── localsend-protocol.md
├── transfer-engine.md
├── packaging-notarization.md
└── apple-hig-review.md
```

---

# 17. MVP Priority

For the first usable LocalDrop MVP, prioritize these skills:

```text
1. localsend-protocol.md
2. macos-networking.md
3. appkit-drag-drop.md
4. transfer-engine.md
5. appkit-ui.md
```

Do not start with advanced Finder integration, menu bar drop targets, auto-updater, or complex visual polish.

The MVP should prove:

```text
LocalDrop can discover LocalSend devices.
LocalDrop can send files to official LocalSend clients.
LocalDrop shows reliable progress.
LocalDrop handles accept/reject/cancel/failure.
LocalDrop feels native enough to use daily.
```

---

# 18. Suggested Implementation Phases

## Phase 1: Protocol Research and Discovery

Goal:

```text
Understand the current LocalSend protocol and discover nearby devices.
```

Tasks:

```text
Search official LocalSend protocol documentation.
Identify discovery mechanism.
Implement device model.
Implement discovery service.
Build debug device list.
Test with official LocalSend app on phone/desktop.
```

Done when:

```text
LocalDrop can show nearby official LocalSend devices.
```

## Phase 2: Send One File

Goal:

```text
Send a single file to an official LocalSend receiver.
```

Tasks:

```text
Implement transfer metadata.
Implement sender request flow.
Implement receiver accept/reject handling.
Stream file upload.
Show transfer progress.
Handle failure and cancellation.
```

Done when:

```text
LocalDrop can send one small file successfully.
```

## Phase 3: AppKit MVP UI

Goal:

```text
Make the sender experience usable and native.
```

Tasks:

```text
Create main AppKit window.
Add nearby devices list.
Add drag-and-drop zone.
Add selected files preview.
Add progress list.
Add cancel/retry controls.
Add basic error states.
```

Done when:

```text
A user can drag a file, choose a device, and send it successfully.
```

## Phase 4: Multi-file and Folder Support

Goal:

```text
Support real-world file sending.
```

Tasks:

```text
Support multiple selected files.
Support folders.
Calculate total size.
Stream large files.
Preserve folder structure if protocol supports it.
Handle duplicate filenames.
```

Done when:

```text
LocalDrop can send common file/folder selections reliably.
```

## Phase 5: Receive Mode

Goal:

```text
Allow LocalDrop to receive files.
```

Tasks:

```text
Implement local receiver server.
Show receive confirmation sheet.
Save files to configured folder.
Show progress.
Notify on completion.
Handle trusted device behavior.
```

Done when:

```text
Official LocalSend clients can send files to LocalDrop.
```

## Phase 6: Trust and Security

Goal:

```text
Make device trust safer and more user-friendly.
```

Tasks:

```text
Store device fingerprints.
Use Keychain where appropriate.
Warn on fingerprint changes.
Add trusted devices settings.
Avoid sensitive logs.
```

Done when:

```text
LocalDrop has a clear trust model for nearby devices.
```

## Phase 7: Menu Bar Utility

Goal:

```text
Make LocalDrop convenient for daily use.
```

Tasks:

```text
Add NSStatusItem.
Show nearby devices in menu.
Show current transfer status.
Add receive toggle.
Add open downloads action.
Add quit/open app actions.
```

Done when:

```text
LocalDrop works well as a background menu bar utility.
```

## Phase 8: Packaging

Goal:

```text
Ship a usable public build.
```

Tasks:

```text
Set app icon.
Configure signing.
Configure hardened runtime.
Notarize app.
Generate DMG.
Prepare GitHub release.
Optionally add Sparkle updater.
```

Done when:

```text
A user can download, install, open, and use LocalDrop without Gatekeeper issues.
```

---

# 19. Architecture Rules

The agent should keep the project modular.

Recommended structure:

```text
LocalDrop/
├── App/
│   ├── AppDelegate.swift
│   ├── MainWindowController.swift
│   └── PreferencesWindowController.swift
│
├── UI/
│   ├── DeviceListViewController.swift
│   ├── DropZoneView.swift
│   ├── TransferProgressView.swift
│   ├── ReceiveRequestSheetController.swift
│   └── SettingsViewController.swift
│
├── ProtocolCore/
│   ├── LocalSendModels.swift
│   ├── DiscoveryService.swift
│   ├── LocalSendHTTPClient.swift
│   ├── TransferSession.swift
│   └── CertificateManager.swift
│
├── Transfer/
│   ├── FilePayloadBuilder.swift
│   ├── UploadManager.swift
│   ├── DownloadManager.swift
│   ├── ProgressTracker.swift
│   └── TransferQueue.swift
│
├── Persistence/
│   ├── SettingsStore.swift
│   ├── TrustedDeviceStore.swift
│   └── TransferHistoryStore.swift
│
├── Platform/
│   ├── NotificationsManager.swift
│   ├── KeychainStore.swift
│   ├── LoginItemManager.swift
│   └── FileAccessManager.swift
│
└── Shared/
    ├── Logger.swift
    ├── ResultTypes.swift
    └── NetworkUtils.swift
```

Rules:

```text
UI must not directly implement protocol logic.
ProtocolCore must not depend on AppKit.
Transfer engine must be testable without UI.
File transfer must be cancellable.
Large files must be streamed.
All UI updates must happen on the main thread.
```

---

# 20. Research Rules for the AI Agent

The agent may search online.

When searching, prefer:

```text
Official Apple Developer documentation
Apple Human Interface Guidelines
Official LocalSend protocol documentation
LocalSend source code
Swift.org documentation
Sparkle documentation
Current macOS notarization/signing references
```

Avoid relying only on:

```text
Old Stack Overflow answers
Outdated AppKit tutorials
Unmaintained GitHub snippets
Generic SwiftUI-only advice
Electron/Flutter desktop patterns
```

Before implementing security, local-network permissions, Bonjour, signing, notarization, or sandbox entitlements, the agent should verify current documentation.

---

# 21. Definition of Done for MVP

The MVP is done when:

```text
The app launches as a native macOS AppKit app.
Nearby LocalSend-compatible devices are discovered.
A user can drag one or more files into the app.
A user can choose a target device.
The receiver can accept or reject.
Transfer progress is shown.
Cancel works.
Failure states are understandable.
The UI remains responsive during transfer.
The app uses native macOS controls and layout.
The app can interoperate with the official LocalSend app.
```

Non-MVP features:

```text
Finder extension
Menu bar drop target
Auto updater
Transfer history
Trusted auto-accept
Mac App Store sandboxing
Advanced animations
iOS/iPadOS companion app
Linux/Windows clients
```

---

# 22. Final Priority Reminder

Do not overbuild the UI before the protocol works.

The phase 0 and 1 skills to implement first are:

```text
1. localsend-protocol.md
2. macos-networking.md
```

Without protocol compatibility, LocalDrop is only a nice-looking shell.

Without a real networking core, LocalDrop cannot prove protocol compatibility.

After phase 1 is stable, the next UI-facing skill should be:

```text
3. appkit-drag-drop.md
```
