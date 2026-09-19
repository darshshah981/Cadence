# Shortcut responsiveness: first measured change

September 18, 2026. Branch: `codex/shortcut-responsiveness`.
Baseline: `2fe67bc2c0d800ac1259116e08c347ae00730d58`.

## Finding and change

The recording HUD hid available audio behind its entrance animation. Its
244.8 ms reveal delay was followed by a 420 ms decorative sweep that only
blended live levels near the end. A deterministic test of the production
`HUDViewModel` first distinguished voiced input from silence at 600 ms.

Available audio now interrupts that decorative sweep on the next display
frame and uses the existing waveform smoother. Silence retains the entrance
animation. Waveform styling, window animation, shortcut recognition, the
240 ms modifier-only hold threshold, microphone capture, and transcription
are unchanged. This is a feedback timing fix, not the complete shortcut
latency investigation.

## Measurement

Run `python3 scripts/measure_shortcut_feedback.py` from the repository root.
This exercises production view-model code with synthetic input and advances
a deterministic display clock. It never opens the microphone or loads a
transcription model.

| Input and clock | Before | After |
| --- | ---: | ---: |
| Dictation, 60 Hz | 600 ms | 16.67 ms |
| Dictation, 120 Hz | 600 ms | 8.33 ms |
| Scribe, 60 Hz | 600 ms | 16.67 ms |
| Scribe, 120 Hz | 600 ms | 8.33 ms |

The expected reduction was 583–592 ms; the isolated change achieved that
range on this workload. Worst-case simulated response improved by 583.33 ms
(97.2%). Confirmation in the full suite produced the same values.

These numbers measure **animation masking after audio is available**, not
physical key-to-microphone latency or pixels appearing on screen. The
separate opacity transition still applies. They do not prove that the
installed app feels faster or that a spoken first word is preserved.

## Verification

- Full unsigned Debug unit suite: 669 tests passed, zero failures or skips.
- Regression coverage: audio arriving during an existing entrance, successive
  sessions, both recording modes, retained silent entrance, hidden HUD, plus
  existing Reduced Motion and hold/tap/double-press tests.
- Privacy canary scan of test runtime logs passed.
- Evidence: `Build/ShortcutResponsiveness/verification.xcresult`,
  `baseline.log`, `candidate.json`, and `decision.json`.
- One serial experiment, no dependencies or paid scoring. No push performed.

## Local installation

At the user's request, built a signed Release configuration and replaced
`/Applications/Cadence.app` in place. Verified strict nested signatures,
matching bundle ID and designated signing requirement, configured OAuth,
and the installed executable's match to the new build. Relaunched and
confirmed the current UI and existing history. Exactly one installed
Cadence application and one running process remain.

The rollback copy is a ZIP, not a second installed application:
`Build/ShortcutResponsiveness/install/Cadence-before-update.zip`.
Executable hashes and source identity are recorded in the adjacent
`installation.json`. This is a local signed build, not a newly notarized
distribution artifact. The live voice acceptance checks below remain open.

## Follow-up changes and acceptance

The user accepted the installed feature after the final status-flash correction
on September 19, 2026. This closes the current responsiveness and pill-polish
checkpoint. Earlier live-check notes below record validation at each step;
physical key-to-microphone latency has not been benchmarked.

### Status flash correction

The attempted stagger reduced combined label opacity to 0.3725 at 69 ms,
creating a dimming pulse. A new production-curve regression test failed
before the correction. Status labels now use complementary opacity over
140 ms. Their isolated compositing group uses additive blending so common
glyph pixels do not darken from source-over compositing. The gentle
checkmark scale remains, respecting Reduce Motion.

The regression checks every millisecond through the handoff. Evidence:
`Build/ShortcutResponsiveness/status-flash-red.log` and
`Build/ShortcutResponsiveness/status-flash-green.log`. Curve checks alone
do not establish the perceived quality of live rendering. All 54 focused
transition and geometry tests passed. Signed Release installed in place;
signature and launch verified. Rollback ZIP and evidence are retained in
`Build/ShortcutResponsiveness/flash-install/`.

### Stable status handoffs

Processing/completion feedback previously switched from a normal status view
to a special transition view and back, replacing the SwiftUI subtree at both
ends of Transcribing → Inserted (and other status pairs). A single stable
status container now renders the stationary state and the crossfade. Its app
cue stays outside the changing activity region; finishing the fade removes
only the outgoing content. Recording/resting-microphone transitions retain
their specialized layout and the continuous opacity curves.

Regression coverage checks 121 status pairs through intermediate progress
and completion, including stable widths and container selection. Full suite:
679 tests passed; runtime-log privacy canary scan passed. Evidence:
`Build/ShortcutResponsiveness/stable-status-verified.xcresult`.
The signed Release replacement was installed at `/Applications/Cadence.app`
and launch verified, with one running app. Signature verification passed;
installation evidence and the rollback ZIP are in
`Build/ShortcutResponsiveness/stable-status-install/`.
These deterministic checks do not replace live visual acceptance.

