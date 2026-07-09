# Cadence Seven-Feature Product Plan

Label: wayfinder:map

## Destination

Produce a decision-complete product and technical planning map for the seven ranked Cadence feature directions from `docs/ideation/2026-07-07-cadence-next-product-ideation.html`, so a later `ce-brainstorm` / implementation-planning pass can turn the chosen scope into buildable requirements without reopening basic product, domain, UX, privacy, or sequencing questions.

## Notes

- Domain: native macOS SwiftUI/AppKit local dictation and meeting-capture app.
- Planning only: tickets resolve decisions, research, or prototypes; they do not implement the seven features.
- Consult `AGENTS.md`, `docs/codebase-guide.md`, `docs/audit-2026-07.md`, `docs/privacy.md`, and the ideation artifact before resolving tickets.
- Follow the repo invariant: keep dictation and meeting pipelines separate; keep raw meeting capture durable before lossy processing; prefer focused services with thin `AppModel` coordination.
- Use domain-modeling discipline for terms such as capture session, meeting recording, ledger, live draft, final pass, working note, speaker ledger, trust surface, and rehearsal.
- Use grilling for product decisions. Ask one decision question at a time; look up repo facts instead of asking the user for facts.
- UI decisions must account for full-surface audit: main window, menu bar, note view, settings, onboarding, scrolled states, recovery states, and repeated components.
- Privacy boundary is strict: do not send audio, transcript text, vocabulary, shortcut values, app names, raw errors, or saved audio to analytics or remote services.

## Decisions so far

_**Map complete (2026-07-09): all 13 tickets resolved; destination reached. The route is clear for an implementation-planning skill to take over. Remaining fog: cross-meeting memory only (deferred, see below). Tickets 04, 05, 10, 11, 12 were resolved as adopted defaults under blanket authorization and are worth a human spot-check before build.__

- [Choose the product thesis and release shape](issues/01-choose-product-thesis-and-release-shape.md) — Cadence's next effort is a reliability-and-trust release: Crash-First Meeting Ledger is the spine, Meeting Runway / Trust / Final Pass / Capture Rehearsal support it, and Private AI Notepad plus Editable Speaker Ledger follow once the capture foundation is solid.
- [Define shared domain language](issues/02-define-shared-domain-language.md) — canonical terms fixed in `CONTEXT.md`: capture session is the root durable identity, ledger is its persisted state, recording is one-or-more audio artifacts, meeting note composes transcript+summary+working note, final pass is the process vs. final transcript the output, speaker ledger is per-meeting, and trust surface splits into readiness / data boundary / recovery.
- [Audit current meeting capture durability](issues/03-audit-current-meeting-capture-durability.md) — capture is already crash-safe for audio (per-chunk CAF) and live-draft transcript (per-window); the only real gap is discoverability — the note↔recording link is written only at stop, so a mid-recording crash strands safe audio. Asset: research/03-meeting-capture-durability-audit.md.
- [Decide the menu bar and main-window surface split](issues/04-decide-menu-bar-main-window-surface-split.md) — menu bar = "right now" (Runway, start/stop, recording indicator, route to main); main window = manage/review (+ recovery section); note view = read/edit; settings = trust center; onboarding = permissions + rehearsal. Menu bar never becomes the full app.
- [Prototype Meeting Runway states](issues/05-prototype-meeting-runway-states.md) — Runway is a finite state over {calendar}×{proximity}×{readiness}×{capture phase}; Join+Record is the single primary action (enabled iff joinable × ready × not recording); recovery stays off the menu bar in v1.
- [Define the capture ledger contract](issues/06-define-the-capture-ledger-contract.md) — recording-ledger entry (metadata + explicit per-recording `state`) persists on the note at capture start, backed by a relaunch audio-dir sweep; calm non-modal recovery UI; unlimited idempotent retry from saved audio; never auto-delete. Architecture in ADR 0001.
- [Define final-pass lineage contract](issues/07-define-final-pass-lineage-contract.md) — calm default shows final text + a state row; a "challenge" affordance (draft peek + revert/retry) appears only on failure or material change; word-level diff out of scope; live-draft segments retained per-recording to enable revert.
- [Research speaker attribution options](issues/08-research-speaker-attribution-options.md) — stage it: editable turns over capture-source proxies first (no model); local diarization deferred pending a packaging/perf spike. All options local-first. Asset: research/08-speaker-attribution-options.md.
- [Define the editable speaker ledger contract](issues/09-define-editable-speaker-ledger-contract.md) — v1 is manual/editable turns, per-meeting; merge/split; summaries/exports resolve Speaker names; no confidence score and no diarization in v1; capture-source proxy clearly not identity.
- [Define the Private AI Notepad contract](issues/10-define-private-ai-notepad-contract.md) — meeting note with the working note as the editable front door; rough notes steer summaries/reports; transcript is collapsible source material below the fold.
- [Define inspectable trust surfaces](issues/11-define-inspectable-trust-surfaces.md) — calm/situational; menu bar minimal, settings = trust center, an export/copy data-boundary reminder; four privacy assertions must be code-verified (analytics call sites, process-audio exclusion, no other egress, coarse buckets) before trust copy ships.
- [Prototype Capture Rehearsal](issues/12-prototype-capture-rehearsal.md) — 5-step private pre-flight (pick source → capture 5–10s → show transcript + level → show "stayed local" → name any missing permission); success and named failure states defined.
- [Sequence the seven-feature implementation plan](issues/13-sequence-seven-feature-implementation-plan.md) — M1 spine (06+07) → M2 surface (04, then 05+11) → M3 rehearsal (12) → M4 intelligence (09, 10); per-milestone gates; mock-engine unit tests; durability/recovery as the critical new coverage; map ends here.

## Not yet specified

- Whether cross-meeting memory returns as a standalone feature later or stays folded into the Private AI Notepad direction; currently deferred because the verifier found existing cross-note Ask/search already covers part of it.

## Out of scope

- Implementing any feature during wayfinding; this map ends when the route to implementation is clear.
- Cloud sharing links, shared team workspaces, SaaS admin controls, CRM integrations, or bot auto-join agents. The current destination keeps Cadence local-first and user-controlled.
- Replacing local-first transcription with a cloud-first model pipeline. Optional future cloud helpers would require a separate trust and privacy map.
- Solving monetization, pricing, public launch copy, or App Store distribution. This map may note packaging and trust requirements, but it does not plan go-to-market.
