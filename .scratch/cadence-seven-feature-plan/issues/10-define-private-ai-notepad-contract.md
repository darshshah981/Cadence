# Define the Private AI Notepad contract

Type: prototype
Status: resolved
Claimed by: opencode
Blocked by: 01, 02, 04
Parent: ../map.md

## Question

What is the primary meeting-note artifact Cadence should optimize for after capture?

Prototype or outline the note-first workflow: rough notes during the meeting, transcript as source material, final-pass transcript arrival, summaries, Ask, reports, action items, and export. Decide whether rough notes can steer summaries/reports, what the note view prioritizes, and how to avoid making the transcript the front door.

## Comments

## Answer

_Adopted as a recommended default per blanket authorization; not individually human-confirmed. Taste-sensitive — flagged for optional spot-check. Outline contract (planning prototype)._

The primary artifact is the **meeting note, with the working note as the editable front door** — not the transcript (terms per 02).

- **Note view priority:** working note (editable) → summary → action items → transcript (collapsible, below the fold). Transcript is source material, not the front door.
- **Rough notes steer summaries/reports: yes.** Formalize that the working note is the primary input to `MeetingSummaryService` (it already consumes `userNotes`); transcript is secondary evidence. Action items and reports draw on both.
- **Final-pass arrival:** integrates into the note by replacing the live draft (per 07); it does not disrupt the working note.
- **Ask / reports:** operate over working note + transcript + summary together (existing primitives).
- **Export (Markdown):** working note + summary + transcript, working note leading.

Out of scope v1: freeform AI generation beyond existing summary/Ask, cross-note memory (deferred per map), real-time AI assist during the meeting.

Touched code (for ticket 13): note-view layout reorder, summary-service primacy of the working note.
