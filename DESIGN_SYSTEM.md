# LocalDrop Design System — Tokens

Scope: color, type, spacing/radius, materials, and logo usage rules. No screen layouts here. Built to Apple Human Interface Guidelines: prefer system dynamic colors/materials wherever possible, reserve custom tokens for brand identity (accent color + logo).

## Logo / Mark

Source icon: `Assets/Logo/localdrop-mark-source.svg` (paper-plane "send" glyph, two-path stroke drawing).

| Variant     | File                                        | Use                                                                                                |
| ----------- | ------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Brand color | `Assets/Logo/localdrop-mark-color.svg`      | App icon glyph (light appearance), marketing, About panel, empty states                            |
| Mono light  | `Assets/Logo/localdrop-mark-mono-light.svg` | On dark/primary-color fills — dark app icon variant, filled buttons, splash                        |
| Template    | `Assets/Logo/localdrop-mark-template.svg`   | `NSStatusItem` menu bar icon, toolbar icons — set `NSImage.isTemplate = true`, never tint manually |

**Construction rules**

- Stroke width scales proportionally with size; never let the rendered stroke drop below 1pt — below ~16pt, use a simplified single-path glyph instead of the two-path detail version.
- Clear space: minimum half the mark's height on all sides, on every surface.
- Minimum sizes: 16pt (menu bar), 22pt (toolbar), 32pt (list/row icon), 1024×1024px source (app icon).
- Never place the color mark on a background that fails 3:1 contrast against `#426834`; use the mono-light variant instead.

**App icon (macOS icon grid / Icon Composer, 3 required appearances)**

| Appearance | Background                          | Glyph                                                |
| ---------- | ----------------------------------- | ---------------------------------------------------- |
| Light      | `Primary/500` (`#426834`) flat fill | mono-light mark, centered in safe zone               |
| Dark       | `Primary/800` (`#1D3116`) flat fill | mono-light mark                                      |
| Tinted     | Grayscale glyph                     | system applies tint automatically — do not pre-color |

Let the OS apply the standard continuous-corner (squircle) mask; don't bake a rounded-rect into the source art.

## Color

Apple HIG default: use system semantic colors (`labelColor`, `secondaryLabelColor`, `systemBackground`, `systemGray`…`systemGray6`, etc.) for text, backgrounds, and separators — they already adapt to light/dark mode and accessibility settings (increased contrast, reduced transparency). LocalDrop defines exactly **one** custom brand token family: the accent/primary green. Everything else rides on system colors.

### Primary accent scale (derived from `#426834`)

Hue 104°, generated as a 10-step tonal scale. Base = `500`.

| Token         | Hex       | HSL                         |
| ------------- | --------- | --------------------------- |
| `Primary/50`  | `#F0F6EE` | 104°, 30%, 95%              |
| `Primary/100` | `#E2EEDD` | 104°, 32%, 90%              |
| `Primary/200` | `#CAE0C2` | 104°, 33%, 82%              |
| `Primary/300` | `#A7CC99` | 104°, 33%, 70%              |
| `Primary/400` | `#6CAA55` | 104°, 33%, 50%              |
| `Primary/500` | `#426834` | 104°, 33%, 31% ← brand base |
| `Primary/600` | `#38592C` | 104°, 34%, 26%              |
| `Primary/700` | `#2A4521` | 104°, 36%, 20%              |
| `Primary/800` | `#1D3116` | 104°, 38%, 14%              |
| `Primary/900` | `#111D0C` | 104°, 40%, 8%               |

**Semantic mapping (light mode)**

- `AccentColor.primary` → `Primary/500` — the app's `NSApp.appearance`-visible accent (buttons, selected states, links, progress indicators, the logo glyph).
- `AccentColor.primaryHover` → `Primary/600`
- `AccentColor.primaryPressed` → `Primary/700`
- `AccentColor.primaryDisabled` → `Primary/200` at reduced opacity (40%)
- `AccentColor.primarySubtleFill` → `Primary/50` — selected-row backgrounds, badges

**Semantic mapping (dark mode)**

Apple shifts accent colors brighter/lighter against dark backgrounds for contrast (see how `systemBlue` behaves across appearances) — do the same here rather than reusing the light-mode base:

- `AccentColor.primary` → `Primary/400` (`#6CAA55`)
- `AccentColor.primaryHover` → `Primary/300`
- `AccentColor.primaryPressed` → `Primary/500`
- `AccentColor.primaryDisabled` → `Primary/700` at reduced opacity (40%)
- `AccentColor.primarySubtleFill` → `Primary/900`

Verify both directions pass 4.5:1 contrast for any text drawn in the accent color (Xcode Accessibility Inspector) before shipping — icon/control usage can tolerate lower ratios than text.

**Everything else — use system colors, don't hardcode:**

