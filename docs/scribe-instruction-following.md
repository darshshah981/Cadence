# Scribe: spoken writing directions

September 19, 2026. Branch: `codex/scribe-improvements`.

## Behavior

Scribe turns a spoken writing request into a reviewable draft. Speech can
contain both the intended message and instructions about how to write it.
This supersedes the instruction-as-text rule in the July 11 polished-dictation
contract. Ordinary dictation still receives meaning-preserving polish.

- Apply writing directions such as "keep it casual", "make that more formal",
  or "put this in two bullets" without repeating them in the draft.
- Turn "tell Alex" or "ask the coding agent to" into the intended message.
- Preserve requests addressed to the recipient. "Tell Alex to keep the
  announcement casual" must still ask Alex to keep the announcement casual.
- Preserve questions intended for a recipient instead of answering them.
- Preserve quoted wording, technical literals, uncertainty, and action limits.
  "Investigate without changing code" must remain an investigation request.
- Use the user's final explicit correction without inventing replacement facts.
- Explicit spoken writing directions override conflicting style defaults.
  They cannot override the no-invention or draft-only rules.
- Missing context stays unresolved: "make this shorter" with no supplied text
  cannot rewrite a document that Scribe has not read. The optional selected-text path has its own explicit
  permission; broader screen context and memory remain separate work.

Model-backed drafting uses one request to the selected provider. A narrowly recognized local coding-agent question can instead be formatted directly without a model call; the evaluation reports that execution method separately. Cloud requests retain
the shared instruction-following prompt. On-device requests additionally recognize
standalone style and reply-drafting commands at the beginning or end of speech and use a focused
rewrite prompt for them. Quoted/literal requests and recipient instructions are
not stripped. A complete short greeting followed by “write this formally” also
uses that path when transcription omits the sentence boundary, for example
“Hey how’s it going write this formally.” This exception does not create a
general whitespace boundary for recipient instructions. Known formal-rewrite
introductions remain outside insertion-ready drafts unless dictated as content.
Formal rewrites also preserve recognized first-person uncertainty phrases, such
as “I think,” “I do not know,” and “I am not sure.” The on-device prompt retains
those phrases with their source statements; direct-draft validation rejects
outputs that drop a recognized qualifier class, accepting common variants such
as “I believe” or “I am unsure.” Literal requests and explicit corrections keep
their existing path. This guard checks qualifier presence and count, not full
semantic equivalence or whether a qualifier has moved to another statement.
App presets remain style defaults; see [on-device behavior](scribe-on-device.md). Mandatory review, insertion-target checks,
retry identity, unpolished fallback, and existing egress allowlists remain.
Speech is presented directly as the user's writing request instead of a quoted
JSON value. Explicit technical literals retain their separate JSON metadata;
unnecessary slash escapes are omitted so paths remain readable verbatim.

## Verification

`CadenceTests/Fixtures/AdaptiveScribe/instruction-following.json` contains 24
synthetic examples. Example drafts illustrate acceptable meaning; they are
not exact-output requirements. Required/forbidden phrases help review results
but cannot establish semantic quality by themselves.

`ScribeTests.instructionFixturesUseProductionRequestsAndPreserveRequiredLiterals`
builds the actual requests through the normal presets, literal normalizer, and
request policy, and checks that example drafts pass literal validation. It does
not pretend a mock provider proves instruction-following. A coordinator test
verifies that the full spoken input is retained and the generated draft requires
review before insertion.

For an optional local model evaluation on a Mac with Apple Intelligence ready:

```sh
TEST_RUNNER_CADENCE_EXPORT_ON_DEVICE_FIXTURES=1 xcodebuild test \
  -project Cadence.xcodeproj -scheme Cadence -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .derived-data-contracts \
  -only-testing:CadenceTests/ScribeTests CODE_SIGNING_ALLOWED=NO
scripts/evaluate_scribe_instructions.sh \
  Build/ScribeOnDevice/requests.json Build/ScribeOnDevice/local-model-results.json
```

