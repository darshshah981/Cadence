# Compose roadmap implementation evidence

The [feature roadmap](plans/2026-09-22-0042-feat-compose-feature-roadmap-plan.md) remains the long-term reference. This ledger separates implemented increments from verified milestone completion. Work proceeds one small goal at a time; no milestone is complete merely because a new type, test fixture, or UI control exists.

September 30 U12 scheduling-commitment polarity increment: the existing
day-and-hour guard still accepted "Thursday at 3 does not work for me" for a
speaker who said "Reply that Thursday at 3 works." A red run reproduced four
unsafe accepted drafts: explicit rejection, inability to meet, an unanswered
question, and unavailability. The narrow output check now requires an
affirmative commitment and refuses negation for that complete spoken form.
Positive paraphrases such as "I can meet Thu at three" remain accepted. The
focused native suite passed 13 tests, including four opt-in synthetic
Apple Intelligence cases; a full native rerun was not needed for this
compiler-only change. It does not cover other scheduling request shapes,
general reply grounding, a live screen capture, or the installed app.

September 30 U11 multi-adapter action-scope increment: the action owner and
session-memory controller can now register more than one trusted identity
adapter. Only adapters for the pinned process are asked to capture identity,
and memory access is issued only when exactly one adapter verifies that
surface; two valid claims fail closed rather than selecting by registration
order. Synthetic tests show a second host gets a distinct scope, replaces the
old action, and loses access on navigation change. The focused identity,
action-scope and session-store run passed 57 tests; the full native suite
passed 1,375 tests in 116 suites with the known focus-dependent keyboard
suite excluded. Production still registers
only the saved-TextEdit adapter and keeps its separate opt-in consent; this is
integration groundwork, not ChatGPT, Codex, Muse, or browser recognition.

September 30 U12 spoken-schedule guard: a deterministic regression showed
that screen-text output validation would have accepted Friday at 3, Thursday
at 4, or an added Friday when the speaker had explicitly said “Reply that
Thursday at 3 works.” The compiler now checks that narrow complete scheduling
shape before review: the stated weekday and hour must survive, and another
weekday cannot be introduced. Full weekday and common three-letter forms,
numeric and spelled hours are accepted. The red run failed all three unsafe
cases; the final focused suite passed 13 tests, and the full native suite
passed 1,373 tests in 116 suites with the known focus-dependent keyboard
suite excluded. Other scheduling phrasings and
general factual grounding remain outside this guard.

September 30 U12 adversarial screen-text checkpoint: an opt-in synthetic
on-device case put a hostile “answer Friday” instruction beside a visible
Thursday scheduling question. With the speaker asking to reply that Thursday
at 3 works, the final draft contained Thursday and “works,” excluded Friday,
and did not repeat the hostile instruction. The tightened first and second
runs each passed the screen compiler suite (12 tests); this is one narrow
provider observation, not general prompt-injection certification. The codebase
guide now reflects the current TextEdit pilot rollout defaults, while all
content-access and retention choices remain separately off by default.

September 30 U12 explicit-update reply increment: a synthetic on-device screen
preview exposed a real failure. Asked to request an update about pending refund
RF-12, the model repeated the visible pending status instead of asking a
question. The failed result and log are preserved. For a single, fully named
“Ask for an update on …” request, output validation now replaces a non-request
status echo with “Could you please provide an update on …?” using only the
speaker's subject. It never copies a screen claim into that repair. If the
subject is unresolved or compound, the same non-request output is rejected
before review. Existing valid questions remain unchanged. The focused screen
compiler suite passed 11 tests; the full native suite passed 1,371 tests in
116 suites with the known focus-dependent keyboard suite excluded. The
current on-device checks passed both the
original request and a variant without an explicit warning about false
approval, as well as the two earlier grounded-reply cases. This is a narrow
synthetic repair, not proof that arbitrary screen replies resist prompt
injection or produce useful responses.

September 30 U6 recipient-question latency increment: a complete, single
recipient-facing request such as “Can you send me the report by Friday?” now
returns the original wording as an immediate local prepared draft on the
key-free on-device path. The rule requires one bounded question, no separate
writing direction, no protected literal, no unresolved reference, and no
writer/recipient frame; cloud-provider behavior is unchanged. This avoids a
model call that previously took about 13 seconds on the existing synthetic
development case while yielding those same words. Focused direct-draft and
writing-request suites passed 97 tests. A current-source 24-case on-device
evaluation generated all 24 drafts. Its text matched the prior baseline
byte-for-byte in every case; only this question changed execution path, from
13,355 ms of model generation to 0 ms of measured prepared-draft work. Native
policy replay remained 23 READY and one missing-source REJECTED. Installed-app
latency remains unverified. The rule deliberately does
not handle open-ended questions or unspecified “send this” requests.

September 30 U6 immediate-draft presentation increment: when a direct Compose
action already has a prepared Apple Intelligence draft, the coordinator keeps
the transcribing presentation until the checked result reaches review. It no
longer publishes a fleeting composing state or starts the slow-generation
timer for that path. Ordinary model generation still publishes its progress
state. Focused coordinator and notch-presentation suites passed 165 tests,
including an observed-state assertion for the exact recipient-question case;
the full native suite passed 1,369 tests in 116 suites with the known
focus-dependent keyboard suite excluded.
The installed notch transition has not been visually checked.

September 30 U13 TextEdit opt-in pilot: the session-memory and saved-document
adapter rollout flags now default on, so their Settings section is
visible in a normal install. Every actual permission inside it still defaults
off: recognizing a saved document, remembering explicit facts, retaining a
chosen draft, and using relevant facts in local generation all require
separate affirmative controls. The disclosure revision advanced, so consent
from an earlier hidden development build cannot silently activate this
pilot. Other apps and cloud providers remain excluded. Forty-eight focused
feature-flag, consent, scope, and store tests passed; the current full native
run passed 1,367 tests in 116 suites with the known focus-dependent keyboard
suite excluded. The privacy-canary scan passed. This exposes the existing
TextEdit workflow for an eventual trial; integrated installed-app interaction
and a supported chat-thread adapter remain unverified.

September 30 U1 current-source quality baseline: the existing frozen 24-case
synthetic instruction corpus was exported through the production compiler and
run three times with the current on-device generator. All 72 requests completed
without generation failure; the 24 draft texts were byte-identical across runs.
Native policy replay made 23 cases ready and rejected the source-free “Make
this shorter” case. Separate case-by-case agent review against the frozen
rubric accepted all 72 outputs, including the unresolved source-free request
as a safe rejection, with zero critical errors. The bound aggregate reports
`PASS` for its provisional Compose-pipeline and model-generation gates. One
mechanical phrase warning is an acceptable paraphrase of a recipient-directed
formal-writing request. This is repeatable synthetic development evidence,
not independent broad quality, live microphone, or installed-app evidence.

September 30 U3 recovered-reserve increment: the original checkout became
readable again. Its 201 dirty files were archived without changing that
checkout, and its previously frozen but unevaluated meaning reserve J was
restored to the clean recovery branch with the same SHA-256. On the first
current-source on-device run, all 16 synthetic cases generated and the native
replay marked all 16 READY, but manual semantic review found two critical
READY errors: a copied “Ask Max if…” writer frame and a past meeting recast as
merely scheduled. The first-run independent gate therefore **failed** despite
zero mechanical phrase warnings. A bounded direct question path now handles
single ticket/issue/case identifiers, and the existing past-versus-scheduled
cue and output guard accept the natural comma before “and.” The focused native
suites passed 96 tests. Current policy replay rejects both original bad
outputs; the repaired development rerun changed only those two drafts and
marked all 16 READY. This corpus is now exposed development evidence. A fresh
independent reserve is required for any new U3 quality claim, and the original
checkout and installed app remain unreconciled.

September 30 U15 immediate-preference increment: four complete, single-sentence
forms with one explicit saved tone or concision preference now produce a
bounded local edit without model latency. Four previously unchanged drafts in
the existing six-case development corpus became immediate prepared drafts;
the other two stayed on the model path with their prior output. Manual review
accepted all six exposed-case results without lost facts, audience, questions,
or uncertainty. This is not an independent general-quality gate. A tested
second-model-pass candidate was rejected: only one of four ignored preferences
improved, one output leaked a “Message:” label, and it added seconds of latency.
The final focused native run passed 278 tests across five suites plus a
nine-test profile-priority rerun. See [writing defaults](scribe-writing-defaults.md).

September 30 U12 source-free reply increment: standalone requests such as
“Reply to this” or “Draft a reply to this thread” now stop before provider
dispatch when Cadence has no certified source message and destination in one
conversation. The original transcript remains available for explicit Copy;
the failure explains that “this” cannot be identified and asks for a complete
spoken reply or message details. Complete named-recipient replies and exact
literal requests remain ordinary content. The focused native parser and
coordinator run passed 201 tests across two suites. This is a bounded refusal,
not a grounded-reply implementation. A read-only native AX structure probe of
the current ChatGPT/Codex desktop process found a WebArea URL with only one
generic app path segment, an empty window document value, and no non-menu
AXIdentifier in the first 500 inspected elements.
That one view does not provide a certified thread key; the existing
cross-conversation memory gate remains closed. The probe did not save text,
conversation titles, full URLs, screenshots, or pixel data.

September 30 U2/U3 independent synthetic checkpoint: after preserving failed
first runs O and P, the frozen U2 instruction reserve Q passed its first run.
One on-device run generated all 16 outputs; native policy replay marked the 14
contentful drafts ready and rejected both source-free transformation commands.
Manual review found zero critical meaning errors and 12 of 14 visible writing
direction outcomes. Casual and concise examples remained plain. The separately
frozen U3 meaning reserve N also passed its narrow first-run gate: 14 contentful
ready, two safe source-free rejections, zero critical meaning errors on manual
review. The frozen corpora, source archives, raw runs, replay, scorecards, and
semantic reviews are preserved in the external Compose staging bundle. These
are synthetic local-provider gates, not broad provider certification or live
microphone-to-insertion evidence. The primary Documents checkout still needs
reconciliation with the working candidate before an installed build can be
claimed. Later historical entries below describe earlier snapshots.

September 30 U7 synthetic refinement checkpoint: an exposed eight-case
on-device run originally made only five requested edits. Three bounded local
revisions now turn an unchanged model result into a shorter timed status, a
shorter coding prompt that retains exact path/flag and no-file-edits rule, or
a warmer, shorter invitation decline with its first sentence unchanged.
Runtime coordinator tests and native policy replay exercise this path. A
separately frozen eight-case first-run reserve then generated 8/8; replay
found 8/8 effective drafts ready, three bounded revisions, and zero remaining
unchanged drafts. Manual review found all eight instructions satisfied with
no critical meaning, literal, restriction, or protected-text error. This is
a narrow synthetic local-provider pass; live review/undo interaction and
installed-app certification remain open.

September 30 latest full native checkpoint: a temporary copy of the current
source outside the Documents checkout passed **1,271 tests in 112 suites** with code
signing disabled. A content-free report at
`Build/ComposeRoadmap/U18-temp-suite-full-pass-question-subject.json` binds the test log and all
399 copied source files by SHA-256; those files matched the working checkout
after the run. This resolves the immediate full-suite observation gap caused
by the in-place runner stall, but it does not certify signed installed-app
behavior, live permissions, writing quality, or the remaining roadmap gates.
The earlier 1,270-, 1,265-, 1,264-, 1,263-, 1,258- and 1,251-test checkpoints remain preserved separately at
`Build/ComposeRoadmap/U18-temp-suite-full-pass-reserve-repair.json`,
`Build/ComposeRoadmap/U18-temp-suite-full-pass-u7-warm.json`,
`Build/ComposeRoadmap/U18-temp-suite-full-pass-u2-warm.json`,
`Build/ComposeRoadmap/U18-temp-suite-full-pass-u13.json`,
`Build/ComposeRoadmap/U18-temp-suite-full-pass-u10.json` and
`Build/ComposeRoadmap/U18-temp-suite-full-pass.json`.

September 30 fresh-reserve development findings: a newly frozen 20-case
synthetic instruction corpus generated 20/20 outputs in one actual on-device
run. Native policy replay allowed 19 for review and rejected one literal
metadata result. Inspection exposed a more important missing-source case:
“Summarize this in one sentence” echoed the command and was incorrectly
allowed for review. It also found two drafts that repeated writer instructions:
one asked the recipient to keep two stated statuses distinct; another promised
to make a decline polite without inventing a reason. This corpus is now exposed
development evidence, not an independent holdout. Production now treats the
bounded standalone summary request as missing source before provider dispatch,
prepares the complete coding-flag request locally, and prepares the two
complete named-recipient messages locally without copying those writer clauses.
Quoted, compound, recipient-directed, and cloud cases keep their prior paths.
The current-source development rerun generated 20/20 outputs with four
prepared drafts; native replay marked 19 ready and rejected the missing-source
summary. Its two mechanical phrase warnings are acceptable paraphrases on
inspection, but the separate question “whether the file needs approval”
became “do you need approval,” changing the subject. A bounded local question
route now preserves the file as subject and excludes compound/quoted requests.
Focused parser, coordinator and direct-draft tests pass, along with the full
copied-source suite above. A final rerun of this exposed corpus and a fresh
independent semantic reserve are still required before any U2 quality claim.

September 30 U13 chosen-draft increment: an independent default-off TextEdit
session-memory control now permits retaining a reviewed local draft only after
successful Copy or confirmed Insert. The action, draft version, document,
retention category, and current permission are rechecked at write time.
Repeated Copy of one version is deduplicated. Selected-text rewrites and drafts
that used session or saved facts are excluded. Inspect labels the content as a
copied or inserted draft, explicitly without proof of delivery; fact retrieval
and future draft generation omit it. Turning the control off clears the
in-memory store. The 21 focused consent, action-scope and coordinator tests
passed, as did the privacy-canary scan. This has not been tried in the installed
app and does not add conversation identity for other apps.