| Purpose                                  | Token                                                            |
| ---------------------------------------- | ---------------------------------------------------------------- |
| Primary text                             | `NSColor.labelColor`                                             |
| Secondary text                           | `NSColor.secondaryLabelColor`                                    |
| Tertiary/disabled text                   | `NSColor.tertiaryLabelColor`                                     |
| Window/content background                | `NSColor.windowBackgroundColor` / `.controlBackgroundColor`      |
| Grouped/inset background                 | `NSColor.underPageBackgroundColor`                               |
| Separators/hairlines                     | `NSColor.separatorColor`                                         |
| Neutral grays (icons, disabled controls) | `NSColor.systemGray` … `systemGray6`                             |
| Success                                  | `NSColor.systemGreen`                                            |
| Warning                                  | `NSColor.systemYellow` (or `systemOrange` for stronger emphasis) |
| Error / destructive                      | `NSColor.systemRed`                                              |
| Info                                     | `NSColor.systemBlue`                                             |

Note the brand accent is also green — for transfer status specifically, keep `systemGreen` for "success/complete" states so it reads as a system-standard status color rather than "the app's brand color happens to be showing," and reserve `AccentColor.primary` for interactive/selection UI.

## Typography

Apple HIG: use the system font (San Francisco) via Dynamic Type text styles, not fixed point sizes — this gets accessibility text-size scaling for free.

| Text Style              | Weight   | Approx. size (macOS) | Use                                         |
| ----------------------- | -------- | -------------------- | ------------------------------------------- |
| `largeTitle`            | Regular  | 26pt                 | Window/onboarding hero text (rare on macOS) |
| `title1`                | Regular  | 22pt                 | Panel titles                                |
| `title2`                | Bold     | 17pt                 | Section headers                             |
| `title3`                | Semibold | 15pt                 | Subsection headers, sheet titles            |
| `headline`              | Semibold | 13pt                 | Row primary text (device name, file name)   |
| `body`                  | Regular  | 13pt                 | Default body text                           |
| `callout`               | Regular  | 12pt                 | Secondary row text                          |
| `subheadline`           | Regular  | 11pt                 | Metadata (file size, timestamp)             |
| `footnote`              | Regular  | 10pt                 | Fine print                                  |
| `caption1` / `caption2` | Regular  | 10pt                 | Badge labels, smallest UI text              |

- Font family: system font (SF Pro) via `NSFont.preferredFont(forTextStyle:)` / `NSFont.systemFont(ofSize:weight:)` — never bundle a custom font for UI text.
- Wordmark ("LocalDrop" lockup next to the mark, About panel/splash only): SF Pro Display, Semibold, tracking -0.5%. Not used in-app chrome — window titles use the system title bar font automatically.
- Monospace (IP addresses, device fingerprints/certificate hashes, transfer speed, protocol debug output): SF Mono via `NSFont.monospacedSystemFont(ofSize:weight:)`.
- Numeric transfer stats (speed, percentage, ETA) that update frequently: apply `.monospacedDigit()` variant of the body font so digits don't jitter the layout as they change.

## Spacing & Radius

4pt base grid, per HIG:

| Token        | Value |
| ------------ | ----- |
| `space.xxs`  | 4     |
| `space.xs`   | 8     |
| `space.sm`   | 12    |
| `space.md`   | 16    |
| `space.lg`   | 20    |
| `space.xl`   | 24    |
| `space.xxl`  | 32    |
| `space.xxxl` | 48    |

Corner radius — continuous ("squircle") curvature, matching macOS control/window rounding, not simple rounded-rect:

| Token        | Value | Use                                                    |
| ------------ | ----- | ------------------------------------------------------ |
| `radius.sm`  | 6     | Small controls, checkboxes, tags                       |
| `radius.md`  | 8     | Buttons, list row highlight                            |
| `radius.lg`  | 10    | Cards, dropzone panel                                  |
| `radius.xl`  | 12    | Sheets, popovers                                       |
| `radius.xxl` | 16    | Window corners (system-controlled, informational only) |

## Materials (elevation)

HIG replaces drop-shadow "elevation" with translucent materials (`NSVisualEffectView`). Map surfaces to system material, not custom shadows:

| Surface                      | Material                                                                                                                 |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Sidebar (device list)        | `.sidebar`                                                                                                               |
| Main content area            | `.contentBackground`                                                                                                     |
| Toolbar/title bar            | `.titlebar`                                                                                                              |
| Menu bar extra popover       | `.popover`                                                                                                               |
| Receive-confirmation sheet   | system sheet (default vibrancy, no custom material needed)                                                               |
| Drag-and-drop active overlay | `.hudWindow`-style vibrancy over the drop target, tinted with `Primary/50` (light) / `Primary/900` (dark) at low opacity |

Respect `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` — fall back to a solid `windowBackgroundColor` when the user has reduced transparency enabled.

## Accessibility notes

- All custom accent usage must be re-verified under Increased Contrast and Reduced Transparency accessibility modes.
- Never convey transfer status (success/failed/pending) by color alone — pair with SF Symbols (`checkmark.circle.fill`, `xmark.circle.fill`, `arrow.triangle.2.circlepath`) and text.
- Respect Dynamic Type scaling; don't clip text at larger accessibility sizes — test row layouts at the largest supported size.