The optional export contains only synthetic fixture requests. The evaluation
uses the on-device system model, greedy sampling, and no credentials or app
settings. It saves generated drafts for human review. Results from this model
do not establish results for the user's configured provider or model. The
existing remote-provider release gates remain separate.

If the test host cannot write into a checkout under Documents, also set
`TEST_RUNNER_CADENCE_SCRIBE_EVALUATION_DIRECTORY` to an accessible temporary
directory. Its exported file is named `requests.json`; pass that path to the
evaluation script. The fixture itself loads from the test bundle.

## September 19 cloud-provider development evidence

An initial system-instruction-only revision still reproduced writing directions
and lost recipient constraints in several on-device model cases. Presenting
speech directly as the request helped, but the small on-device model still
failed complex constraints and borrowed an example for a missing-context request.
The final revision removes embedded example facts and explicitly checks
recipient restrictions and missing-context handling in the request footer.

The final exported production requests were evaluated against the configured
DeepSeek V4 Flash connection using its existing recipient and consent snapshot,
production generation settings (temperature 0.3, thinking disabled, 1,024 output
tokens), synthetic input only, and no redirects. Credentials stayed in memory;
no provider settings or permissions were changed. This was a developer model
evaluation, not an app-mediated release certification or microphone test.

All 16 drafts satisfied the core behavior on manual semantic review: writing
directions were applied, recipient requests and restrictions remained, exact
technical literals survived, and missing source text did not produce fabricated
content. Exact phrase checks flagged two acceptable paraphrases: "Thursday, not
Tuesday" uses the corrected date, and "after you review it" preserves the review
condition. Some wording is still more formal or repetitive than the example
drafts, so this establishes the first instruction-following pass, not universal
writing quality across models.

Evidence is in the ignored `Build/ScribeInstructions/` directory:
`requests.json`, `deepseek-results.json`, and `confirmed-tests.xcresult`.
The opt-in `CADENCE_VALIDATE_SYNTHETIC_SCRIBE_RESULTS=1` test-runner environment
also validates these actual synthetic results through production output and
literal validation. The small on-device model's development results are not
treated as acceptance for this final DeepSeek evaluation.

Final full suite: 682 passed, no failures or skips. Runtime privacy canary scan
passed. The signed Release app was installed in place at
`/Applications/Cadence.app`; matching identity, strict signature, executable
hash, and launch were verified. One Cadence process is running. The rollback
ZIP and installation manifest are in `Build/ScribeInstructions/install/`.
Live voice acceptance with the user's own requests remains the next check.


## Already-worded uncertainty replies

For the narrow request “I think the draft is ready. Write it as a reply in Slack.”,
the local compiler now prepares “I think the draft is ready.” directly. The
recorded model failure removed “I think”; no paraphrase is needed to fulfill this
reply-placement request. The entire retained message is copied byte-for-byte;
“in Slack” remains a drafting direction and cannot select an insertion target.

The bounded rule accepts only one short first-person uncertainty statement and
only the reply direction. A request to change tone or length, a correction, a
quotation, a question, a compound statement or recipient frame remains model
work. Explicit saved styles also disable direct formatting. These limits apply
before generation; there is no attempt to insert uncertainty words into a model
result after it has changed meaning. Other model-generated uncertainty failures
remain a U3 quality gate.

`ScribeDirectDraftPolicyTests` exercises the exact recorded failure, variants,
unsupported requests, Unicode byte preservation, cloud exclusion, saved-style
precedence and the actual compiler-to-generator prepared-draft boundary. A
prepared result starts neither model work nor a model timeout. These tests prove
that narrow behavior, not live microphone transcription or real-app insertion.


## Natural edit-command forms

The bounded parser also recognizes polite style commands such as “Could you make
this more formal?” and counted formatting commands such as “Turn this into two
bullet points” or “Please format that as two bullets.” Counts remain limited to
one, two or three. A complete command can stand alone, occupy an independent
sentence at a request edge, or introduce supplied content with a colon.

