# Cadence interaction refinements: verification

Date: 2026-09-05. Implementation branch: `codex/cadence-interaction-refinements`.
Plan: [interaction refinements](2026-09-05-1626-fix-cadence-interaction-refinements-plan.md).

## Implemented

- R1–R2: retained-content/actionable failures persist; failure Copy/Escape belong to the focused panel. Global ready-review behavior remains intact.
- R3–R4: accepting a completed result synchronously publishes full text and actions. Stale animation cancellation, once-per-result completion, pinned insertion verification, and copy/outside dismissal retain their contracts.
- R5–R6: styles have static illustrative examples and explicit custom state. Instructions remain editable behind disclosure. The sheet scrolls with Save/Cancel outside the scroll area.
- R7–R8: one provider summary; secondary management is disclosed. A tested placement policy chooses exactly one location for setup/replacement.
- R9–R11: Home/latest/Earlier/detail share successful-copy feedback. Compose Open/Copy are siblings; stale expiry cannot clear newer feedback.

## Automated evidence

- Full CI-equivalent unsigned Debug gate: **650 Swift Testing tests in 66 suites plus 4 XCTest cases passed**. Log: `/tmp/cadence-ux-final-regression.log`.
- Includes actual `NSApplication.sendEvent` coverage for failure-panel Copy/Escape, focus loss, and teardown; all provider-readiness placement cases; immediate long-result readiness in normal/Reduce Motion paths; coordinator insertion safeguards; copy expiry; prompt/storage semantics.
- UI test bundle: **build-for-testing passed**. Log: `/tmp/cadence-ux-ui-build-final.log`.
- UI execution did **not** pass: the first layout test lacked its expected element, a later connection was lost, and subsequent tests reported macOS UI automation authorization failures. Log: `/tmp/cadence-ux-ui-tests.log`. Do not treat compiled UI tests as executed coverage.
- Standard development signing failed with `errSecInternalComponent`. An ad-hoc signed test attempt did not attach to XCTest and was stopped. The unsigned CI-equivalent run is the authoritative full test result.
- `git diff --check` passed. No repository lint command is configured beyond compiler/test checks.

## Installed Debug checks

The repository build/install/verify script succeeded using a temporary, out-of-repository ad-hoc signing override. Installed path: `/Applications/Cadence Debug.app`, bundle `com.darshshah.Cadence.debug`. This is local Debug validation, not a distributable or Release build.

Final executable SHA-256: `2eeac9fa07045b2547c096fbeebc74a27f5a4072d7d1099a3a8f02948f3350f5`. Final install log: `/tmp/cadence-ux-install-final.log`.

Verified through native computer control:

- Main window launches. Compact Compose content at 420 points and the wider rail layout are usable.
- Configured needs-attention provider: Manage, data/recipient disclosure, removal confirmation, and Cancel preserving configuration.
- Built-in/custom profile examples, expanded instructions, and scroll/footer geometry. Cancel preserves custom instructions; Save commits a restored preset in isolated synthetic fixture storage.
- Recovery remains visible beyond six seconds. TextEdit successfully copies unrelated synthetic text while recovery remains visible. Focusing the failure panel and pressing Escape dismisses it.
- Home/latest/Earlier/detail report successful copy; Compose Copy retains the list, Open navigates separately. Synthetic copied text was checked without printing clipboard content. Original clipboard was restored and the temporary editor document was closed.
- Completed fixture result and Copy/Insert are visible with Reduce Motion. Unit tests establish zero intentional readiness delay; no numeric live result-to-action latency claim is made.

## Review and preservation

`ce-simplify-code` completed with no changes. `ce-code-review` completed (run `20260905-225132-32e3a1c3`); it found two automated-coverage gaps and no demonstrated production defect. Both gaps were addressed by the passing local-event and provider-placement tests. External review routes could not authenticate; the skill's local adversarial fallback completed.

The existing working-tree edits were preserved. Review used temporary pre-work baseline object `0790f282b86d1b0a3372aeb5cc059e12ac03a319`; this is not a branch commit. Work remains uncommitted because several changed files also contain pre-existing edits. No push, PR, Release replacement, or distribution occurred.

## Remaining verification

U6 is partial: rerun the UI suite with an authorized runner; validate real microphone-to-provider-to-insertion flow with normal app permissions/signing; verify ready-provider management live; cover the other hardware geometry and Release build. Synthetic fixtures and unit tests do not establish these results. Existing Release installation is retained.
