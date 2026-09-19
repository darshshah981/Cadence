# Cadence development baseline — September 18, 2026

## Purpose

Preserve the existing working app and unfinished demo work before starting one
feature at a time. This is a source checkpoint, not a new installed build or a
release approval.

## Saved work

- `main` and GitHub's `main` started at `9374cbf4`.
- `codex/baseline-2026-09-18` preserves the existing permission setup, Compose
  review/recovery, history feedback, settings, HUD, tests, and developer scripts.
  These changes overlap in shared files, so they are retained together rather
  than split into artificial intermediate app states.
- A separate demo commit preserves editable film sources and their required
  media assets. Rendered deliveries, cached frames, Python environments, and
  JavaScript dependencies remain on disk but are ignored by Git.
- `codex/preserve-calendar-work-2026-09-18` preserves the older calendar work
  at `57b2c0a6`. Its original base is `3b365520`; it is not merged into the app
  baseline. This is an unvalidated recovery checkpoint, not completed work.
- The three pre-existing stashes and older branches are retained.

Both working copies were archived before any cleanup. The local recovery folder
is `~/Documents/Cadence Backups/20260918-201600-baseline/`. It contains a verified
Git bundle of the original references (including stashes), binary patches,
working-file archives, and SHA-256 manifests. Every archived regular file was
verified against its source. The primary archive also preserves untracked build
output, demo dependencies, and rendered deliveries.

The cleanup changes ignore rules and adds this record. Original app, test,
script, and documentation changes were verified byte-for-byte against the
safety snapshot; no product behavior was changed during checkpointing.

## Verification performed

- Regenerated the Xcode project from `project.yml`; it matches the captured
  generated project.
- Full Debug unit suite on macOS: **665 tests passed, 0 failed, 0 skipped**
  (661 Swift Testing tests plus 4 XCTest tests, excluding expanded parameter
  case counts). Code signing was disabled, matching CI's unit-test mode.
- The `CadenceUITests` scheme successfully built for testing. UI tests were
  compiled, not executed in this baseline pass.
- Privacy canary scan passed for the unit-test log and result bundle.
- Both changed build/install shell scripts passed `bash -n`; app changes
  passed `git diff --check`.
- Demo JSON and Python sources parsed; local HTML asset references resolved.
  The film was preserved, not re-rendered or visually re-approved.

Local test evidence is under `Build/BaselineVerification/2026-09-18/`, including
`unit-tests.xcresult`, `unit-tests.log`, and `ui-build.log`.

This does not establish fresh-account macOS permission behavior, microphone or
provider behavior, measured shortcut latency, or Release distribution readiness.
Existing temporary HUD timing instrumentation remains in the captured source;
its overhead and disposition belong in the responsiveness investigation.
The installed apps, personal settings, and macOS permission grants were not
changed. Nothing was pushed or released during baseline preparation.

## Working one feature at a time

1. Define the user-visible behavior and a short list of acceptance examples.
2. Start a dedicated branch from the tested baseline.
3. Implement the smallest complete change and run relevant automated checks.
4. Review a working build together, including the original failure scenario.
5. Commit the accepted change, then decide when to merge and release it.

The next proposed feature is shortcut responsiveness. Waveform redesign,
instruction-aware Scribe, and background context memory remain separate work.