A standalone command still requires source text. With the optional TextEdit
selection path enabled and authorized, it uses that selection. Without source,
Compose reports missing information before calling the provider. With dictated
message content, the parser keeps the message separate from its writing directions.
It does not consume an instruction addressed to someone else, a quoted command,
a protected exact literal, or a command bundled with an additional task such as
emailing somebody. Unsupported table requests are not newly interpreted.

Software tests compare the new selected-text aliases with existing formal and
counted-bullet commands and require identical provider-input bytes and provenance.
This reuses the existing model path; it is not evidence that all rewritten outputs
are good. The earlier selected-rewrite quality gate remains unresolved.

## Copied writer-command recovery

For direct drafts, the local parser records the exact standalone writing commands
it removed from the spoken message. After generation, Cadence rejects a result
that repeats one of those commands as draft text. For “Hey, how's it going?
Write this formally,” a result ending in “Write this formally” stays out of
review and insertion; the original speech remains available for recovery.
Quoted requests and instructions addressed to a recipient are never consumed
as writer commands, and selected-text rewrites use their separate source-aware
validation path. This bounded guard does not judge paraphrased command leakage
or make the generator better at following instructions.

## Complete coding-agent instructions

The local provider can now format a short, complete instruction without model
generation when speech explicitly asks an agent or coding assistant to inspect,
investigate, review, check, locate, or find something. “Draft a short request to
review the cache miss, but do not modify configuration” becomes “Review the
cache miss, but do not modify configuration.” The task body stays intact; the
formatter only removes the spoken drafting frame and capitalizes its action
verb. This also preserves `--dry-run` and “leave files untouched” in an already
complete request. These are drafts for review, never actions Cadence performs.

The shortcut is limited to one bounded request. Corrections, extra writing
directions, questions, quoted/literal requests, multiline requests, configured
styles, and cloud providers retain their existing paths. The coordinator still
applies literal, writing-direction, named-recipient, and recipient-restriction
checks before review. Tests verify those boundaries and prove that a prepared
draft starts neither a model call nor a model timeout.

The exposed 16-case instruction replay now has three prepared drafts and 13
model calls. The three prepared results repair the previously lost
no-configuration-change limit, literal flag/file limit, and tentative reply.
A strict manual review scored 12 acceptable, one critical and three minor
results. The remaining critical raw model result invents a letter for “Make this
friendlier” without source text; the real coordinator refuses that request
before generation. The updated policy replay marks it rejected as
`missingSource`, leaving 15 generated outputs review-ready under deterministic
guards. Review-ready does not mean semantically good: the named-recipient
message is still insufficiently upbeat, and the private-reason direction still
appears in the drafted message. This previously exposed corpus is development
regression evidence, not a new held-out quality claim. Artifacts are in
`Build/ComposeRoadmap/U2-complete-coding-requests/`.

## Short upbeat schedule announcements

The exposed Nora case kept the recipient and time but ignored the requested
upbeat tone. Four isolated local-model prompt variants were compared. Only a
concrete punctuation cue produced an upbeat result without adding facts. The
production local rewrite now uses that cue solely for a single named-recipient
announcement that a supported event starts or begins at a stated time. A
cancellation, uncertain time, extra sentence, or request without upbeat tone
keeps the existing prompt. This changes phrasing only; it never changes the
insertion destination or bypasses review.

The production request exported from the 24-case development fixture generated
“Nora, the rehearsal starts at nine!” with Apple Intelligence. The focused
`ScribeTests` suite passed 24 tests, including neighboring negative cases.
Artifacts are in `Build/ComposeRoadmap/U2-upbeat-prompt-probe/`; the test log
is `/tmp/cadence-u2-upbeat-export.log`. This is one exposed development case,
not a fresh quality scorecard or live microphone-to-insertion verification.
