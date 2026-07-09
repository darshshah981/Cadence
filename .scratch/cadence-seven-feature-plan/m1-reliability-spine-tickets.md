# Tickets: M1 Reliability Spine (Crash-First Ledger + Final-Pass Lineage)

Builds the reliability core of the release — the implementation of plan tickets [06 (capture ledger)](issues/06-define-the-capture-ledger-contract.md) and [07 (final-pass lineage)](issues/07-define-final-pass-lineage-contract.md) from the [Cadence seven-feature plan](map.md). Architecture: [ADR 0001](../../docs/adr/0001-capture-ledger-persistence.md). Terms: [CONTEXT.md](../../CONTEXT.md). Durability basis: [research/03](research/03-meeting-capture-durability-audit.md).

Work the **frontier**: any ticket whose blockers are all done. After T1, both T2 and T3 are takeable; T4 follows T3. Clear context between tickets with `/implement`.

## T1: Recover a recording interrupted by a force-quit

**What to build:** If Cadence is force-quit in the middle of a meeting recording, relaunching shows that recording *recovered* — its audio and live-draft transcript are preserved, and a calm status explains what happened. This is the crash-first headline: durability from the first frame, not from stop.

**Blocked by:** None — can start immediately.

- [ ] Starting capture writes a recording-ledger entry (recordingID, source, startedAt, CAF reference, `state = recording`) onto the note from the first frame, before any lossy processing.
- [ ] A per-recording lifecycle `state` exists (`recording → recorded → finalizing → final / finalizationFailed`); legacy notes decode with all recordings at `.final` (additive migration, non-breaking).
- [ ] Force-quitting mid-recording, then relaunching, recovers the recording: audio + live-draft transcript preserved; the note is marked recoverable rather than appearing as a stranded live draft.
- [ ] Recovery status is calm, non-modal, and privacy-safe (no audio/transcript content), via the existing status-message channel.
- [ ] Recovery has direct unit tests (mid-record recovery, after-stop recovery, no-audio case) using mock engines — no WhisperKit in unit tests.
- [ ] `./script/build_and_run.sh --test`, `--verify`, and `--audio-smoke` pass (capture path is touched).

## T2: Relink orphaned audio that no note references (backstop sweep)

**What to build:** If a recording's audio survives but no note references it (e.g. the note write itself failed), relaunch discovers it from the audio directory and relinks it — to its note if the note exists, or into a recovery section if it doesn't. Cadence never auto-deletes captured audio.

**Blocked by:** T1 (shares the recovery + per-recording state machinery).

- [ ] On relaunch, an audio-directory sweep finds audio referenced by no note and relinks it, using the recordingID/noteID encoded in the filename.
- [ ] Audio whose note is absent appears in a recovery section (kept, not auto-deleted) with a keep/discard choice.
- [ ] Sweep + relink and the never-delete invariant are covered by unit tests.
- [ ] `./script/build_and_run.sh --test` and `--verify` pass.

## T3: Retry the final pass from saved audio (unlimited, idempotent)

**What to build:** A recording left in `finalizationFailed` can be re-finalized on demand — the user triggers a retry, the final pass re-runs over the saved audio, and state advances to final (or back to failed). Retrying never duplicates or loses segments.

**Blocked by:** T1 (per-recording state model).

- [ ] A user-facing retry action re-runs the final pass from saved audio for a `finalizationFailed` recording.
- [ ] Success → state `final`, failure message cleared; failure → back to `finalizationFailed` with the new reason.
- [ ] Retry is idempotent and per-recording: re-running replaces only that recording's final segments, never duplicates.
- [ ] Retry is covered by unit tests (success advances, failure re-fails, idempotent re-run, empty output → failed) using mock engines.
- [ ] `./script/build_and_run.sh --test` and `--verify` pass.

## T4: Show final-pass lineage and allow reverting to the live draft

**What to build:** When a final pass fails or materially changes the draft, the note shows a calm "challenge" affordance — a one-line peek at the retained draft, with actions to accept the final, revert to the live draft, or retry. Reverting restores that recording's live-draft segments. Word-level diffing is explicitly out of scope.

**Blocked by:** T3 (the lineage surface sits alongside retry).

- [ ] Live-draft segments are retained per-recording after final-pass replacement, enabling revert.
- [ ] On failure or material change, a calm affordance shows a one-line draft peek plus accept / revert / retry.
- [ ] Revert restores the retained live-draft segments for that recording.
- [ ] No lineage chrome appears when the final pass succeeded normally.
- [ ] Revert and the affordance are covered by unit tests and stay privacy-safe (no transcript content beyond the existing note).
- [ ] `./script/build_and_run.sh --test` and `--verify` pass.
