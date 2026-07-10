---
title: Dictation activation feedback - Plan
type: feat
date: 2026-07-10
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Dictation activation feedback - Plan

## Goal Capsule

| Field | Value |
|---|---|
| Objective | Play a short sound and animate a waveform pulse when the dictation HUD pill first appears, signaling that listening is active. |
| Authority | AGENTS.md, existing HUD/DictationCoordinator patterns, AppModel preference conventions, SettingsView section layout. |
| Execution profile | SwiftUI/AppKit implementation with unit tests for preference persistence and state-transition logic, plus visual HUD verification. |
| Stop conditions | Stop if the change requires modifying the meeting capture pipeline, the dictation audio/insertion path, or the HUD panel/window lifecycle. |
| Tail ownership | Run unit tests and a manual dictation trigger to confirm both the sound and waveform pulse fire on pill appearance. |

---

## Product Contract

### Summary

Add activation feedback to the dictation HUD: a short macOS system sound and a waveform pulse animation when the pill first appears, with a Settings toggle to enable or disable the sound.

### Problem Frame

When the user triggers dictation, the pill appears silently. The waveform is flat until real audio levels arrive, which can take a moment — leaving the user uncertain whether listening actually started. An auditory cue and a brief visual pulse provide immediate confirmation.

### Requirements

- R1. Play a short activation sound when the dictation pill first transitions from hidden to the recording state.
- R2. The waveform starts flat, then briefly pulses (a quick wave) before settling into real audio-driven levels.
- R3. A Settings toggle controls whether the activation sound plays (default: on).
- R4. The waveform pulse respects Reduce Motion — it is skipped when the system accessibility setting is active. The sound is not affected by Reduce Motion.
- R5. Meeting capture UI is unaffected; only the dictation HUD is modified.

### Scope Boundaries

#### Out of scope

- Activation sounds for stop, cancel, or error states.
- Haptic feedback.
- Custom or bundled sound assets — using a macOS system sound.
- Changes to the meeting capture pipeline or the broader HUD redesign (a separate plan exists).

---

## Planning Contract

### Key Technical Decisions

- **KTD1. System sound via NSSound.** Use `NSSound(named:)` to play a built-in macOS system sound (e.g., `"Tink"` or `"Pop"`). Avoids asset catalog packaging and `project.yml` changes. The sound is short, subtle, and appropriate for a UI activation cue. The exact system sound name is a private implementation constant, adjustable during implementation.

- **KTD2. FeedbackServing protocol for testability.** A `FeedbackServing` protocol in the Services layer keeps the sound trigger mockable. `SoundFeedbackService` is the concrete implementation. `DictationCoordinator` receives it as an init dependency, consistent with its existing service-injection pattern (`audioCaptureService`, `transcriptionEngine`, etc.).

- **KTD3. Pulse via initial displayBars pattern.** Rather than adding new animation machinery, inject a predefined wave pattern into `HUDViewModel.displayBars` on the hidden-to-recording transition. The existing smoothing loop naturally decays the pulse toward real audio levels, producing a settle effect. Skip the pulse when Reduce Motion is active.

- **KTD4. Preference via AppModel.PreferenceKey.** Follow the existing `Cadence.*` prefix convention for the new preference key. Default to enabled. Place the Settings toggle in the Advanced audio controls section alongside existing dictation audio preferences.

---

## Implementation Units

### U1. Sound feedback service, trigger, and Settings toggle

**Goal:** Create a feedback sound service, wire it into the dictation start flow, and add a Settings toggle.

**Requirements:** R1, R3, R4 (sound portion)

**Dependencies:** none

**Files:**
- `Cadence/Services/FeedbackService.swift` (new — `FeedbackServing` protocol + `SoundFeedbackService` concrete impl)
- `Cadence/Services/DictationCoordinator.swift` (modify — add `feedbackService` init parameter, call on activation)
- `Cadence/App/AppModel.swift` (modify — preference key, property, setter, create and inject service)
- `Cadence/UI/SettingsView.swift` (modify — add toggle in `advancedAudioControls`)
- `CadenceTests/CadenceTests.swift` (modify — preference default and persistence tests)

**Approach:**

Create a `FeedbackServing` protocol with `func playActivationSound()`. The concrete `SoundFeedbackService` holds an `isEnabled` flag; `playActivationSound()` is a no-op when disabled, and calls `NSSound(named:)?.play()` when enabled. File follows the repo convention: focused imports, `private let feedbackLogger = Logger(...)` at the top.

`DictationCoordinator` gets a `feedbackService: FeedbackServing` parameter in its init (alongside the existing service dependencies). In `beginDictationIfPossible()`, call `feedbackService.playActivationSound()` right after the first `publishHUD` call that sets `isVisible: true` with the recording visual state — the single point where the pill appears for a new session. Do not call it from the audio-capture callback updates or mid-session mode-switch updates.