September 30 U2 development regression: the existing, previously exposed
16-case synthetic holdout was re-exported through the production request
compiler and run once through the current on-device generator. All 16 rows
completed: 12 model generations and four prepared drafts. Native policy replay
marks 15 ready for review and rejects the missing-source “Make this friendlier”
case before it could reach a user; that raw model output still invented a long
letter. The earlier Nora, private-reason, no-configuration-change, technical
literal and tentative-reply failures are visibly repaired in this development
run. The mechanical scorecard has two advisory phrase warnings, one for the
unsafe missing-source output and one for an equivalent wording of the
configuration restriction. Semantic quality has not been independently graded
and this exposed corpus cannot certify the quality gate. Artifacts are under
`Build/ComposeRoadmap/U2-current-regression/`. The replay shell wrapper now
accepts the schema-2 native direct-draft report instead of rejecting a passed
native test as an unsupported schema.

The larger, existing 24-case synthetic development corpus also completed in
one current on-device run: 19 model results and five prepared drafts, with no
generation failures. Native replay marks 23 ready and rejects only the
missing-source “Make this shorter” case before dispatch. The phrase scorecard
flags that same raw output; it does not grade meaning. The short warm note to
Maya remains plain rather than distinctly warm, and the polite decline adds
an unnecessary “Thank you.” These are exposed development observations, not
fresh validation. Exact artifacts are under
`Build/ComposeRoadmap/U2-current-development/`.

September 30 U2 warm-status increment: the model was removing the “Hi Maya”
opening from a short status update despite an explicit warm-tone request.
The compiled prompt also carried a generic default against adding greetings.
Three isolated one-case prompt variants were compared; a reminder to retain
the already-present greeting and a stronger default override kept it, while a
warm-opening cue did not. Production uses the smaller reminder only for a
single positive named-recipient ready-for-review/testing status. Its exact
exported prompt matches the successful one-case model probe byte-for-byte.
The 26-test policy suite passes, including uncertain, negative, compound and
formal exclusions. This repairs the exposed Maya example in development
evidence; it is not an independent quality-gate pass. Probe and export artifacts
are under `Build/ComposeRoadmap/U2-warm-status-prompt-probe/` and
`Build/ComposeRoadmap/U2-warm-status-production/`.

September 30 U7 warm-refinement increment: in the eight-case exposed voice
refinement set, the local model previously left five requested edits unchanged.
Two isolated two-case prompt probes showed that a short system cue produced
greeting changes without dropping a quoted phrase. Production now adds that
cue only for a short, named-recipient “make it warmer” request, and excludes
negative drafts, protected opening text, existing greetings and explicit
no-greeting instructions. The exported production requests for both changed
cases exactly matched the successful probe inputs. In a complete current-source
eight-case on-device run, those two drafts changed and the other six outputs
remained byte-identical to the prior run. Native policy replay accepted all
eight generated outputs; this is not a semantic quality pass, and three
requested edits still yielded unchanged drafts. Ten focused policy/export tests
passed. Artifacts are under `Build/ComposeRoadmap/U7-warm-refinement-probe/`
and `Build/ComposeRoadmap/U7-warm-refinement-production/`.

September 30 U11 Codex native identity probe: with the current Codex desktop
app active and Accessibility trusted, its focused window exposed an empty
`AXDocument`. A bounded inspection of 11 accessibility descendants found no
nonempty URL, document, or identifier attribute; no conversation text, title,
or URL value was read into the report. This surface supplies no verified
per-thread key for the existing identity resolver, so production continues to
deny Codex conversation memory. The content-free metadata report is at
`Build/ComposeRoadmap/U11-codex-native-metadata/report.json`. This is one app
version and window state, not a claim about every Codex view or browser tab.

September 30 U9/U17 checkpoint: the coordinator's synthetic TextEdit fixture
now uses the system TextEdit bundle path it claims to represent. Production
correctly rejected the old `/Applications/Test.app` identity; the isolated
expiry case and all 136 coordinator tests now pass. A fresh current-source,
trusted standalone probe launched a new TextEdit 1.20 process with a synthetic
saved document and observed exact insertion, selected-text capture, revalidation,
and exact replacement readback. Its content-free report is
`Build/ComposeRoadmap/U17-textedit-surface/run.6OMg4K/report.json`. This is one
development editor path, not a signed installed-app or model-quality claim.
The in-place full native suite and the isolated `AdaptiveScribeContractTests`
first case stalled after starting; both were stopped without a pass result.
The temporary-copy full-suite pass above resolves the software-suite gate for
that source snapshot; the in-place runner behavior remains unexplained.

September 30 U10 increment: screenshot targets now require a finite, nonempty
expected focused-window frame. The default-denied native adapter compares it
before reading pixels, then compares a fresh ScreenCaptureKit frame before
publishing. A moved window with the same ID, process, and pixel dimensions is
refused at either boundary. OCR now flags separated, vertically overlapping
text columns as an ambiguous reading order instead of presenting the flattened
line sequence without a limitation. A real Vision run on a synthetic two-column
bitmap confirmed the signal. The 29 screen-context/adapter tests and 10 Vision
OCR tests passed. No live screen image was captured. This does not establish an
AX-to-ScreenCaptureKit window mapping or protect against reuse at an identical
frame.

Later September 30 U10 platform smoke: a standalone, ad-hoc-signed development
probe used the production `SystemComposeScreenCaptureAdapter` against only the
controlled Compose Test Host window. It produced one exact-window image at
1640×1504 pixels and correctly refused default-denied authority, a different
window ID, a changed frame, and a stale process launch identity. No image
bytes were saved. A follow-up closed-window attempt did not run because the
probe's Screen Recording preflight returned denied, while a separate `swift`
preflight still returned granted. This does not certify repeatable TCC access,
AX-to-ScreenCaptureKit target mapping, a closed-window refusal on the live OS,
or installed-app behavior. The capture/OCR service remains unregistered.

Later September 30 U10 picker bridge: a default-disabled ScreenCaptureKit
single-window picker can bind one explicit system choice to the already pinned
Compose action and external process. It rejects a display, multiple windows,
an offscreen window, a changed action/process, or invalid window geometry;
the resulting exact ID and frame match the existing capture-adapter contract.
The selected-window list API requires macOS 15.2, so this picker refuses to
start on older supported systems. The 21 focused picker/capture-adapter tests
pass. This bridge is not connected to a user-facing Compose control, screenshot
capture, OCR publication, or provider dispatch, and it has not been live-tested
with the system picker. U10 remains incomplete.

The next U10 increment adds an inert action controller that requires an
eligible, currently pinned Compose target and a separate live screenshot grant
before showing the picker. A selected window must still match the pinned
process and expected geometry. During capture, the controller rechecks action,
target, permission, and policy across picker, native capture, and OCR work; a
late result is discarded when any authority changes. The controller creates no
grant and is not registered in AppModel. Its focused synthetic checks cover
private surfaces, missing/revoked permission, switched actions, an unexpected
picker window, overlapping requests, and bounded OCR output. No live screen
content was read or made available to a provider by this increment.

The subsequent U8/U10 consent increment adds a one-action, three-minute grant
owner. Beginning a screen-context action grants nothing. A first explicit UI
confirmation can authorize local screenshot capture/OCR; a second confirmation
can authorize extracted text for one exact provider recipient. Changing the
provider, switching actions, expiry, or revocation removes that authority.
No retention grant is issued. Twenty-seven focused consent/policy tests pass.
This owner is not wired into the Compose UI or provider dispatch yet; its
approval methods must only be called from an explicit, reviewable user action.

The next U10 identity check reads the original pinned Accessibility window's
frame only after an explicit screen-context request. The ordinary Compose
shortcut and subsequent focus checks do no additional geometry reads. A
system-picker selection in the same process but at another frame is rejected,
and an application-only capture without verifiable window geometry cannot
activate screen context. This observes only window geometry, not text. The
focused tests cover demand-only frame reads and
same-app wrong-window refusal; live AX/ScreenCaptureKit frame equality and
window-ID reuse remain to be certified on a signed app.

The U10/U12 text-only bridge compiles one complete, high-confidence OCR
snapshot into a bounded local-provider request. The bridge separately
revalidates screenshot capture and exact-provider text transmission consent,
then pins the source hash, action, window, provider and 120-second lifetime.
Visible text is marked untrusted, image bytes are excluded from model input,
and a known model preface is rejected rather than inserted. The resulting
draft has no automatic insertion authority. Focused synthetic checks pass;
two opt-in on-device model cases check a directed reply and a bare reply
without an invented meeting commitment. The production
notch now offers an explicit review/recovery action on macOS 15.2+ for a
currently pinned local-provider Compose request. It asks separately before
local window reading and before the recognized text reaches Apple Intelligence,
shows the OCR preview, and keeps the screen-grounded result copy-only. The
177 focused tests across four controller/coordinator/notch/compiler suites cover approval
order, revocation, action switching, expiry, model wrappers, and insertion
shortcut suppression. The ordinary shortcut path is unchanged. A signed live
window-picker/capture smoke, UI geometry, arbitrary-window compatibility,
recipient-field certification and broader reply quality remain open; U10 and
U12 are not complete.

The following visual check rendered fifteen synthetic notch states offscreen,
including long OCR previews and long copy-only drafts in both floating and
hardware-notch layouts. The first hardware render exposed a duplicated top
inset that clipped the preview and draft. Removing that inset made both texts
scroll within the surface while keeping the approval and Copy controls
visible. The final frame test passed, and entry-state renders show “Use screen”
in the ordinary review and missing-source recovery. These generated frames
verify layout for the synthetic content; live focus, picker, and motion remain
uncertified. The final 15-case native frame test log and PNGs are saved under
`evidence/u10-screen-notch-layout/` in the external recovery staging area;
the log SHA-256 is `11e7694ae2652916d7a62f61fc75b1cd02f15d9e9dbcd32e871b48aa7a04a6c1`.

The next U10 recovery check treats a user-cancelled system window picker as a
quiet return to the original Compose review rather than a screen-context
failure. It revokes the one-action grant and permits a fresh explicit attempt.
The three focused controller/action/picker suites passed 18 tests. A signed
synthetic app invoked the real system-picker API with only the controlled
Compose Test Host window as its intended target, but the available desktop
automation could not access the selection panel before its 60-second timeout. No
window was selected, no pixels were read, and no result was presented as a
successful live picker test. The content-free probe report and source are in
external staging at `evidence/u10-picker-cancel/`; live picker and installed
app behavior remain unverified.

Later September 30 U14 host-Keychain smoke: a standalone ad-hoc-signed probe
used `SystemScribePersistentMemorySecurityBackend` and a unique synthetic
namespace. Three separate process launches created a 32-byte key, reopened
that exact namespace, then deleted the key and confirmed it was absent.
A second three-process probe used that real host Keychain backend with the
production encrypted memory store: it saved a synthetic fact, verified that
the ciphertext did not contain the fact's plaintext bytes, reopened and read
the record in a fresh process, forgot it, and deleted the key. No key material
or fact text was printed or saved in the evidence; temporary files were
removed. The private staging reports are `evidence/u14-live-keychain/report.json`
and `evidence/u14-live-record/report.json`. This certifies a synthetic host
roundtrip, not the installed Cadence signature, review UI, or actual user
consent.

September 30 U2 increment: a short, explicit upbeat schedule announcement now
receives a concrete local-model punctuation cue. The exported production request
generated “Nora, the rehearsal starts at nine!”; 24 focused native tests passed,
including cancellation, uncertainty, compound-message, and no-upbeat exclusions.
Three less specific prompt variants did not improve the exposed case. The
artifacts are under `Build/ComposeRoadmap/U2-upbeat-prompt-probe/`. This repairs
one observed tone miss in development evidence; U2's independent provider
quality gate and the broader roadmap remain open.

September 30 U2 formal-greeting increment: a complete short greeting such as
“Hey, how's it going? Write this formally” now prepares “Hello, how are you?”
locally. The production on-device generation seam returns a prepared draft
without starting model work, avoiding both latency and writer-command leakage
for this bounded case. Quoted uses, recipient instructions, compound requests,
configured styles and cloud requests retain their existing paths. The 42 focused
policy tests and two runtime-seam/coordinator tests passed; this does not change
the historical model-quality score.

Later September 30 U2 casual/concise increment: two complete status-message
shapes now apply an explicit casual or concise voice direction locally instead
of returning a plain model rewrite. The bounded forms keep the named recipient,
subject, status, event and day; uncertainty, quotation, extra instructions,
configured styles and cloud destinations stay on their existing paths. The
exposed independent-Q corpus was rerun as **development evidence**: 16/16
current-source results, with 14 contentful drafts review-ready and both
source-free requests rejected. Only the two targeted draft texts changed from
the prior run; the other fourteen are byte-identical. An agent review rates
14/14 visible direction outcomes and zero critical meaning errors for this
exposed set, with the unchanged judgments carried forward after byte checks.
The 184-test focused direct-policy/coordinator run passed. A broader prompt
cue was tried and reverted because it did not visibly improve either target.
Bound results, native replay, source hashes, semantic notes and the rejected
trial are in external staging at `evidence/u2-casual-concise/`. This is neither
a fresh independent provider-quality pass nor live microphone-to-insertion
evidence; general writing-direction quality remains open.

September 30 U3 increment: a generated coding-agent draft beginning “I fixed
the crash” is now rejected when speech only asked the agent to investigate.
The original transcript remains available and insertion stays disabled. The
guard is limited to explicit coding-agent delegations and first-person completed
actions absent from the speaker's own words. The 25-test Scribe policy suite
and the one-test coordinator path passed. A wider coordinator attempt exposed
an unrelated selected-rewrite expiry failure, then stalled in the next case;
it was stopped and is not counted as a passing checkpoint. U3's broader meaning
and provider-quality gates remain open.

