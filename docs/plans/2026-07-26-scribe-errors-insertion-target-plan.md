# Scribe Startup Errors and Original-Target Insertion

## Problems

1. Provider setup failures thrown before recording are flattened into a generic
   recording error.
2. The nonactivating Scribe review panel can still retain key-window ownership
   while the Insert action begins, allowing Unicode events to miss the editor
   that was focused when Scribe started.

## Changes

1. Preserve `ScribeProviderFailure` categories at the AppModel boundary and
   present their existing, specific recovery copy.
2. Keep configuration errors in the Scribe error state rather than describing
   them as microphone or recording failures.
3. Treat `.inserting` as an immediate focus-handoff state: resign and hide the
   review panel before `ScribeContextService` restores the pinned app and
   insertion point.
4. Continue using `TextInsertionService`, the same Unicode event mechanism as
   normal dictation, after the original process and focus are restored.
5. Reopen the review surface with the retained draft if insertion verification
   fails.

## Verification

- Regression-test provider failure copy for missing setup and invalid saved
  configuration.
- Regression-test that the `.inserting` presentation requires immediate focus
  handoff.
- Retain Scribe context tests proving insertion targets the captured app and
  blocks a different app.
- Run the full suite, rebuild, install, and verify Cadence Debug.
