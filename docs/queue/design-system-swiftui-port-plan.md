# DESIGN_SYSTEM.md rewrite + SwiftUI/AppKit port of `docs/design/LocalSend macOS.dc.html`

> **Status:** Part 1 (DESIGN_SYSTEM.md rewrite) landed. Part 2 (SwiftUI/AppKit port) in progress — `Modules/DesignSystem` tokens/primitives underway, `Modules/FeatureTransfer` screens next.

## Context

`docs/design/LocalSend macOS.dc.html` is an interactive HTML/CSS mock (DC prototyping format) of the LocalDrop macOS app: sidebar nav (Receive/Send/History/Settings), a toolbar, 4 content screens, and 2 modal sheets (incoming-request, transfer-progress). It's the only screen-level design reference in the repo. [DESIGN_SYSTEM.md](../../DESIGN_SYSTEM.md) currently covers tokens only (color/type/spacing/materials/logo) and explicitly excludes screen layouts.

Goal: make DESIGN_SYSTEM.md the complete source of truth (tokens + component specs derived from the mock), then build the real screens in SwiftUI against it, swapping in native macOS components wherever one exists instead of hand-rolling the mock's custom CSS chrome.

**Resolved conflict:** the mock uses `#2E7D46` for all accent/interactive elements, but the actual brand mark (`Assets/Logo/localdrop-mark-color.svg`, `-mono-light.svg`) and DESIGN_SYSTEM.md's `Primary/500` are `#426834`. User confirmed: **brand `#426834` wins**. The mock's green is a prototyping placeholder — port layout/spacing/proportions pixel-for-pixel, re-skin every green surface onto the existing `Primary/*` scale. No token math changes; DESIGN_SYSTEM.md's existing 10-step scale is correct and stays.

Codebase is greenfield for UI: `Modules/DesignSystem/Sources/DesignSystem/DesignSystem.swift` is an empty `enum`, `Modules/FeatureTransfer/Sources/FeatureTransfer/FeatureTransfer.swift` is an empty stub, `App/LocalDropApp/LocalDropApp.swift` renders `EmptyView()`. No existing view code to preserve or migrate — this is new construction, not a refactor.

## Native-vs-custom decisions (the "use native where suitable" call)

| Mock element | Build as |
|---|---|
| Traffic lights, title bar, dock, page background gradient | **Skip** — that's demo-container chrome for a real macOS window, not app content |
| Sidebar shell (232pt, nav items, "this device" chip) | `NavigationSplitView` sidebar column + `List(selection:)`, `.listStyle(.sidebar)` — gets native vibrancy/selection for free instead of hand-rolled button backgrounds |
| Toolbar (title + action buttons) | Native `.toolbar { ToolbarItem }`, `.windowToolbarStyle(.unified)` — not the mock's custom bordered-button bar |
| Nav/toolbar/status icons (device glyphs, gear, clock, arrows, checkmarks) | **SF Symbols** (`macbook`, `iphone`, `ipad`, `desktopcomputer`, `gearshape`, `clock.arrow.circlepath`, `checkmark.circle.fill`, `xmark.circle.fill`, `arrow.up`/`down`, `heart.fill`) instead of the mock's hand-drawn SVG paths |
| Brand paper-plane mark | **Custom** — only kept as the actual bespoke asset, per DESIGN_SYSTEM.md logo rules (sidebar header, Receive hero, app icon). Rendered from `Assets/Logo/*.svg` → vector asset in the asset catalog, not SF Symbols |
| "Quick Save" segmented control | Native `Picker(selection:).pickerStyle(.segmented)` |
| All toggle switches (Settings) | Native `Toggle(...).toggleStyle(.switch)` |
| Appearance/Language dropdowns | Native `Picker` (menu style) |
| Settings grouped sections | Native `Form { Section }.formStyle(.grouped)` — replaces the mock's manually-bordered white cards; this *is* what modern System Settings uses, so it's the correct native match, not a compromise |
| Accept/Decline/Cancel/Choose/Clear all/nav buttons | Native `Button` with `.buttonStyle(.bordered/.borderedProminent/.plain)`, tinted via `AccentColor.primary` |
| Sheets (incoming-request, progress) | Native `.sheet(isPresented:)` — matches DESIGN_SYSTEM.md's materials table ("system sheet, no custom material needed") |
| Progress bar | Native `ProgressView(value:)`, linear style, accent-tinted |
| History list | `List` with `.listStyle(.inset(alternatesRowBackgrounds:))`, custom row content (icon+title+subtitle+trailing status — no native equivalent for that composite row) |
| Send: device grid, "selection" type grid, staged-file chip, drop zone | **Custom** SwiftUI views — no native primitive matches these; but drop zone uses real `.dropDestination(for:)` (macOS 13+), not just cosmetic dashed border |
| Receive hero (pulse rings, rotating dashed ring) | **Custom** — `Circle().stroke()` + `.scaleEffect`/`.opacity` with `.repeatForever` animation, `rotationEffect` driven by `TimelineView`. No native radar/pulse component exists |
| Accent-color swatch row (Settings) | **Custom** small control — no native "row of color dots" component |
| Sidebar/toolbar materials | System materials via SwiftUI (`.sidebar`, `.regularMaterial`, etc.) — matches DESIGN_SYSTEM.md's Materials table already. **No AppKit bridging needed**: `NavigationSplitView`'s sidebar column already applies correct vibrancy automatically on macOS. Only reach for `NSViewRepresentable` (per `appkit-swiftui-bridge` skill) if a specific material/behavior gap shows up during implementation — not planned upfront |

