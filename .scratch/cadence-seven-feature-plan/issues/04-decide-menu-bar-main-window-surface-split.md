# Decide the menu bar and main-window surface split

Type: grilling
Status: resolved
Claimed by: opencode
Blocked by:
Parent: ../map.md

## Question

Which parts of the seven-feature experience belong in the menu bar, the main window Home tab, the note view, settings, and first-run/onboarding?

Resolve the surface boundary before prototyping Meeting Runway, Trust You Can Inspect, and Capture Rehearsal. The answer should account for active recording state, next-meeting readiness, recovery alerts, transcript/final-pass state, permissions, and privacy explanations without turning the menu bar into the full app.

## Comments

## Answer

_Adopted as a recommended default per blanket authorization; not individually human-confirmed. This is a taste-sensitive UX call — flagged for optional spot-check._

The split, by surface (existing windows per `AGENTS.md`: `MainWindowView` owned by `MainWindowController`, `MenuContentView` popover, `MeetingNotesWindow`, `SettingsView`, `HUDView`, `PermissionGuideWindow`):

- **Menu bar popover — "right now."** Glanceable, action-oriented, never the full app. Holds: next-meeting readiness (Meeting Runway), one-action start/stop capture + join-link, active-recording indicator, and a single route to the main window. No transcript editing, no settings detail, no full note view.
- **Main window Home — "manage and review."** The workspace: meeting list, capture controls, recording state, and the recovery queue section (per ticket 06). The primary surface for managing meetings.
- **Note view — "read and edit."** The per-meeting artifact: working note → summary → action items → transcript (collapsible) → final-pass lineage (ticket 07) → speaker editing (ticket 09).
- **Settings — "configure and verify."** Hotkeys, model, capture source, analytics opt-in, appearance — plus the **trust center**: storage locations, analytics exclusions, permissions status + re-grant, data-boundary detail. Deep trust/privacy explanation lives here, not in the menu bar (ticket 11).
- **First-run / onboarding — "prove it privately."** Minimal permissions (Mic + Accessibility + Input Monitoring; Screen Recording contextual) then Capture Rehearsal (ticket 12), progressive.

State placement:
- **Active recording** → menu-bar indicator + main-window state; not a separate window.
- **Next-meeting readiness** → menu bar (Runway) + main window.
- **Recovery alerts** → inline on notes + main-window recovery section in v1 (per ticket 06, which deferred a global menu-bar recovery badge).
- **Transcript / final-pass state** → note view only.
- **Permissions / privacy explanations** → onboarding (minimal) + settings (deep).

Governing principle: menu bar answers "what's happening right now and can I act?"; main window answers "what do I manage/review?"; note view answers "what did this meeting say?"; settings answers "how is this configured and can I trust it?". The menu bar must not become the full app.