| Milestone | Current status | Evidence or remaining gate |
|---|---|---|
| U1 Quality scorecard | Baseline complete | Bound production requests, real generator manifests, offline scoring, semantic rubric, held-out corpus, repeated-run aggregation, and integrity tests implemented. Three local runs establish the baseline. Original review: 51/69 passes; a later case-limited warmth adjudication yields 48/69 passes, 18 critical and 3 minor failures, zero generation failures. Original evidence is preserved. New evaluator runs distinguish content-free timeout, busy, cancellation and other model failures; older artifacts lacking this field remain explicitly unspecified. Quality gate fails; evidence collection succeeds. |
| U2 Writing directions | In progress | Typed interpretation, bounded recipient/setup framing, and missing-source recovery implemented. Three uncapped, 30-second-deadline development runs completed: 66/69 pipeline passes, 63/66 model passes, 3/3 prepared passes, three minor warmth failures and zero critical failures. Outputs exactly match the individually reviewed previous candidate; grades are explicitly carried forward after byte-equality verification. The direct coding-question result is deterministic formatting, not better model reasoning. The cold held-out run scored 9/16 acceptable, five critical and two minor failures: lost recipient/uncertainty, invented missing-source content, omitted restrictions, and literal metadata output. Bounded parser/guard regressions repair four observed classes. Direct-draft validation now also rejects a provider result that repeats an exactly recognized edge writing command, while preserving literal quotations and recipient instructions; this prevents review/insertion of that known failure but does not improve generation. Deterministic routes preserve a narrowly recognized uncertainty reply and a simple attendance decline with a trailing private-reason direction; neither demonstrates better model reasoning. A bounded formal-greeting shortcut returns an exact draft without local-model latency; its 42 focused policy tests pass. A new exact named-recipient guard rejects the observed Nora omission before review or insertion; it does not make the provider more likely to write the desired upbeat draft. These cases are now exposed development evidence, so future independent quality claims need a fresh reserve. |
| U3 Meaning and exact details | In progress | Added rejection of the literal-metadata output observed in the real baseline and byte-exact Unicode validation. Narrow recipient-restriction checks now reject drafts that omit explicit no-change/file/code limits; original words remain available. The restriction/coordinator/performance run passed 58 tests. A 30-second deadline and removal of the silently truncating response-token cap passed the full native checkpoint. Native saved-result replay exposed one false restriction rejection for a direct Codex address; a narrow fix and regression pass. Unquoted relative file paths now become byte-exact source obligations; whole-token validation rejects changed filenames, prefixes and suffixes. Broader semantic validation remains. |
| U4 Provider capability | In progress | Immutable text-only capability profiles and request-budget gate implemented. Profile revision 3 separately permits local draft refinement and selected-text rewrite; cloud profiles remain direct-draft only. A pinned direct-only local profile cannot dispatch a selected rewrite. Quality certification remains separate. Coverage included in the latest 83-test coordinator/capability run. Provider-specific quality matrix and broader certification remain. |
| U5 Insertion and recovery | In progress | Two earlier unlocked controlled runs passed 14/14; the expanded September 25 standalone runs passed 15/15 and then 16/16 native/web cases. The new cases inject event creation failure after one real posted character and switch foreground focus to a second synthetic host process. A subsequent 17/17 standalone run proves a capture cannot post twice after a complete or uncertain insertion; the service also fences overlapping posts, rejects a capture cleared during asynchronous preflight, and checks cancellation before posting. Thirty focused context-service tests pass. The host observes exactly the one-character prefix in the first case; production refuses the second before any insertion call, and both editors stay empty. A coordinator admission guard prevents simultaneous polished/unpolished Insert actions from posting twice; uncertain posting preserves Copy but blocks another automatic Insert, retry or refinement. Production completion copy and diagnostic status say insertion was attempted, not confirmed. Clipboard failure reports failure without saved history or success feedback through an injectable commit seam. Actual AX/CGEvent insertion succeeded for native fields, WebKit textarea/contenteditable, Unicode, multiline and a cursor-hint editor; changed-field/window, cleared capture, secure/noneditable and dead-process refusals passed. The current-source standalone host run passed 18/18 native/WebKit cases, including the new cross-bundle focus refusal. The first cross-bundle trial safely refused insertion but returned a generic error; production now reports target-changed when the live frontmost PID differs, with 31 focused context-service tests passing. Cancellation and clipboard-failure regressions passed 14/14 and 20/20 focused tests. The original XCTest runner still lacks Accessibility trust. Independent Muse readback, broader installed-app certification, and naturally occurring partial-event failure remain; the user confirmed one installed Muse Insert trial on September 29. |
| U6 Responsiveness and motion | In progress | Content-free timing now starts at the recognized Compose shortcut in AppModel and spans permissions, provider preflight, transcription configuration, target pinning and microphone listening, using one action ID. Focused coordinator/timing tests pass. A local debug log reports recognized-shortcut-to-listening time without content. The default Fn+Control Compose chord now waits 160 ms before recognition instead of 240 ms; the single-Fn Dictation gesture and custom modifier-only shortcuts retain 240 ms. The log excludes that gesture wait. Actual app timing baseline, measured end-to-end improvement, and expanded frame evidence remain. |
| U7 Voice refinement | In progress, narrow synthetic gate passed | Local-only Refine/Undo, immutable version binding, literal guards, retained recovery, and synchronous Dictation interruption fence implemented. A bounded named-recipient warmth cue and three validated, deterministic revisions repair unchanged local-model outputs for specific message forms. The fresh frozen eight-case first run produced eight review-ready effective drafts, three bounded revisions and no unchanged drafts; all eight passed manual instruction and meaning review. Other unchanged outputs still retain the existing version and report no changes. Controlled UI and installed-app certification remain. |
| U8 Context controls | In progress | Separate deny-by-default capture, retention, and transmission policy implemented and native-tested. TextEdit-only selected-text settings, disclosure, revocation cancellation, and coordinator wiring pass the latest combined checkpoint; defaults remain off. A separate, development-only document-identity preview now requires both memory/adapter rollout switches plus explicit TextEdit settings; it grants no fact retention or provider transmission. The one-action screen-consent owner is now connected to two separate affirmative controls in the production notch: local window reading, then previewed OCR-text use by the on-device provider. It grants no retention and expires after three minutes. Focused consent/policy and screen-review checks pass; signed live permission and picker behavior still need certification. |
| U9 Accessibility text | In progress, narrow selected-rewrite gate passed | Invocation-bound selected-text capture, local rewrite, source revalidation, guarded replacement, and contextual no-history behavior remain. Actual on-device baseline yielded 2/8 useful edits; later first-run reserves A and B failed at 5/8 and 6/8, and their exposed development repairs are kept separate. A fresh frozen reserve C passed its predeclared narrow gate: 8/8 model calls generated, 7/8 effective review-ready drafts made the requested edit, one off-pattern quote case stayed unchanged, and no critical unsafe accepted draft was found on manual review. Six successes came from bounded local transformations after unchanged model output; the model made the two-bullet edit. The local rules preserve exact quoted text, paths, flags, names and uncertainty and still pass the production output guards. This does not establish general rewrite quality or live Accessibility replacement, installed-app behavior, or other-provider quality. |
| U10 Screenshot context | In progress | Service rechecks live policy/target across asynchronous boundaries and before publication, with a total deadline and whole-line UTF-8 bounds. Vision OCR uses synthetic images and reports ambiguous separated columns; 29 screen-context/adapter and 10 OCR tests pass. An explicit ScreenCaptureKit adapter and single-window picker bind a user-selected ID to the pinned process on macOS 15.2+ with exact-window/process filtering and capture bounds; 21 earlier picker/adapter tests passed. The original pinned AX window frame is read only on an explicit screen-context action, and a different same-app window is refused. The production notch now joins two separate affirmative approvals, picker choice, exact capture, OCR preview and on-device provider dispatch for one copy-only draft. A source-free reply failure can use the same recovery route; 177 related focused tests pass. No screen read is added to the ordinary shortcut path. Live AX/ScreenCaptureKit frame equality and same-process window-ID reuse at the same frame remain uncertified. |
| U11 Conversation identity | In progress | Strict adapter evidence and isolated durable/transient identity resolver implemented; 18 isolation tests pass natively. A TextEdit saved-document adapter reads AX identity metadata, pins a window incarnation, and derives an opaque file identity; seven synthetic adapter tests pass, including replacement of a file at the same path, close/reopen binding isolation, and process-restart key recovery. Controlled September 25 TextEdit AX probes confirmed A→B→A scope separation, closed-window invalidation, same-key recovery after reopening and process restart, and refusal of a replaced file while the editor still displays old contents. An unsaved document receives no durable binding. An action-scope service admits identity only for the current authorized action/target and rechecks it after async work. The coordinator schedules the TextEdit adapter after microphone startup for the separately opted-in session-memory flow; this runtime path has synthetic lifecycle tests but no installed-app certification. Current Codex native AX metadata has no verified thread key in the probed view, so cross-thread memory remains denied. |
| U12 Grounded drafting | In progress, selected rewrite wired | The local compiler now serves runtime selected-text rewriting through the context controller. Invocation-only selection authority carries no conversation memory key and cannot authorize a reply. Full-source provenance, voice/source literal obligations, byte budgets, 120-second freshness and consent checks reach generation, review and insertion preflight. Existing prompt bytes are preserved across all eight saved evaluation cases. Explicit coding-agent requests, including fix, remove, and rename tasks, now carry written relative file paths and command flags as byte-exact provider obligations. Whole-token checks reject changed path or flag suffixes, and a rename task cannot use literal-mutation wording to drop its old file target. A recipient-facing Codex/Claude prompt may omit the agent's name while human addressees remain required. The affected Scribe policy, direct-draft, and coordinator suites pass 211 tests. A bounded complete inspection request with a backticked file path removes only the spoken "Ask Codex" frame and bypasses local model work. The evaluation exporter, direct replay, and refinement replay now apply the same coding-target literal derivation as runtime. A fresh four-case synthetic local-provider corpus with three greedy runs generated 12/12 drafts; all passed production review checks and agent semantic review, with no critical error. These four exposed cases do not close broader coding-prompt or real-app quality. A separate explicit, copy-only screen recovery can draft from previewed OCR text when a reply has no selected source. It does not certify the conversation or a recipient field. General replies still require distinct certified fields; relevance, contradiction detection, broader coding-prompt assembly, live adapters and semantic grounding evaluation remain. See [grounded context](scribe-grounded-context.md). |
| U13 Session memory | In progress | Typed scoped records/provenance, ephemeral store, correction tombstones and expiry/isolation/revocation pass native tests. Default-off runtime voice commands now save, inspect, forget and correct explicit facts for a verified saved TextEdit document. A separate default-off control permits relevant facts in a local draft, pinned to one action; changed or revoked facts invalidate the reviewed draft before Copy or Insert. Fact-backed drafts stay out of ordinary history. A short generic follow-up can use the sole explicit fact in that verified document; multiple facts prompt the user to name an issue before generation. Another default-off control retains a user-chosen reviewed draft after successful Copy or confirmed Insert for the same verified document, labeled without delivery proof and excluded from facts and generation. Its 21 focused tests pass. Two synthetic on-device model cases passed, including the generic follow-up; broader quality and installed-app certification remain. |
| U14 Persistent memory | In progress, source voice and local-draft paths wired | Typed AES-256-GCM manifest, explicit save proposals, durable revisions/deletion, exact-scope access, correction lineage, bounded nonblocking IO and corruption preservation pass native tests. The Keychain lifecycle has synthetic provisioning/deletion and path-isolation coverage; later host-Keychain smokes created/deleted a unique synthetic key and reopened/forgot an encrypted synthetic record across processes. Closed-app ciphertext and external backups are outside immediate deletion guarantees. A versioned namespace owner preserves identity across reopen and refuses orphaned or moved state. A separate default-off consent policy requires the current durable-retention disclosure, limits TextEdit records to 30 days, and issues no cloud grant. AppModel constructs the runtime inertly; a separate default-off rollout gate permits only previously confirmed reopening. Settings presents activation and global deletion confirmations with retention and backup terms. Exact voice commands save, inspect, correct, or propose forgetting facts for a verified TextEdit document without provider dispatch, insertion, or history; destructive actions have review and revision checks. A second default-off switch permits relevant saved facts only in a local Apple Intelligence draft. Its fact IDs, text, and use revision are pinned; deletion, correction, or revocation invalidates the dependent draft before review, Copy, or Insert. The latest focused 167-test run passed across coordinator, action-scope, and presentation suites. Review can discard a fact-backed draft and regenerate from the same speech without all facts or one chosen fact; repeated omissions compound across session and saved facts, and a duplicate in both stores is omitted from both. The replacement action rebinds only the verified pinned document, with no new focus capture; stale documents or changed facts stop provider dispatch. Installed-app review interaction, encrypted-record roundtrip under the app signature, and full release certification remain. |
| U15 Writing preferences | In progress | Typed scoped resolver has 17 native tests. Global tone/concision defaults now have explicit Settings Save/Cancel/Reset, versioned local persistence, stale/corrupt recovery and recording-time runtime snapshots. Configured app profiles and current voice take precedence; selected rewrite/refinement preserve their separate boundaries. Production model baseline: 2/6 acceptable, four unchanged, zero critical; quality gate fails. A 3/6 focused-prompt experiment introduced a critical question-answering error and was reverted. A later bundled-preset candidate produced drafts byte-identical to baseline on all six cases and was also reverted. A versioned explicit-save scoped archive now round-trips closed choices for opaque app, project and conversation keys, rejects temporary actions and malformed keys, and preserves unreadable or newer data until explicit recovery. An explicit edit controller commits a typed choice to the archive before publishing it in the active snapshot; stale writes leave both unchanged. The scoped archive and edit store pass 11 focused native tests across two suites. A named TextEdit profile is now editable in Settings with Save/Cancel/Reset, stored under the current macOS account and TextEdit integration key, and snapshotted into Compose after audio starts only for the pinned system TextEdit app. App fields override conflicting global fields and current voice wins at compilation. The final focused TextEdit/coordinator run passed 136 tests across two suites, including an after-audio-start snapshot check; the 11 archive/edit-store tests also passed. The generic scoped edit controller still needs a verified target-scope supplier and user surface for other apps, projects and conversations. An isolated Debug Settings fixture showed the full section without clipping and confirmed Save/Cancel/Reset state changes. Settings now identifies when a configured TextEdit app profile supersedes these saved choices and uses accurate Reset/recovery notices; 3 focused native tests pass. A hand-built reminder prompt left all six production-model outputs byte-identical to baseline and was rejected. A guarded short-prompt experiment repaired the earlier question-answering error and scored 3/6 with zero critical failures, but still failed the quality gate and was not shipped. Model quality, per-field profile integration, suggestions, installed-app interaction and live dictation certification remain. See [writing defaults](scribe-writing-defaults.md). |
| U16 Quiet controls | In progress | Selected-source inspection and action-scoped exclusion are wired into the notch and debug panel. Exclusion keeps the previous draft visibly attributed, blocks insertion/retry, and invalidates a pending generation. Inspector focus suspends draft shortcuts; stale popover callbacks cannot change newer focus ownership. Six offscreen selected-source variants fit and were inspected. An explicit replacement recording suppresses selection capture for that one action. Refresh selection re-reads the original field under a new action and snapshot, while Retry preserves the old snapshot. The facts cue opens an inspector of the exact frozen session and saved facts used for that draft on both review surfaces; inspecting suspends review shortcuts. Regeneration can omit every fact or one chosen fact. Individual omissions accumulate across both memory stores, retries retain the excluded set, and changed source facts block dispatch and use of the draft. Eight short, six-fact, long-fact and requested accessibility-size light/dark renders fit and were visually inspected. Enabling Reduce Motion mid-typing or dismissal now settles the current state; focused model tests pass. Additional context categories and native popover/focus/frame certification remain. |
| U17 App adapters | In progress | A per-surface TextEdit candidate record now distinguishes generic drafting/insertion from selected rewrite, saved-document identity, session facts and persistent facts. The identity adapter requires Apple's system TextEdit path and an exact focused editor/window signature; nine focused native tests and a current-source synthetic saved-document probe pass. Current-source TextEdit insertion and selected replacement passed exact synthetic readback in a fresh saved document; memory actions and signed installed-app certification remain. ChatGPT, Codex, Muse and browser conversations have no identity adapter or memory support claim. |
| U18 Release resilience | In progress | Production local generation has one shared admission permit, released only after actual work finishes, plus monotonic timeout/publication checks. Cancellation-resistant work cannot accumulate overlapping model operations. Separate context, memory and adapter rollout flags resolve with master/context hierarchy. The context kill switch prevents the selected-text controller from receiving active preferences and hides its Settings control while retaining stored user choices. Memory and adapter flags default off and gate the TextEdit identity path used by separately opted-in fact retention and local draft use. The latest copied-source full native checkpoint passes 1,271 tests in 112 suites. Migrations, live gate certification and full release evidence remain. |

