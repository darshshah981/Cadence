# Grounded context: selected-rewrite runtime increment

This increment connects the U12 context compiler to the existing U9 selected-text
rewrite flow. It does not complete grounded replies, coding-prompt assembly,
conversation recognition or memory. Those roadmap gates remain open.

## What the app now does

After an opted-in, local TextEdit selection is captured, the context controller
compiles a complete-selection rewrite under the current permission policy.
The compilation contains the actual provider input, its source provenance,
the replacement destination, exact-text obligations, size limits and expiry.
The coordinator retains that immutable compilation for the active attempt.

The provider receives the same selected-rewrite prompt as before. The full
selection stays in its JSON source field; writing directions and saved defaults
stay in their established instruction fields. The compiler does not add app,
account, capture, field or memory identifiers to that input. No model capability,
capture setting or cloud permission changes as a consequence of this wiring.

The runtime uses the compilation to validate generated output. Policy and
freshness checks run before dispatch, output acceptance, Copy and insertion
preflight. Replacement still restores the exact original app and revalidates
the actual selected range and text using the existing bounded reader. Compiler
comparison values do not replace that native content check.

## Selection identity and conversation identity

An exact-selection rewrite needs to identify the captured field and selection;
it does not need to know which ongoing conversation the document belongs to.
The compiler therefore supports an invocation-only field reference bound to
the action, capture, process incarnation and verification metadata.

This reference contains no verified conversation and grants no memory lookup.
It cannot authorize a reply in another field. The reply path continues to require
source and destination fields in the same verified conversation, a distinct
destination capture and field, and an empty insertion caret. No production
conversation adapter or reply route is enabled by this increment.

## Bounds and recovery

Default compiler limits are 4 KiB for voice, 8 KiB for source, 16 KiB for the
combined prompt and 16 KiB for output. The provider's separate capability limit
still applies and can be stricter. A selected rewrite includes one complete,
required source section. A too-large request is rejected, never truncated.

The selection snapshot has a 120-second use lifetime. Retry retains the same
source and does not extend that lifetime. Expiry during generation prevents
the result from becoming reviewable. Expiry discovered during Copy or Insert
ends dependent work and asks the user to start a new request. The ended request
does not display a retry action that cannot work. These are use-boundary checks,
not a background timer promising to erase bytes exactly at 120 seconds.

The spoken rewrite instruction is never offered as replacement text after a
contextual failure. Neither the selection nor its generated draft is saved to
history. Revocation and cancellation continue to clear dependent work.

## Software evidence

The native tests exercise the controller, compiler, coordinator and presentation:

- Invocation-only fields cannot authorize replies or yield conversation keys.
- Runtime prompt bytes match the existing selected-rewrite compiler, including
  formal voice overriding a saved warm tone while retaining concision.
- Exact payload limits accept the boundary and reject one byte over it.
- Source provenance includes the complete range, snapshot identity and byte count.
- Expiry before dispatch starts no provider work; a delayed expired result cannot
  publish a draft; expired Copy cannot expose or retain the old result.
- Changed source values, permission revocation and cloud destinations fail.
- Oversized generated output cannot become reviewable.
- Quoted literals that look identical but have different Unicode bytes remain
  separate requirements, including when merging voice and source obligations.
- Ended context has no nonfunctional retry action.

The saved-result replay now uses the same grounded compilation and output checks
as the runtime selected branch. All eight baseline prompts remain byte-identical.
The checkpoint report under `Build/ComposeRoadmap/U12-selected-runtime/` binds 18
source files as they existed at that checkpoint and reports seven mechanically review-ready drafts, one rejected
quoted-source failure and five unchanged notices. Its semantic quality is
explicitly not evaluated. The original separate model-quality score remains
2/8 acceptable; the compiler integration does not relabel that failed gate.

The latest native checkpoint and log are recorded in
[the roadmap ledger](compose-roadmap-progress.md). A later current-source,
standalone probe passed real Accessibility selection capture, revalidation and
exact replacement readback in one fresh synthetic TextEdit document; its report
is under `Build/ComposeRoadmap/U17-textedit-surface/`. Signed installed-app
behavior, other editors, motion and model quality still require their own
evidence. The installed Cadence application has not been replaced by this work.


## Inspecting and excluding the selected source

The notch and debug panel now expose the captured source through a compact
inspector. It displays the full source used by the compilation, rather than
refreshing the current app. Opening checks authorization and freshness. Excluding
it keeps the previous draft attributed to that source but disables insertion and
retry. A pending generation is invalidated. Exclusion is action-scoped and does
not change the optional-capture setting for future requests.

The only current source is the complete selection. After exclusion there is no
source to rewrite. **Record new message** explicitly discards the previous draft
and starts a fresh recording with selection capture disabled for that one action.
Record Again also honors exclusion. Neither the old draft nor its source enters
the new request. Subsequent independent requests resume the configured capture
preference. A new edit command without message content stops before model work. Exclusion/regeneration
with multiple remaining sources is still roadmap work. Copying the labeled
previous draft remains explicit and does not save it to history.

Native controller tests cover keyboard suspension while inspecting, excluded
insertion, delayed provider completion, source-ID isolation, revocation and
copied-review dismissal ownership. Six offscreen production-view renders cover
short, long and excluded sources in light/dark appearances. Native popover focus,
scrolling interaction, expanded Accessibility operation and motion remain
separate certification gates on the unlocked desktop.


## Written technical details

Selected-source obligations include plain relative file paths with a directory
and file extension, even without backticks. `src/Auth.swift` must remain that
complete token, not `old/src/Auth.swift` or `src/Auth.swift.bak`. Validation compares
UTF-8 bytes, preserving Unicode spelling. Surrounding prose punctuation may change;
source text itself cannot authorize removal. Quoted text and URLs keep their full
existing obligations, without creating redundant nested path requirements.
Extensionless paths and general slash-separated prose are not newly inferred as
file paths. This guard protects specific details; it does not establish that a
rewrite follows the requested style or preserves every aspect of meaning.


## Refreshing the selection

**Refresh selection** is an explicit action in the source inspector. It discards
the reviewed derivative, restores the original pinned field, reads that field's
current selection under the live capture permission, and applies the same spoken
editing instruction. It creates a new request ID and source snapshot. No microphone
is opened, no text is inserted, and the previous source or draft is not sent as
input. The same provider and writing-default snapshot are retained; dispatch still
checks that provider's current authorization. There is no automatic provider switch.

Retry keeps the old source snapshot and its existing expiry. Refresh performs a
new bounded read and starts a new source lifetime. It cannot redirect to another
field or application. An application-only insertion target does not qualify for
refresh. A changed target, revoked permission or missing selection stops the new
request; the editing instruction cannot be copied or inserted as an unpolished
message. Excluded sources offer Record new message instead of Refresh selection.

The prior source inspector closes before refresh. Pending old generation results
are invalidated, and repeated or stale source-control callbacks cannot recreate
the discarded action. Selected rewrites remain excluded from history even after
the source capture has been cleared on successful insertion. Native focus and
selection behavior still require the separate real-app certification gate.
