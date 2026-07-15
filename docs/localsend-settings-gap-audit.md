# LocalSend Settings Gap Audit

Reference audited on 2026-07-15 against `localsend/localsend` `main` (`b43b79504953001156f5c1728f7ab7df565dda4a`).

Reference files:

- `/tmp/localsend-audit/app/lib/pages/tabs/settings_tab.dart`
- `/tmp/localsend-audit/app/lib/pages/tabs/settings_tab_controller.dart`
- `/tmp/localsend-audit/app/lib/pages/settings/network_interfaces_page.dart`

SwiftUI client files inspected:

- `Modules/FeatureTransfer/Sources/FeatureTransfer/SettingsView.swift`
- `Modules/FeatureTransfer/Sources/FeatureTransfer/Application/TransferFeatureStore.swift`
- `Modules/FeatureTransfer/Sources/FeatureTransfer/Application/TransferFeatureContainer.swift`
- `App/LocalDropApp/LocalDropApp.swift`

## Framing

This audit is macOS-specific, not a raw one-to-one copy of Flutter LocalSend's Settings tab.

- Items that are mobile-only, Linux-only, Windows-only, or otherwise not meaningful for a native macOS client are not treated as gaps.
- Items that LocalDrop already exposes in a more idiomatic macOS surface, such as app menus, the About view, or the menu bar extra, are not treated as settings-page gaps.
- Items that can be validly adapted for macOS are called out as adaptations, not misses.

## Summary

LocalDrop does not have a hidden "advanced settings" mode like LocalSend, but that is not a gap by itself. The real parity gaps are narrower:

- receive-side options such as `Quick Save`, `Quick Save from Favorites`, `Auto finish`, and `Save to history`
- advanced network controls such as editable `port`, interface filtering, `discovery timeout`, and `multicast group`
- a few desktop utility options with plausible macOS equivalents, such as window-placement persistence and an "open minimized to menu bar" style startup behavior

After checking overlapping settings for real wiring, the main clear business-logic gap in LocalDrop remains `autoAcceptFavorites`, which is persisted but not consumed anywhere else.

## Not Counted As Gaps

### Platform-specific or not meaningful for macOS

- `OLED` and `Yaru` under LocalSend's color modes are not macOS requirements.
- `Save to gallery` is not applicable to this macOS app.
- `Show in context menu` is Windows-specific in LocalSend.
- `Terms of use` is only shown by LocalSend on Apple platforms because of App Store packaging; that placement is not a LocalDrop settings requirement.

### Covered elsewhere in LocalDrop in a more macOS-native way

- `About`, `Privacy policy`, `Support`, and `Terms of use` should not be counted as missing settings entries.
  LocalDrop already exposes these through app-level surfaces in `LocalDropApp.swift`, including `AboutLocalDropView`, help links, and the macOS command/menu structure.
- Version / app-info footer content is also better treated as About/menu content than a Settings requirement on macOS.
- `Accent color` is an acceptable macOS-native replacement for LocalSend's broader cross-platform color-mode menu.

### Valid adaptation instead of strict parity

- `Launch minimized` should be interpreted on macOS as "launch directly into menu bar/background state" rather than copied literally from LocalSend's desktop toggle wording.
- Lack of an explicit advanced-settings switch is acceptable if advanced controls are either always visible or intentionally omitted.

## Real UI Gaps

### Still missing and relevant on macOS

#### Receive

- `Quick Save` toggle is missing.
- `Quick Save from Favorites` toggle is missing.
- Destination reset-to-default behavior is missing.
  LocalSend lets the user clear the custom destination back to Downloads from the same row; LocalDrop currently only exposes picking a folder.
- `Auto finish` is missing.
- `Save to history` is missing.

#### Network

- Editable `Port` field is missing. LocalDrop shows the port as read-only text.
- `Network interfaces` filter UI is missing.
- `Discovery timeout` field is missing.
- `Multicast group` field is missing.