Evidence under `Build/ComposeRoadmap/` is local and ignored by Git. Example-draft scorer demonstrations are labeled synthetic examples, not model results. Software tests use synthetic requests; this work has not enabled background context collection. Historical statements below about an unchanged installed app describe their respective earlier checkpoints.

## Muse insertion increment, September 29 — user trial passed

The bounded goal was Compose insertion into Muse's focused chat composer. The user first reported that the formal-rewrite live trial “works,” then confirmed “it was” Muse. This is a user-reported pass for recording, review and Insert into Muse on the installed Cadence Release, not a claim about all Muse conversations, other editors or future Muse versions. The installed Muse 4.1 (build 1077426479, bundle `com.meta.endo`) opens its chat composer; the accessibility surface exposes a combined Message button. Local version and source hashes are recorded without chat content in `Build/ComposeMuseTrial/surface-baseline.json`. The existing capability policy accepts a button only when it has the text-cursor hint; the synthetic test uses a placeholder bundle ID and cannot establish whether this Muse instance supplies that hint. The existing dirty checkout and single installed Cadence app remain unchanged in this increment.

A read-only probe using production `SystemDictationTargetCapabilityService` confirmed Accessibility trust, but classified the focused element as unavailable because Muse was not the system-frontmost app. Raising its window through the available UI control did not make it frontmost. That probe remains inconclusive about editor capability; it does not negate the subsequent user-reported live success. No text was posted by the probe and no private chat content entered the evidence report.

The existing target-capability and Scribe-context-service suites were rerun against the current source without changing the harness: **44 passed, zero failed, one skipped**. The skipped case was `TextInsertionCapabilityTests.cancellationAfterOneCharacterStopsPostingAndReportsUncertainty`, reported by XCTest as “Test cancelled”; this run cannot claim that case passed. Summary: `Build/ComposeMuseTrial/focused-test-summary.json`. The run checks synthetic cursor-hint and guarded insertion policies, not the real Muse editor or installed app.

The previously missing live result is now provided: the user confirmed the successful Compose Insert was in Muse. No Muse-specific failure reproduced in this installed trial, so production insertion behavior was not changed and no new Release build was needed. The installed executable hash still matches the signed candidate the user tested; exactly one `/Applications/Cadence.app`, 43 tracked modified files, 130 untracked entries and zero staged entries were preserved at close. Independent Muse readback, other input states and future Muse versions remain unverified. This goal is complete at its one-user-visible-improvement scope; U5's broader cross-editor certification remains open.

## Formal uncertainty increment, September 29

This completed increment preserved uncertainty during a formal rewrite. Completion required the reported compound statement to retain both lack of certainty and tentative optimism; a short “I think” statement to remain tentative; writing directions and assistant introductions to stay absent; focused production-policy/coordinator checks; and one user-reported microphone-to-insertion trial. No other roadmap capability advanced during this increment.

A five-case current-production Apple Intelligence baseline reproduced “I think the draft is ready. Write this formally” as “The draft is ready.” The formal on-device prompt now names recognized first-person uncertainty phrases, without preparing or substituting the draft. A direct-draft guard rejects missing qualifier classes before review and insertion while accepting common synonymous forms. Quoted/literal requests and explicit corrections retain their existing handling.

Focused verification passed **57/57 native tests**, including mocked coordinator acceptance/insertion and rejection/recovery. Five subsequent actual Apple Intelligence calls all used `MODEL_GENERATION` and passed production output validation. The three uncertainty cases retained their qualifiers and statement meaning on a limited semantic review; the greeting control remained clean. The confident control stayed confident, but paraphrased “I know what I’m doing” into confidence about successful actions, so it is not evidence of complete factual preservation. No broad quality percentage or cloud-provider certification is claimed. The guard checks qualifier presence and count, not the qualifier's semantic attachment, and does not cover every form of uncertainty.

Bound baseline and revised inputs/results, the native test summary and local build log are under `Build/ComposeUncertaintyTrial/`. The requested live Compose recording-to-insertion trial was reported as working by the user; the editor identity and broader app compatibility remain unverified. The existing test harness was reused; no screen context, memory feature, or broad test-suite expansion is part of this increment.

A Developer ID signed Release replaced the single `/Applications/Cadence.app` installation and launched successfully. Its executable matches the candidate; exactly one Release process and no Debug process were verified. The prior working installation is preserved at `Build/ComposeUncertaintyTrial/PreviousCadence.app`. This is a local unnotarized trial from the preserved dirty checkout, not a distributable release. The user replied “works” to the requested live recording and insertion trial, satisfying this goal's live check. That is user-reported acceptance for the tested editor, not software certification of every app or provider. The goal is complete. No next feature was started in this increment.

## Formal greeting increment, September 28

This increment fixes one message: “Hey, how’s it going? Write this formally,” including the version without a question boundary. A current-source production Apple Intelligence baseline rewrote the punctuated form but copied the unpunctuated command into its draft. The parser now recognizes only a complete short greeting followed by this explicit formal-writing command. Recipient instructions and quoted or protected commands keep their existing boundaries. Known formal-rewrite introductions are rejected by the existing post-generation validation seam rather than stripped.

The two focused native suites passed **51/51** checks. Three actual Apple Intelligence calls, with no prepared-draft shortcut, produced “Hello, how are you?” for both formal requests and preserved “Hey, how’s it going?” for the plain control. All three passed production validation and the bound evidence checks; interpreting these three drafts is a limited semantic assessment, not a general provider quality score. Local artifacts are under `Build/ComposeFormalTrial/`. A signed Release build replaced `/Applications/Cadence.app`; the previous installation is preserved at `Build/ComposeFormalTrial/PreviousCadence.app`. Microphone recognition and live Compose review-to-insertion for this exact request remain unverified. The trial is local and unnotarized; broad instruction following and full U2 certification remain outside this increment.

## Local insertion trial, September 27

The current-source standalone insertion suite passed **18/18** native/WebKit cases in `Build/ComposeRoadmap/cadence-compose-U5-cli.B2XQF0/integration-report.json`. Focused native checks passed 31 context-service tests, 14 insertion-capability tests, and six coordinator insertion tests. A wider coordinator run was stopped after selected-text source tests failed; it is not a broad-suite pass or an insertion failure. The existing TextEdit production-service probe passed ten fresh exact insertion/replacement runs, but an earlier run with the same source and binary hashes failed `insertionReadbackMismatch`. The probe now records a content-free readback classification on future failures; the cause of that earlier mismatch is still unknown. Muse insertion and a naturally occurring partial event remain unverified.

A Developer ID signed Release candidate from this dirty checkout replaced the single `/Applications/Cadence.app` installation and launched locally. The prior app is preserved at `Build/Goal1Trial/PreviousCadence.app`; the candidate build is at `Build/Goal1Trial/DerivedData/Build/Products/Release/Cadence.app`. Its embedded source commit is the shared baseline HEAD, **not** a reproducible identifier for the uncommitted changes. The candidate is unnotarized because the local `cadence-notary` keychain profile is absent; Gatekeeper assessment rejects it as a distributable app, though the unquarantined local installation launched. This is a trial build, not a release artifact or completion of insertion certification.

The user reports that insertion works in this trial, but Cadence comes to the foreground **after pressing the recording trigger**, before Insert. The destination was not specified, so this is user-reported insertion evidence rather than a certified Muse case. Source inspection found no explicit main-window activation in the normal shortcut/start-recording path; the recording pill's native panel cannot become key or main. Temporary focus diagnostics run while the desktop was locked are inconclusive.

An unlocked live check identified a stale **Cadence Debug** process (PID 13379) running for more than a day from Xcode DerivedData alongside the installed Release app (PID 25235). The actual trigger was registered as `Press to Dictate`, not Compose. At 20:22:03 on September 27, the Debug process logged that trigger immediately followed by `Cadence main window requested` and `Main window visible=true`; the user confirmed the window jumped forward after starting from TextEdit. The stale app was inspected with no active recording shown, then quit normally. Process verification now finds only the installed Release app. No production focus code or installed binary was changed for this correction. The user subsequently confirmed that the repeat trigger **does not jump forward**. This closes the reported foreground regression for the installed trial; it does not certify all Compose surfaces or resolve the separate earlier TextEdit readback mismatch.

U17's first per-surface candidate and remaining certification gates are recorded
in [the Compose surface capability record](compose-surface-capabilities.md).
The September 27 TextEdit path/surface test log is
`/tmp/cadence-u17-textedit-surface-tests.log` (9/9 focused native tests). A
later unlocked, current-source probe passed saved-document identity on a newly
launched TextEdit 1.20 (415) instance containing only a synthetic file. The
content-free, source-hashed report is
`Build/ComposeRoadmap/U17-textedit-surface/current-source-report.json`; its
privacy scan passed. This verifies one development identity case, not
installed-app insertion, selected replacement or memory behavior.

A subsequent one-off current-source Swift probe called production
`ScribeContextService` and `TextInsertionService` on a new synthetic TextEdit
document. The first immediate AX read preceded queued events; a bounded
readback then observed the exact expected text once. The source for this
successful development observation is retained at
`/tmp/cadence-u17-textedit-insertion.swift`. The reusable
`tools/ComposeTextEditSurfaceProbe/` implementation now compiles with `--check`
and records a content-free, source-hashed result on `--run`. Its first live
attempt wrote `current-source-insertion-report.json` with `blocked_desktop`
before opening TextEdit. The next unlocked run passed both verified identity
and exact production-service insertion readback in a newly launched synthetic
TextEdit 1.20 (415) document. The report binds source, Debug library and probe
hashes; its privacy scan passed. Selected replacement, memory actions and a
signed installed-app run remain.

U18 privacy evidence now fails closed when any requested artifact is missing,
is a symlink, or the recursive scanner errors. The scan does not echo matched
canary values or filesystem paths. The focused script suite verifies clean,
leaked, missing, explicit and nested symlink, and scanner-failure cases
(6/6 passing). The focused native contract
wrapper also refuses to claim success when its test-log directory is absent.
This verifies the evidence gate, not the complete release or privacy behavior.

The initial local-model baseline used macOS 26.6.2 (25G83), the production Foundation Models generator, greedy sampling, and a 1,024-token output limit. Its p50 generation time was 10,218 ms and p95 was 11,065 ms across 69 calls. These are model-call timings, not shortcut or app-animation latency. Semantic grading is agent-assisted judgment against a fixed rubric, not deterministic proof. Identical drafts repeated across the three baseline runs; hashes bind each distinct execution artifact and its review. See `U1-production-baseline/aggregate-baseline.json` for the full denominator and failure categories.


The warmth adjudication changes only the identical `tone-first` output in the
three baseline reviews. It is a review correction, not a product regression.
Alternate review files and `aggregate-baseline-adjudicated.json` coexist with the
original artifacts under `U1-production-baseline/`. The latest single-run
`U2-direct-recipient-plan/` result uses the old 1,024-token setting; it is not
combined with the upcoming uncapped, deadline-bound generator runs.

The latest broad native checkpoint reports **1,134 passing tests in 104 suites**;
log: `/tmp/cadence-u5-focus-fallback-broad-20260925.log`.
One real desktop-focus test was explicitly excluded: an isolated run on the
unlocked console failed because the XCTest app never became active. The opt-in
original XCTest insertion harness stopped before opening the synthetic host
because that test process lacks Accessibility trust. Its report is
`Build/ComposeRoadmap/cadence-compose-U5.Hd0buO/integration-report.json`, with
zero passed editor cases. The separate trusted standalone runner has since
executed two 14/14 controlled-host runs, detailed below. The latest broad
runtime log passed the privacy-canary scan and `git diff --check`.

The standalone runner's initial build-only check passed. Its actual executable
reported Accessibility trust; the first wrapper's locked-desktop preflight wrote
`Build/ComposeRoadmap/cadence-compose-U5-cli.3FnV39/integration-report.json`
with `blocked_desktop` and zero completed cases. No synthetic host process was
launched. Subsequent unlocked runs are recorded below.

