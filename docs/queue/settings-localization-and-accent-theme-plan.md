# Settings Localization and Accent Theme Plan

## Goal

Make the two remaining settings in `TransferFeatureStore` actually drive app behavior:

1. **Language** – persist a selected language and render the UI in that language using localized strings.
2. **Accent color** – persist a selected accent color and apply it across the app as the primary brand/tint color instead of the hardcoded green palette.

## Current state

- `AccentTheme` is defined in `DesignSystem/Color+Tokens.swift` as an environment-aware theme with `primary`, `primaryHover`, `primaryPressed`, `primaryDisabled`, and `primarySubtleFill`.
- `AccentColorChoice` in `Models/FeatureTransferModels.swift` vend a full `AccentTheme` and includes system colors, eight named custom palettes, and a system-accent option. Medina Emerald is the default.
- `LanguageSetting` in `TransferViewState.swift` covers the v1 supported-language set plus Uyghur, with endonyms and `Locale` identifiers.
- `Localizable.xcstrings` exists under `Modules/FeatureTransfer/Sources/FeatureTransfer/Resources/` and is wired into `Package.swift` via `resources: [.process("Resources")]`.
- `FeatureTransferLocalization` provides a package-safe fallback for `String` lookups by reading the English entries from `Localizable.xcstrings` when SwiftPM returns raw keys.
- Hardcoded UI strings in `FeatureTransfer` have been converted to `LocalizedStringKey` / `String(localized:)` lookups.
- `TransferFeatureContainer` injects `.environment(\.accentTheme, store.accentColor.theme)` into `RootView` and `MenuBarExtraView`.
- Views throughout `FeatureTransfer` read `\.accentTheme` instead of the static `AccentColor` palette.
- The incoming PIN field forces `.leftToRight` layout to keep digits readable in RTL languages.

## Implementation

### 1. Accent color dynamic theme

- Replaced the static `AccentColor` enum in `DesignSystem` with `AccentTheme`, a struct that can be injected via the SwiftUI environment.
- Added an `AccentThemeKey` `EnvironmentKey` and `EnvironmentValues.accentTheme`.
- Provided:
  - Six system-like color themes: Blue, Green, Purple, Orange, Pink, Teal.
  - Eight named custom palettes with light/dark hex pairs.
  - A system-accent theme that follows `NSColor.controlAccentColor`.
- Updated `AccentColorChoice` to vend a full theme and localized name.
- In `TransferFeatureContainer`, injected the theme into `RootView` and `MenuBarExtraView`.
- Replaced every `AccentColor.primary` usage in `FeatureTransfer` with `\.accentTheme`.
- Kept the deprecated `AccentColor` shim pointing to `AccentTheme.medinaEmerald` as a fallback for any remaining call sites.

### Accent palette

The picker shows the six system-like colors first, followed by the eight named custom palettes, then the system-accent option. Medina Emerald is the default.

| Order | Theme name | Source / light hex | Dark hex |
|---|---|---|---|
| 1 | Blue | `NSColor.systemBlue` | `NSColor.systemBlue` |
| 2 | Green | `NSColor.systemGreen` | `NSColor.systemGreen` |
| 3 | Purple | `NSColor.systemPurple` | `NSColor.systemPurple` |
| 4 | Orange | `NSColor.systemOrange` | `NSColor.systemOrange` |
| 5 | Pink | `NSColor.systemPink` | `NSColor.systemPink` |
| 6 | Teal | `NSColor.systemTeal` | `NSColor.systemTeal` |
| 7 | Medina Emerald | `#15803D` | `#22C55E` |
| 8 | Samarkand Teal | `#0F766E` | `#2DD4BF` |
| 9 | Iznik Blue | `#2563EB` | `#60A5FA` |
| 10 | Andalusian Gold | `#C58A12` | `#F2B84B` |
| 11 | Ottoman Crimson | `#B42335` | `#F05261` |
| 12 | Cordoba Burgundy | `#7F1D3A` | `#D65A82` |
| 13 | Umayyad Pearl | `#D6C7A1` | `#E8DDBD` |
| 14 | Abbasid Obsidian | `#27272A` | `#71717A` |
| — | System accent | Follows `NSColor.controlAccentColor` | Follows `NSColor.controlAccentColor` |

### 2. Language localization

- Converted hardcoded strings in `FeatureTransfer` to `LocalizedStringKey` / `String(localized: .init(key), bundle: .module)` lookups.
- Created `Localizable.xcstrings` with English as the source language and a key for every user-facing string.
- Added the resources target configuration to `Modules/FeatureTransfer/Package.swift` so the bundle is exposed to the app.
- Extended `LanguageSetting` with the v1 supported languages plus Uyghur.
- The settings language picker lists languages in product-priority order using each language's endonym.
- English (US) is the default language; `.system` remains available so users can follow the macOS system language.
- For each language, provided:
  - `Locale` identifier
  - `label` in its own endonym (e.g. "Français" for French)
- Updated `applyingLanguageOverride` to handle the new locales.

### RTL layout considerations

Arabic, Urdu, and Uyghur are right-to-left languages. Steps taken:

- Audit layout code for hardcoded leading/trailing alignment. SwiftUI `leading`/`trailing` is used; these flip automatically in RTL.
- Directional SF Symbols used in animations (paperplane, orbiting devices, progress sparkle) are motion effects and are left unchanged; static list icons flip automatically.
- The incoming PIN field forces `.environment(\.layoutDirection, .leftToRight)` so digits remain left-to-right.

## Languages supported

