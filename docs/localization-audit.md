# LocalDrop macOS App — Localization Audit Report

## 1. Executive Summary

| Metric | Value |
|--------|-------|
| Total declared languages | 18 (`LanguageSetting.allCases`) |
| Languages with translation resources | 4 (`ar`, `en`, `id`, `ur`) |
| Localization resource | `Modules/FeatureTransfer/Sources/FeatureTransfer/Resources/Localizable.xcstrings` |
| Catalog keys | 227 |
| Source language | `en` |
| English coverage | ~99.1% (224/226 non-empty keys translated) |
| ar/id/ur coverage | ~98.2% (222/226 non-empty keys translated) |
| Hard-coded or incorrectly wired user-facing strings | 24 distinct issues |
| Empty / malformed keys | 3 |
| Missing translations in supported languages | 2 keys |
| Unused catalog keys | ~18 |

**Overall health:** The app has a centralized, well-structured `Localizable.xcstrings` catalog and most UI is wired through `FeatureTransferLocalization`. However, **14 declared languages have no translations**, several primary UI strings are hard-coded English, one key is displayed literally to users, and the app does not declare its supported languages to macOS/App Store.

---

## 2. Supported-Language Matrix

| Language | Locale Code | Resource File | Translation Coverage | Missing Keys | Untranslated / Empty | Wiring/Runtime Issues | Overall Status |
|----------|-------------|---------------|----------------------|--------------|----------------------|------------------------|----------------|
| English | `en` | `Localizable.xcstrings` | ~99.1% | 0 for used keys; 3 empty/malformed keys exist | `""`, `Complete`, `In Progress` | None | Partial |
| Arabic | `ar` | `Localizable.xcstrings` | ~98.2% | 2 | `incomingRequest.fileNotSelected`, `incomingRequest.fileSelected` | 14 declared languages have no strings; selecting a language with no catalog falls back to system locale/English | Partial |
| Indonesian | `id` | `Localizable.xcstrings` | ~98.2% | 2 | same as Arabic | same as Arabic | Partial |
| Urdu | `ur` | `Localizable.xcstrings` | ~98.2% | 2 | same as Arabic | same as Arabic | Partial |
| Bengali | `bn` | **None** | 0% | all | all | UI falls back to system locale or English | Missing |
| Hindi | `hi` | **None** | 0% | all | all | same | Missing |
| Turkish | `tr` | **None** | 0% | all | all | same | Missing |
| French | `fr` | **None** | 0% | all | all | same | Missing |
| Russian | `ru` | **None** | 0% | all | all | same | Missing |
| Uyghur | `ug` | **None** | 0% | all | all | same | Missing |
| Simplified Chinese | `zh-Hans` | **None** | 0% | all | all | same | Missing |
| Spanish | `es` | **None** | 0% | all | all | same | Missing |
| Brazilian Portuguese | `pt-BR` | **None** | 0% | all | all | same | Missing |
| German | `de` | **None** | 0% | all | all | same | Missing |
| Vietnamese | `vi` | **None** | 0% | all | all | same | Missing |
| Korean | `ko` | **None** | 0% | all | all | same | Missing |
| Japanese | `ja` | **None** | 0% | all | all | same | Missing |
| System | — | Uses system locale | — | — | — | — | — |

**Configuration issue:** `App/LocalDropApp/Info.plist` has `CFBundleDevelopmentRegion` set to `en`, but it does **not** contain a `CFBundleLocalizations` array. macOS and the App Store will not know the app supports `ar`, `id`, or `ur`.

---

## 3. Missing or Untranslated Entries

### 3.1 Keys missing translations in Arabic, Indonesian, and Urdu

| Key | Base (English) Value | Affected Languages | File / Line | Issue Type | Recommended Correction |
|-----|----------------------|-------------------|-------------|------------|------------------------|
| `incomingRequest.fileNotSelected` | "Not selected" | `ar`, `id`, `ur` | `Localizable.xcstrings:2217` | Missing translation | Add translations |
| `incomingRequest.fileSelected` | "Selected" | `ar`, `id`, `ur` | `Localizable.xcstrings:2286` | Missing translation | Add translations |

### 3.2 Empty / malformed keys in all languages

