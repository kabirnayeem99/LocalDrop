# UI/UX Motion Polish Plan

## Goal

Improve LocalDrop's SwiftUI experience with purposeful micro-interactions, clearer state feedback, and one or two memorable animation moments that make transfer and discovery feel alive without turning the app into a toy.

This plan is based on the current UI implementation in:

- `Modules/FeatureTransfer/Sources/FeatureTransfer/RootView.swift`
- `Modules/FeatureTransfer/Sources/FeatureTransfer/ReceiveView.swift`
- `Modules/FeatureTransfer/Sources/FeatureTransfer/SendView.swift`
- `Modules/FeatureTransfer/Sources/FeatureTransfer/DeviceCardView.swift`
- `Modules/FeatureTransfer/Sources/FeatureTransfer/HistoryView.swift`
- `Modules/FeatureTransfer/Sources/FeatureTransfer/SettingsView.swift`
- `Modules/FeatureTransfer/Sources/FeatureTransfer/Sheets/IncomingRequestSheet.swift`
- `Modules/FeatureTransfer/Sources/FeatureTransfer/Sheets/TransferProgressSheet.swift`
- `Modules/DesignSystem/Sources/DesignSystem/Components/DropZoneView.swift`
- `Modules/DesignSystem/Sources/DesignSystem/Components/PulseRingView.swift`

## Design constraints

- Respect both system `accessibilityReduceMotion` and the app-level `appReducesMotion` environment.
- Keep animations short, state-driven, and interruptible.
- Prefer SwiftUI primitives, SF Symbols, materials, and existing `DesignSystem` tokens.
- Do not add decorative motion that is unrelated to a user-visible state change.
- Keep signature animations in only one or two places so the app still feels like a focused macOS utility.

## Priority 1: High-impact UX fixes

### 1. Make the drop zone actually react to dragging

Current issue:

- `SendView` passes `isTargeted: false` into `DropZoneView`.
- The `.dropDestination` `isTargeted` callback is empty, so drag-over feedback never appears.

Planned improvement:

- Store local `@State private var isDropTargeted = false` in `SendView`.
- Pass `isDropTargeted` into `DropZoneView`.
- Update it from the `dropDestination` targeted callback.
- Enhance `DropZoneView` with scale, border glow, material shift, and icon lift while targeted.
- On successful drop, briefly show an accepted state before the staged file chip appears.

Expected impact:

- Drag and drop becomes discoverable and satisfying.
- Users get immediate confirmation that the app can receive the dragged item.

### 2. Add meaningful nearby-device card states

Current issue:

- `DeviceCardView` is visually static.
- There is no hover, press, new-device, or send-start feedback.

Planned improvement:

- Add hover lift, subtle shadow, and border tint.
- Add press compression before invoking send.
- Add a small "available" pulse or glow for newly discovered devices.
- Add a trailing affordance icon on hover, such as `paperplane.fill`.
- Add context menu actions later if favorites or details are implemented.

Expected impact:

- Device cards feel clickable and more trustworthy.
- Discovery feels active instead of like a static placeholder list.

### 3. Animate staged-file insertion and removal

Current issue:

- `StagedFileChip` appears and disappears abruptly.

Planned improvement:

- Use a spring transition for insertion from the drop-zone direction.
- Use an opacity/scale transition for removal.
- Flash the file icon background briefly after staging.
- Consider showing multiple staged items once the store supports it visually.

Expected impact:

- Users clearly understand that the dropped/selected file has been accepted.

### 4. Improve transfer progress feedback

Current issue:

- `TransferProgressSheet` has a spinning icon and progress bar, but progress updates still feel mechanical.

Planned improvement:

- Animate `ProgressView` value changes with a short ease-out.
- Use monospaced digit transitions for percent, throughput, and ETA updates.
- Add directional styling: sending can lean toward blue/cyan, receiving can lean toward green.
- Add an explicit completion state before dismissing the sheet.

Expected impact:

- Transfers feel smoother and less abrupt.
- Completion becomes a clear moment instead of a silent disappearance.

## Priority 2: Signature animations

### 1. Upgrade the Receive hero into the app's signature idle animation

Current surface:

- `ReceiveHero` already has `PulseRingView`, `RotatingDashedRing`, the brand mark, and reduce-motion handling.

Planned over-the-top animation:

- Add layered orbiting device glyphs around the brand mark.
- Add a subtle radial scan sweep that passes behind the brand mark.
- Add a breathing glass badge effect on the central brand tile.
- Add occasional tiny signal sparks on the dashed ring.
- In reduce-motion mode, render a static layered hero with a stronger visual hierarchy and no continuous movement.

Why here:

- Receive is the app's first impression and idle state.
- The existing radar concept already supports this kind of animation.

Guardrails:

- Keep the animation calm and slow.
- Avoid heavy particle effects.
- Use `TimelineView(.animation)` or state-driven repeat animations carefully.
- Consider `Canvas` only if drawing complexity grows.

### 2. Add a short transfer-complete celebration

Current surface:

- `TransferProgressSheet` already owns transfer direction, file name, percent, and counterpart.

Planned over-the-top animation:

- For sent transfers: morph/spin the paper-plane icon into a checkmark with a short path trail burst.
- For received transfers: glow the tray icon, then snap into a checkmark badge.
- Add a brief radial accent burst behind the icon.
- Keep the celebration under 900ms.
- In reduce-motion mode, skip the burst and show an immediate checkmark plus stronger color feedback.

Why here:

- Completion is the highest-emotion state in a file transfer app.
- It rewards the user without adding friction to the core workflow.

## Priority 3: Smaller micro-interactions

### Send screen

- Add refresh button spin while discovery is refreshing.
- Add scan button radio-wave ripple while scanning.
- Add hover and pressed states to `SelectionTypeButton`.
- Add a selected state once file/folder/text/paste actions are wired.
- Add a "no nearby devices" empty state with a subtle radar glyph instead of showing an empty grid.
- Add loading/skeleton state for peer discovery if the runtime exposes scanning state.

### Incoming request sheet

- Add a soft entrance scale and fade for the sheet content.
- Stagger file rows on presentation.
- Pulse the source device icon once.
- Make the Accept button visually primary and Decline quieter.
- Add subset-selection affordance later, matching `IncomingTransferDecision.acceptSubset`.

### History

- Animate newly inserted history rows with slide/fade.
- Add a polished empty state for no recent transfers.
- Add a confirmation dialog for `Clear all`.
- Add row-level context menu actions later, such as reveal in Finder or retry.

### Sidebar and toolbar

- Add a small badge or dot for incoming requests and active transfers.
- Animate the `ThisDeviceChip` status dot and map it to actual runtime status.
- Add tooltip/status detail for runtime state.
- Add button disabled/loading states during refresh or active operations.

### Settings

- Convert `AccentSwatchRow` into real selectable controls.
- Add hover rings and selected checkmarks to swatches.
- Persist accent color choice instead of showing static swatches.
- Wire `Choose...` to an `NSOpenPanel` for save location.
- Animate the saved path update after choosing a folder.
- Add confirmation or explanatory dialog for security-sensitive toggles if behavior becomes non-obvious.

## Color and visual hierarchy improvements

Current issue:

- The design system is mostly one green family. It works as a brand color, but it gives transfer, discovery, pending, success, and error states too little separation.

Planned semantic color expansion:

- Brand: existing green `Primary` scale.
- Discovery/scanning: blue or cyan.
- Receiving/success: green.
- Pending/PIN/waiting: amber.
- Declined/error/destructive: system red.
- Neutral surfaces: system background/materials and separator colors.

Implementation notes:

- Add semantic wrappers to `DesignSystem` instead of scattering raw colors through `FeatureTransfer`.
- Continue using `.primary`, `.secondary`, and system colors for text.
- Avoid replacing native button styles unless a specific control needs custom interaction.

## Dialog and feedback improvements

Add lightweight user feedback for:

- Transfer accepted.
- Transfer declined.
- Transfer canceled.
- Transfer completed.
- File staged.
- Discovery refreshed.
- Save location changed.
- Settings persisted if persistence can fail.

Recommended pattern:

- Use compact toast/banner feedback for non-blocking status.
- Use confirmation dialogs only for destructive actions, such as clearing history.
- Use sheets only for multi-step or consent-heavy flows.

## Accessibility requirements

- All continuous animations must pause or simplify when either system reduce motion or app reduce motion is enabled.
- Decorative animation layers should be hidden from VoiceOver.
- Interactive custom controls need labels, hints where useful, and proper button traits.
- Motion must not be the only feedback; pair it with color, icon, text, or state changes.
- Ensure hover-only affordances still work for keyboard and VoiceOver users.

## Suggested implementation order

1. Fix drop-zone targeted state and staged-file transitions.
2. Add hover/press states to device cards and selection buttons.
3. Add transfer progress value animation and completion state.
4. Add `Clear all` confirmation and empty states for history/device discovery.
5. Expand semantic colors in `DesignSystem`.
6. Upgrade `ReceiveHero` as the first signature animation.
7. Add transfer-complete celebration as the second signature animation.
8. Wire settings polish: accent swatches, save-location picker, and toggle feedback.

## Verification

- Build `Modules/DesignSystem` and `Modules/FeatureTransfer` with `swift build`.
- Run app integration after package work with `xcodegen generate` and `xcodebuild -scheme LocalDrop build`.
- Manually verify:
  - drag-over and drop acceptance
  - hover and press states
  - discovery refresh feedback
  - incoming request sheet
  - transfer progress and completion
  - history empty and clear-all flows
  - settings controls
  - light mode, dark mode, and increased contrast
  - system Reduce Motion and app Reduce motion

## Out of scope for this plan

- Changing LocalSend protocol/runtime behavior.
- Adding new transfer features not already represented by the feature state.
- Replacing the current app architecture.
- Building a full custom design system beyond the semantic colors and interaction primitives needed for this polish pass.
