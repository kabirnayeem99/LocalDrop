# LocalDrop Modules

LocalDrop is split into five modules plus a thin app target. Each module has one job and communicates through small, stable interfaces.

| Module | Path | Purpose |
|--------|------|---------|
| LocalSendKit | `Modules/LocalSendKit` | Implements the LocalSend wire protocol: discovery, HTTP server, HTTP client, TLS identity, sessions, and file streaming. |
| FeatureTransfer | `Modules/FeatureTransfer` | SwiftUI feature for sending, receiving, history, and settings. Bridges LocalSendKit into the UI. |
| DesignSystem | `Modules/DesignSystem` | Shared tokens and components: colors, typography, spacing, radius, and reusable views. |
| AppLogging | `Modules/AppLogging` | Structured logging with OpenTelemetry-shaped records, pluggable sinks, and redaction. |
| LocalDropApp | `App/LocalDropApp` | The macOS app entry point, menu commands, menu bar extra, and system integrations. |

Read the protocol spec first: [LocalSend Protocol v2.1](./LocalSend-Protocol.md).

## Module Dependency Graph

```
LocalDropApp
└── FeatureTransfer
    ├── LocalSendKit
    │   ├── AppLogging
    │   ├── swift-certificates (X509)
    │   └── swift-crypto (Crypto)
    ├── DesignSystem
    └── AppLogging
```

## How to Read This Wiki

- [LocalSendKit](./LocalSendKit.md): start here if you are working on networking, protocol compliance, discovery, or security.
- [FeatureTransfer](./FeatureTransfer.md): start here if you are working on UI, state flow, persistence, or user-facing behavior.
- [DesignSystem](./DesignSystem.md): start here if you are adding or changing UI components or visual style.
- [AppLogging](./AppLogging.md): start here if you are adding telemetry, diagnostics, or new sinks.
- [LocalDropApp](./LocalDropApp.md): start here if you are changing app lifecycle, menus, or system integrations.
- [Testing](./Testing.md): start here for test structure and how to run them.

## Quick Orientation

- The app target is intentionally thin. It owns the `App` protocol, `WindowGroup`, `MenuBarExtra`, and `AppDelegate`. It does not contain business logic.
- `FeatureTransfer` owns the UI state, settings, history, and the adapters that talk to LocalSendKit.
- `LocalSendKit` has no SwiftUI dependency. It exposes `AsyncStream` and `actor` based APIs that `FeatureTransfer` consumes on the main actor.
- `DesignSystem` and `AppLogging` are leaf modules. They are imported by `FeatureTransfer` and `LocalSendKit` but do not import them back.
