# Compose voice refinement

September 22 roadmap implementation. Source behavior is not evidence that the
installed application has been updated. Native lifecycle checks pass in the latest
1,120-test broad checkpoint, which excludes a locked-desktop focus test. Actual
model quality and controlled UI certification remain separate gates.

## Behavior

An explicit **Refine** action starts a new voice recording for the current
reviewed Apple Intelligence draft. It reuses the original pinned destination;
opening Cadence's review controls cannot change the destination to Cadence.
The request carries the exact draft version, original action and capture IDs,
and the provider configuration that produced the draft. A different action or
stale result cannot replace the accepted version.

The ordinary Compose transcript remains the original spoken request. Revision
speech is stored separately in memory. Cancel, silence, timeout, invalid output,
or a changed target keeps the prior accepted draft available. Failure also keeps
the revision instruction for recovery. Starting another Compose action clears
this session. No persistent memory is created.

If normalized output is byte-identical to the accepted draft, Compose keeps that
version, preserves Undo, and displays “No changes made. Your draft is unchanged.”
This is an honest no-change outcome, not a successful revision or a new version.

**Undo** restores the preceding accepted version byte-for-byte without a model
call. The bounded standalone voice commands “undo”, “undo that”, and “undo that
change” also perform Undo. A new successful revision after Undo starts a new
branch of the in-memory history. At most eight accepted versions are retained.

The first protected-text command is “Keep the first sentence.” That sentence
must survive unchanged in the output. This recognizer is deliberately narrow;
it does not expose general selection editing or infer arbitrary source ranges.
Explicit technical literals and recipient restrictions are checked after every
revision. A request to remove an existing recipient restriction is currently
unsupported; the conservative guard may retain the older draft instead.

Cloud refinement is unavailable. Existing cloud consent covers the spoken
request and writing behavior, not a prior draft. A local-only operation never
falls back to a remote service. Both capability and destination checks occur
before refinement dispatch.

## Recording and interface ownership

Refinement uses the existing voice-session arbiter. It cannot acquire the
microphone while another voice task owns it. Ordinary Dictation beginning during
refinement generation immediately invalidates that completion. Cadence retains
the accepted draft, suppresses Compose's HUD updates, and restores the same
review only after Dictation and its terminal HUD feedback are idle.

Escape cancels refinement and keeps the draft. Closing the surface removes the
refinement keyboard monitor. No delayed result or old keyboard registration may
take control after a new task starts.

## Verification

The deterministic suites cover:

- A revision compiles the actual current version and its separate instruction.
- Original transcript/history survives successful and failed revisions.
- Undo restores exact text and does not dispatch another provider request.
- Out-of-order provider results, new actions, and invalidated completions cannot
  overwrite a newer draft.
- Source text containing “remove” or “rename” does not authorize a later model
  to drop a literal; only the new revision instruction can authorize that change.
- Cloud requests, changed targets, unavailable capabilities, and excessive
  compiled requests fail before dispatch.
- Silence, cancellation during microphone startup, generation failure, and a
  busy Dictation session preserve the accepted draft.
- Local-only availability, retained failure text, compact scrolling, Escape
  registration, and Dictation interruption have presentation/state coverage.

The synthetic refinement corpus and export test compile requests through the
production refinement policy. Real Apple Intelligence runs and independent
semantic review must be recorded before claiming that refinement follows every
supported writing instruction. Automated controlled-UI testing remains required
for the final integration milestone; passing view-model tests is not that proof.

The latest eight-case run uses the production task-first request compiler and
the current deadline/admission generator. The unchanged preregistered rubric
grades three drafts acceptable and five unchanged drafts as minor failures;
there are no generation or critical semantic failures in this run. The semantic
gate fails. Saved-output native replay validates policy admission separately;
an admitted unchanged draft still did not satisfy its requested writing change.
Evidence is under `Build/ComposeRoadmap/U7-refinement-task-first-bounded/`.

A later exposed development run added a bounded prompt cue for short,
named-recipient requests to make a draft warmer. The local model changed the
Maya status and Alex quoted-phrase cases by adding a greeting; native replay
accepted both, and the other six outputs were unchanged. The current policy
excludes negative drafts, protected opening text, existing greetings, and
explicit no-greeting requests. Three of eight requests still returned an
unchanged draft, so the semantic quality gate remains open. See
`Build/ComposeRoadmap/U7-warm-refinement-production/`.
