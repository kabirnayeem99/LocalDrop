# DesignSystem

DesignSystem is a Swift Package Manager library that provides the shared visual language and reusable components for LocalDrop. It targets macOS 14+ and has no external dependencies.

See also: [DESIGN_SYSTEM.md](../DESIGN_SYSTEM.md) for the full design token reference.

## Responsibilities

- Define color, typography, spacing, and radius tokens.
- Provide reusable SwiftUI components.
- Draw the brand mark.
- Expose environment values for reduce motion and accent theme.

## File Reference

- `DesignSystem.swift`: public namespace enum.
- `Color+Tokens.swift`: color tokens.
  - Hex initializer.
  - `Primary.p50` through `Primary.p900` scale derived from `#426834`.
  - `AccentTheme`: primary, hover, pressed, disabled, subtle fill.
  - `SemanticColor`: brand, discovery, sending, receiving, pending, success, destructive.
  - `EnvironmentValues.accentTheme`.
- `Font+Tokens.swift`: typography tokens.
  - `Typography.largeTitle`, `title1`, `title2`, `body`, `callout`, etc.
  - Monospaced font helper and `monospacedStat()` modifier.
- `Spacing.swift`: static spacing scale: `xxs=4`, `xs=8`, `sm=12`, `md=16`, `lg=20`, `xl=24`, `xxl=32`, `xxxl=48`.
- `Radius.swift`: corner radius tokens and `continuousCorners` helpers.
- `BrandMark.swift`: custom `Shape` drawing the paper-plane logo. Supports color, mono-light, and template variants.
- `Environment+ReduceMotion.swift`: adds `EnvironmentValues.appReducesMotion` so the app can respect its own reduce-motion setting alongside the system one.
- `Components/DropZoneView.swift`: drop zone with idle, targeted, and accepted states. Includes animated scale, material fill, stroke, and glow.
- `Components/PulseRingView.swift`: animated pulsing ring. Collapses to a static resting state when reduce motion is enabled.
- `Components/StatusBadge.swift`: small badge with a count or dot.

## Design Principles

- Prefer system dynamic colors and materials. Custom tokens are reserved for brand identity.
- Use the primary green accent only for interactive and selection UI. Use system colors for status.
- Respect Dynamic Type, Increased Contrast, Reduce Motion, and Reduce Transparency.
- Never convey transfer status by color alone. Pair color with SF Symbols and text.

## Usage in FeatureTransfer

Views import `DesignSystem` and reference tokens directly. For example:

```swift
import DesignSystem

SomeView()
    .foregroundStyle(Color.primary.p500)
    .padding(.md)
    .background(.regularMaterial, in: RoundedRectangle.continuous(.lg))
```