| Key | Base Value | Affected Languages | File / Line | Issue Type | Recommended Correction |
|-----|------------|-------------------|-------------|------------|------------------------|
| `""` | (empty) | all | `Localizable.xcstrings:4` | Malformed empty key | Remove |
| `Complete` | (empty) | all | `Localizable.xcstrings` | Empty key; code uses hard-coded "Complete" instead | Either fill and wire in `TransferProgressSheet.swift:92` or delete |
| `In Progress` | (empty) | all | `Localizable.xcstrings` | Empty key; code uses hard-coded "In Progress" instead | Either fill and wire in `TransferProgressSheet.swift:92` or delete |

---

## 4. Hard-Coded or Incorrectly Wired UI Text

### 4.1 Critical wiring bugs

| Visible Text | UI Location / Component | File / Line | Why It Is Not Localized | Recommended Fix |
|--------------|-------------------------|-------------|-------------------------|-----------------|
| `"send.dropZoneLabel"` | Drop-zone label in Send view | `Modules/FeatureTransfer/Sources/FeatureTransfer/SendView.swift:133` | The raw localization key is passed as a `String` to `DropZoneView`, which renders it literally. | Use `FeatureTransferLocalization.string(forKey: "send.dropZoneLabel")` |
| `"Complete"` / `"In Progress"` | Transfer progress sheet status header | `Modules/FeatureTransfer/Sources/FeatureTransfer/Sheets/TransferProgressSheet.swift:92` | Hard-coded literals; matching catalog keys `Complete` and `In Progress` are empty. | Use `FeatureTransferLocalization.string(forKey: "Complete")` / `FeatureTransferLocalization.string(forKey: "In Progress")` and fill the catalog entries |

### 4.2 Hard-coded English settings strings

| Visible Text | UI Location / Component | File / Line | Why It Is Not Localized | Recommended Key / Fix |
|--------------|-------------------------|-------------|-------------------------|------------------------|
| `"Choose the name other LocalSend devices will see."` | Device-name field hint | `SettingsView.swift:12` / `SettingsView.swift:327` | Stored in `DeviceNameCopy.fieldHint` | `settings.deviceNameHint` |
| `"Enter a device name to apply."` | Device-name validation message | `SettingsView.swift:13` / `SettingsView.swift:402` | Stored in `DeviceNameCopy.validationMessage` | `settings.deviceNameValidation` |
| `"Use system name"` | Device-name button tooltip | `SettingsView.swift:14` / `SettingsView.swift:305` | Stored in `DeviceNameCopy.useSystemName` | `settings.deviceNameUseSystem` |
| `"Generate random alias"` | Random-alias button tooltip | `SettingsView.swift:15` / `SettingsView.swift:313` | Stored in `DeviceNameCopy.generateRandomAlias` | `settings.deviceNameRandomAlias` |

### 4.3 Hard-coded transfer progress / status strings

| Visible Text | UI Location / Component | File / Line | Why It Is Not Localized | Recommended Key / Fix |
|--------------|-------------------------|-------------|-------------------------|------------------------|
| `"Calculating…"` | Transfer ETA label | `FeatureTransferModels.swift:253` | Hard-coded in `TransferETA.descriptionText` | `transfer.eta.calculating` |
| `"Stalled"` | Transfer ETA label | `FeatureTransferModels.swift:255` | Hard-coded in `TransferETA.descriptionText` | `transfer.eta.stalled` |
| `"Queued"` | Per-file status label | `FeatureTransferModels.swift:385` | Hard-coded in `TransferFileProgress.statusLabel` | `transfer.status.queued` |
| `"Failed"` | Per-file status label | `FeatureTransferModels.swift:391` | Hard-coded in `TransferFileProgress.statusLabel` | `transfer.status.failed` |
| `"Retrying"` | Per-file status label | `FeatureTransferModels.swift:395` | Hard-coded in `TransferFileProgress.statusLabel` | `transfer.status.retrying` |
| `"Completed Item X"` | Fallback completed file name in multi-item transfer | `FeatureTransferModels.swift:539` | Hard-coded string with interpolation | `transfer.completedItemFormat` |
| `"Queued Item X"` | Fallback queued file name in multi-item transfer | `FeatureTransferModels.swift:550` | Hard-coded string with interpolation | `transfer.queuedItemFormat` |
| `"Transfer failed"` | Feedback banner on failed transfer | `TransferFeatureStore.swift:711` | Hard-coded in `TransferFeedback` | `feedback.transferFailed` |
| `"Transfer failed"` | Per-file error summary in transfer progress | `LocalSendRuntimeAdapter.swift:787` | Hard-coded `errorSummary` | `feedback.transferFailed` or `transfer.status.failed` |

