# Define the capture ledger contract

Type: grilling
Status: resolved
Claimed by: opencode
Blocked by: 02, 03
Parent: ../map.md

## Question

What user-visible and data-level contract should Crash-First Meeting Ledger guarantee?

Decide the promise precisely: when a ledger entry is created, what it must persist, how Cadence discovers interrupted recordings, what recovery UI must say, what can be retried, what failure states are acceptable, and what should remain out of scope for the first implementation.

## Comments

## Answer

The capture-ledger contract (architectural decision recorded in [ADR 0001](../../../docs/adr/0001-capture-ledger-persistence.md); terms in [CONTEXT.md](../../../CONTEXT.md); durability basis in [ticket 03's audit](03-audit-current-meeting-capture-durability.md)):

**1. Ledger entry — what / when / where.** The recording-ledger entry is `MeetingAudioRecordingMetadata` plus a new explicit per-recording `state`, persisted onto the **meeting note** at **capture start** (not at stop). At creation it persists the durable facts only — recordingID, source, startedAt, CAF fileName, `state = recording`; metrics (duration, frameCount, …) are enriched at stop. A **relaunch audio-directory sweep** is the backstop: CAF filenames encode `<noteID>-<recordingID>`, so any CAF referenced by no note is found and relinked. No separate ledger store for v1.

**2. State model.** Each recording carries its own `state`: `recording → recorded → finalizing → final / finalizationFailed`. The note's existing `transcriptState` becomes a derived UI rollup of recording states. This scales to multi-recording sessions without a later reshape.

**3. Discovery.** Runs **at launch, before notes are presented**. Cross-reference recordingIDs referenced by notes against CAFs on disk; recordings in `recording`/`recorded`/`finalizing` are the interrupted ones. Orphaned CAFs whose `noteID` matches an existing note are **auto-relinked** (deterministic from the filename); an orphan whose note is absent is held in a surfaced recovery queue. **Cadence never auto-deletes audio.** The recovery *action* is always user-triggered.

**4. Recovery UI contract.** Calm, **non-modal**: a status row on the affected note via the existing `transcriptStatusMessage` channel, plus a recovery section for orphaned-no-note cases. Copy must (a) name what happened calmly ("interrupted," never "crashed/failed/lost"), (b) name what survived ("your audio and draft transcript are saved"), (c) name the available action, (d) stay privacy-safe (no audio/transcript content). **Default: no auto-action** — live draft retained, final pass is the user's explicit choice. Final strings graduate to ticket 11.

**5. Retry contract.** The final pass is **idempotent and retryable without limit** for any recording with saved audio — including recordings interrupted mid-capture, whose CAF is finalizable as-is (per-chunk writes yield a valid file). Success → `.final`; failure → `.finalizationFailed`. Capture itself is **not resumable** — "resume" starts a new recording. The rolling live-draft tail is in-memory and gone, but superseded by the full-audio final pass.

**6. Acceptable failure states.** Empty final transcript (`noTranscript`) and model/transcription errors → `.finalizationFailed`, live draft retained, retryable. Unreadable/corrupt CAF → surfaced, not auto-retriable, audio preserved, user may discard. Near-zero-duration recording → yields empty → treated as `noTranscript`.

**7. Out of scope for v1.** Separate ledger store; global "N recordings need attention" menu-bar indicator; per-source recording splitting (combined source still mixes into one CAF — the *model* accommodates multi-recording, delivering it does not); auto-running the final pass; audio retention / auto-deletion policy (only rule is "never auto-delete"); cross-meeting speaker identity (ticket 09).

**Migration.** Existing recordings (no `state` field) are treated as `.final` on load.

**Touched code (for the implementation sequence, ticket 13).** `MeetingAudioStore` (write recording-ledger entry at `makeRecorder`), `MeetingModels` (per-recording `state` + derived `transcriptState` rollup), `AppModel.recoverInterruptedFinalizations` (becomes discovery + sweep + relink; gains direct tests), a new retry entry point (reuses `MeetingFinalTranscriptionService.transcribe`).

