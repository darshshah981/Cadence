# Prototype Capture Rehearsal

Type: prototype
Status: resolved
Claimed by: opencode
Blocked by: 04, 11
Parent: ../map.md

## Question

What should a first-run private capture rehearsal prove to the user before their first real meeting?

Prototype the smallest rehearsal flow that tests microphone capture, system-audio readiness when relevant, local transcription proof, missing-permission explanations, and privacy reassurance. Decide what success and failure look like and what not to include.

## Comments

## Answer

_Adopted as a recommended default per blanket authorization; not individually human-confirmed. Taste-sensitive — flagged for optional spot-check. Smallest-flow contract (planning prototype)._

The rehearsal is a private, user-run pre-flight that proves the capture path before a real call — a user-facing version of the app's own `--audio-smoke` test. Triggered from onboarding or Settings.

**Flow (5 steps):**
1. **Pick source** — mic / system / both (mirrors meeting capture sources).
2. **Capture ~5–10 seconds privately** — reuses existing capture machinery.
3. **Show what was heard** — live transcript proof + an audio-level meter (so silence vs. speech is visible).
4. **Show what stayed local** — "processed on your Mac" reassurance (the data-boundary claim, per ticket 11).
5. **If a permission is missing, name exactly which** and how to grant it (Mic / Accessibility / Input Monitoring required; Screen Recording when system audio is chosen).

**Success:** captured frames above a level threshold + a transcript returned + "stayed local" confirmation.

**Failure states (each named, with remediation):**
- Missing permission → named, with the grant path.
- No audio detected (level ~0) → mic/source/hardware problem.
- Transcription returned empty → model problem (point to model download / quality mode).

**Not included:** real diarization, full-meeting simulation, network tests, long recordings, or anything that sends data off the Mac.

Touched code (for ticket 13): a lightweight rehearsal mode reusing `AudioCaptureService` / `SystemAudioCaptureService` + `MeetingRollingTranscriptionService`-style transcription proof, plus permission checks.