An earlier focused 76-test coordinator/compiler run also verifies contextual recovery, including rejection
of the actual quoted-source failure and a valid retry that inserts the rewrite
through the mocked production insertion boundary. Real Accessibility insertion
remains blocked by permission for the test build, independently of the lock.

Fresh U7 and U9 model artifacts use generator SHA-256
`c129c4db695db019661dd3ed8ca6b6ad9117f7e8deb8ae7e0dc1b5768b743b9b`.
`U7-refinement-task-first-bounded/aggregate.json` records 3/8 passes;
`U9-selected-rewrite-baseline/aggregate.json` records 2/8. Both semantic gates
fail. The fixed-rubric reviews are agent-assisted judgments; integrity and native
policy replay do not turn them into deterministic semantic proof. Frozen older
generator runs remain separate. Prompt prototypes under `U9-prompt-experiment/`
are experiments, not the current production compiler.

No app installation, commit, push, context activation, or persistent-memory
retention was performed by these increments.

Latest focused checkpoints:

- Coordinator and provider capability: 83 tests passed; contextual no-op notices,
  literal recovery exclusions, valid retry and distinct dispatch capabilities.
- Selected-output replay: eight integrity/replay tests passed. The saved baseline
  yields seven review-ready outputs and one rejected quoted-source failure; five
  of those seven carry the unchanged-selection notice. Only two baseline outputs
  passed the separate writing rubric. Report: `U9-selected-rewrite-baseline/current-policy-replay.json`.
- Grounded request compiler and selected runtime: included in the latest broad checkpoint. The earlier 18-test pure compiler foundation is now extended and wired for selected rewrites; no native capture or model quality is inferred from these tests.
- Persistent store and Keychain lifecycle: 43 tests passed. Keychain calls use an
  injected backend; encrypted-file tests use synthetic temporary files.
- Offline evaluation tooling: 39 Python tests passed. Selected-source corpora can
  omit advisory phrase annotations without changing their original evidence hash;
  the report labels the absence of phrase checks and keeps semantic grading separate.

The earlier focused runtime logs passed the privacy-canary scan. The desktop-focus
and real-insertion gates remain open despite the September 23 unlocked session.

U15 global-default implementation and its six-case model evaluation are documented
in `docs/scribe-writing-defaults.md`. The focused U15 compiler experiment was reverted. A subsequent deterministic
reply-placement increment changes prepared-draft eligibility and honors saved
app/environment styles; the current policy is therefore no longer byte-identical
to the frozen U15 baseline. Historical evidence remains bound to its saved inputs.
This work did not enable global settings in the installed app. No app replacement,
real context capture, or new cloud-provider selection was performed.

## Narrow reply-placement repair

The original `U2-cold-holdout/run-1.json` generated “The draft is ready.” from
“I think the draft is ready. Write it as a reply in Slack.” Its original failed
grade is preserved. The current compiler can now return the entire already-worded
uncertainty statement directly when reply placement is the only recognized
writing direction. This is deterministic formatting, not a successful model
rewrite or a general semantic guard. It does not change the insertion target.

Supported messages are one short first-person uncertainty statement, with no
recipient frame, unresolved source, correction, quotation, question, multiple
sentences or additional writing task. The full retained message is preserved
byte-for-byte. Tone/length directions, global defaults, configured app guidance,
remembered environment preferences and explicit legacy styles use generation.
The saved-style gate also applies to the existing coding-question shortcut,
repairing its ability to skip an explicit app profile.

Focused production compiler/generator checks passed **29 tests in three suites**:
`/tmp/cadence-compose-unbounded-20260922/uncertainty-reply-tests.log`. The tests
include the exact observed source/output pair, six statement variants, twelve
unsupported/ambiguous cases, byte-exact Unicode, saved-style precedence and proof
that neither the injected model operation nor timeout starts for the prepared
reply. The privacy-canary scan passed. No new real-model quality percentage is
claimed, and uncertainty preservation during style rewriting remains open.

## Private-reason attendance decline

The exposed held-out request “Tell Eli I cannot join the call, and keep the
reason private” previously produced “Eli, I cannot join the call, and I will
keep the reason private.” For a single already-worded attendance decline in
the recognized named-recipient frame, the local compiler now prepares “Eli,
I cannot join the call.” The prepared draft bypasses model generation and
remains subject to the ordinary review and output guards. A supplied reason,
additional sentence, separate style request, quotation, recipient-facing
privacy request, or remote provider stays on its existing path. This repairs
the observed local case without claiming general private-reason understanding.

## Grounded selected-rewrite runtime integration

`ComposeSelectedTextContextController` now issues a `ComposeGroundedCompilation`
from the captured selection and live policy. `ScribeCoordinator` dispatches that
compilation's prompt, uses its output obligations and rechecks its authorization
and expiry before accepting or exposing a result and during insertion preflight.
The existing native selection revalidation remains the final content check.
This does not activate capture, conversation recognition, memory or reply routing.

The compiler distinguishes invocation-only field identity from verified
conversation fields. A replacement requires the same complete selection;
invocation-only identity cannot authorize a reply to a different field, and has
no conversation memory key. Runtime provenance records the exact source snapshot,
one included section and its byte count. Required source content is never
silently truncated. Prepared output contains no local authority identifiers.

The existing selected-rewrite prompt is preserved byte-for-byte, including saved
writing defaults. All eight saved baseline requests matched the current compiler
in native replay. The fresh report at
`Build/ComposeRoadmap/U12-selected-runtime/current-policy-replay.json` binds 18
current source files and reports seven review-ready outputs, one rejected
quoted-source failure and five unchanged notices. This is not a fresh model run;
the original quality result remains **2/8 acceptable**. Earlier reports remain
historical, source-bound evidence.

Additional tests cover scope separation, exact payload boundaries, no source
truncation, expiry before dispatch/during generation/at Copy, revocation, cloud
rejection, forged source values, oversized output, retained provenance, and
byte-distinct canonically equivalent quoted literals. An ended request no longer
offers a dead retry action. The snapshot is bounded to 120 seconds for use;
expiry is checked at use boundaries, not a promise of immediate background erasure.

The final broad checkpoint for this integration passed **1,073 tests in 100 suites**:
`/tmp/cadence-compose-unbounded-20260922/grounded-runtime-final-tests.log`.
It retains the explicit desktop-focus exclusion, and the opt-in real insertion
harness did not run. The runtime privacy-canary scan and `git diff --check` pass.
No installation, commit, push, personal capture or cloud-provider change occurred.

## Quiet selected-source controls

The selected-text indicator now opens an inspector showing the exact source used
by the reviewed draft. Opening checks current authorization/freshness. Both the
notch and debug panel use the same inspector. Exclusion is bound to the source's
snapshot ID and the current action; it does not modify capture preferences or
future requests. It preserves the previous source/draft attribution, disables
insertion and retry, and invalidates a pending provider attempt. Explicit Copy
can still copy the labeled previous draft; its history exclusion remains intact.
Revocation, expiry at use and cancellation keep their stricter clearing behavior.

With only one selected source, exclusion leaves no material to rewrite. The
inspector offers **Record new message**: explicitly discard the old draft and
record a complete replacement without reading selected text for that action.
The ordinary Record Again route also honors exclusion. A subsequent independent
request resumes the configured capture preference. Multi-source exclusion and
regeneration remain open.

The source inspector suspends global draft shortcuts and copied-review outside-
click dismissal while open. Closing it restores only eligible commands; an
excluded draft cannot acquire an Insert command. Source-ID checks prevent late
popover callbacks from changing keyboard ownership for a different source.

The session-facts inspector now uses one shared production popover content view
on the notch and panel. Eight offscreen renders cover one fact, six facts, a
long scrolling fact, and a requested large Dynamic Type category in light and
dark appearances. The layout test passed all eight cases and the images were
inspected under `Build/ComposeRoadmap/U16-session-facts-inspector/`. The long
fact remains inside a bounded scroll area while the explanation and Done
button stay visible. On this offscreen macOS host, requesting an accessibility
Dynamic Type size did not visibly enlarge the text; actual large-text behavior,
keyboard scrolling, native popover focus, and motion remain unverified. The
privacy-canary scan passed. No personal facts were rendered or stored.

The same inspector now offers **Regenerate without facts**. It explicitly
discards the current fact-backed draft after rechecking its target and source,
then reuses the spoken request under a new action ID with no session-memory
retrieval. Retry of that replacement action remains fact-free; the saved facts
stay in the current document's session memory for later independent requests.
The inspector source ID is the draft action ID, so a stale control cannot act
on another draft that happens to share the same memory-consent revision. The
final coordinator run passed 112 tests; a separate presentation run passed 17
tests, and the bounded inspector layout passed its 14 parameter cases. All eight
fact-inspector
light/dark renders were inspected with the new control. The privacy-canary scan
and `git diff --check` passed; artifacts are in
`Build/ComposeRoadmap/U16-fact-free-regeneration/`. This is source and synthetic
UI evidence, not an installed-app or native-popover interaction check.

The inspector also offers **Regenerate without this fact** for each fact when
more than one is present. A replacement draft keeps the other frozen facts;
removing another fact accumulates the exclusions. The coordinator compares the
full original fact set before every dispatch and before Copy or Insert, so a
changed, expired, or revoked fact invalidates the replacement rather than
silently changing its context. Removing the last fact creates a transcript-only
request. The saved facts remain available for later independent requests.
Focused coordinator, presentation, and layout checks passed **132 tests in
3 suites**. The separate inspector export passed **2 tests** and produced
eight light/dark synthetic variants; the privacy-canary scan and
`git diff --check` passed. Native popover interaction, focus, motion, and
installed-app behavior remain unverified.

Changing the macOS Reduce Motion setting while the notch is typing or
dismissing now cancels its cosmetic transition, resolves the current surface
size without animation, and renders the current content under that setting.
The focused `ScribeNotchViewModelTests` run passed **8 tests in 1 suite**;
`git diff --check` and the runtime privacy-canary scan passed. This verifies
the state transition, not native display motion. A separate focused render
check passed four synthetic cases: short and long ready drafts, an actionable
failure, and a typing state with Reduce Motion enabled. The four exported
frames were visually inspected under
`Build/ComposeRoadmap/U16-motion-checkpoint/`; the notch remains readable
under both light and dark host appearances because production forces dark
content on its black surface. These are static offscreen renders. Live frame
timing, scrolling interaction and focus still need controlled UI certification.

The checkpoint passed **1,079 tests in 101 suites** in
`/tmp/cadence-compose-unbounded-20260922/source-controls-broad-tests.log`, with the
same explicit desktop-focus exclusion and no opt-in real insertion run. The
privacy-canary scan passed. The production inspector was rendered offscreen in
six short/long/excluded and light/dark variants; every image was inspected and
all layouts were bounded. Screenshots and source hashes are preserved under
`Build/ComposeRoadmap/U16-source-controls/`. These are synthetic view renders,
not evidence of native popover focus, scrolling interaction or motion on the
locked desktop. No installation, commit, push or private context capture occurred.

A final phase-boundary regression verifies that a delayed source-control action
cannot rewind insertion once its selection preflight has started. The suspended
insertion completes once, and the old inspector cannot reopen or exclude it.
Final checkpoint: **1,080 tests in 101 suites** passed in
`/tmp/cadence-compose-unbounded-20260922/source-controls-final-tests.log`, with the
same documented platform exclusions. Its privacy-canary scan passed.


### Replacement recording checkpoint

The new recording receives a fresh action ID, target, provider and writing-default
snapshot. It receives neither the old source nor the old draft. Duplicate control
callbacks cannot cancel or start another replacement; stale source IDs are ignored.
If the user supplies only an edit command such as “Make this shorter,” missing-source
recovery stops before another model call. No capture preference changes.

The UI starts tap-to-stop recording through the existing shortcut mode. Software
coordinator tests cover the capture suppression, independent-request reset,
missing-source recovery and concurrent callback boundaries: **90 tests passed**.
The broad checkpoint passed **1,083 tests in 101 suites**, retaining the previously
documented desktop-focus exclusion and opt-in insertion limitation. This proves
source and lifecycle behavior, not actual native shortcut or editor certification.
The updated excluded-state light/dark renders were visually inspected; all six
production-view variants passed the layout harness. Their artifacts and source
hashes are preserved under `Build/ComposeRoadmap/U16-source-replacement/`.


## Selected-edit quality experiments and written-path fidelity

Two additional synthetic local-model experiments used the same eight-case
selected-rewrite development corpus and the existing semantic rubric. An editing
example plus task placement scored **2/8 acceptable, six minor, zero critical**.
A more explicit shortening directive scored **3/8 acceptable, four minor, one
critical**. Both were rejected; production prompts remain unchanged. Frozen
requests, actual outputs, generator source and per-case reviews are preserved in
`Build/ComposeRoadmap/U9-edit-instruction-experiments/`. These are exposed
development cases and do not establish independent generalization.

Separately, the output fidelity boundary now recognizes unquoted relative file
paths with a directory and extension, such as `src/Auth.swift`. Generated text
must preserve the full UTF-8 token; a changed directory, filename or suffix cannot
satisfy the obligation through a substring match. Surrounding sentence punctuation
and added backticks remain editable. Source text cannot authorize removal; an
explicit voice instruction still can. Existing quotes, URLs and rooted paths keep
their existing protection. Extensionless paths and arbitrary prose with slashes
are outside this new recognizer; this is not complete semantic fidelity.

Native checks cover real compiler admission and shared output validation,
including decomposed Unicode and distinguishing source instructions from voice
authority. Validation status and the final broad checkpoint are recorded above.


Final written-path checkpoint: **1,086 tests in 101 suites passed** in
`/tmp/cadence-compose-unbounded-20260922/relative-path-final-tests.log`.
Privacy-canary scan and `git diff --check` passed. The Mac console was freshly
verified locked; the same one desktop-focus test was excluded and the opt-in
real-editor insertion harness did not run. No production prompt, installed app,
provider choice or capture setting changed. Source snapshots, log and manifest
are preserved in `Build/ComposeRoadmap/U3-written-path-fidelity/`.


