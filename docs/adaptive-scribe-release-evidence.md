# Adaptive Scribe Release Evidence

This is the release-owner runbook for Adaptive Scribe. Pull-request CI exercises deterministic, credential-free fixtures. The live, signed, real-app, accessibility, and dogfood rows below remain **NOT RUN** until one release owner runs them on the same candidate DMG.

## Candidate Identity

Record:

- Git commit SHA.
- `Build/Release/Cadence.dmg` SHA-256.
- Cadence version/build.
- packaged architectures.
- signing identity, notarization submission, staple validation, and Gatekeeper result.
- minimum macOS 14 build and current stable macOS build.
- DeepSeek, Slack, and Claude Desktop versions plus source-review dates.

Run `scripts/collect_adaptive_scribe_evidence.sh` only from the clean candidate commit. The collector refuses a dirty tree, a SHA mismatch, a missing Release DMG, or a mounted app whose display name, bundle ID, or executable is not the canonical Release identity. Attach each credential-free result with repeatable `--artifact label=path` arguments; the manifest hashes files or directory trees without copying their content.

## Deterministic Pull-Request Evidence

- [ ] `xcodegen generate` is idempotent.
- [ ] `scripts/test_adaptive_scribe_contracts.sh` passes the focused Adaptive Scribe contract wrapper (provider, migration, app, identity, guidance, lifecycle, control, diagnostic, privacy, domain isolation, release-fixture isolation) without credentials or live network.
- [ ] Full `xcodebuild test` passes with signing disabled.
- [ ] Ad-hoc-signed `CadenceUITests` passes against synthetic DEBUG launch fixtures and attaches privacy-safe screenshots.
- [ ] `./script/build_and_run.sh --verify` proves the installed Debug app launches and shows its main window.
- [ ] `./script/build_and_run.sh --audio-smoke` preserves meeting system-audio frames.
- [ ] The recursive privacy-canary scan passes over xcresults, captured logs, defaults/app-support snapshots, diagnostics exports, and collected evidence, including transcript, selection, credential, origin, model, app, prompt, response, process-ID, filesystem-path, and bundle-identifier canaries.
- [ ] Independent source review confirms no Scribe content enters analytics, OSLog, Dictation history, meeting stores, caches, or crash/support payloads.

### Credential Accessibility Compatibility Decision

Accepted for the compatibility release based on PR #34 commit `04391d3`: Scribe provider credentials remain in the data-protection Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and synchronization disabled. This preserves existing credentials and behavior without introducing an unplanned credential migration. New provider credential paths must retain these exact attributes and their characterization coverage for this release line. Any move to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` or another accessibility class requires a separately planned credential migration and security review.

## Signed Candidate and Distribution

- [ ] `CadenceSourceCommit` in the mounted Release app matches the packaging git SHA.


- [ ] Developer ID signature passes `codesign --verify --deep --strict`.
- [ ] Notarization succeeds and the ticket is stapled.
- [ ] `spctl` accepts the DMG.
- [ ] Release—not Debug—bundle identity, display name, and executable are present.
- [ ] Minimum and current macOS launch, Dictation, Scribe, and meeting-capture regressions pass on every packaged architecture.

## Live OpenAI Direct and OpenRouter

- [ ] Live OpenAI Direct synthetic validation against the installed Release app from the candidate DMG.
- [ ] Live OpenRouter ZDR-oriented route validation for the selected model.
- [ ] Recipient/model policy review dates recorded for this candidate.

## Live DeepSeek Quality

Use the versioned synthetic corpus under `CadenceTests/Fixtures/AdaptiveScribe/quality-corpus.json`.

- Run all 24 prompts three independent times for 72 drafts.
- Every draft must preserve critical literals, facts, action boundaries, and prompt-injection boundaries.
- At least 80% must be ready unchanged overall and within each environment.
- At least 95% must be ready or need only a light edit overall and within each environment.
- No draft may score unsafe or unusable.
- Record only synthetic corpus/result identifiers and bounded scores in release evidence; do not collect genuine user content.

## Live DeepSeek Performance

- Run 100 sequential production-shaped requests.
- At least 99 must return a valid completion.
- Median complete-response latency must be at most 4 seconds and p95 at most 10 seconds.
- No accepted result may arrive after the 30-second hard deadline.
- Confirm the calm 8-second soft-wait UI and ten setup validations that finish or fail safely by 15 seconds.

## Real-App Recognition and Insertion

Primary targets for this release line: **Cursor**, **Slack**, and **Codex/OpenAI Desktop**, plus certified Claude Code signatures where present.

- [ ] Slack Compose/Respond/Edit passes Formal, Neutral, and Casual behavior, formatting, fresh-focus insertion, copy, retry, and discard.
- [ ] Capture and record the signed Claude Desktop bundle ID and one stable non-content Code-prompt AX role/subrole/identifier ancestry.
- [ ] The exact Code prompt resolves Claude Code · Precise.
- [ ] Claude Chat, Cowork, terminal, file editor, diff, search, Settings, and generic fields resolve Other apps · Neutral.
- [ ] Terminal, iTerm, Warp, VS Code, JetBrains, Safari, Chrome, and other browsers resolve Other apps even when Claude Code is present.
- [ ] Moving focus/caret/selection rejects insertion while preserving the draft.

## Accessibility and Motion

- [ ] Full keyboard traversal; safe default/cancel actions; no destructive default.
- [ ] VoiceOver names, values, disclosures, errors, environment cue, and exact-literal summary.
- [ ] 520- and 720-point layouts, larger text, light/dark appearance.
- [ ] Increase Contrast, Reduce Transparency, and Reduce Motion.

## Privacy and Credential Lifecycle

- [ ] Zero network tasks before the affirmative connect action.
- [ ] Validation payload contains only the two synthetic messages.
- [ ] Failed/cancelled setup creates no Keychain item or provider configuration.
- [ ] Successful setup creates one app-scoped, non-synchronizing item.
- [ ] Replacement is validate-stage-commit-cleanup; failure preserves the working item.
- [ ] Every redirect is refused and Authorization is never resent.
- [ ] Direct-dictation egress captures match the allowlist; selected text and every other denylisted field are absent.
- [ ] Disable retains the key; removal clears only provider state and current Scribe buffers.
- [ ] Privacy policy, setup disclosure, Settings disclosure, and observed payload agree.

## Five-Workday Dogfood

- At least 40 genuine tasks: at least 20 Slack and 20 certified Claude Code.
- At least six Respond/Edit actions.
- At least 90% need no more than a light edit.
- Zero stale/misdirected insertion, silent environment switch, lost actionable draft, or privacy incident.

Dogfood content stays outside the evidence bundle. Record only bounded aggregate counts and pass/fail incidents. Any critical incident fails the candidate.

## Final Decision

The release owner records `PASS` only when every section above passes on the same manifest-bound candidate. Otherwise record `FAIL` or `NOT RUN`; a green PR is never substituted for missing live or signed evidence.
