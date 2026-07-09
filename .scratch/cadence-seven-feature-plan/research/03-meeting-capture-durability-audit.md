# Meeting Capture Durability Audit (ticket 03)

Research asset for [Audit current meeting capture durability](../issues/03-audit-current-meeting-capture-durability.md). Code-grounded; all claims cite file:line. Domain terms follow [CONTEXT.md](../../../CONTEXT.md).

## Scope read

- `Cadence/Models/MeetingModels.swift` — `MeetingNote`, `TranscriptSegment`, origins, `replaceLiveDraftSegments`
- `Cadence/Services/MeetingStore.swift` — note persistence, migration, quarantine
- `Cadence/Services/MeetingAudioStore.swift` — CAF write path, `MeetingAudioRecorder`
- `Cadence/Services/MeetingRollingTranscriptionService.swift` — live-draft windows, finalizer timeout
- `Cadence/Services/MeetingFinalTranscriptionService.swift` — final pass from saved audio
- `Cadence/App/AppModel.swift` — capture lifecycle, recovery, persistence calls
- `CadenceTests/CadenceTests.swift` — existing coverage
- `docs/audit-2026-07.md` — prior "Crash Recovery Is Partial" finding

## Data lifetimes (what is durable, and when)

| Artifact | Write trigger | Durability during active capture | Reference |
|---|---|---|---|
| Note JSON (`<noteID>.json`) | capture start (`createMeetingNote`), then every state/segment/recording change | Exists from first frame; rewritten on every change | `AppModel.swift:1822`, `MeetingStore.swift:90-96` |
| Audio CAF (`<noteID>-<recordingID>.caf`) | opened for writing **before** capture starts; each chunk written immediately | **Per-chunk durable** — every frame flushed to disk as it arrives | `MeetingAudioStore.swift:106`, `:109-134` |
| Live-draft transcript segments | every rolling window (~30s default) emits a segment | **Per-window durable** — each appended segment re-saves the note atomically | `AppModel.swift:1794-1823`, `MeetingRollingTranscriptionService.swift:170-215` |
| Recording metadata (`MeetingAudioRecordingMetadata`) | produced by `recorder.finish()`, appended to note | **NOT durable until stop** — note↔CAF link written only after recording ends | `AppModel.swift:1054`, `:1066`, `:1568-1582` |
| Final transcript segments | final pass replaces live-draft segments for the recording | Durable after final pass completes | `AppModel.swift:1584-1624`, `MeetingModels.swift:296-308` |

Writes are atomic (`Data.write(..., options: [.atomic])`, `MeetingStore.swift:95`), so a mid-write crash cannot corrupt an existing note file.

## Capture lifecycle trace

1. **Start** (`startMeetingCaptureForSelectedMeeting`, `AppModel.swift:931`): creates a blank note if none selected, generates a `recordingID`, opens the CAF via `makeRecorder` (`:957-968`), sets transcript state `.liveDraft`. The recorder's CAF file exists on disk from this moment.
2. **Capture** (`makeMeetingCaptureChunkHandler`, `AppModel.swift:1626`): each chunk fans out to (a) progress metering, (b) `recorder.append` → writes CAF, (c) `service.append` → rolling transcription → emitted segments persisted as `.liveDraft` with this `recordingID`.
3. **Stop** (`stopMeetingCapture`, `AppModel.swift:1034`): stops capture services with timeout, calls `recorder.finish()` → produces metadata, **appends metadata to the note** (`appendMeetingAudioRecording`, `:1066`), then finalizes the rolling tail and runs the final pass.
4. **Final pass** (`runFinalTranscriptionPass`, `AppModel.swift:1584`): re-transcribes the saved CAF (`MeetingFinalTranscriptionService.transcribe` reads the file, `:23-26`), throws `noTranscript` on empty output (`:1593-1595`), and on success calls `replaceLiveDraftSegments` scoped to the recording (`MeetingModels.swift:296-308`).
5. **Relaunch** (`recoverInterruptedFinalizations`, `AppModel.swift:2101-2118`, invoked at `:201`): scans loaded notes; any in `.liveDraft`/`.finalizing` become recoverable **only if** `effectiveAudioRecordings` is non-empty (→ `.finalizationFailed`, "Retry from saved audio"); otherwise reset to `.empty`/`.liveDraft`.

## What is guaranteed vs. not

**Guaranteed today:**
- Saved audio is durable before any lossy processing — the CAF is written per-chunk during recording.
- Live-draft transcript survives a crash — segments are persisted per window.
- Final pass never silently overwrites: empty output is failure, so live draft is retained; replacement is scoped to one `recordingID`.
- Corrupt note JSON is quarantined without dropping readable notes; legacy schemas migrate on load (`MeetingStore.swift:130-152`, `:199`).
- A crash **during finalization** (after stop) is recoverable: recording metadata is already on the note, so relaunch marks it retryable from saved audio.

