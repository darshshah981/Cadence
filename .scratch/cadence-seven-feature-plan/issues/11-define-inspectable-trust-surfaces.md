# Define inspectable trust surfaces

Type: grilling
Status: resolved
Claimed by: opencode
Blocked by: 01, 04
Parent: ../map.md

## Question

Where should Cadence make local-first privacy, permissions, analytics exclusions, storage, export boundaries, and recording state inspectable?

Resolve Trust You Can Inspect without creating a noisy settings maze. The answer should decide what appears in onboarding, menu bar, active recording, note export/copy, settings, and recovery states; it should also identify exact privacy assertions that require code or docs verification.

## Comments

## Answer

_Adopted as a recommended default per blanket authorization; not individually human-confirmed. Taste-sensitive — flagged for optional spot-check. Grounded in ticket 02 (trust surface / readiness / data boundary / recovery) and `docs/privacy.md`._

Per-surface placement — calm and situational; deep detail only when asked; no settings maze:

- **Onboarding:** minimal required permissions + one-line local-first reassurance + Capture Rehearsal (ticket 12).
- **Menu bar:** active-recording indicator + next-meeting readiness only. No detailed privacy.
- **Active recording:** persistent, calm recording indicator; "stays on your Mac" microcopy on hover, not always visible.
- **Note export/copy:** one-line data-boundary reminder **at the moment of export** ("this leaves your Mac") — the boundary moment.
- **Settings (trust center):** local storage locations, analytics exclusions (the `privacy.md` list), analytics opt-in, permissions status + re-grant, data-boundary explanation.
- **Recovery states:** inline on notes (per 06), calm.

**Privacy assertions requiring code/docs verification before any UI claims them** (from `privacy.md` + audit-2026-07):
1. Audio / transcript text / vocabulary / shortcut keys / dictated app names / raw errors / saved audio are never sent to analytics — verify every `AnalyticsService` call site.
2. System-audio capture excludes Cadence's own process audio — verify in `SystemAudioCaptureService`.
3. The only data egress is explicit export/copy + opt-in analytics — verify no other network calls.
4. Analytics carry only coarse duration/character buckets — verify.

These four are the verification gate before trust copy ships.
