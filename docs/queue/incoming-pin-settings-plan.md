# Incoming PIN Settings Plan

## Goal

Replace the hardcoded incoming-transfer PIN with a user-configurable setting so `Require PIN for incoming` is a complete, trustworthy feature.

## Current state

- `SettingsView` exposes `Require PIN for incoming`.
- `TransferFeatureContainer.live()` maps that toggle to `pin: settings.requirePIN ? "000000" : nil`.
- `TransferProtocolSettings` has `requirePIN` but no stored PIN value.
- The runtime already supports arbitrary PIN strings through `LocalSendRuntimeConfiguration` and `LocalSendServerConfiguration`.

## Desired behavior

- When PIN protection is off, LocalDrop behaves exactly as it does today with no PIN requirement.
- When PIN protection is enabled, LocalDrop uses a real persisted PIN instead of a hardcoded value.
- The Settings page lets the user view and edit the PIN in a clear macOS-native flow.
- Enabling PIN protection without an existing PIN produces a valid default PIN automatically.
- Runtime updates continue to apply through the existing `persistSettings()` and `runtime.updateSettings()` path.

## Implementation plan

### 1. Extend the settings model

- Add a persisted `incomingPIN` field to `TransferProtocolSettings`.
- Keep `requirePIN` as the feature toggle and treat `incomingPIN` as the backing value when the toggle is on.
- Update `TransferSettingsSnapshot.default(...)` to generate a valid default PIN string for first launch.
- Add decode compatibility so older saved settings without `incomingPIN` still load successfully and receive a fallback PIN value.

### 2. Add store helpers for PIN lifecycle

- Add `incomingPIN` state to `TransferFeatureStore`.
- Include `incomingPIN` in `currentProtocolSettings` and `makeSnapshot()`.
- Add helper methods instead of pushing PIN rules into the view:
  - `ensureIncomingPIN()` to create a PIN when the toggle is enabled and the current value is empty or invalid.
  - `updateIncomingPIN(_:)` to sanitize, persist, and push runtime updates.
  - `maskedIncomingPIN` or equivalent presentation helper if the UI should support hidden/revealed display.
- Keep validation centralized in the store or model layer so tests do not depend on SwiftUI behavior.

### 3. Replace the hardcoded runtime wiring

- Update `TransferFeatureContainer.live()` so `LocalSendRuntimeConfiguration.pin` uses the persisted PIN when `requirePIN` is true.
- Remove the `"000000"` literal entirely.
- Preserve the existing runtime restart behavior through `runtime.updateSettings(...)`.

### 4. Expand the Settings UI

- In the `Receiving` section, keep the existing toggle and add a PIN row directly beneath it.
- Suggested control shape:
  - `SecureField` or `TextField` with a reveal/hide toggle.
  - Disabled while `requirePIN == false`.
  - Inline helper copy explaining that nearby senders must enter this PIN before upload is accepted.
- Add a `Regenerate` action that creates a fresh valid PIN without forcing manual entry.
- When the user enables PIN protection:
  - Ensure a PIN exists before persisting.
  - Show the existing explanatory alert, updated to mention that the configured PIN will be required.
- Avoid persisting partial invalid edits on every keystroke; commit on submit, focus loss, or explicit action.

### 5. Define validation and UX rules

- Pick one PIN format and enforce it consistently. Recommended: exactly 6 numeric digits, matching the existing LocalSend test shapes.
- Sanitize non-digit input before saving.
- Reject invalid manual values with inline error text or revert-on-submit plus banner feedback.
- Never allow `requirePIN == true` with an empty invalid persisted PIN after a successful save.

### 6. Add migration-safe persistence coverage

- Add tests for:
  - Loading older settings blobs that omit `incomingPIN`.
  - Default snapshot generation including a non-empty PIN.
  - Persisting and reloading a custom PIN value.

### 7. Add feature/runtime tests

- Extend `FeatureTransferTests` to cover:
  - Enabling PIN generates a PIN when missing.
  - Updating the PIN persists the new value.
  - Runtime settings receive the configured PIN through `updateSettings(...)`.
- Extend the fake runtime test surface if needed so the last pushed settings include the PIN field.

### 8. Add UI-level verification

- Add at least one UI or view-level test for the Settings flow:
  - Opening Settings.
  - Enabling PIN protection.
  - Confirming the PIN editor appears or becomes enabled.
  - Saving/regenerating a PIN.

## File targets

- `Modules/FeatureTransfer/Sources/FeatureTransfer/Models/FeatureTransferModels.swift`
- `Modules/FeatureTransfer/Sources/FeatureTransfer/Application/TransferFeatureStore.swift`
- `Modules/FeatureTransfer/Sources/FeatureTransfer/Application/TransferFeatureContainer.swift`
- `Modules/FeatureTransfer/Sources/FeatureTransfer/SettingsView.swift`
- `Modules/FeatureTransfer/Sources/FeatureTransfer/Infrastructure/SettingsPersistenceAdapter.swift` if migration helpers belong there
- `Modules/FeatureTransfer/Tests/FeatureTransferTests/FeatureTransferTests.swift`
- `Tests/LocalDropAppUITests/...` if a Settings UI test is added

## Recommended implementation order

1. Add `incomingPIN` to the protocol settings model with backward-compatible decoding.
2. Thread the value through `TransferFeatureStore` and snapshot creation.
3. Replace the hardcoded runtime `"000000"` mapping.
4. Add validation/generation helpers in the store.
5. Update the Settings UI to edit and regenerate the PIN.
6. Add unit tests for migration, persistence, and runtime updates.
7. Add UI verification for the settings flow.

## Risks

- Saving on every keystroke can restart the runtime repeatedly if PIN edits reuse the current `persistSettings()` behavior.
- Backward compatibility matters because existing users already have settings persisted without a PIN field.
- The UX must avoid exposing a security toggle that appears enabled while the effective PIN is still invalid.

## Verification

- `swift test --package-path Modules/FeatureTransfer`
- Targeted LocalSendKit tests if model changes ripple into runtime fixtures.
- App-level verification after package changes:
  - `xcodegen generate`
  - `xcodebuild -scheme LocalDrop build`
- Manual flow:
  - Enable PIN, inspect/regenerate value, restart app, confirm value persists.
  - Attempt an incoming transfer with and without the correct PIN.