### 4.4 Hard-coded format separators and units

| Visible Text | UI Location / Component | File / Line | Why It Is Not Localized | Recommended Fix |
|--------------|-------------------------|-------------|-------------------------|-----------------|
| `" · "` | Device subtitle separator | `FeatureTransferModels.swift:103` | Concatenated separator | Move into a localized format string |
| `" / "` | Per-file byte-progress separator | `FeatureTransferModels.swift:379` | Concatenated separator | Move into a localized format string |
| `" / "` | Aggregate byte-progress separator | `FeatureTransferModels.swift:703` | Concatenated separator | Move into a localized format string |
| `"/s"` | Speed unit suffix | `FeatureTransferModels.swift:712` | Concatenated unit | Move into a localized format string |
| `" • ETA "` / `"ETA "` | Secondary status line separators | `FeatureTransferModels.swift:722`, `726` | Concatenated separator and prefix | Move into a localized format string |
| `" · "` | History entry subtitle separator | `FeatureTransferModels.swift:791` | Concatenated separator | Move into a localized format string |
| `"X of Y completed"` | Menu-bar active-transfer title | `MenuBarExtraView.swift:230` | Hard-coded English word and separator | `transfer.progress.menuItemCountFormat` |
| `" · "` | Menu-bar active-transfer separator | `MenuBarExtraView.swift:237` | Concatenated separator | Move into a localized format string |

### 4.5 Minor / optional hard-coded strings

| Visible Text | UI Location / Component | File / Line | Recommended Fix |
|--------------|-------------------------|-------------|-----------------|
| `"—"` | Missing history size placeholder | `TransferFeatureStore.swift:828` | Optional: `history.sizeUnavailable` |
| `"99+"` | Badge overflow indicator | `Modules/DesignSystem/Sources/DesignSystem/Components/StatusBadge.swift:25` | Optional: `badge.overflow` |
| Retro device aliases (`"Midnight Macintosh"`, etc.) | Generated device names shown to peers | `RetroDeviceNameGenerator.swift:4–13` | Consider localizing or mark as brand-style identifiers |

### 4.6 Inconsistent localization wiring

| Issue | File / Line | Details |
|-------|-------------|---------|
| `SecurityDialog.message` uses `LocalizedStringKey` literals | `SettingsView.swift:473–477` | The dialog messages `"settings.requirePINMessage"`, `"settings.allowDownloadsMessage"`, and `"settings.httpsDisabledMessage"` are returned as `LocalizedStringKey` instead of through `FeatureTransferLocalization`. This works via SwiftUI's default bundle resolution but is inconsistent with the rest of the app and may not respect the custom override path uniformly. |
| `TransferSecurityCopy` enum is dead code | `SettingsView.swift:5–9` | Contains user-facing strings (`"Use HTTPS for transfers"`, etc.) but is only referenced in tests. Remove or wire into the HTTPS toggle UI. |

---

## 5. Unused, Duplicate, or Malformed Localization Entries

### 5.1 Malformed / empty entries

| Key | Issue | Recommended Action |
|-----|-------|--------------------|
| `""` | Empty key in catalog | Delete |
| `Complete` | Empty; code uses hard-coded literal | Fill and wire, or delete |
| `In Progress` | Empty; code uses hard-coded literal | Fill and wire, or delete |

### 5.2 Duplicate base values (same English text under multiple keys)

| English Value | Keys | Recommended Action |
|---------------|------|--------------------|
| `System` | `accent.system`, `appearance.system`, `language.system` | Acceptable if contexts differ; otherwise consolidate |
| `Cancel` | `general.cancel`, `sendText.cancel` | `sendText.cancel` is unused; delete or use it |
| `History` | `root.history`, `screen.history.title` | Acceptable if contexts differ |
| `Settings` | `root.settings`, `screen.settings.title` | Acceptable if contexts differ |
| `%@ · %@` | `send.stagedSubtitleFormat`, `transfer.stagedSummary` | Verify if both are needed |
| `General` | `settings.general`, `settings.section.general` | `settings.general` is unused; delete |
| `Network` | `settings.network`, `settings.section.network` | `settings.network` is unused; delete |
| `Receiving` | `settings.receiving`, `settings.section.receiving`, `transfer.progress.receivingProgress`, `transfer.status.receivingProgress` | `settings.receiving` is unused; delete |

