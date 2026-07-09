# Audit current meeting capture durability

Type: research
Status: resolved
Claimed by: opencode
Blocked by:
Parent: ../map.md

## Question

What exactly does the current code guarantee, fail to guarantee, and persist during active meeting capture, stop, finalization, retry, and relaunch?

Read the meeting capture services, stores, transcript state model, recovery code, tests, and docs. Produce a linked markdown research asset that identifies current data lifetimes, failure modes, existing tests, missing tests, and the smallest seams a crash-first ledger could use.

## Comments

## Answer

Research asset: [research/03-meeting-capture-durability-audit.md](../research/03-meeting-capture-durability-audit.md).

Headline finding: **capture is more durable than the "crash-first" framing implies.** Audio (CAF) is written per-chunk during recording and live-draft transcript is persisted per window — both are already crash-safe. Writes are atomic, corrupt notes are quarantined, legacy schemas migrate, and a crash *during finalization* (after stop) is already recoverable.

The single real gap is **discoverability**: the note↔recording link (`MeetingAudioRecordingMetadata`) is appended only at `stopMeetingCapture`, so a **force-quit during active recording strands otherwise-safe audio** — an orphaned CAF that `recoverInterruptedFinalizations` (which scans notes, not the audio directory) cannot relink.

Other findings fed downstream:
- `recoverInterruptedFinalizations` has **no direct test**.
- The final-pass **retry** path is signposted (`.finalizationFailed` + "Retry from saved audio") but no `retryFinalTranscription` entry point was found in `AppModel` — wiring it is a question for ticket 07.
- **Combined source mixes into one CAF** under one `recordingID`; "one or more recordings per session" (CONTEXT.md) holds for pause/resume but not for per-source splitting — a divergence for ticket 06.

Implication for ticket 06: the crash-first ledger is a **discoverability/metadata contract** (persist the recording link from the first frame; add an audio-directory sweep on relaunch), not a "make audio durable" project. The smallest seams are inventoried in the asset.

