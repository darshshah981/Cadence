---
title: HUD runtime correctness and release readiness - Corrective Plan
type: fix
date: 2026-07-10
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
---

# HUD runtime correctness and release readiness

## Objective

Make the three recent HUD plans work in the installed Cadence app, not merely exist in source. Refactor the runtime interaction boundary, complete the missing tray services and visibility lifecycle, correct activation feedback, and prove every acceptance criterion in Debug and Release builds.

## Scope

- Dictation activation sound and waveform pulse.
- Always-on idle HUD, true click expansion, stable dragging, five-position snap, drop zones, persistence, tooltip, Dock tracking, permission gating, and non-activating behavior.
- Expanded tray lifecycle, copy, dictionary capture with clipboard fallback, timed/session hiding, and menu-bar restore.
- Accessibility, Reduce Motion, privacy, regression tests, installed-app QA, and Release compilation.

## Non-goals

- Redesigning the HUD visual language.
- Changing dictation capture, transcription, insertion, or meeting recording pipelines.
- Adding new telemetry beyond coarse privacy-safe outcomes.
- Custom HUD positions beyond the five planned presets.
- Shipping, notarizing, pushing, or opening a PR without explicit authorization.

## Audit findings

1. `DragGesture(minimumDistance: 1)` cannot recognize a zero-movement click, so expansion never fires for a normal click. The tested tap helper is unused by the view.
2. Drag translation is applied while moving the gesture's own window and uses the wrong AppKit Y convention, producing unstable or ineffective dragging.
3. The outer drag gesture covers the expanded tray and competes with Button/Menu interactions.
4. Clicking the HUD can activate Cadence, while `applicationDidBecomeActive` broadly opens the main window.
5. Expansion resize animates size and repositions separately using an in-flight frame; controller animation does not respect Reduce Motion.
6. Activation pulse detects hidden-to-recording, but production is visible idle-to-recording; the passing test exercises a dead transition.
7. Dictionary capture lacks its planned service, clipboard fallback, trimming, and dedicated tests; analytics records selected-text length.
8. Hide/restore lacks an explicit state model, persistence, menu restore, and correct until-next-session semantics.
9. Permission revocation does not explicitly hide the idle HUD.
10. The installed Debug app predates the final main merge, so all final QA must reinstall the exact corrected build.

## Ordered implementation

### Phase 1 — Runtime interaction and activation refactor

Dependencies: none. Must complete before tray actions are evaluated.

Owned files/modules:

- `Cadence/UI/HUDView.swift`
- `Cadence/Services/HUDWindowController.swift`
- `Cadence/App/AppDelegate.swift`
- `Cadence/Models/DictationModels.swift` only if a value-type interaction model is needed
- focused HUD tests in `CadenceTests/`

Tasks:

1. Replace the ambiguous outer drag-only interaction with a collapsed-logo interaction surface that recognizes a true click and tracks drag using stable screen/global pointer coordinates.
2. Keep drag behavior off the expanded tray so Button/Menu hit testing is independent.
3. Correct AppKit Y-coordinate handling and persist the final snap position.
4. Compute one final panel frame for expand/collapse; animate only when Reduce Motion is off.
5. Ensure HUD interaction does not activate Cadence or open the main window; gate the broad app-activation reopen path without breaking Dock reopen behavior.
6. Change waveform activation detection to the production `.idle -> .recording` transition and retain once-per-session behavior.
7. Add production-boundary tests for click, drag deltas, snap persistence, expanded control isolation, target-frame sizing, Reduce Motion, and `.logoIdle -> recording` pulse.

Acceptance criteria:

- A normal click expands the installed idle HUD without opening the main window.
- A second click/contract action collapses it.
- A drag follows the pointer smoothly in every direction, shows drop zones, snaps, and persists.
- Expanded controls receive clicks without initiating drag.
- Reduce Motion disables panel resize/morph animation and activation pulse.
- The activation pulse occurs once when the always-visible idle HUD begins recording.

### Phase 2 — Complete tray services and visibility lifecycle

Dependencies: Phase 1.

Owned files/modules:

- new `Cadence/Services/SelectionCaptureService.swift`
- `Cadence/App/AppModel.swift`
- `Cadence/Models/DictationModels.swift`
- `Cadence/Services/HUDWindowController.swift`
- `Cadence/UI/HUDView.swift`
- `Cadence/UI/MenuContentView.swift`
- focused service/state tests in `CadenceTests/`
- `project.yml` only if XcodeGen source discovery requires it

Tasks:

1. Implement an injected selection-capture service using AX selected text with clipboard fallback, trimming, empty handling, and no sensitive logging/telemetry.
2. Wire dictionary feedback states and vocabulary append behavior through AppModel setters.
3. Introduce an explicit, testable HUD visibility model/store/scheduler for visible, timed hidden, and until-next-session states.
4. Make timed hides restore on expiry; make until-next-session restore on process relaunch, not dictation start.
5. Add an immediate “Show Cadence bar” menu action while hidden.
6. Hide the idle HUD when required permissions are revoked and restore only when policy permits.
7. Preserve active dictation visibility and reliability semantics explicitly.

Acceptance criteria:

- Copy is disabled with empty history and copies the latest transcript otherwise with confirmation.
- Dictionary capture works from AX and clipboard fallback; whitespace is rejected; terms are not logged or sent to analytics.
- 10-minute and 1-hour hides use correct expiry state and restore scheduling.
- Until-next-session remains hidden through dictation and restores after relaunch.
- Menu-bar restore works during any hide.
- Permission revocation removes the idle HUD.

### Phase 3 — Plan-level verification and release hardening

Dependencies: Phases 1–2.

Before release verification, complete a separately committed visual-motion pass:

1. Reduce the collapsed idle icon by 30% while retaining a practical pointer target through an invisible hit area where needed.
2. Make expand/collapse geometrically symmetric around the current anchor: bottom-center grows equally left/right; corner positions preserve their flush boundary edges and grow inward from the attached corner.
3. Keep pill edges flat wherever they touch a usable display boundary or the Dock top, including expanded and transient states. Top-left and top-right must attach below the macOS menu bar at `visibleFrame.maxY`, not the physical display top.
4. Make corner drop-zone outlines match the collapsed icon's visible dimensions rather than exceeding it.
5. Drive waveform and morph animation at the maximum practical display refresh rate using the native rendering clock; remove timer/animation paths that introduce avoidable low-FPS stepping.
6. Align waveform bars, logo, pill contents, overlay outlines, and panel frames through shared metrics rather than duplicated constants.
7. Preserve Reduce Motion by disabling non-essential interpolation while keeping state transitions immediate and legible.

Visual acceptance criteria:

- The idle mark is 30% smaller visually but remains easy to click and drag.
- Bottom-center expansion does not visibly shift left or right.
- Corner expansion remains flush to the same usable edges and grows only into available screen space; top corners stay below the menu bar.
- Drop-zone outlines are the same visible size as the idle icon.
- Recording waveform and morphing appear smooth at the display's available refresh rate without misaligned frames.

Owned surfaces: tests, generated Xcode project via XcodeGen, build/install artifacts, and corrective fixes delegated back to workers.

Tasks:

1. Regenerate the project from `project.yml`; never hand-edit the generated project.
2. Run focused HUD/service tests, the full Debug suite, installed-app verification, and Release build.
3. Exercise empty/populated, collapsed/expanded, dragging, each snap position, recording/finalizing/error, tooltip, hidden/restored, permission-revoked, reduced-motion, and narrow/multi-screen-relevant states.
4. Use isolated defaults for tooltip and hide-state QA so existing user state cannot mask behavior.
5. Run an independent fresh-context runtime/code review; fix every material finding and repeat verification.
6. Commit a clean local branch; do not push.

## Validation commands

```zsh
xcodegen generate
./script/build_and_run.sh --test
./script/build_and_run.sh --verify
xcodebuild build -project Cadence.xcodeproj -scheme Cadence -configuration Release \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
git diff --check
git status --short
```

Manual/runtime proof must use `/Applications/Cadence Debug.app` built from the final commit and record the exact commit/build provenance.

## Risks and mitigations

- **Window activation regression:** preserve Dock/menu routes to the main window and test them separately from HUD interaction.
- **Gesture/button conflict:** scope drag/tap exclusively to the collapsed logo and add an integration-level hit-testing test or AppKit harness.
- **Coordinate/multi-display errors:** use screen-space pointer positions and `NSScreen` frames; unit-test positive/negative screen origins where possible.
- **Hide policy suppressing active recording:** model idle visibility separately from active dictation presentation and test both.
- **Privacy regression:** selection content remains local and absent from logs/analytics; tests inspect only outcomes.
- **Generated project drift:** regenerate with XcodeGen and review the generated diff.

## Rollback

Each phase should be committed separately. If runtime verification fails, revert the phase commit rather than partially restoring generated files. The pre-corrective main commit is `2f90146`.

## Definition of done

All requirements in the three source plans pass against the installed app, all automated tests and Release compilation pass, no material independent-review findings remain, and the local branch is clean and unpushed.
