---
title: Adaptive Scribe U13–U14 release candidate gates
type: feat
date: 2026-07-12
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
origin: docs/plans remaining units from Adaptive Scribe U1–U14 spine after U12 commit 2864e50
---

# Adaptive Scribe U13–U14 release candidate gates

## Goal Capsule

- **Objective:** Close the remaining Adaptive Scribe spine after U12: bind packaging and evidence to one signed Release candidate (U13), and provide the admission tooling and documentation path for live gates (U14) without claiming live PASS in CI.
- **Authority:** Parent Adaptive Scribe plan units U13–U14; `docs/adaptive-scribe-release-evidence.md`; `docs/release-checklist.md`; existing `scripts/package_release.sh` and `scripts/collect_adaptive_scribe_evidence.sh`.
- **Stop conditions:** Deterministic U13 contract tests green; collector `--check` green; live verifiers exist and fail closed without credentials; Release packaging embeds source commit; U14 live gates remain explicitly `NOT_RUN` until a release owner runs them.

## Product Contract

### Summary

U12 proved deterministic integration and privacy. Release still needs tamper-evident candidate identity (commit, DMG hash, bundle identity) and live-gate tooling that cannot silently green without real evidence.

### Requirements

- **R1.** Packaging injects the full clean source commit into the Release app before signing.
- **R2.** Collector mounts the Release DMG and derives commit (when present), bundle identity, DMG SHA-256; rejects Debug identity and dirty trees.
- **R3.** Evidence schema is frozen and tested; manifests are immutable once PASS/FAIL is written.
- **R4.** Live provider and real-app verifiers are real deliverables that embed gate/schema/corpus/policy revision fields and refuse to emit PASS without required credentials/environment.
- **R5.** Dogfood input accepts only aggregate counters and closed incident codes.
- **R6.** U14 live OpenAI/OpenRouter, real-app, a11y, privacy, and dogfood remain release-owner gates; CI never claims them green.
- **R7.** Feature/readers-off and legacy retention stay deterministic (U3/U12); not a second live matrix.

### Scope boundaries

**In scope:** scripts, contract tests, packaging Info.plist injection, evidence docs, catalog review dates placeholders.  
**Out of scope:** Actually running notarized live dogfood in this PR; shipping credentials; merging to main; HUD-only work.

## Planning Contract

### Key technical decisions

1. **Embed commit via build setting** written into Info.plist as `CadenceSourceCommit` during Release archive (package_release exports `CADENCE_SOURCE_COMMIT=$(git rev-parse HEAD)` and the project Info.plist key, or a generated Info.plist snippet). Prefer a single Info.plist key over custom binaries.
2. **Live verifiers are shell scripts** that write credential-free JSON envelopes under `Build/AdaptiveScribeEvidence/` with schema fields; without env vars they exit non-zero or write `NOT_RUN`/`BLOCKED` and never `PASS`.
3. **Contract tests** use temporary directories and synthetic manifests — no real DMG required for unit tests; collector `--check` remains the smoke path.
4. **U14 in this PR** = tooling + docs alignment + model catalog review date fields; not five-day dogfood execution.

### Assumptions

- Developer ID cert may be missing on CI; packaging tests assert script contracts, not a successful notarized DMG.
- OpenAI/OpenRouter live keys are never placed in repo or CI secrets for this unit.

## Implementation Units

### U1. Embed source commit into Release packaging

**Goal:** Release app Info.plist carries the exact full git commit of the clean packaging tree.  
**Requirements:** R1.  
**Dependencies:** none.  
**Files:** `scripts/package_release.sh`; `Cadence/Supporting/Info.plist` or build settings via `project.yml`; `CadenceTests/ReleaseEvidenceContractTests.swift`.  
**Approach:** Refuse dirty tree in packaging (or warn + refuse when not `--allow-dirty` — prefer refuse for evidence). Export `CADENCE_SOURCE_COMMIT` into xcodebuild. Add Info.plist key `CadenceSourceCommit` with `$(CADENCE_SOURCE_COMMIT)` or write after export. Tests assert package script contains commit injection and dirty-tree refusal.  
**Test scenarios:**  
1. package_release.sh documents/enforces clean tree and sets CADENCE_SOURCE_COMMIT.  
2. Info.plist or project.yml declares CadenceSourceCommit.  
**Verification:** Script grep tests pass; xcodegen still generates cleanly.

### U2. Freeze evidence schema and harden collector