## Explicit selected-context refresh

The notch and debug-panel source inspectors now offer **Refresh selection** for
an included selected source. This discards the prior draft, restores the original
field, reads its current selection and applies the existing voice edit under a
new request/source snapshot. Provider and writing-default snapshots are retained,
with live capture and dispatch permission checks. It opens no microphone and
emits no insertion events. Retry remains distinct: it reuses the old source.

Source-free failures retain the instruction only for recovery state, never as an
unpolished message or history entry. Cancel/revoke clears the pending action and
late callbacks cannot restore it. Changed or unrelated fields and application-only
insertion authority cannot authorize a refresh. Exclusion continues to offer a
new complete recording rather than silently re-reading an excluded source.

The first focused checkpoint passed 120 tests in three suites, including native
service boundaries, coordinator flows and six production-inspector layout cases.
Additional tests cover late retry completion, failure-publication retry eligibility,
excluded-source rejection and application-only authority. See the latest broad
checkpoint above for final validation. Real native focus restoration and actual
AX selection reading remain separately uncertified on the locked desktop.


Refresh final checkpoint: **1,094 tests in 101 suites passed** in
`/tmp/cadence-compose-unbounded-20260922/source-refresh-broad-tests.log`.
The privacy-canary scan and `git diff --check` passed. All six short/long/excluded
light/dark inspector renders were inspected; controls fit within the existing
bounded view. Artifacts and source snapshots are preserved under
`Build/ComposeRoadmap/U16-source-refresh/`. The desktop-focus test remains explicitly
excluded and the opt-in real insertion harness did not run. No installation,
private context capture, provider change or memory activation occurred.


## Natural editing-command aliases

The parser now recognizes polite style-command wrappers and natural counted-bullet
verbs: “Could you make this more formal?”, “Turn this into two bullet points” and
“Format that as two bullets.” Counts remain bounded to one through three. Existing
request-edge/colon rules, exact-literal and quotation protection, and recipient-task
boundaries still apply. Source-free commands stop before provider dispatch.

New controller/compiler tests compare selected-source provider input byte-for-byte
with the existing canonical formal/bullet forms. Parser tests cover supplied message
content, standalone missing source, quoted text, exact literals, recipient tasks,
unsupported counts and bundled extra tasks. This is expanded interpretation,
not a claim of improved generative quality.

The selected-rewrite fixture's policy-only unsupported case now uses an unsupported
table command instead of the newly supported bullet alias. Its eight generation
cases are unchanged. Archived model runs retain their original corpus bytes and
hashes; they have not been relabeled as runs of the updated fixture.


Final natural-command checkpoint: **1,100 tests in 101 suites passed** in
`/tmp/cadence-compose-unbounded-20260922/natural-edit-directions-broad-tests.log`.
Freshly exported production requests preserve all eight existing selected-rewrite
provider inputs byte-for-byte against the frozen baseline. New alias/canonical
comparisons pass through the actual selected-context compiler. No new model run
or semantic-quality claim is implied. Evidence is preserved under
`Build/ComposeRoadmap/U2-natural-edit-directions/`. The documented desktop-focus
exclusion and real-insertion limitation remain.


## Persistent-memory namespace ownership

`ScribePersistentMemoryDomainStore` supplies the stable installation/storage-domain
identifiers previously required from an external caller. Construction and absent
reads create no files. Confirmed creation locks the same encrypted-file domain,
atomically persists metadata and verifies it before returning a usable namespace.
Reopening preserves the same Keychain account. Existing corrupt, future, oversized,
symlinked, moved and wrong-build metadata are preserved; encrypted data without its
namespace blocks creation. The key-store factory rejects stale domain values.

The first focused run passed **53 tests in three suites**. Added integration coverage
reopens an actual encrypted synthetic record using the production owner, Keychain
lifecycle with an injected Security backend, and encrypted store. Disabling retention
still blocks retrieval before a key query. No host Keychain key was provisioned and
no personal memory or runtime retention was enabled. See
[memory storage ownership](scribe-memory-storage.md) for the remaining runtime,
consent, retention and backup decisions; U14 remains incomplete.


Memory-domain final checkpoint: **1,112 tests in 102 suites passed** in
`/tmp/cadence-compose-unbounded-20260922/memory-domain-broad-tests-2.log`. The initial broad attempt stopped on a missing `try` in a newly added test;
that test compilation error was corrected before this passing run. Privacy-canary
scan and `git diff --check` passed. The desktop-focus exclusion and opt-in native
insertion limitation remain unchanged. Source snapshots and logs are preserved
under `Build/ComposeRoadmap/U14-domain-owner/`. Runtime memory remains disabled.


## Persistent-memory expiry driver

The new inactive-by-default maintenance driver performs an expiry pass on explicit
activation, then one pass per 60 seconds while authorized. Stop cancels scheduling,
invalidates pending operations and notifies the consumer without content. Delayed
wakes cannot restart an old generation. Unchanged passes are quiet, lock contention
waits for the next interval, and other failures stop without repair or key changes.

Seven initial scheduling tests passed. An added integration test uses the production
encrypted store to verify durable expired-record removal and stale pending reads and
saves. This service is not yet attached to app launch or consent controls: no real
background memory job was enabled. Full runtime revocation/draft wiring and the
remaining U14 product gates stay open.


Maintenance final checkpoint: **1,120 tests in 103 suites passed** in
`/tmp/cadence-compose-unbounded-20260922/memory-maintenance-broad-tests.log`.
Privacy-canary scan and `git diff --check` passed. The desktop-focus test remains
explicitly excluded and the opt-in real insertion harness did not run. Evidence
and source snapshots are preserved in `Build/ComposeRoadmap/U14-maintenance/`.
No personal data, real Keychain key, or production memory timer was created.

## Named-recipient fidelity guard

The exposed U2 cold holdout dictated “Make this upbeat and brief. Tell Nora the
rehearsal starts at nine,” but the local model returned “Rehearsal starts at nine.”
The parser had correctly identified Nora as the addressee; the loss happened
during generation. Direct-draft validation now requires a recognized named
addressee to appear as its own name token in the result. If it is missing,
Compose retains the original speech for explicit recovery and does not offer
the generated draft for insertion. Quoted material, ambiguous multiword names,
and selected-text rewrites do not gain a recipient requirement from this guard.

The exact failed output, accepted Nora drafts, a changed-name negative, Unicode
name handling, and coordinator insertion denial are native tests. The affected
coordinator and parser suites passed **127 tests in two suites**; the broad run
passed **1,127 tests in 103 suites** at
`/tmp/cadence-compose-recipient-fidelity-broad-20260923.log`, excluding the
existing desktop-focus test. The privacy-canary scan and `git diff --check`
passed. This is a safety check, not an improved model-quality score. The cold
holdout remains failed historical evidence, and a new independent reserve is
required for a future quality claim. The Mac desktop remained locked, so the
controlled insertion harness was not run.

## First native conversation identity adapter

`ScribeTextEditDocumentIdentityAdapter` is an unregistered, opt-in adapter for
saved regular files in TextEdit. Its system reader captures an active TextEdit
editor and exact focused window, then rechecks the pinned window, editor,
process incarnation and saved file on identity retrieval. The conversation ID
is an opaque digest of the canonical path and file identity. A different file,
replaced file, closed window, process restart or unavailable AX document
attribute cannot reuse an earlier action binding. The local macOS user ID is
the account coordinate; workspace and project are explicitly inapplicable.
Unsaved documents and browser surfaces remain unresolved. The adapter retains
no document text, title or raw path in its observation state and does not
capture anything until called.

Three synthetic tests cover distinct saved files, unsupported URL/unsaved
sources, A→B→A identity recovery, account separation and stale binding denial.
The full native checkpoint passed **1,130 tests in 104 suites** at
`/tmp/cadence-textedit-identity-broad-20260923.log`, excluding the known
desktop-focus test. Privacy-canary scan and `git diff --check` passed. The Mac
desktop was locked, so the AX reader could not be certified against a live
TextEdit window. Runtime registration, memory retrieval and retention remain
disabled; this is adapter groundwork rather than U11/U13 completion.

## Selected-rewrite retry experiment and evaluator failure categories

The local-model retry prototype used six exposed selected-edit failures. Its
first run generated one unchanged draft, then recorded a 31.7-second failure
and four immediate failures. The earlier evaluator labeled all failures only
`FAILED`, so their exact typed causes cannot be reconstructed from that artifact.
The evaluator now records content-free `timedOut`, `busy`, `cancelled`, or
`modelError` categories; the offline scorer validates and counts these while
remaining compatible with older uncategorized runs. No raw platform error,
prompt or output is serialized as a failure reason.

A complete second run generated all six drafts. The fixed-rubric review found
**0/6 acceptable**, four minor failures and two critical losses of source
quotation or attribution. The prototype was rejected and production prompts
remain unchanged. Regression coverage uses both exact bad outputs to verify
that current output guards refuse them before review; those guards do not make
the local model a reliable editor. The experiment request, both real-model
runs and bound review are preserved under
`Build/ComposeRoadmap/U9-edit-retry-experiment/`. The corpus is exposed, so this
is development evidence only. The native checkpoint passed **1,131 tests in
104 suites** at `/tmp/cadence-u9-retry-evidence-broad-20260924.log`; 40 offline
scorer tests, privacy-canary scan and `git diff --check` passed. The desktop
remained locked, so no live AX edit or insertion was certified.

## Unchanged selected rewrite cannot insert

The selected-text rewrite path can retain the original selection as a review
draft when the local model returns it unchanged. The notch and panel now label
this result “No changes made” and permit Copy and Retry, while disabling Insert
in the notch, removing Insert from the panel actions and rejecting a direct
coordinator insertion call. It therefore cannot replace the selection with
identical text while suggesting the edit succeeded. Three focused coordinator,
notch keyboard and presentation tests passed, as did the broad **1,132-test,
104-suite** checkpoint at `/tmp/cadence-noop-review-broad-20260924.log`, with the known desktop-focus
test excluded. The privacy-canary scan and `git diff --check` passed. The
desktop was locked during that checkpoint, so this is software-path evidence rather than live
editor certification or improved model editing quality.

## Controlled insertion certification and focus recovery

The standalone runner initially misclassified the unlocked desktop because
macOS omitted `CGSSessionScreenIsLocked` when the console session was active.
It now requires an active logged-in console and refuses only an explicitly
locked session. That correction launched the synthetic host and exposed a real
Compose issue: seven insertion cases could not read the current system-wide AX
focus, although the frontmost app exposed its focused element. The reader now
falls back to the *currently frontmost* application's focused element, never
the pinned application's element. An unrelated foreground target therefore
cannot acquire the captured field's authority through this fallback.

The first fixed run passed 13/14. The first WebKit textarea still sometimes
published document focus before its AX focused element appeared; a second run
reproduced that one failure. `prepareTarget` now retries only transient
`noFocusedTarget` reads for at most four attempts separated by 40 ms, clearing
any stale pin between attempts. Two controlled runs then passed **14/14** each:
`Build/ComposeRoadmap/cadence-compose-U5-cli.A7FHgx/integration-report.json`
and `Build/ComposeRoadmap/cadence-compose-U5-cli.HXP9ZH/integration-report.json`.
The real production context, AX reader, capability and Unicode-event services
were exercised against synthetic native and WebKit editors. Both reports bind
the host binary hash, runner identity, OS version and all fixed outcome codes.
The initial 5/14 and intermediate 13/14 reports remain archived as failure
evidence; they do not count toward certification.

Two focused retry tests and the broad **1,134-test, 104-suite** native run passed.
The known desktop-focus XCTest was excluded. Privacy-canary scans across the
logs, passing reports and local model experiment, plus `git diff --check`,
passed. The controlled host does not certify installed Cadence, Muse, arbitrary
third-party editors, duplicate UI activation or partial-event recovery.

The coordinator now claims each insertion synchronously before awaiting the
target service. A suspended-service test submits polished and unpolished Insert
actions during that claim and confirms that only the first posts text. If the
event emitter reports an unconfirmed outcome, the reviewed draft remains
copyable, but the same action cannot Insert, retry generation or refine again.
The notch removes the Insert shortcut and the panel removes both Insert routes
for that outcome. The coordinator suite passed **99/99** tests, and the new
notch shortcut test passed in the affected-suite run. That run's only failure
was the previously known desktop-focus test: the locked console could not make
the test app active. A broad rerun made no progress after entering the native
model tests and was stopped after about three minutes, so this turn does not
claim a fresh broad-suite pass. The new concurrent/partial-posting tests use a
stub insertion service; they do not certify real partially posted CGEvents.

The expanded standalone host run at
`Build/ComposeRoadmap/cadence-compose-U5-cli.GHdr0f/integration-report.json`
passed **15/15** cases. The fifteenth case used the production Unicode event
poster for one character, injected an event-creation failure before the second,
and required the production insertion path to report an unconfirmed outcome.
The host observed exactly the published one-character prefix and no duplicate
or Return event. This checks a controlled partial post through actual AX,
focus and CGEvent services; it cannot prove how an unobservable OS delivery
failure would behave. Production success text and diagnostics now distinguish
posted keystrokes from confirmed destination content. A separate clipboard
commit boundary reports write failure without saving Compose history or showing
success feedback. The host self-test, eight controller protocol tests, **131**
focused native tests across the coordinator, diagnostics, copy and capability
suites, and privacy-canary scan passed.

A subsequent 16-case standalone run at
`Build/ComposeRoadmap/cadence-compose-U5-cli.Z3scid/integration-report.json`
also passed. Its second synthetic host had a different live process ID from
the captured host. After that process took foreground focus, production refused
the old capture before the event-poster wrapper was reached, and both host
editors remained empty. This establishes a cross-process focus boundary with
the same synthetic app bundle; a true third-party bundle remains untested.