Deployment stays at `.macOS(.v14)` (already set in all 3 `Package.swift` files) — **not** adopting `.glassEffect()`/Liquid Glass (macOS 26 API). The mock is drawn in classic frosted-vibrancy HIG style, not glass-capsule Tahoe style; porting it "pixel perfect" means matching *that* style with today's materials, not restyling it into Tahoe's newer language.

## Part 1 — Rewrite DESIGN_SYSTEM.md ✅ done

Kept the existing Logo/Color/Typography/Spacing/Materials/Accessibility sections (they're accurate, logo-file-verified). Added:

- A short note in the Color section flagging that early visual prototypes used `#2E7D46`; the shipped app uses `Primary/500` (`#426834`) everywhere — so future contributors don't reintroduce the mock's color by copying hex values from the html file.
- A new **Components** section specifying, per component: composition, sizing, and which DESIGN_SYSTEM tokens it consumes:
  - Sidebar nav row (active/inactive state — background `primarySubtleFill`, icon/text color swap)
  - "This device" chip
  - Toolbar action button
  - Segmented control (Quick Save)
  - Selection-type button (Send screen grid)
  - Staged-file chip (with remove button)
  - Device card (Send grid) + badge/favorite overlay
  - History row
  - Settings grouped-section row (label+control variants: value text, chevron dropdown, toggle, disclosure button, color swatch row)
  - Sheet container (incoming-request, progress)
  - Progress bar + percent/ETA row
  - Receive hero (pulse rings + rotating ring + avatar glyph)
  - Drop zone
- Each spec references exact pt values pulled from the mock's CSS (see below) so the doc stays the single numeric source of truth instead of re-deriving them from the html later.

## Part 2 — SwiftUI/AppKit port (in progress)

### Module layout (uses existing structure, no new modules)

- **`Modules/DesignSystem`**: turn the tokens from DESIGN_SYSTEM.md into code.
  - `Color+Tokens.swift`: `Primary50...Primary900` as `Color` statics (asset-catalog-backed `Color("Primary/500")` etc. so light/dark variants are data-driven, not `#if` branches), plus semantic wrappers (`AccentColor.primary`, `.primaryHover`, `.primaryPressed`, `.primarySubtleFill`) computed from color-scheme environment.
  - `Font+Tokens.swift`: text-style helpers matching the Typography table (`.headline`, `.body`, monospacedDigit numeric variant, SF Mono helper).
  - `Spacing.swift` / `Radius.swift`: enums/constants (`Spacing.xs = 8`, `Radius.md = 8`, etc.) — continuous corner radius via `.clipShape(RoundedRectangle(cornerRadius:, style: .continuous))`.
  - `Components/`: the reusable primitives from the new Components section that aren't natively provided — `PulseRingView`, `SegmentedPill` (or just use native `Picker` directly and skip this), `StatusBadge`, `DropZoneView`.
  - Add the brand mark as a proper vector asset (SVG → PDF/SF-Symbol-style template asset in an asset catalog) with the 3 documented variants, replacing raw inline SVG paths.
- **`Modules/FeatureTransfer`**: the actual screens, built against `DesignSystem`.
  - `RootView.swift`: `NavigationSplitView` wrapping sidebar List + toolbar + selected screen.
  - `ReceiveView.swift`, `SendView.swift`, `HistoryView.swift`, `SettingsView.swift`.
  - `Sheets/IncomingRequestSheet.swift`, `Sheets/TransferProgressSheet.swift`.
  - Rows/cards: `DeviceCardView.swift`, `HistoryRowView.swift`.
  - Local UI state only (screen selection enum, toggle bindings, Quick Save mode, sheet presentation) — an `@Observable` view-state type owned by `RootView`, mirroring the mock's `Component.state` shape. This is presentation state needed to make the port interactive/navigable, not a stand-in for real transfer data — wiring to `LocalSendKit` is separate, future work and out of scope here. Screens take this state via `@Bindable`/`@Environment`, not hardcoded mock values, so hookup later is a data-source swap, not a rewrite.
- **`App/LocalDropApp/LocalDropApp.swift`**: replace `EmptyView()` with `RootView()`, set `.windowStyle`/`.defaultSize` to match the mock's 1120×~700 proportions (title bar + 232pt sidebar + content), keep `MenuBarExtra` as-is (out of scope — mock doesn't model it beyond a placeholder icon).