### Recording-to-processing content blackout (September 19)

The 140 ms active-content replacement used separate opacity schedules: the
old content faded out over 75 ms while the incoming content waited 50 ms
before fading in over 90 ms. Analytical evaluation finds their combined
opacity drops below 10%, explaining a near-empty handoff even though the
panel background is not explicitly hidden along this path.

Changed to complementary opacity curves over the same 140 ms duration so
the recording content remains visible as processing content appears. Updated
the regression test to assert no opacity gap throughout the transition.
This addresses a concrete fade defect; whole-panel visibility still needs a
live check after installation.

After the user accepted the Xcode 27 license, built and installed the signed
Release replacement at the same app path. Full suite passed 677 tests on
a rerun without the competing Release compile. The initial concurrent run
exceeded the existing 5 ms parser-performance threshold; no threshold was
changed. Strict signing, matching identity, executable hash, and launch were
verified. The visual handoff still needs the user's live confirmation.
Evidence: `Build/ShortcutResponsiveness/crossfade/comparison.json`,
`crossfade-confirmed.xcresult`, and `crossfade-install/installation.json`.

### Single-word recordings

Local, content-free timing logs showed repeated 0.19–0.49 second processed
inputs returning no transcript after only 2–5 ms. The pinned WhisperKit
dependency defaults `DecodingOptions.windowClipTime` to one second. Its
`TranscribeTask` starts decoding only while `seek < seekClipEnd - windowPadding`.
Consequently, nonempty clips at or below one second never enter decoding.
Silence trimming can put longer recordings below that cutoff too.

The production options now set the cutoff to zero for processed clips at or
below one second, retaining the default for longer recordings. Capture,
speech detection, no-speech probability threshold, and model selection are
unchanged. The decision uses the actual post-trimming sample count.

Before the fix, all seven short-input test cases and the silence-trimmed
single-word case failed the dependency's decoder-entry condition. Afterward,
the full suite passed 677 tests. These tests exercise production decoding
options without loading an ML model; actual recognition quality remains a
live voice check. Evidence: `short-word-before.log`, `short-word-verified.xcresult`,
and `short-utterance-timing.ndjson` under `Build/ShortcutResponsiveness/`.
Signed Release replacement installed in place and launch verified; hashes
and rollback archive are in `Build/ShortcutResponsiveness/short-word-install/`.

Also repaired silence wording: the localized empty-audio error is recognized
as no speech, and Scribe's already-compact “No speech” label no longer falls
through to “Try again.” Coordinator tests cover both engine silence outcomes.

### Short-lived processing labels

The HUD now gives processing labels a shared 120 ms presentation grace period.
If a result arrives sooner, it appears directly without briefly showing
Transcribing, Preparing, Inserting, or Copying. Longer work displays the
latest processing stage; repeated updates do not restart the deadline.
Recording, terminal feedback, and hiding remain immediate. A new recording
or result cancels stale pending progress. This changes presentation only,
not capture, recognition, insertion, or backend state timing.

Controlled-clock regression tests cover fast silence, longer work with stage
changes, new-recording cancellation, and hiding. Full suite: 673 tests passed.
The signed Release replacement was installed at the existing path and launch
verified. Evidence and rollback archive are in
`Build/ShortcutResponsiveness/transition-install/`; test results are in
`Build/ShortcutResponsiveness/transition-verified.xcresult`.
User-perceived transition quality remains a live acceptance check.

### Follow-up polish

Removed the warning glyph and error coloring specifically for the compact
“No speech” status. Real errors retain their warning presentation. Increased
waveform release speed: after the target reaches zero, all 16 bars fall below
5% within 200 ms at both 60 and 120 Hz. Audio history and capture remain
unchanged, so that bound is a smoothing measurement, not time from the last
spoken sound.

Repeated frame requests now preserve an already-running display clock rather
than resetting its timestamp during an expansion. This addresses a concrete
timing defect; the user's visually reported expansion glitch has not yet
been identified or reproduced conclusively.

All 670 unit tests passed. Built a signed Release replacement, verified its
signature and matching identity, replaced the same installed app, and
verified launch. Evidence and rollback ZIP are in
`Build/ShortcutResponsiveness/polish-install/`; tests are in
`Build/ShortcutResponsiveness/polish-verification.xcresult`.

Use a consistently signed test build and record its executable identity.
Measure physical shortcut recognition, microphone start, first captured
buffer, and the first visible recording feedback separately. Test a first
activation and several subsequent activations.

Check hold and release, quick tap without recording, double-press lock and
stop, and the Scribe chord without accidentally starting Dictation. Speak
immediately after pressing to check first-word preservation. Repeat with
Reduced Motion. Do not lower the hold threshold solely on the basis of the
animation measurement: it also distinguishes taps and incomplete chords.