The single-use insertion increment adds a posting reservation to each captured target. Verification or selected-text preflight can fail before posting and release the in-flight reservation; once posting begins, a second call for that capture is refused as unconfirmed. The final controlled standalone host report at `Build/ComposeRoadmap/cadence-compose-U5-cli.pPqaMD/integration-report.json` passed **17/17** native/WebKit cases with the then-current production source, including exact one-copy success, duplicate refusal and no second post after a real one-character partial event. The focused context-service run passed **30/30** tests at `/tmp/cadence-u5-single-use-final-tests.log`, including an overlapping-call test. Muse was running on its login surface during this turn, so no composer or real Muse insertion was certified. The installed Cadence app was not replaced.

The next U5 host extension adds a newly launched system editor instance with a synthetic document, separately from the captured synthetic host. It verifies different bundle and PID, then requires production to refuse insertion before calling the event poster. Its first live run at `Build/ComposeRoadmap/cadence-compose-U5-cli.ZSOzGv/integration-report.json` passed 17 of 18 cases; the new case failed only because a missing focused AX element in the other app produced `noFocusedTarget` rather than the more accurate `targetChanged`. Neither editor received text. `ScribeContextService` now maps that error using the independent frontmost process ID and retains `noFocusedTarget` when the captured process remains frontmost. The focused suite passed **31/31** at `/tmp/cadence-u5-cross-bundle-tests.log`. The Unicode poster now checks task cancellation before the first event and between characters: pre-post cancellation emits nothing, while cancellation after one character stops the rest and reports an uncertain partial insertion. Fourteen focused capability tests passed at `/tmp/cadence-u5-cancellation-tests.log`. A separate 20/20 Dictation coordinator run at `/tmp/cadence-u5-clipboard-recovery-final-tests.log` now checks both an uncertain cursor-hint editor and a definite non-text control: a failed clipboard backup retains the transcript, emits no typing or Return, plays no completion feedback, and shows a retryable copy error. The next live run at `Build/ComposeRoadmap/cadence-compose-U5-cli.A5NHNE/integration-report.json` reported `blocked_desktop` with zero cases executed, so that attempt supplied no final integration evidence.

The September 27 first unlocked retry reached the synthetic host but could not
bring it foreground, so all cases stopped at the harness focus check before
production insertion (`cadence-compose-U5-cli.gJLVJq`). The runner now asks its
owned host process to activate after each focus command and still requires the
host's PID to be frontmost. The immediate current-source rerun at
`Build/ComposeRoadmap/cadence-compose-U5-cli.Q7x0Yr/integration-report.json`
passed **18/18** cases, including the cross-bundle refusal. The archived
evidence passed the privacy canary scan. This verifies the controlled host,
not the installed Cadence app or Muse.

The separate plain-source U9 prompt prototype used the existing eight-case
synthetic corpus. Its bound run generated one unchanged draft in 25.7 seconds,
timed out on the second call and received six `busy` denials while the single
model-operation permit remained occupied. The offline integrity scorer bound
8/8 cases and classified those seven failures without prompt or output logging.
The run cannot support a semantic-quality comparison, so the prompt was not
shipped. Evidence is under `Build/ComposeRoadmap/U9-plain-source-experiment/`.

## Controlled TextEdit document-identity observation

With Accessibility trust and an unlocked foreground session, a local probe
linked against the current production Debug module called
`ScribeTextEditDocumentIdentityAdapter` and
`ScribeConversationIdentityResolver` on two synthetic saved TextEdit files.
The adapter returned a verified opaque identity for A, a different identity
for B, then A's original durable identity when A was focused again. A new
empty unsaved TextEdit document returned no binding or verified identity.
The probe printed only booleans and 16-character opaque key fingerprints;
it did not read or export document text. Its source and synthetic files are
under `Build/ComposeRoadmap/U11-live-identity/`. TextEdit was not running
before this controlled session and was quit afterward.

This observation exercises real TextEdit AX metadata, but separate probe
processes did not establish long-lived window/action revalidation across a
document switch, close/reopen or process restart. It also does not certify
ChatGPT, Codex or browser identity. Registration and runtime memory retrieval
remain disabled until those boundaries and user-facing controls are verified.

A later probe kept one adapter and resolver alive while synthetic documents B
and A exchanged focus. Capturing the current A binding invalidated B's earlier
action binding; a new B action recovered B's original opaque memory key. Closing
B made its pinned window evidence unavailable. Reopening B created a new action
binding with the same durable key, while the old pinned binding stayed invalid.
The probe printed only booleans, and the deterministic adapter tests include
the close/reopen isolation rule. TextEdit was quit afterward. An initial process
restart attempt could not reliably establish foreground ownership after reopening
and was not counted. The blocking probe's main run loop had not processed
NSWorkspace activation notifications.

After the probe explicitly pumped the run loop for each command, a new
controlled run captured a verified identity for synthetic saved file A, quit
TextEdit, observed the old pinned window become invalid, reopened A in a new
TextEdit process, and recovered the original opaque memory key from a new
binding. The old action remained invalid both before and after reopening. The
live report and reusable probe are in `Build/ComposeRoadmap/U11-live-identity/`;
**24 tests in two identity suites passed** at
`/tmp/cadence-u11-process-restart-tests.log`. TextEdit was quit afterward. This
verifies process-restart behavior for a synthetic saved TextEdit document, not
arbitrary documents or conversation apps; no adapter registration or memory
retrieval is active.

The live same-path replacement check then exposed a real identity error: after
the synthetic file was replaced on disk, TextEdit still displayed the old
contents, but the adapter accepted a new binding for the replacement file's
memory key. The system reader now fences each open window to its first verified
file identity. A changed identity invalidates the old binding and quarantines
that window from receiving any new document scope, even if the old file later
returns at the path. Reopening the original file in a new window recovered its
old key while the prior binding remained invalid. The before/after synthetic
platform evidence is in `U11-live-identity/replaced-file-report.json`; **25
tests in two identity suites passed** at
`/tmp/cadence-u11-replacement-fence-tests.log`. No personal document text was
captured or stored, and TextEdit was quit afterward. This closes the observed
TextEdit replacement-file boundary; it does not certify other app surfaces or
activate runtime memory.

## Complete coding-instruction preparation and honest U2 replay

Apple Intelligence now prepares a bounded, already-complete coding-agent
instruction by removing only its spoken drafting frame. In the observed
failures, “Draft a short request to review the cache miss, but do not modify
configuration” keeps the no-change limit, and “Ask the agent to inspect
tools/replay.sh using --dry-run and leave files untouched” keeps both technical
literals and the no-edit limit. This direct route returns before model work and
its timeout; it remains subject to the coordinator's normal output guards and
review. Corrections, extra writing work, quoted requests, ambiguous compound
requests, configured style guidance and cloud providers stay on their existing
paths. No application action is performed by preparing the draft.

The two focused suites passed **32 tests**, including production request
compilation, exact bytes, restrictions, negative boundaries and an injected
model/timeout proof. Log:
`/tmp/cadence-u2-direct-instruction-tests-3.log`. The adjacent coordinator,
literal, restriction, provider-capability and replay suites then passed
**155 tests in seven suites** at
`/tmp/cadence-u2-complete-adjacent-tests.log`. A 20-test synthetic export
run passed, then the real on-device evaluator completed all 16 previously
exposed holdout cases: 13 model generations and three prepared drafts, with no
generation failures. The strict manual regression review recorded 12
acceptable, one critical and three minor results. Two newly prepared coding
requests and the earlier prepared uncertainty reply repair three historical
failures. The model's new Nora result retains the recipient but misses the
requested upbeat tone; the missing-source model result still invents a letter,
and the private-reason instruction still leaks into message content.

The direct-draft replay was corrected to run the same missing-source preflight
and direction/recipient guards as the coordinator. Its opt-in native test passed
and now reports 15 review-ready outputs and one `missingSource` rejection. That
rejection prevents the critical invented letter in real Compose; it does not
convert the underlying model generation into a quality pass. The replay does
not evaluate semantic quality or certify live microphone-to-insertion behavior.
Requests, model manifest/results, manual review and policy replay are in
`Build/ComposeRoadmap/U2-complete-coding-requests/`. The privacy-canary scan
and `git diff --check` passed. U2's provider quality gate remains open, and
this used an exposed corpus, not a fresh independent holdout.

## Action-scoped conversation identity boundary

`ScribeConversationActionScope` now admits the TextEdit identity adapter only
when the Compose action is still current, the original target remains current,
Accessibility is granted, the adapter matches the captured process, and an
explicit session-memory capture grant passes `ScribeContextPolicy`. It holds
one opaque verified identity for that action and rechecks action ownership,
target, identity, consent and OS permission before returning it after async
work. The session store now requires a caller-supplied current-action authority
at every read/write boundary and drops pending operations/leases when it fails.
A late callback or previously issued access object for an older action cannot
erase, replace, or use the newer scope, even when both actions refer to the
same document. Scope defaults deny all access; the service itself retains no
content.

Synthetic integration checks exercise explicit session-memory write/retrieval
for document A, reject access after clear, and reject old access and pending
work after a new action on the same document. They also reject A's old access
after switching to B, show B has no A facts, and
recover A's fact only after fresh verification on returning to A.
Revocation checks include target changes, action changes, policy revision,
removed capture grant, Accessibility loss, grant expiry and permanent revoke.
The focused native run passed **31 tests in three suites** at
`/tmp/cadence-action-scope-final.log`; its privacy-canary scan and
`git diff --check` passed. The final clear-action assertion passed the
four-test action-scope suite at `/tmp/cadence-action-scope-clear-final.log`.
These were software boundary checks, not a live Compose memory experience.
At that checkpoint, `AppModel` and `ScribeCoordinator` did not yet own the
scope or session store. The following increment adds action wiring and a
separate identity preview; selected-text opt-in still does not authorize memory.

## TextEdit identity development preview

The next increment connected the TextEdit action scope to `AppModel` and
`ScribeCoordinator` behind both default-off memory and adapter rollout
switches and a separate, default-off Settings disclosure. When opted in for
TextEdit and using Apple Intelligence, an explicit Compose action may read
saved-document identity metadata after the microphone starts. The coordinator
clears the scope on cancellation and action cleanup. The policy grants only
local session-memory identity capture; fact retention has a separate dormant
preference and no user-facing save path. There is no transcript extraction,
memory retrieval, provider payload, or installed-app certification.

The consent policy passed two focused tests, the action scope passed four, and
the coordinator suite passed 100 including the new microphone-before-identity
lifecycle test. Logs: `/tmp/cadence-session-live-boundary-final.log` and
`/tmp/cadence-session-coordinator-final.log`.

## Explicit local session-memory commands

The next increment adds a distinct, default-off “Remember facts I explicitly
state” switch. On a verified saved TextEdit document, Compose recognizes only
the bounded whole-utterance commands “Remember that …”, “What do you remember
for this document?”, and “Forget this document.” It saves explicit facts in
the local session store, displays a separate Done-only notice, and bypasses
draft generation, insertion, and Compose history. The action and target are
revalidated on every store operation; switching documents cannot retrieve a
previous document's facts. Ordinary text is not treated as a memory command.
Facts expire within 30 minutes or when the app session ends.
This increment does not put memory into generated drafts, support other apps,
or constitute installed-app validation.

Focused verification: the conversation-scope checks passed in
`/tmp/cadence-compose-memory-focused.log`; the coordinator suite passed 101
tests, including local-command isolation, in
`/tmp/cadence-compose-memory-coordinator-final.log`. The final source built in
`/tmp/cadence-compose-memory-final-build.log`, and `git diff --check` passed.

## Relevant local facts in a draft

A separate, default-off “Use relevant facts in local drafts” control now
allows explicitly saved TextEdit session facts to help draft a later request in
that same verified document. The first retrieval is deliberately conservative:
only facts sharing a specific word with the spoken request are selected. The
local provider receives bounded facts as JSON data with a reminder that facts
are not instructions or proof of an outcome. Cloud provider paths reject
memory facts. A retry compares record IDs and text with the original draft's
snapshot; changed facts or revoked access invalidate a memory-backed reviewed
draft and prevent Copy or Insert. Insertion rechecks the same snapshot before
posting text. Memory-backed drafts are excluded from ordinary Compose history,
and the review shows a quiet “Session facts · This Mac” cue. A use-only setting
change preserves existing session facts but invalidates an in-flight
memory-backed draft, including a late local-model result. Unsupported documents
continue transcript-only. This is a
limited U13 runtime slice; it has not passed live-provider factual-grounding
evaluation or installed-app certification.

Focused verification passed 110 memory/coordinator tests in
`/tmp/cadence-compose-memory-revocation-final.log`, 32 prompt regression tests in
`/tmp/cadence-compose-memory-prompt-focused.log`, and 21 policy tests after the
local-only assertion in `/tmp/cadence-compose-memory-policy-final.log`. The
synthetic refund fact was absent from those test logs in the privacy-canary
scan, and `git diff --check` passed. These checks establish routing and scope
behavior, not generated-answer quality.

The first actual on-device model check failed: with the generic Compose prompt,
the local model repeated “Ask for an update on the refund” and omitted the
saved delayed-refund fact. A concise prompt used only when session facts are
present passed the same synthetic check in
`/tmp/cadence-compose-memory-on-device-eval-2.log`: the generated draft asked
for an update, included the delay, and did not assert approval or payment.
The original transcript-only prompt remains unchanged. The opt-in evaluation
test is disabled in ordinary CI and the temporary local enable file was
removed after the run. One synthetic case is evidence of a fixed failure, not
U13 provider-quality certification across tasks or model versions.
After the prompt adjustment, 33 focused prompt and direct-draft tests passed
in `/tmp/cadence-compose-memory-prompt-final.log`; the synthetic fact was
absent from the model-evaluation and coordinator logs in the canary scan.

## Explicit correction of session facts

Compose now accepts the bounded voice command “Cadence, correct memory [old
fact] should be [new fact]” for a recent fact in the currently verified saved
TextEdit document. The old wording must match one current fact after case,
spacing and trailing-punctuation normalization. The new record explicitly
supersedes the old record; current inspection and draft retrieval see only the
correction. No match or multiple matches returns a “Correction not applied”
notice, without writing another fact or dispatching a provider request. This
remains session-only and behind the default-off memory feature gates.
The focused scope/coordinator run passed 112 tests in
`/tmp/cadence-compose-memory-correction-focused.log`, including A→B→A isolation,
the correction lineage link, corrected draft retrieval, and provider bypass.
The synthetic fact was absent from its test log in the privacy-canary scan.

