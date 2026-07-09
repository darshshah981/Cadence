# Define final-pass lineage contract

Type: grilling
Status: resolved
Claimed by: opencode
Blocked by: 02, 03
Parent: ../map.md

## Question

How should Cadence explain and expose the relationship between live draft text, saved audio, final transcription, retained segments, failures, and retries?

Resolve the product contract for Final Pass as Challenge, Not Replacement. Decide which lineage details are always visible, which appear only on failure or conflict, how much transcript diffing is needed, and what user action is allowed when final output disagrees with the live draft.

## Comments

## Answer

_Adopted as a recommended default; well-grounded in tickets 02, 03, 06._

The Final Pass as Challenge contract, layered on ticket 06's per-recording `state` and unlimited retry:

**Always visible (calm default).** The note shows the final transcript as working text once a final pass completes; a single status row (existing `transcriptStatusMessage` channel) shows transcript state — *live draft / finalizing / final / final pass couldn't improve on the draft*. No lineage chrome when everything succeeded normally.

**Visible only on failure or material change (the "challenge").** Two triggers surface extra affordance:
- *Failure:* final pass empty/errored → state `finalizationFailed`, live draft retained, with reason + "Retry final pass" (ticket 06).
- *Material change:* final output differs meaningfully from the retained live draft → a calm "Final transcript replaced your draft" row with a single expandable "draft said: …" peek (one line, not a diff view).

**Diffing scope.** Lightweight only — a before/after character or segment-count summary plus the one-line draft peek. **Word-level / scrollable diff is out of scope.**

**User actions when final disagrees with draft.** Three, all per-recording:
1. *Accept final* (default — already applied).
2. *Revert to live draft* — restores the retained `.liveDraft` segments for that recording (new; enabled by keeping live-draft segments internally after replacement, keyed by recordingID).
3. *Re-run final pass* — retry from saved audio (ticket 06).

**Retention.** Live-draft segments are retained internally (origin tag + recordingID) after final replacement, enabling revert, until the user accepts or finalizes. Per-recording, consistent with 06.

**Out of scope.** Word-level diffing, automated confidence/quality scoring, side-by-side diff views, and any UI that implies the final pass is unreliable when it succeeded normally.

Touched code (for ticket 13): `MeetingNote` (retain + revert live-draft per recording), `AppModel.runFinalTranscriptionPass` + retry entry point (shared with 06), note-view lineage rows.
