# Define the editable speaker ledger contract

Type: grilling
Status: resolved
Claimed by: opencode
Blocked by: 02, 08
Parent: ../map.md

## Question

What should Editable Speaker Ledger promise before Cadence attempts true diarization?

Decide whether the first version is manual/editable turns, source-aware labels, inferred turns, local diarization, or a staged combination. The answer should define speaker identity persistence, merge/split behavior, how summaries and exports consume speaker labels, and how Cadence avoids overclaiming identity certainty.

## Comments

## Answer

_Adopted as a recommended default; well-grounded in tickets 02 and 08._

v1 is **manual/editable turns over capture-source proxies — no diarization** (per 08). The honest, zero-packaging-risk foundation.

- **Identity persistence:** per-meeting speaker ledger (per 02). A Speaker = `{ id, displayName (editable) }`; speaker turns reference a Speaker id. The capture-source proxy (today's `TranscriptSpeaker`) seeds the initial assignment; the user promotes a proxy-group into a named Speaker.
- **Merge/split:** merge two Speakers (all turns re-pointed to one; the other removed); split (select contiguous turns → assign to a new or existing Speaker). Edits are durable on the note. Speaker is per-segment, so it survives final-pass replacement where the turn maps.
- **How summaries/exports consume labels:** `MeetingSummaryService` and `MeetingMarkdownFormatter` resolve the Speaker `displayName` (not the raw proxy). Action-item owner extraction is unchanged.
- **Avoiding overclaiming identity:** the UI presents speaker labels as *user-assigned*; capture-source proxies render as inferred ("You" / "System Audio") with no certainty claim. **No confidence score in v1** — it would be misleading without diarization.
- **Scope:** per-meeting only (per 02); cross-meeting identity graduates later.

Out of scope v1: automatic diarization, cross-meeting identity, confidence scores, voice fingerprinting.

Touched code (for ticket 13): `MeetingModels` (Speaker model + turn reference), speaker-edit UI in the note view, label resolution in `MeetingSummaryService` / `MeetingMarkdownFormatter`.