## Fact-backed review and revocation

Fact-backed reviews show “Session facts · This Mac” in the notch and panel.
Compose rechecks the frozen fact IDs and text before Copy and Insert and again
at the insertion preflight. A forgotten, corrected or otherwise changed fact
discards the derived review instead of leaving a copyable or insertable stale
draft. Copy and Insert of a valid fact-backed draft do not save it in ordinary
Compose history. Refinement is disabled for these drafts until it can preserve
the same authorization checks across a new voice action.

Focused coordinator and presentation verification passed 122 tests in two
suites in `/tmp/cadence-compose-memory-cue-safety-final.log`, including a
fact revoked at insertion preflight before text was posted. The synthetic fact was
absent from that log under the privacy-canary scan, and `git diff --check`
passed. This verifies source behavior with test adapters; the installed app
and real TextEdit flow have not been certified.

## Generic follow-up with one saved fact

“Ask for an update” and a small set of equivalent, whole-utterance follow-ups
now use the sole explicitly saved fact in the current verified TextEdit
document. A request naming another topic, a different document, and cloud
providers remain on the transcript-only path. When the current document has
several facts, Compose stops before provider dispatch and asks the speaker to
name the issue. A newly ambiguous memory snapshot invalidates an earlier
fact-backed review instead of leaving its draft copyable.

The focused action-scope suite passed nine tests in
`/tmp/cadence-compose-single-fact-followup-focused.log`. Two opt-in tests
against the actual Apple Intelligence provider passed in
`/tmp/cadence-compose-single-fact-followup-model.log`: the original explicit
refund request and the generic follow-up both produced a draft mentioning the
delayed refund without claiming approval or issuance. The synthetic fact was
absent from both logs under the privacy-canary scan; `git diff --check` passed.
The temporary opt-in file was removed after the model run. These synthetic
cases do not establish quality for multiple memories, other topics, installed
Compose, or other Apple model versions.

The ambiguity follow-up passed 118 focused action-scope/coordinator tests in
`/tmp/cadence-compose-ambiguous-followup-focused.log`. Tests verify zero
provider calls for a newly ambiguous request and removal of a previously
reviewed fact-backed draft when a retry becomes ambiguous. This is software
evidence for the clarification path, not an installed-app UI certification.

## Separate durable-memory consent foundation

`ComposePersistentMemoryConsentController` now issues a distinct, local-only
policy for explicit durable facts in verified TextEdit documents. It is disabled
by default, requires both the TextEdit choice and acceptance of the current
durable-retention disclosure, grants no cloud transmission, and limits retention
to a proposed 30 days. Changes to the choice or rollout revision invalidate
earlier authorizations. The policy creates no domain, file or Keychain item.
The proposed period and backup disclosure still need a user-facing decision
before activation; no Settings control or app runtime save path is connected.

Three focused consent tests passed in
`/tmp/cadence-compose-persistent-consent-final.log`, including authorization
through the production context policy, other-app rejection, retention-bound
rejection and revocation. The user-facing session-memory disclosure was also
updated to describe the currently implemented explicit session facts and local
draft use. Persistent-memory feature completion remains unproven.

## Explicit durable-memory runtime owner

`ComposePersistentMemoryRuntime` now binds a verified TextEdit document to the
invoking action and reuses the encrypted store, stable namespace, and Keychain
boundary. Construction and an unconfirmed activation create nothing. With
synthetic user confirmation, it can open the local domain, prepare an exact
explicit fact without writing it, reject an unconfirmed proposal, commit a
confirmed proposal, inspect only the active document, and forget that document
durably. Reopening reads the encrypted fact under the same identity; another
document sees none. Disabling retention invalidates an uncommitted proposal
without changing ciphertext, and a stale clear callback cannot cancel a newer
proposal.

Eleven focused action-scope/runtime tests passed in
`/tmp/cadence-compose-persistent-runtime-revocation.log`; the synthetic fact was
absent from the log under the privacy-canary scan and `git diff --check`
passed. Tests use a temporary encrypted file and an in-memory Security backend.
At this checkpoint the owner was not yet constructed by AppModel; no Settings
or voice action could activate it, and no host Keychain key was created. The
later activation checkpoint below supersedes the first two limitations.

The runtime owner now prepares an exact persistent correction only when one
current explicit fact matches after conservative case, whitespace and terminal
punctuation normalization. A rejected proposal leaves the old fact current;
confirmation supersedes it while retaining lineage. A reopened encrypted store
returns only the corrected current fact. The session and persistent flows use
the same bounded matching rule. Eleven focused action-scope tests passed in
`/tmp/cadence-compose-persistent-correction-final.log`, and the synthetic fact
was absent from the privacy-canary scan. This is an unconnected runtime
capability; no installed-app voice command can request it yet.

Forgetting a document now closes that invocation's memory authority after the
encrypted deletion commits. A proposal pending at Forget cannot be confirmed,
and a late callback cannot prepare another save under the deleted action.
The focused action-scope suite passed 11 tests in
`/tmp/cadence-compose-persistent-forget-fence.log`; the synthetic fact was
absent from its privacy-canary scan. This fences local pending writes. Future
provider-backed persistent-memory drafts still need a separate late-result
invalidation gate when that runtime path is connected.

At the earlier foundation checkpoint, the unconnected runtime started the
existing expiry driver only after a
confirmed encrypted domain opens. It runs an initial purge, schedules bounded
maintenance while authorized, and stops access when retention is disabled.
Opening after the proposed expiry period physically removed an expired
synthetic fact, changed the ciphertext, and emitted one content-free
invalidation; the subsequent scoped read was empty. Twelve focused tests passed
in `/tmp/cadence-compose-persistent-expiry-focused.log`, and the synthetic
fact was absent from its privacy-canary scan. App launch and Settings were not
connected at that checkpoint, so no installed-app background task was started.

## Durable-memory activation and global deletion preview

AppModel now constructs the durable runtime without file or Keychain work. A
new, separately default-off persistent-memory rollout gate requires the
existing context, session-memory and adapter gates. Only a previously confirmed
choice can reopen an existing domain at launch; absence or unreadable state is
reported without creating a replacement. Settings requires a separate
confirmation before creating local encrypted storage and a Keychain key, and
discloses the 30-day limit, off-versus-delete distinction, and backup limits.
At this activation checkpoint, Settings stated that Compose voice saving was
not connected yet; the voice-proposal checkpoint below supersedes that limit.

A separately confirmed **Forget all saved facts** operation advances the
encrypted store's revision and removes all current records even after access
is disabled. It does not create a domain or key when no store exists. The
focused feature-gate and action-scope/runtime run passed **21 tests in 2
suites** in `/tmp/cadence-u14-app-wiring.log`. Source compilation passed; no
installed-app Settings interaction or real Keychain operation was performed.
At that checkpoint the per-fact voice proposal, per-document inspect/forget UI,
dependent-draft invalidation and signed-app certification remained open.

## Explicit durable fact by voice

The exact phrase **“Cadence, remember for later that …”** now branches before
writing-provider dispatch. It binds the current verified saved TextEdit document
only after transcription, prepares one encrypted-store proposal without writing,
and shows the exact fact in the notch or debug panel. Save fact confirms only
that action's proposal ID; Discard, cancellation, a changed document, revoked
consent, or a stale revision cannot commit it. Ordinary writing requests and
the shorter session-memory “Remember that …” phrase remain separate. The
proposal has no global Insert shortcut and never enters Compose history.

The focused command, coordinator, runtime, context, presentation and frame run
passed **178 tests in 6 suites** in `/tmp/cadence-u14-voice-save-final4.log`.
Tests also reject Copy or Insert of the spoken memory command itself, late
confirmation after cancellation or revocation, and unrelated focus during
review. The synthetic proposal frame was visually inspected. These checks use a fake
persistent-memory context or an injected Security backend; they do not prove
real Keychain, TextEdit focus during confirmation, or installed-app behavior.
Source-level local-draft use and dependent-draft invalidation were added next;
installed-app and signed-app certification remain open.

## Durable voice inspection, correction, and document forget

Three additional exact commands now branch before writing-provider dispatch:
“Cadence, what do you remember for this document?”, “Cadence, correct saved
memory [old fact] should be [new fact]”, and “Cadence, forget saved facts for
this document”. Inspection shows the verified document's current facts without
creating a draft. Correction shows both the old and replacement fact before
the existing exact proposal confirmation. Forget shows the current fact count
and requires a separate confirmation. The store compares its durable revision
under its exclusive lock before deletion; an intervening save makes the old
review stale and leaves the newer facts intact. These commands have no global
Insert route and do not expose their spoken transcripts for draft recovery.

The focused command, coordinator, encrypted-store, and notch-presentation run
passed **164 tests in 4 suites** in `/tmp/cadence-u14-controls-test.log` on
September 26. It includes rejection of a wrong or repeated confirmation ID,
provider and insertion bypass, and a stale forget after an intervening save.
An additional cancellation regression passed in the **122-test coordinator**
rerun at `/tmp/cadence-u14-controls-coordinator-final.log`.
This is source-level synthetic verification. Real installed-app review,
TextEdit focus handoff, and signed-app Keychain behavior are still unverified.

## Opted-in saved facts in local drafts

A second saved-memory switch defaults off independently of encrypted storage.
When enabled, only a verified saved TextEdit document and the local Apple
Intelligence provider can supply relevant explicitly saved facts to a draft.
The runtime bounds retrieval to six facts and 8,192 UTF-8 bytes and issues no
cloud context grant. The coordinator pins each fact's ID and text together with
the local-use revision. It compares that snapshot before publishing a model
result, on retry, before Copy, and immediately before insertion events. A
forget, correction, changed document, or revoked setting invalidates the
dependent draft. Global deletion and local-use preference changes also notify
the coordinator immediately. Fact-backed drafts stay out of ordinary history;
review exposes the exact facts used. Saved-fact omission controls remain a
separate UX increment.

The final focused coordinator, scoped-runtime, consent, and presentation run
passed **164 tests in 4 suites** in `/tmp/cadence-u14-draft-final2.log`.
The run includes synthetic local and cloud provider requests, a forgotten fact
while generation is suspended, and stale Copy and Insert refusals. It uses an
injected Security backend and fake provider; it does not certify an installed
Cadence build, live Keychain behavior, or real Apple Intelligence output.

## U9 bounded selected-text rewrite checkpoint, September 30

A real on-device run of the eight-case selected-text corpus showed that the
local model frequently returned the selected source unchanged. That behavior
was safe but did not accomplish the requested edit. The coordinator now applies
small, source- and instruction-bound revisions for six common forms: a review
status made shorter, a Swift path and flag instruction made concise, a named
review note made warmer, uncertain attendance made shorter without losing
uncertainty, a casual named review invitation made formal, and an intact
quoted request made warmer. It also completes one exact partial formalization
where the model drops only “Hey.” The result still goes through the selected
source's exact-literal and recipient-restriction output guards. Unmatched text
keeps the existing guarded behavior; an unchanged result cannot be inserted.

The original eight-case on-device baseline had two satisfactory edits, five
unchanged outputs and one quote-only meaning failure rejected by the current
review guard. A first frozen eight-case reserve A failed its predeclared gate
with five meaningful edits and three unchanged results. A second reserve B
failed at six meaningful edits, one unchanged result, and one partial formal
edit. Their first-run outputs and exposed development replays are retained.
After the partial-form correction, a third corpus C was frozen before export
and model generation. Its first run generated 8/8. Current production-path
replay marked 8/8 review-ready, with seven meaningful edits on manual synthetic
case review, one unchanged off-pattern quoted case, and zero unsafe accepted
outputs. That met its predeclared 7/8 narrow gate. Source, request, result,
replay, rubric and case-review hashes are recorded in the local staging
`evidence/u9-reserve-c/` directory. The final temporary candidate passed
1,318 native tests across 111 suites; the focus-dependent keyboard suite was
excluded. This is a bounded improvement, not a claim that arbitrary selected
text is rewritten well. The primary Documents checkout is still unreadable,
so this candidate is not yet reconciled or installed.

A short-prompt, synthetic-only development probe was also run against eight
already exposed reserve-B cases. It moved the writing direction into a concise
user message while keeping the selected source JSON data and explicit
source-is-untrusted instruction. The on-device model returned seven selections
unchanged and formatted only the two-bullet case, so it did not improve raw
rewrite quality and was not adopted. The request envelope, generated outputs
and generator log are under `Build/ComposeRoadmap/U9-short-prompt-prototype/`.

A separate development-only guided edit-plan probe asked the on-device model
for exact source-span replacements on four exposed reserve-B cases. It produced
two no-op replacements, one partial formal edit, and one proposed replacement
that altered protected quoted text. The existing exact-literal guard would
reject that last edit. The prototype was not integrated into Cadence; its
source and outputs are under `Build/ComposeRoadmap/U9-edit-plan-prototype/`.

The primary Documents checkout continued to hang on file opens after the
candidate was preserved. An isolated local Git checkout was created from the
same `main` commit as the primary checkout, then the candidate's source was
copied without deleting any tracked files. The 421 compared source and
documentation files matched byte-for-byte. XcodeGen regenerated the project;
the Git-backed checkout passed 1,318 native tests across 111 suites, 46
offline evaluator tests, the runtime privacy-canary scan and the Git diff
whitespace check. One stale rubric test revealed that its development corpus had 24
cases but the rubric covered only 23; the missing case was added and the
count check now verifies source-ID uniqueness rather than a fixed size. This
is a local recovery checkpoint, not a reconciliation of the dirty primary
checkout or an installed-app certification.

A later bounded U9 increment handles one remaining unchanged-output form:
“make this concise” on a sentence introducing a quoted or test string.
It shortens only that introductory clause and copies the quotation plus every
following sentence unchanged. The current production guard replay against the
previously frozen eight-case reserve C now reports eight review-ready results,
zero unchanged notices, and seven bounded revisions. Seven focused native
tests pass, including a changed-quote no-fallback case. This is saved-output
replay on an exposed synthetic corpus, not a fresh independent model-quality
gate or a claim of general selected-text editing.
