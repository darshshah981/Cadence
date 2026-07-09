# Sequence the seven-feature implementation plan

Type: grilling
Status: resolved
Claimed by: opencode
Blocked by: 05, 06, 07, 09, 10, 11, 12
Parent: ../map.md

## Question

Given the resolved feature contracts and prototypes, what implementation sequence and verification gates should the eventual build plan follow?

Resolve the dependency order, likely milestones, acceptance gates, test strategy, and which features must ship together versus later. This ticket should end the wayfinding map by making the route clear enough for a requirements or implementation-planning skill to take over.

## Comments

## Answer

_Synthesis of the resolved contracts; reliability before intelligence, per ticket 01._

**Implementation sequence and milestones:**

- **M1 — Reliability spine:** [06 capture ledger](06-define-the-capture-ledger-contract.md) + [07 final-pass lineage](07-define-final-pass-lineage-contract.md). **Ship together** — both are the trust core. Gate: durability/recovery tests (`recoverInterruptedFinalizations`, orphan-CAF sweep, retry, lineage revert) pass; `--test`, `--verify`, `--audio-smoke` green.
- **M2 — Surface foundation + operational UX:** [04 surface split](04-decide-menu-bar-main-window-surface-split.md) first (enabler for half the features), then [05 Meeting Runway](05-prototype-meeting-runway-states.md) + [11 Trust surfaces](11-define-inspectable-trust-surfaces.md) **together** (they share surface work). Gate: full-surface audit (menu bar / main / note / settings / onboarding / recovery) is calm and consistent; the four privacy assertions from 11 are code-verified before any trust copy ships.
- **M3 — Activation proof:** [12 Capture Rehearsal](12-prototype-capture-rehearsal.md) (needs 11). Gate: a first-run user can privately prove mic/system capture and see what stayed local.
- **M4 — Post-foundation intelligence:** [08 research](08-research-speaker-attribution-options.md) (ships nothing) → [09 Editable Speaker Ledger](09-define-editable-speaker-ledger-contract.md) and [10 Private AI Notepad](10-define-private-ai-notepad-contract.md), **independent of each other**, after M1 is trustworthy. Gate: speaker edits durable across final-pass replacement; working note is the note view's front door.

**Ship-together rules:** 06+07; 05+11. 09 and 10 may ship independently post-M1. 08 is research only.

**Test strategy:**
- Unit tests use mock `TranscriptionEngine` — **no WhisperKit in unit tests** (repo invariant).
- Durability/recovery is the critical new coverage (today `recoverInterruptedFinalizations` has none): orphan sweep, relink, retry, lineage revert, multi-recording-per-note.
- Capture-touching work also passes `--audio-smoke`; everything passes `--test` / `--verify`.
- Privacy assertions (11's four) verified by code audit before trust copy ships.

**Cross-cutting invariants the build must respect** (from `AGENTS.md`): dictation and meeting pipelines stay separate; raw capture stays durable before lossy processing; `AppModel` stays thin (services do the work); strict privacy boundary (audio/transcript/vocabulary/shortcut/app-names/raw-errors/saved-audio never leave the Mac or reach analytics).

**This ends the wayfinding map.** The destination — a decision-complete product and technical plan — is reached: every feature has a contract, the surface split is fixed, the sequence and gates are set, and the route is clear for a requirements / implementation-planning skill to take over. Open tickets: none. The only deferred item is cross-meeting memory (folded into a future Private AI Notepad extension, per the map).
