# Prototype Meeting Runway states

Type: prototype
Status: resolved
Claimed by: opencode
Blocked by: 01, 04
Parent: ../map.md

## Question

What should the Meeting Runway feel like across real calendar and recording states?

Create a cheap prototype or storyboard for the menu-bar and main-window states covering: no calendar, signed in with no meeting, upcoming meeting, meeting starting soon, permissions blocked, joinable meeting, join-plus-record in progress, active recording, recovery needed, and meeting complete. Link the prototype asset and record which state model should proceed.

## Comments

## Answer

_Adopted as a recommended default per blanket authorization; not individually human-confirmed. Taste-sensitive — flagged for optional spot-check. Text storyboard (planning prototype; the menu bar is the primary Runway surface per ticket 04)._

The Runway is a small finite state over {calendar connection} × {next-meeting proximity} × {readiness} × {capture phase}. **Join + Record is the single primary action**; it is enabled iff joinable × ready × not-already-recording.

| State | Menu bar shows | Action |
|---|---|---|
| Not signed in (no calendar) | "Connect Google Calendar to see your next meeting." | Connect |
| Signed in, no upcoming meeting | "No upcoming meetings." (calm) | — |
| Upcoming (later) | Next meeting title + time (low prominence) | Open note |
| Starting soon (<window) | Elevates: title, time, joinable badge | Join + Record appears |
| Permissions blocked | "Not ready — missing [Mic/Screen Recording]" + remediation | Join + Record disabled |
| Joinable meeting (has meeting URL) | Join link prominent, source selector | Join + Record enabled |
| Join + Record starting | "Starting…" transient | — |
| Active recording | Recording indicator + timer | Stop |
| Recovery needed | (per ticket 06 — **not** in menu bar v1; inline on note + main-window recovery section) | — |
| Meeting complete | Brief "Capture complete — open note", then settles to next | Open note |

State model to proceed: the cockpit computes (connection, proximity, readiness, capture-phase) and renders one row; transitions are driven by calendar polling, the proximity window, `PermissionsSnapshot`, and the capture phase. Recovery stays off the menu bar in v1 (consistent with 04/06).

Out of scope v1: recurring capture rules, post-meeting automation, multi-meeting prioritization beyond "next."