**Goal:** Candidate descriptor schema is versioned; collector rejects malformed/mismatched envelopes; atomic manifest finalization for PASS/FAIL.  
**Requirements:** R2, R3, R5.  
**Dependencies:** U1.  
**Files:** `scripts/collect_adaptive_scribe_evidence.sh`; `CadenceTests/ReleaseEvidenceContractTests.swift`; `docs/adaptive-scribe-release-evidence.md`.  
**Approach:** Expand manifest schemaVersion to 2 with explicit gate map, required revisions (`gateRevision`, `schemaRevision`, `corpusRevision`, `policyRevision`), `signedCodeIdentity` optional, `embeddedSourceCommit` when read from mounted app. Reject overwriting an existing PASS/FAIL manifest. Accept dogfood aggregates only via allowlisted keys.  
**Test scenarios:**  
1. Manifest schema fields present in collector output template.  
2. Collector refuses dirty tree and commit mismatch (script contract tests).  
3. Overwrite of finalized PASS/FAIL is rejected.  
4. Dogfood allowlist documented and enforced when dogfood artifact present.  
**Verification:** `scripts/collect_adaptive_scribe_evidence.sh --check` passes; contract tests green.

### U3. Live provider and real-app verifier scripts

**Goal:** Deliver `verify_live_scribe_providers.sh` and `verify_scribe_real_apps.sh` that produce credential-free result envelopes bound to candidate descriptor fields.  
**Requirements:** R4, R6.  
**Dependencies:** U2.  
**Files:** `scripts/verify_live_scribe_providers.sh`; `scripts/verify_scribe_real_apps.sh`; `CadenceTests/ReleaseEvidenceContractTests.swift`; `scripts/test_adaptive_scribe_contracts.sh`.  
**Approach:** Without `CADENCE_LIVE_OPENAI_KEY` / `CADENCE_LIVE_OPENROUTER_KEY` (or equivalent), scripts write `status: NOT_RUN` and exit 0 for dry-check mode (`--check`) or exit 2 for execute mode. With keys (local only), they may call synthetic validation against production adapters — optional; minimum is envelope structure + fail-closed. Real-app script similarly requires `CADENCE_REAL_APP_PROOF=1` and records only closed outcomes.  
**Test scenarios:**  
1. `--check` validates script syntax and envelope schema without network.  
2. Execute without credentials does not write PASS.  
3. Envelope includes commit, schemaRevision, corpusRevision, gate id.  
**Verification:** bash -n + contract tests; no network in unit tests.

### U4. U14 admission documentation and catalog review hooks

**Goal:** Align release checklist and evidence runbook with OpenAI Direct / OpenRouter / Cursor·Slack·Codex gates; ensure model catalog review dates are explicit fields.  
**Requirements:** R6, R7.  
**Dependencies:** U2, U3.  
**Files:** `docs/adaptive-scribe-release-evidence.md`; `docs/release-checklist.md`; `Cadence/Resources/` or model catalog if present; `CadenceTests/ReleaseEvidenceContractTests.swift`.  
**Approach:** Document admission sequence: deterministic green → package → collect → live providers → real apps → a11y → dogfood → immutable PASS. Refresh policy-review date placeholders to 2026-07-12. Do not mark any live gate PASS.  
**Test scenarios:**  
1. Evidence doc lists OpenAI Direct, OpenRouter, Cursor, Slack, Codex.  
2. Collector and checklist still say green PR ≠ release.  
**Verification:** Contract tests on documentation presence; no live execution required.

## Verification Contract

- `xcodegen generate` succeeds on the adaptive worktree.
- `CadenceTests/ReleaseEvidenceContractTests` pass.
- `scripts/collect_adaptive_scribe_evidence.sh --check` passes.
- `scripts/verify_live_scribe_providers.sh --check` and `scripts/verify_scribe_real_apps.sh --check` pass.
- `scripts/test_adaptive_scribe_contracts.sh` includes the new tests (or focused xcodebuild).
- Privacy canary scan still green over test logs when run.

## Definition of Done

- U1–U4 complete on `codex/adaptive-scribe-writing-environments`.
- No live gate claimed PASS in CI or default script output.
- Branch pushed; PR opened when shipping tail runs.
- Live dogfood / notarization remain human release-owner steps documented as NOT_RUN.

## Residual / deferred (U14 human gates)

- Signed notarized DMG on release machine.
- Live OpenAI/OpenRouter synthetic matrix (72 drafts / latency) when keys available.
- Real Cursor/Slack/Codex interactive proof.
- Five-workday dogfood ≥40 actions.
- Accessibility human review.