### 5.3 Genuinely unused keys (no code reference)

| Key | Recommended Action |
|-----|--------------------|
| `send.remove` | Delete or wire to the staged-item remove button |
| `sendText.cancel` | Delete or replace `general.cancel` usage in `SendTextEntrySheet` |
| `settings.general`, `settings.network`, `settings.receiving` | Delete (duplicates of `settings.section.*`) |
| `transfer.progress.complete`, `transfer.progress.currentFile`, `transfer.progress.overall` | Delete or wire |
| `transfer.progress.receivingFrom`, `transfer.progress.sendingTo` | Delete or wire |
| `transfer.status.complete`, `transfer.status.itemsRemaining`, `transfer.status.preparing`, `transfer.status.receiving`, `transfer.status.receivingProgress`, `transfer.status.saved`, `transfer.status.uploaded`, `transfer.status.waitingForSender` | Delete or wire |

---

## 6. Priority-Ranked Remediation Plan

### Critical (fix first)

1. **Fix `send.dropZoneLabel` literal display** — `SendView.swift:133`
2. **Localize "Complete" / "In Progress" in transfer progress sheet** — `TransferProgressSheet.swift:92`
3. **Localize the two "Transfer failed" messages** — `TransferFeatureStore.swift:711`, `LocalSendRuntimeAdapter.swift:787`
4. **Localize `DeviceNameCopy` strings** — `SettingsView.swift:12–15`
5. **Add missing `ar`/`id`/`ur` translations** for `incomingRequest.fileSelected` and `incomingRequest.fileNotSelected`
6. **Add `CFBundleLocalizations` to `Info.plist`** so macOS/App Store recognize the supported languages

### High (primary UI translations)

7. Localize transfer status labels: `Queued`, `Failed`, `Retrying`, `Calculating…`, `Stalled` — `FeatureTransferModels.swift:253–395`
8. Localize the fallback item names `"Completed Item X"` and `"Queued Item X"` — `FeatureTransferModels.swift:539–550`
9. Replace hard-coded format separators (`" · "`, `" / "`, `"/s"`, `"ETA "`, etc.) with localized format strings — `FeatureTransferModels.swift`, `MenuBarExtraView.swift`
10. Localize the menu-bar active-transfer title `"X of Y completed"` — `MenuBarExtraView.swift:230`

### Medium (secondary UI / consistency)

11. Remove or wire the dead `TransferSecurityCopy` enum — `SettingsView.swift:5–9`
12. Standardize `SecurityDialog.message` to use `FeatureTransferLocalization.resource` instead of `LocalizedStringKey` literals — `SettingsView.swift:473–477`
13. Decide on the 14 declared-but-untranslated languages: either remove them from `LanguageSetting.allCases` or add translations

### Low (cleanup)

14. Remove or wire genuinely unused keys listed in section 5.3
15. Remove the empty/malformed keys `""`, `Complete`, `In Progress`
16. Optionally localize `"—"` placeholder, `"99+"` badge, and retro device aliases

---

### Summary of Files Requiring Changes

- `Modules/FeatureTransfer/Sources/FeatureTransfer/Resources/Localizable.xcstrings` — add missing translations, remove empty/unused keys
- `Modules/FeatureTransfer/Sources/FeatureTransfer/SendView.swift` — fix drop-zone label
- `Modules/FeatureTransfer/Sources/FeatureTransfer/Sheets/TransferProgressSheet.swift` — localize status text
- `Modules/FeatureTransfer/Sources/FeatureTransfer/SettingsView.swift` — localize `DeviceNameCopy`, clean up `TransferSecurityCopy`
- `Modules/FeatureTransfer/Sources/FeatureTransfer/Models/FeatureTransferModels.swift` — localize status, ETA, separators, fallback names
- `Modules/FeatureTransfer/Sources/FeatureTransfer/MenuBarExtraView.swift` — localize menu active-transfer title
- `Modules/FeatureTransfer/Sources/FeatureTransfer/Application/TransferFeatureStore.swift` — localize feedback message
- `Modules/FeatureTransfer/Sources/FeatureTransfer/Infrastructure/LocalSendRuntimeAdapter.swift` — localize error summary
- `App/LocalDropApp/Info.plist` — add `CFBundleLocalizations`
