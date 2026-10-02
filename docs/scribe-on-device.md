# On-device Compose

Apple Intelligence is the key-free default on fresh installations. Existing
provider selections are preserved. The public label is Apple Intelligence;
`legacyLocal` remains the persisted identifier for compatibility.

## Availability

- macOS 26 or later with Apple Intelligence supported, enabled, and downloaded.
- Cadence presents the system model's actual availability and never silently
  routes a failed local request to a cloud service.
- A provider can become ready during the app session. Availability is checked
  again on app activation, before recording, before dispatch, and at generation.
- Unsupported Macs can use the existing explicit cloud-provider setup.

## Selection and storage

The first provider migration creates the local configuration only when no legacy
provider exists. Completed migrations preserve user choice, including removals.
The local URI and credential-reference fields are schema placeholders. They are
never contacted, loaded from Keychain, or deleted from Keychain. No key is needed.
Selecting the built-in provider later retains saved cloud configuration entries.

## Verification

Unit coverage exercises fresh installation, interrupted migration, retained cloud
and disabled settings, removal persistence, key-free selection, current model
availability, dispatch revocation, and active-action/corrupt-store rejection.

Opt-in synthetic request export:

```sh
TEST_RUNNER_CADENCE_EXPORT_ON_DEVICE_FIXTURES=1 xcodebuild test \
  -project Cadence.xcodeproj -scheme Cadence -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
scripts/evaluate_scribe_instructions.sh \
  Build/ScribeOnDevice/requests.json Build/ScribeOnDevice/model-results.json
```

The evaluation uses only synthetic fixtures. It does not read app settings,
credentials, recorded speech, screen content, or history. Unit tests use mocks.
Model quality is a separate review: the system model is less reliable on complex
instructions than the configured cloud model. The UI describes its suitability
for short messages and everyday rewrites, and drafts always require review.
No model evaluation is a release certification.

### September 20, 2026 verification

- Full suite: 688 passed, zero failures or skips (`Build/ScribeOnDevice/final-tests.xcresult`).
- Privacy canary scan passed for the test log.
- Real on-device model generated all 16 synthetic requests with production prompts.
  Manual review found 13 suitable drafts; recipient-direction framing and two
  coding requests remained poor. One coding output reproduced literal metadata
  rather than drafting the task. These are known model-quality limits, not passing
  semantic acceptance cases. Cloud selection is retained for existing users.
- Signed Release replaced `/Applications/Cadence.app`; signature, executable hash,
  and a single running process verified. The replaced bundle was removed after
  verification; a ZIP rollback remains under `Build/ScribeOnDevice/install`.
- Follow-up visual verification completed after unlock: the installed picker
  displayed the built-in choice, selecting it showed provider ready, and its
  in-app practice generated a draft successfully. Apple Intelligence was selected
  for this installation at the user's request; saved cloud configurations remain.
- A separate local model smoke check of a short greeting generated a draft without
  error. This does not independently verify microphone-to-insertion behavior.

## Explicit writing commands

`ScribeWritingDirectionParser` separates standalone leading or trailing tone,
length, and reply-drafting commands from message content before an on-device request. Recognized
commands use a focused rewrite prompt with the direction in the system message.
Other requests retain the existing general prompt. Remote requests are unchanged.
The original transcript remains intact for history and literal recovery.

The parser is deliberately narrow: it does not delete matching words from the
middle of a message, strip recipient tasks, or interpret quoted/literal requests.
Commands without source content remain unresolved. The last explicit tone wins;
a length command can also apply. Existing custom guidance is retained in the
request, while explicit spoken style overrides the default style.

The evaluator now compiles `OnDeviceScribeGeneration.swift`, the same generation
implementation used by the app. Regression fixtures cover formal greetings with
and without conversational setup, leading commands, quotes, and recipient tasks.
This is a bounded style-command improvement, not a guarantee that the local model
will follow every possible instruction correctly.

### Style-command verification, September 20

- A regression test first reproduced the missing separation for “Hey, how's it
  going? Write this formally.” The parser and focused prompt consume the style
  command while retaining the original request for recovery.
- The production on-device generator produced “Hello, how are you?” for that
  synthetic request. Casual rewriting and a spoken date correction also passed
  manual review with the focused prompt. Conversational “can you help” framing
  remains inconsistent, and existing complex coding/literal failures are not
  treated as passing acceptance cases.
- An additional prompt reminder regressed the date correction during evaluation
  and was removed. Structured generation was also evaluated and rejected. Neither
  experiment is in the shipped generation path.
- Final focused suite: 52 Compose policy/coordinator tests passed; runtime privacy
  canary scan passed. The full suite earlier passed 691 of 692 tests; the existing
  window-focus interaction test failed and passed in a separate 17-test rerun.
  Later focus attempts also failed, so this is not a clean full-suite pass.
- Test fixtures now load from the test bundle. Reading the source checkout from
  the native test host stalled on macOS Documents-folder access. Optional source
  exports still require developer access to the checkout.
- Final four-case on-device recheck passed manual review: formal greeting, casual
  message, formal rewrite, and final spoken date correction. Evidence is under
  `Build/ScribeFormalGreeting/`: `release-regressions-bundled.xcresult` and
  `release-model-results.json`.
