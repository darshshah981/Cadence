# SaaS-style Settings and Cadence control-system contract

Date: 2026-07-11  
Wayfinder ticket: [Prototype the SaaS-style Settings architecture and Cadence control system](https://github.com/darshshah981/Cadence/issues/39)  
Prototype verdict: Variant A — nested category rail

## Decision

Cadence Settings uses a nested category rail and card-based detail pane. Cadence-owned product surfaces share one visual control system with explicit semantic roles; operating-system-owned dialogs and security surfaces remain native.

The chosen direction is calm, dense, warm, and recognizably macOS. It avoids generic SaaS gloss: no decorative glass, floating card shadows, oversized marketing typography, or web-dashboard chrome.

## Settings shell

- Preserve the existing global 220-point app sidebar.
- Add a 176-point Settings category rail inside the detail area.
- Use a centered detail column with an ideal width of 680–720 points and a practical minimum near 520 points.
- Keep the existing minimum main-window size as the primary target. When the detail column would fall below roughly 560 points, stack row labels above controls and replace the nested rail with a compact top category menu.
- A category change replaces the detail page while preserving the Settings shell, scroll position per category where practical, keyboard focus, and VoiceOver context.
- Page headers use a title plus one concise description. Each page contains one to three focused cards rather than reproducing the current long vertical form.

The horizontal category-bar prototype is rejected because it weakens hierarchy as Apps and Providers grow. The overview-hub prototype is rejected because it adds an unnecessary drill-in step for frequently adjacent settings.

## Information architecture

### General

- Setup and permission readiness
- Appearance and launch behavior
- Google Calendar and meeting integration
- Replay or resume onboarding

### Dictation

- Start/stop shortcuts and recording behavior
- Transcription quality/model choice
- Vocabulary and filler handling
- Audio and HUD response, including waveform sensitivity

### Scribe

- Enabled/readiness state
- Active provider/model summary with a direct route to Providers
- Meaning-preserving polish explanation
- Mandatory review, Retry Polish, Insert Unpolished, and failure behavior
- Global default preset

### Apps

- Installed-app configurations using icon and display name
- Reusable environment/preset family selection
- App-specific custom guidance
- Missing/uninstalled app recovery
- Other Apps fallback

### Providers

- Saved provider library and explicit active provider
- Searchable recommended/live/custom model selection
- Credential and validation state
- Recipient and data-sent disclosure
- Add, edit, disable, activate, and remove actions

### Privacy

- Local processing and content-boundary summary
- Provider payload and recipient explanation
- Analytics opt-in
- Content-free diagnostics, export, and clearing

Provider diagnostics do not receive a dedicated top-level page. Provider-specific readiness and validation stay on provider cards; the complete content-free log/export controls live in Privacy.

### Advanced

- Low-frequency transcription and decoding controls
- Audio normalization and silence behavior
- Migration/recovery tools
- Custom OpenAI-Compatible endpoint and Custom Model ID paths

## Visual language

- Use system typography with compact macOS density.
- Page title: semibold title scale; card title: 13-point medium/semibold; description: 12-point regular; hint: 11-point; section label: 10-point uppercase semibold with 0.7 tracking.
- Cards and fields use 8-point continuous corners, one-point borders, solid dynamic surfaces, and no shadow.
- Internal card rows use 12-point insets and inset dividers. Section spacing remains compact and deliberate.
- Retain the existing warm monochrome palette from `FlowTheme`: warm off-white/charcoal backgrounds, black/cream primary actions, muted secondary text, restrained green success, and muted red destructive/error states.
- Dark mode is a first-class token mapping, not an overlay or inversion.

## App-wide control roles

Every Cadence-owned button declares one semantic role and renders through shared components:

- **Primary**: filled high-contrast action; at most one per local task surface and at most one default Return action.
- **Secondary**: outlined action for safe alternatives.
- **Quiet**: borderless or subtle action for low-emphasis navigation and utilities.
- **Destructive**: muted red quiet/outlined by default; filled only when destructive action is the unmistakable primary task in a confirmation surface. Never the default Return action.
- **Icon**: compact visual action with a minimum hit target, tooltip/help, accessibility label, keyboard focus ring, and pressed state.
- **Navigation row**: full-row category/sidebar action with selected state and stable alignment.
- **Menu item**: preserve platform menu semantics and keyboard behavior.

The component system supports default, hover, pointer-down/pressed, keyboard-focus, disabled, and loading states; optional leading/trailing icons; full-width layout; default/cancel keyboard shortcuts; accessibility identifiers; and destructive confirmation policy.

Custom rendering must preserve native semantics. A visual button still exposes Button behavior; toggles expose checked state; menus and dropdowns preserve arrow/typeahead/Escape/Return behavior; sliders expose value and increment semantics.

## Other controls

- Replace discrete segmented controls with compact dropdowns: trigger mode where appropriate, quality preset, filler handling, decoding mode, environment preset, and provider model.
- Keep waveform sensitivity as the only continuous Settings slider and render it through the Cadence visual layer.
- Keep the compact Cadence toggle, but define explicit on/off and disabled accessibility values.
- Use native menu/picker mechanics behind a Cadence-owned dropdown trigger and menu-row appearance rather than building an inaccessible custom popover.
- Shortcut recording may continue to bridge AppKit behavior, but its surrounding label, focus, border, and state styling follow the shared field contract.

## Advanced disclosure

Replace the Settings Advanced `DisclosureGroup` chrome with a full-width plain button row:

- Title and description lead in a vertical label stack.
- An explicit trailing chevron sits in a fixed 24×24 frame aligned to the row center.
- Expanded state rotates the chevron 90 degrees with the shared section motion.
- The entire row is one hit target and exposes expanded/collapsed value to accessibility.
- Expanded content aligns to the card's 12-point content and divider grid.

Use the same disclosure-row primitive for provider and meeting disclosures where the information hierarchy matches. Do not mechanically replace native DisclosureGroup in unrelated OS-owned contexts.

## Motion and feedback

- Press feedback starts on pointer-down with subtle scale/brightness response.
- Default control motion uses the existing critically damped `FlowMotion` character; section disclosure uses the existing section spring.
- Transitions start from current presentation state and remain interruptible.
- Reduced Motion replaces spatial/spring movement with short opacity or immediate state changes while preserving feedback.
- No bounce without gesture momentum; ordinary Settings controls do not overshoot.
- Loading states preserve button dimensions and announce progress without shifting surrounding layout.

## Accessibility and keyboard contract

- All controls support full keyboard traversal with visible high-contrast focus rings.
- The selected Settings category and current page heading are announced.
- Dropdowns retain platform navigation and typeahead behavior.
- Icon-only actions have explicit labels and contextual help.
- State is never communicated by color alone; readiness and validation include text.
- Target size, contrast, VoiceOver order, dynamic type stress, Reduce Motion, and increased-contrast behavior are release acceptance checks.
- Default and cancel shortcuts are unique within a task surface. Destructive actions require an explicit confirmation when data, credentials, or saved configuration would be lost.

## Responsive and state coverage

The implementation and UI tests cover:

- Minimum and initial main-window widths
- Long localized labels and increased text size
- Light/dark and increased-contrast appearance
- Empty, loading, ready, disabled, needs-attention, validation-failed, and missing-app states
- Dropdown open/search/selected/disabled/error behavior
- Button default/hover/pressed/focus/disabled/loading states
- Advanced collapsed/expanded alignment
- Provider library with active and inactive entries
- Apps with installed, missing, and Other Apps fallback entries
- Custom-guidance closed, editing, saved, and validation-error states

## Rollout boundary

The control system is migrated app-wide across Settings, Scribe, Main Window, Meeting Notes, onboarding, permissions, menu-bar content, and HUD controls. Migration is organized by semantic role and shared primitive, then audited across the entire UI surface; it is not a Settings-only restyle.

System permission prompts, file pickers, save/open panels, Keychain dialogs, and other operating-system-owned surfaces remain native.

## Prototype disposition

Variant A answered the layout question. Variants B and C and the switcher are throwaway and should be deleted. Production SwiftUI must be implemented from this contract and existing Cadence patterns rather than promoting prototype code directly.

## Map impact

No new Wayfinder ticket is required. The diagnostics-surface fog is resolved: provider card status plus Privacy diagnostics is sufficient; there is no standalone Diagnostics category.