### Exact values to carry over from the mock (for pixel parity)

- Sidebar: 232pt fixed width, 14/12/12 outer padding, nav row height ~34pt (7px vertical padding + 17px icon), 8pt corner radius on active state, section label uppercase 11px/600.
- Toolbar: 52pt height, 18px horizontal padding, title 15px/600.
- Sheets: 400pt wide, 16pt corner radius, centered.
- Send grid: 4 columns for selection types, 2 columns for device cards, 12pt gaps, card radius 13–14pt.
- History/Settings card radius 12–14pt, row padding 12–14px vertical / 16px horizontal.
- Progress bar: 8pt height, 5pt radius.
- These become the literal frame/padding modifiers in the SwiftUI views — cross-check against DESIGN_SYSTEM.md's `space.*`/`radius.*` tokens and use the nearest token rather than a raw literal wherever one matches (e.g. 12px gap → `Spacing.sm`), falling back to a literal only where the mock's value doesn't line up with the 4pt grid.

## Verification

- `swift build` on each package (`Modules/DesignSystem`, `Modules/FeatureTransfer`) and the Xcode project after wiring `RootView` in.
- Run the app via `preview_start`/Xcode run, walk all 4 sidebar screens, open both sheets (incoming-request via toolbar's simulate action, progress via a device card), toggle every switch/segmented control/dropdown, and resize the window — compare side-by-side against the html mock (open `docs/design/LocalSend macOS.dc.html` in a browser) for spacing/proportions.
- Toggle Dark Mode, Increased Contrast, and Reduce Transparency in System Settings and confirm the accent scale's dark-mode mapping and the materials' opaque fallback (per DESIGN_SYSTEM.md Accessibility section) actually apply.
- Confirm no view hardcodes `#2E7D46` or any raw hex — grep for stray hex literals in `Modules/FeatureTransfer` and `Modules/DesignSystem` before calling it done.