- Signed Release replaced `/Applications/Cadence.app`. Signature and executable
  hash matched the build; one installed process was running. Live Settings showed
  Apple Intelligence selected and provider ready. The old bundle was removed;
  a ZIP rollback and installation manifest remain in the ignored evidence folder.
  The exact model check is separate from live microphone-to-insertion acceptance.

### Reply-drafting repair, September 20

The general prompt reproducibly yielded an assistant preface, a code fence, and
the unchanged writing request when asked to write a response in another app.
Simpler prompts and a single-field structured response did not reliably follow
the instructions; the structured variant also regressed other cases. Those
experiments are retained only in the ignored `Build/ScribePromptLeak` directory.

The existing parser now also recognizes standalone requests such as “Can you
please write this as a response in Codex?” and “Draft this as a reply on Slack.”
It passes a fixed reply-drafting direction into the existing focused rewrite
path. A spoken destination never changes the pinned insertion target. Quoted
requests, recipient tasks, missing source content, and destination clauses with
additional constraints are left intact. This remains a bounded recognizer.

Output validation also rejects known internal prompt labels unless they were
present in the spoken request. It does not delete arbitrary model prose or strip
quotes/fences from legitimate content. Existing recovery retains the transcript.

- Both the leaked-label acceptance and reply-command separation tests failed
  before their fixes. Final focused suite: 61 passed; full suite: 693 of 694
  passed, with only the previously failing window-focus interaction test left.
  The runtime privacy canary scan passed.
- Nine production-generator checks passed manual review, including two identical
  replays of the reported request. Both returned only the message, retaining its
  uncertainty. Formal greeting, corrected date, recipient question, exact quoted
  code, and a no-edit recipient constraint remained correct.
- Evidence: `Build/ScribePromptLeak/focused.xcresult`, `full.xcresult`, and
  `verification-results.json`. These checks do not prove every instruction or
  replace live microphone-to-insertion acceptance.
- Signed Release replaced the existing `/Applications/Cadence.app`. Strict
  signature, build hash, a single running process, and live provider readiness
  were verified. Apple Intelligence remains selected. The old bundle was removed
  after verification; `Build/ScribePromptLeak/install` retains the rollback ZIP
  and installation manifest.


## Roadmap implementation, September 22 (source only)

The active implementation ledger is [Compose roadmap progress](compose-roadmap-progress.md).
The changes below have not replaced the installed application.

- A typed writing request records message content, writing directions, protected
  spans, missing sources, and narrow named/coding-agent recipient frames. The
  original speech remains available. A spoken recipient never selects an app or
  changes the pinned insertion target.
- Unambiguous leading help setup is removed only alongside a supported writing
  direction and a remaining message. Quotes and ambiguous recipient names stay
  on the general path.
- Local direct formatting supports an explicit coding-agent why-question with
  no writing directions and a bounded suffix of recipient restrictions. It
  prefixes the preserved question body with “Explain”; it cannot answer it.
  It also preserves one short already-worded first-person uncertainty statement
  when the only direction is reply placement. Saved styles, corrections and
  additional writing tasks bypass these shortcuts. Other requests use the model. Schema-2 evaluation distinguishes
  prepared drafts from model generation and reports their quality separately.
- Output guards compare protected UTF-8 bytes, reject the exact observed internal
  literal-table leak, and check narrow explicit recipient restrictions. These
  are useful rejection rules, not proof of all meaning or instruction following.
- Voice refinement now has a dedicated local-only request path, in-memory
  versions, explicit Refine/Undo, and cancellation recovery. See
  [refinement behavior](scribe-voice-refinement.md). Cloud refinement is unavailable
  while prior-draft transmission remains outside the existing provider consent.

The latest broad native checkpoint reports 1,120 passing tests in 103 suites,
including context/memory foundations, synthetic-image OCR and generator races.
The real desktop-focus test was explicitly excluded because the Mac console was
locked. The opt-in real insertion harness did not run and remains blocked on
Accessibility permission for the test build. These checks do not establish model
quality or certify native editor behavior; see the ledger for exact evidence.

### Response completion limitation

Apple documents that a configured response-token cap may stop generation early
without an error. The macOS 26 response API does not expose the macOS 27 usage
metadata. Retokenizing returned text cannot prove why the model stopped. See
[maximumResponseTokens](https://developer.apple.com/documentation/foundationmodels/generationoptions/maximumresponsetokens)
and [TN3193](https://developer.apple.com/documentation/Technotes/tn3193-managing-the-on-device-foundation-model-s-context-window).

The implemented generator removes the explicit token cap and bounds response
waiting to 30 seconds; cancellation, timeout, and late-completion tests pass in
the full native checkpoint. Timeout, cancellation, or context-limit failure must
produce no returned draft. That removes this known silent-truncation path; it
still does not prove a naturally completed draft is semantically complete.
Evidence from the old 1,024-token setting remains separate from new runs.

The production generator shares a single admission permit across local Compose
calls. A timeout or cancellation ends caller waiting promptly, but the permit
remains held until the actual operation returns or throws. Another request sees
the existing recoverable busy state instead of accumulating abandoned model work.
The permit is released before a completed result is published, so an immediately
following request can start. Absolute monotonic deadlines reject late results
even if the timer task starts late. Injected cancellation-resistant operations
verify these guarantees; they do not prove the Apple model ignores cancellation.
