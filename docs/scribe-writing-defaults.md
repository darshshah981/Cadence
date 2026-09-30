# Explicit writing defaults

This is an incremental implementation of U15, not completion of scoped writing
preferences or a model-quality certification. The installed app is unchanged.

## Current behavior

Settings has a global writing-default editor with an enable switch, six optional
tones, and a preference for concise drafts. All choices start disabled. Changes
remain local to the editor until Save; Cancel discards them. Reset removes the
saved global choices. Closing and reopening the editor reloads current storage.

The stored payload contains only closed style values. It contains no transcript,
source text, inferred trait, app/account identity, or arbitrary prompt. Unknown
versions and malformed values are preserved and not applied. The explicit
“Remove unreadable defaults” recovery action removes only that preference key;
it refuses to delete a value repaired by another editor in the meantime.

Compose snapshots enabled choices when recording starts. Changes made afterward
apply to the next recording, not the existing draft, retry, or refinement.
Configured app profiles take priority over these global choices. Explicit
recognized voice directions remove conflicting global fields before compilation;
for example, a spoken formal direction removes a saved warm tone while retaining
an independent concision preference. Original speech remains unchanged.

Defaults reach ordinary Compose, the local selected-text rewrite, and local
refinement. They do not choose providers, expand context consent, or retain source
content. Cloud requests receive only the compiled writing-guidance category
already covered by provider setup. Missing/unreadable defaults leave the existing
writing behavior in place. Deterministic prepared-draft shortcuts are disabled
when global defaults, a configured app profile, a remembered environment
preference or an explicit legacy style requires generation. An app profile that
overrides global defaults must not accidentally re-enable a formatting shortcut.

An explicit-save archive now round-trips typed global, account-bound app,
project, and conversation choices using opaque scope keys. It rejects temporary
current-action choices, malformed scope keys, duplicate fields, corrupt values,
and unknown future versions. An unreadable archive is preserved until an
explicit recovery action; stale editors cannot replace a newer saved revision.
An edit controller now commits an accepted typed choice to the archive before
publishing it in the active snapshot. A stale or failed save leaves both copies
unchanged; cancel, delete, reset and restart have explicit paths. Its caller
must provide a freshly verified scope and a real user Save action. The first
scoped surface is now TextEdit. Settings has explicit Tone and Concise choices
with Save, Cancel and Reset. It saves only typed choices under an opaque key
tied to the local macOS user and TextEdit integration. Compose reads them only
for the pinned system TextEdit app after microphone capture starts, then freezes
the result for that recording. App choices override conflicting global fields;
a spoken direction for the current request still wins. Corrupt or newer archive
data is preserved and omitted from generation. Other applications, project and
conversation editing, richer per-field integration with existing app profiles,
preference suggestions, provenance controls and live UI certification remain
open. No automatic learning is active.

An active configured TextEdit app profile still takes priority over both global
and TextEdit defaults. Settings now shows this condition beside the TextEdit
choices, so a saved choice is not presented as if it were currently effective.
Reset and unreadable-data recovery have distinct completion messages instead
of saying that new recording defaults were saved. This does not merge
individual app-profile fields with the scoped choices.

## Verification

Software tests cover explicit save, unsaved edits, reset, restart, stale editors,
corruption/future-version preservation, deliberate unreadable-data removal,
voice precedence, configured-app precedence, separate provider compilation,
recording-time snapshots, retries, selected rewrites and refinement. The latest
native log is recorded in the roadmap ledger. These are synthetic tests; real
Settings rendering and keyboard operation remain separate platform checks.
The scoped archive and explicit edit controller pass 11 focused native tests
across two suites, covering restart, account/project isolation, temporary-scope
rejection, stale-save atomicity and recovery preservation.
Two TextEdit-specific tests cover local account and app isolation, restart,
stale Save, Reset, and current voice precedence. The source path is compiled
and native-tested. The isolated Debug Settings fixture displayed the full
TextEdit section without clipping; Save, Cancel and Reset changed the visible
state as intended. This did not replace the installed app or establish the
model-quality gate or live dictation behavior.

Six synthetic preference cases are exported through the production request
compiler by `ComposeGlobalWritingDefaultsTests.exportProductionPreferenceEvaluation`.
Set `TEST_RUNNER_CADENCE_EXPORT_GLOBAL_DEFAULTS=1` and
`TEST_RUNNER_CADENCE_SCRIBE_EVALUATION_DIRECTORY` to a temporary directory when
running that suite. The exported requests and corpus can be passed to the existing
model evaluator and fixed-rubric aggregate scorer.

The frozen U15 production baseline generated all six requests. Agent review against
the preregistered rubric found two acceptable drafts and four unchanged drafts;
no critical errors occurred in that run. The quality gate fails. A focused-prompt
experiment produced three acceptable drafts but answered a recipient question
with an invented first-person availability claim. That experiment was reverted;
its frozen evidence remains explicitly rejected. These development cases are not
an independent held-out reserve or proof that preferences reduce corrections in
ordinary use.

Evidence: `Build/ComposeRoadmap/U15-global-defaults-baseline/` and the rejected
`Build/ComposeRoadmap/U15-global-defaults-focused/` experiment.

A later candidate retained bundled preset instructions alongside global
defaults in the same request. Six on-device generations were byte-for-byte
identical to the frozen baseline, including its four unchanged drafts. The
candidate added prompt bytes without improving this corpus, so it was reverted.
Its saved source, bound requests, results, and byte comparison are in
`Build/ComposeRoadmap/U15-global-defaults-bundled-candidate/`.

Another hand-built, synthetic prompt experiment added an explicit editing
reminder to the four general-path baseline requests. All six production
on-device model drafts were byte-identical to the frozen baseline. It was not
exported by the current compiler and was not shipped. Its request/result
hashes and comparison are in
`Build/ComposeRoadmap/U15-global-defaults-style-candidate/`. The six-case
quality result remains 2/6 acceptable with zero critical failures; this
candidate provides no improvement. A focused TextEdit/profile-priority test
run passed 3 tests in 1 suite at
`/tmp/cadence-u15-profile-priority-test.log`.

A final hand-built short-prompt experiment kept questions addressed to the
recipient and removed the earlier invented-answer failure. Its model drafts
scored 3/6 acceptable with no critical error, but warm and concise requests
still came back unchanged; the 95% quality gate still fails. It was not
exported from the production compiler or shipped. The bound requests,
results, semantic review and aggregate are preserved under
`Build/ComposeRoadmap/U15-global-defaults-focused-guarded/`.
