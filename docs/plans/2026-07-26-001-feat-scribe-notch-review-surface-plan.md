# Scribe notch review surface

## Outcome

Replace Scribe's ordinary bottom review panel during the primary happy path
with two coordinated, non-activating surfaces:

1. The existing Cadence pill remains at its configured screen position and
   gains a Scribe-only animated hue.
2. A compact, AMOLED-black review surface expands down from the MacBook notch when
   the pill enters `Transcribing`.

The review surface types the processed local transcript after transcription
finishes, replaces it cleanly with the provider result, then exposes Discard,
Copy, and Insert. The pill changes from `Transcribing` to `Scribed` with a
checkmark only when the polished draft is ready.

## Settled interaction contract

- Listening uses the existing pill geometry and location. Scribe changes only
  its mode treatment, sound, label, and outline.
- The notch surface is hidden while listening.
- Entering `ScribeSessionState.transcribing` opens the notch surface.
- Entering `generating` or `generatingSlow` reveals the locally processed
  transcript with a bounded type-on animation.
- Entering `reviewing` performs one clean replacement from the local transcript
  to the polished draft. Actions appear only after replacement completes.
- The review surface has a fixed outer height and a scrollable text viewport.
- On notched displays, its status row starts below a reserved 34-point hardware
  notch region.
- The review surface is opaque `#000000` without material translucency or a
  visible border; the colorful hue belongs to the pill.
- Insert targets the originally pinned application and cursor through the
  existing `ScribeContextService` verification contract. Cadence's own exact
  process may temporarily hold focus while its review controls are clicked;
  unrelated applications remain rejected.
- Copy and Discard clear the in-memory Scribe content through the existing
  coordinator routes.
- Copy confirmation appears in a small floating capsule below the notch surface
  on the same always-on-top window layer.
- Insert, Copy, Discard, cancellation, failure, superseding work, and app
  termination must not persist Scribe content.
- On a display without a hardware notch, the review surface becomes a
  top-center floating capsule.
- Reduce Motion replaces type-on and morphing with short fades while preserving
  the same state and action order.
- Dictation and Meeting behavior remain unchanged.

## Public test seams

These are the agreed behavior boundaries established by the approved sequence:

1. `ScribeNotchPresentation.project(...)`
   - Maps public `ScribeSessionState` plus the coordinator's local transcript
     and failure copy to a content-free/typed presentation state.
   - Proves the notch is hidden during listening, opens during transcribing,
     types local text during generation, and reaches an actionable polished
     result only during review.
2. `ScribeNotchGeometry`
   - Produces a top-centered frame for notched and non-notched screens.
   - Keeps the compact surface inside screen bounds and anchored to the screen
     top rather than the visible menu-bar frame.
3. `ScribeHUDProjection`
   - Maps Scribe lifecycle states to the existing pill without changing
     Dictation projection.
   - Proves `Scribed` is emitted only for a ready polished result.
4. Existing `ScribeCoordinator` action APIs
   - Remain the sole Insert, Copy, Discard, retry, and cancellation routes.
   - Existing target verification and privacy tests remain authoritative.

## Architecture

- Add value types for notch presentation, geometry, and motion constants.
- Add `ScribeNotchViewModel`, `ScribeNotchView`, and
  `ScribeNotchWindowController` as a dedicated Scribe UI module.
- Keep `ScribeCoordinator` responsible for acquisition, transcription,
  provider work, retained in-memory drafts, target verification, and terminal
  cleanup.
- Let `AppModel` coordinate the Scribe coordinator, the existing HUD controller,
  and the new notch controller.
- Retain `ScribePanelWindowController` for debug fixtures and any recovery
  state not yet represented safely by the compact surface; it must not appear
  concurrently with the primary notch happy path.

## Motion starting point

- Surface expansion: top-anchored, near-critically-damped spring with a
  0.26-second response and 0.94 damping fraction.
- Content reveal: begin after enough height exists; fade in over 0.12 seconds.
- Source exit: 0.16 seconds.
- Final entry: bounded type-on, then actions fade in.
- Collapse: hide actions and text first, then transform the empty surface into
  the notch. The fixed transparent window envelope does not resize, and no
  window-server animation is used.

These values are behavioral calibration only. No GPL-covered DynamicNotch
source is incorporated.

## Verification

- Focused unit tests for the three public seams.
- Existing Scribe coordinator, privacy, target, HUD, Dictation, and Meeting
  tests.
- Full `./script/build_and_run.sh --test`.
- `./script/build_and_run.sh --verify`.
- Installed Debug-app inspection on a notched display plus a non-notched or
  synthetic geometry fixture.
- Reduce Motion inspection.
- Final standards and specification review against this plan.