**NOT guaranteed (the gap):**
- A **force-quit during active recording** leaves an orphaned CAF (and a live-draft note with partial transcript) but **no recording metadata on the note**. `recoverInterruptedFinalizations` cannot relink it because it scans notes, not the audio directory. The meeting looks like a transcript-only live draft; the real audio is stranded on disk, undiscoverable.
- The final-pass **retry** is set up by recovery (the `.finalizationFailed` + "Retry from saved audio" message) but I found no dedicated `retryFinalTranscription` entry point in `AppModel` — whether a UI affordance re-runs the final pass from saved audio is unconfirmed and belongs to ticket 07.
- **Multi-recording-per-session is only partial.** A combined source (`microphoneAndSystemAudio`) mixes both streams into one CAF under one `recordingID` (one shared recorder/handler, `AppModel.swift:957-989`). So "one or more recordings per session" (the CONTEXT.md decision) is true for pause/resume (a second start appends a second recording) but **not** for splitting sources into separate recordings.

## Failure modes

- **FM1 — force-quit mid-recording:** orphaned CAF + partial live draft, audio undiscoverable. (The headline gap; corroborates `docs/audit-2026-07.md`.)
- **FM2 — crash during finalization:** recoverable; audio safe; relaunch marks retryable.
- **FM3 — empty final output:** `noTranscript` → `.finalizationFailed`; live draft retained. ✓
- **FM4 — rolling finalization timeout:** `.timedOut` → service reset, problem segment appended (`AppModel.swift:1727-1738`). Distinct from the final pass.
- **FM5 — corrupt note JSON:** quarantined; readable notes preserved. ✓
- **FM6 — legacy schema:** migrated to current `schemaVersion` on load. ✓
- **FM7 — disk write failure mid-capture:** `recorder.append` throws → note set `.finalizationFailed` (`AppModel.swift:1686-1693`); CAF may be partial; behaves like FM1 for discoverability.
- **FM8 — combined source:** produces one mixed recording, not separate per-source recordings (diverges from the domain model).

## Existing tests (`CadenceTests/CadenceTests.swift`)

- `meetingStoreSavesLoadsUpdatesAndDeletesNotes`, `meetingStorePersistsCalendarEventAndTranscriptSourceMetadata` — round-trip persistence incl. recording/origin metadata.
- `meetingStoreMigratesLegacyNotesToCurrentSchemaVersion` — schema migration.
- `meetingStoreQuarantinesUnreadableFilesWithoutDroppingReadableNotes` — quarantine.
- `meetingNoteReplacesOnlyMatchingLiveDraftSegmentsWithFinalTranscript` — the core replacement invariant.
- `finalTranscriptionServiceReplaysSavedRecordingAsSingleFinalSegment` — final pass replays CAF.
- Rolling-transcription suite: bounded segments, short/quiet flush, long-chunk bounding, multi-window streaming, concurrent-append serialization, empty-window recovery, finish timeout.

## Missing tests (durability)

- No test for `recoverInterruptedFinalizations` itself — the recovery function has zero direct coverage.
- No test that audio is recoverable **before** `finish()` (crash-during-recording recovery).
- No test for orphaned-CAF discoverability/relinking (FM1/FM7).
- No test for the final-pass **retry** path from saved audio after `.finalizationFailed`.
- No multi-recording-per-session test (resume → two recordings on one note).
- No atomic-write / partial-write behavior test (mitigated by `.atomic`, but unverified).

## Smallest seams a crash-first ledger could use

Using CONTEXT.md terms (capture session = root; ledger = the session's persisted on-disk state; recording = audio artifact child of session):

1. **Persist recording metadata at recorder creation, not at finish.** Write a record linking `noteID ↔ recordingID ↔ CAF path ↔ source ↔ state=.recording` when `makeRecorder` runs, update it on `finish`. Smallest change; makes the CAF discoverable from the first frame. (This is the R4 fix flagged in `docs/audit-2026-07.md`.)
2. **Introduce a capture-session ledger record** distinct from the note — a small durable record (session/recording → note, source, state, startedAt) written at capture start and updated on each state transition. Relaunch recovery scans these, not just notes. This is where "session as root, ledger as persisted state" lands concretely.
3. **Add an audio-directory sweep on relaunch** — scan `MeetingAudio/` for CAFs referenced by no note and offer relink/recover. Covers FM1/FM7 where a ledger record was never written.
4. **Expose final-pass retry as an idempotent operation** — `MeetingFinalTranscriptionService.transcribe(recording:)` already re-reads the CAF; reuse it as the recovery/retry primitive and wire a UI affordance (ticket 07).
5. **Confirm live-draft per-window persistence is intentional and tested** — it already happens (`AppModel.swift:1822`); add a test so the durability property is locked in, not accidental.

## Net read

Cadence's capture is **more durable than the "crash-first" framing implies**: audio and live-draft transcript are already crash-safe during recording. The real, narrow gap is **discoverability** — the note↔recording link is written only at stop, so a mid-recording crash strands otherwise-safe audio. The crash-first ledger work is therefore primarily about persisting that link from the first frame (seams 1–3), plus locking in retry (seam 4). This sharpens ticket 06 (capture ledger contract): it is a discoverability/metadata contract, not a "make audio durable" project.