#### Desktop utility / advanced behavior

- `Save window placement` has no LocalDrop equivalent.
- There is no macOS-adapted equivalent for LocalSend's `Launch minimized`.
  For LocalDrop, this would more likely be "launch hidden / open in menu bar" behavior.

### Missing, but lower priority or product-choice dependent

- `Device type` selector is missing.
- `Device model` text field is missing.
- Manual server lifecycle controls in Settings (`Start`, `Restart`, `Stop`) are missing.
  This matters only if LocalDrop wants Settings to own runtime restart semantics the way LocalSend does.

## Different UI, But Acceptable

- `Language`:
  LocalSend opens a dedicated page; LocalDrop uses an inline picker.
- `Appearance / Brightness`:
  LocalSend exposes `ThemeMode`; LocalDrop uses an appearance picker plus accent-color selection.
- `Device name / Alias`:
  Both apps expose random alias and system-name shortcuts, but LocalDrop uses a different control layout.
- `Require PIN`:
  LocalSend uses a dialog; LocalDrop uses an inline toggle plus dedicated PIN controls.
- `Save location / Destination`:
  Both expose directory selection, but LocalDrop lacks LocalSend's clear-to-default affordance.
- `Launch on login / startup`:
  Both expose the core startup toggle even though LocalSend also exposes a follow-up minimized-launch option.
- `Minimize to tray / menu bar`:
  LocalDrop's menu bar model is a valid macOS adaptation of LocalSend's tray behavior.

## Present In LocalDrop, Not In LocalSend Settings

- `Reduce motion` toggle.
- Inline `Incoming PIN` management:
  show/hide, apply, regenerate.
- Top-level `Allow downloads` toggle.
- `Accent color` swatch row.

These are not regressions; they are additional or more tailored macOS settings.

## Business Logic Differences Where UI Overlaps

### Clear logic gap in LocalDrop

- `Auto accept favorites` is currently a persisted-only setting in LocalDrop.
  It exists in `SettingsView`, `TransferFeatureStore`, and `TransferSettingsSnapshot`, but there is no usage outside persistence/tests.

### Logic differs, but LocalDrop is wired

- `HTTPS / encryption`:
  LocalSend stores the setting and expects a manual server restart from Settings when alias/port/HTTPS differs from the running server.
  LocalDrop persists the toggle and pushes it through `runtime.updateSettings(...)`, with runtime rebuild/restart coverage in tests.
- `Launch at login / startup`:
  LocalDrop wires `launchAtLogin` through `SMAppServiceLoginItemManager`, persists the reconciled state, and reverts the toggle on failure.
- `Minimize to menu bar / tray`:
  LocalDrop is wired through `TransferFeatureContainer.shouldMinimizeToMenuBar` into `LocalDropApp`'s app delegate termination behavior, so this is not just stored state.
- `Language`:
  LocalDrop applies the language override to both `RootView` and the menu bar extra, so this is not a no-op.
- `Save location`:
  LocalDrop persists the folder and pushes it into live protocol/runtime settings, but it lacks LocalSend's clear-to-default flow.
- `Require PIN`:
  LocalDrop's PIN is live-wired into runtime settings and runtime construction, and it supports regeneration plus exact-length validation.

## Net Result

If the goal is macOS-appropriate parity with LocalSend, LocalDrop is not missing large parts of the settings experience just because Flutter LocalSend has a bigger Settings tab. The meaningful remaining gaps are:

- receive-flow settings: `Quick Save`, `Quick Save from Favorites`, `Auto finish`, `Save to history`, and destination reset-to-default
- advanced network controls: editable `port`, interface filters, `discovery timeout`, `multicast group`
- desktop adaptation gaps: window-placement persistence and an optional "launch hidden to menu bar" startup mode

If the goal is correctness of already-shipped LocalDrop settings, the most concrete follow-up is still to either wire `autoAcceptFavorites` into a real favorites-based receive path or remove the toggle until that behavior exists.