`AppModel` adds `dictationSoundFeedbackEnabled` property and `setDictationSoundFeedbackEnabled(_:)` setter. The preference key uses the `Cadence.*` prefix. AppModel creates the `SoundFeedbackService` in `init`, loads the preference, wires the setter to update the service's `isEnabled`, and passes the service to `DictationCoordinator`.

`SettingsView` adds a `SettingsToggleRow` in the `advancedAudioControls` section, bound to a new `Binding` following the existing pattern (e.g., `waveformSensitivityBinding`).

**Patterns to follow:** `PreferenceKey` enum in `AppModel`; service-injection pattern in `DictationCoordinator.init`; `SettingsToggleRow` + `Binding` pattern in `SettingsView`; existing `Logger` declaration convention.

**Test scenarios:**
- **Default preference:** `dictationSoundFeedbackEnabled` is `true` when no `UserDefaults` value is set for the key.
- **Persistence:** calling `setDictationSoundFeedbackEnabled(false)` persists the value to `UserDefaults` and the published property reflects `false`; calling with `true` reverses it.
- **Disabled no-op:** a `SoundFeedbackService` with `isEnabled = false` does not attempt sound playback (verify through a capturing test double that records calls and asserts zero invocations).
- **Enabled plays:** the test double records that `playActivationSound()` was invoked when enabled.

**Verification:** Unit tests pass for preference default, persistence, and service enabled/disabled behavior. Build succeeds, the Settings toggle appears in the Advanced audio section, and the preference persists across relaunches.

---

### U2. Waveform pulse animation on activation

**Goal:** Inject a brief waveform pulse when the pill appears so the user sees an immediate visual response before real audio levels arrive.

**Requirements:** R2, R4 (motion portion)

**Dependencies:** none

**Files:**
- `Cadence/Services/HUDWindowController.swift` (modify — `HUDViewModel.apply(_:)` pulse logic)
- `CadenceTests/CadenceTests.swift` (modify — transition detection and Reduce Motion tests)

**Approach:**

In `HUDViewModel.apply(_:)`, detect the hidden-to-recording transition by comparing the previous state's `isVisible` and `visualState` against the incoming state. When the transition fires and Reduce Motion is not active, set `displayBars` to a predefined pulse pattern instead of all-zeros — a center-outward bell-curve wave across the 16 bars (e.g., `[0.2, 0.4, 0.6, 0.8, 0.9, 0.8, 0.6, 0.4, 0.2, …]` repeated symmetrically).

The existing smoothing loop then naturally decays these values toward `targetBars` (initially zeros until audio arrives). The downward smoothing factor (0.08) creates a smooth settle over a few hundred milliseconds, giving a wave-then-settle effect. When real audio levels arrive, `targetBars` updates and the bars rise to follow.

When Reduce Motion is active (`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`), skip the pulse — `displayBars` stays at all-zeros as it does today.

Add a guard so the pulse fires only on the initial appearance, not on subsequent `apply()` calls within the same recording session (e.g., when `publishHUD` is called from the audio-capture callback or a mid-session mode switch). Track this with a flag that resets when the HUD returns to invisible/idle.

**Patterns to follow:** Existing `displayBars` smoothing in `HUDViewModel.apply()`; `reduceMotion` handling in `HUDView` and `HUDSpinnerView`.

**Test scenarios:**
- **Transition detection:** calling `apply()` with a recording-plus-visible state after an idle or invisible state sets `displayBars` to non-zero pulse values (at least one bar above 0.1).
- **No pulse on subsequent updates:** calling `apply()` again with another recording state in the same visible session does not re-inject the pulse — `displayBars` continues smoothing toward `targetBars` without resetting to the pulse pattern.
- **No pulse when invisible:** calling `apply()` with `isVisible: false` resets `displayBars` to all-zeros (existing behavior preserved).
- **Reduce Motion skip:** when `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is active, the transition does not inject pulse values — `displayBars` stays at all-zeros.

**Verification:** Unit tests pass for transition detection, no-pulse-on-update, and Reduce Motion behavior. Visual verification: trigger dictation and observe a brief waveform pulse on pill appearance that settles into real audio levels within a few hundred milliseconds.

---

## Verification Contract

| Gate | Command | Applies to |
|---|---|---|
| Regenerate project (after adding new files) | `xcodegen generate` | U1 |
| Unit tests | `./script/build_and_run.sh --test` | U1, U2 |
| Build + visual HUD check | `./script/build_and_run.sh`, then trigger dictation | U1, U2 |

---

## Definition of Done

- Activation sound plays when the pill first appears (default on).
- Settings toggle persists and controls the sound.
- Waveform pulses briefly on pill appearance, then settles into real audio levels.
- Reduce Motion skips the waveform pulse; the sound is unaffected.
- Meeting capture UI and dictation audio/insertion pipeline are unmodified.
- All unit tests pass.
