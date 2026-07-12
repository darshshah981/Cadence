# Willow experience reference

## Provenance and boundary

This is a sanitized, durable reading of Willow Voice 2.3.0 observed on macOS 26.1 on 2026-07-10. Raw frames and their checksums are private in `local/willow-reference-bundle/manifest.md`; they are intentionally not committed. Frame IDs below refer to that private manifest.

Willow is a behavioral reference. Cadence may borrow interaction problems and patterns, not Willow copy, assets, layout, or account model.

## Onboarding flow

| State | Entry and visible hierarchy | Action/exit | Cadence-relevant observation |
|---|---|---|---|
| W-ONB-01 → W-ONB-03 | One question at a time: role, role detail, then acquisition source. Choice grid dominates; one Next action is visually quiet until a choice is made. | Back returns to the previous decision without losing the existing choice. | Cadence should not collect role/acquisition/workspace data; borrow only the focused, single-decision rhythm. |
| W-ONB-04 | Two privacy choices are explained before any training-like preference is accepted. Private mode is selected by default. | Back/Next; settings copy later exposes the same decision. | Cadence should surface a local-first default and describe a real egress boundary, not make generic assurances. |
| W-ONB-05 → W-ONB-08 | Permission summary, private microphone rehearsal, then a language summary with a searchable modal chooser. | Each stage offers Back plus an explicit continuation. | Use contextual permissions, a no-persistence rehearsal, and a model-aware language choice. |
| W-ONB-09 → W-ONB-17 | Willow teaches the product distinction before configuration: Scribe first, then Dictation. Each mode has a separate shortcut check and guided demo in a familiar fake app. | A failed shortcut answer opens an editor with Cancel/Save. Demo screens offer Skip. | Cadence needs the same mental-model ordering, but must define its own HUD focus/insert safety contract. |
| W-ONB-18 → W-ONB-20 | Optional reminder, workspace name, invitation upsell, then a first-use chooser and a seven-task Learning Center. | Invitation has a safe Skip; first-use choices remain visible on Home. | Keep optional growth prompts out of Cadence. Keep a small, replayable learning checklist and first-use choice. |

## Product shell

- Home combines an immediate use chooser, a single current shortcut reminder, compact metrics, a Learning Center checklist, and an empty history state (`W-SHELL-05`). The user has an obvious next action even with no transcript history.
- Dictionary is a single educational surface with two tabs: Personal Terms and Personal Shortcuts. It uses count, search, refresh, and an explicit add action. A synthetic term and a synthetic phrase-to-replacement shortcut were added and captured through a search filter (`W-SHELL-06`, `W-SHELL-07`) so existing cloud items never appear in the reference. Willow exposed no per-item delete control in this pass; Cadence still needs its own empty/populated/edit/disable/delete states.
- Style Matching uses context tabs (Email, Work Messages, Casual Messages, Other), three tone presets with realistic examples, a three-level length choice, and an optional free-text habits field (`W-SHELL-01`, `W-SHELL-02`). The hierarchy is task-first: choose where the style applies, then choose a readable behavioral preset.
- Settings is a modal/sidebar overlay with grouped categories and search (`W-SHELL-03`, `W-SHELL-04`). Privacy is a plainly named destination; destructive transcript deletion is visually separated from preference toggles.

## Interaction and accessibility observations

- Onboarding is mostly Back/Next, with skip only for guided practice and invitations. That makes skipped learning explicit rather than silently treated as complete.
- Shortcut validation asks a human-observable question (whether the control changed color) and offers a recovery editor immediately. Cadence should map its equivalent to a real system state, not decorative animation.
- The owner-supplied compact HUD sequence shows a yellow lock only in the hold-to-listen frame (`W-HUD-03`); it is absent from the two non-hold frames (`W-HUD-01`, `W-HUD-02`). The real lifecycle recording (`W-VID-01`) shows the locked waveform at about 00:06, a transition to a colored Scribe HUD around 00:10-00:12, a generated-result sheet with an explicit Insert action, and a later continuous-listening bar without the lock. Treat the glyph as a latched/hold-specific control state rather than a universal privacy assertion. Cancellation, failure, and retry remain unverified.
- The captured flow uses static status and examples. Motion timing, keyboard-only traversal, VoiceOver order, reduced motion, high contrast, and narrow-window reflow were not captured yet and are not approved design inputs.

## Privacy and focus observations

- Willow presents privacy before microphone rehearsal and later places privacy controls alongside transcript deletion.
- Guided examples disclose their synthetic target context in the visible sample app.
- Do not infer that Willow's screen-context behavior is acceptable for Cadence. Cadence remains explicit, bounded, transient, and never ambient.

## Evidence gaps that block approval

This reference is a useful first pass, not an approved bundle. It now has three real HUD stills and one real HUD/Scribe lifecycle recording, but still needs Scribe cancellation/failure/retry, accessibility and narrow-window variants, permission-denied/recovery states, and fresh Cadence baseline captures. The current desktop-control environment cannot hold Willow's hardware `Fn` hotkey, so remaining shortcut-dependent evidence requires a person at the Mac to trigger it rather than simulated evidence.