| Code | Endonym | Locale identifier | Direction |
|---|---|---|---|
| Arabic | العربية | `ar` | RTL |
| Indonesian | Bahasa Indonesia | `id` | LTR |
| Urdu | اردو | `ur` | RTL |
| Bengali | বাংলা | `bn` | LTR |
| Hindi | हिन्दी | `hi` | LTR |
| Turkish | Türkçe | `tr` | LTR |
| English | English | `en-US` | LTR |
| French | Français | `fr` | LTR |
| Russian | Русский | `ru` | LTR |
| Uyghur | ئۇيغۇرچە | `ug` | RTL |
| Simplified Chinese | 简体中文 | `zh-Hans` | LTR |
| Spanish | Español | `es` | LTR |
| Brazilian Portuguese | Português (Brasil) | `pt-BR` | LTR |
| German | Deutsch | `de` | LTR |
| Vietnamese | Tiếng Việt | `vi` | LTR |
| Korean | 한국어 | `ko` | LTR |
| Japanese | 日本語 | `ja` | LTR |

## Files modified

- `Modules/DesignSystem/Sources/DesignSystem/Color+Tokens.swift` – `AccentTheme` with named palettes and system accent.
- `Modules/FeatureTransfer/Sources/FeatureTransfer/Models/FeatureTransferModels.swift` – `AccentColorChoice`, `TransferOutcome`, `HistoryEntry` localization.
- `Modules/FeatureTransfer/Sources/FeatureTransfer/TransferViewState.swift` – `LanguageSetting`, `Screen`, `QuickSaveMode`, `AppearanceSetting` localization.
- `Modules/FeatureTransfer/Sources/FeatureTransfer/Application/TransferFeatureContainer.swift` – theme injection.
- `Modules/FeatureTransfer/Sources/FeatureTransfer/SettingsView.swift` – environment theme, localized labels, LTR PIN field.
- `Modules/FeatureTransfer/Sources/FeatureTransfer/` views – replaced `AccentColor.primary` with `\.accentTheme` and localized strings.
- `Modules/FeatureTransfer/Package.swift` – resources target for `Localizable.xcstrings`.
- `Modules/FeatureTransfer/Sources/FeatureTransfer/Resources/Localizable.xcstrings` – new.
- `Modules/FeatureTransfer/Sources/FeatureTransfer/LocalizationSupport.swift` – runtime fallback for package string resolution.
- `scripts/verify-featuretransfer-localizations.swift` – verifies every catalog key has an English translation.
- `Tests/FeatureTransferTests/FeatureTransferTests.swift` – theme and locale tests.
- `docs/pending_tasks.md` – marked language/accent settings as done.
- `docs/queue/settings-localization-and-accent-theme-plan.md` – this plan.

## Testing strategy

- Unit tests:
  - `AccentColorChoice.theme` resolves a non-empty primary color for every case.
  - Default snapshot uses `AccentColorChoice.medinaEmerald`.
  - Legacy `green`/`blue`/`orange`/`purple` raw values migrate to the expected new cases.
  - Unknown legacy accent values fall back to Medina Emerald.
  - `LanguageSetting.locale` returns the correct `Locale` for every supported language.
  - `LanguageSetting.allCases` matches the product-priority order.
  - `applyingLanguageOverride` can be applied to a view without error.
  - The string catalog has an English translation for every key.
  - The localization verification script passes against the checked-in catalog.
- Build tests:
  - `swift build` and `swift test` pass for `Modules/FeatureTransfer`.
  - `xcodebuild -project LocalDrop.xcodeproj -scheme LocalDrop` succeeds.
- UI build tests:
  - Each major view builds with each accent color (covered by the theme tests and build).
  - Each major view builds with LTR and RTL languages (covered by `Locale` injection).
- Snapshot tests (optional, recommended if screenshot infrastructure exists):
  - Settings screen in Arabic/Urdu/Uyghur (RTL) and French (LTR) to catch layout regressions.
- Translation coverage:
  - `scripts/verify-featuretransfer-localizations.swift` fails when any key in `Localizable.xcstrings` is missing an English translation.

## Todo list

- [x] Refactor `AccentColor` into environment-aware `AccentTheme` with palette and system accent support.
- [x] Update `AccentColorChoice` to vend full themes, default to Medina Emerald, and migrate legacy raw values.
- [x] Add six standard system-like accent colors (Blue, Green, Purple, Orange, Pink, Teal) before the named custom palettes.
- [x] Inject accent theme into `RootView` and `MenuBarExtraView`.
- [x] Replace `AccentColor.primary` references with `\.accentTheme` in all `FeatureTransfer` views.
- [x] Create `Localizable.xcstrings` and wire it into `Package.swift`.
- [x] Extract hardcoded strings in `FeatureTransfer` to localized keys.
- [x] Extend `LanguageSetting` with the v1 supported languages and Uyghur, using endonyms and correct `Locale` identifiers.
- [x] Update `applyingLanguageOverride` and verify `Locale` behavior.
- [x] Audit and fix RTL layout issues (PIN field forced LTR; leading/trailing alignments checked).
- [x] Add unit tests for theme resolution and locale overrides.
- [x] Update `docs/pending_tasks.md` to mark language/accent settings as done.
- [ ] Add translations beyond English when bandwidth is available.
- [x] Add CI script to verify every `LocalizedStringKey` has an English translation.
- [ ] Add snapshot tests for RTL settings screen if screenshot infrastructure is added.
- [x] Decide whether the accent color should also affect the menu bar icon badge color.

## Open questions

- The app currently ships English strings only; untranslated languages intentionally fall back to English until the catalog is populated.
- Translation management remains manual for now, with `scripts/verify-featuretransfer-localizations.swift` guarding English completeness.
- Accent color applies to the window UI and menu content, but not the status-item icon badge; the menu bar icon should remain a template symbol managed by the system.
- The system accent option remains a distinct picker choice rather than implicitly overriding a named palette.
