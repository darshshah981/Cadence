# Scribe Copy Immediate Outside-Dismiss Regression

## Confirmed failure

The installed app receives and correctly classifies the first mouse click outside
the copied Scribe review. The current handler then delegates to asynchronous
Scribe cancellation without first dismissing either UI surface. Cancellation
can await audio/transcription cleanup, leaving the notch review and HUD pill
visible after the click.

## Fix contract

- Successful Copy keeps the completed review visible and interactive.
- The first outside click starts the notch collapse immediately.
- The Scribe HUD is restored immediately when it owns the HUD.
- Coordinator cancellation and retained-context cleanup continue asynchronously.
- Inside clicks keep Insert, Copy, and Discard usable.
- Mouse monitoring remains one-shot and is removed on dismissal or state change.

## Verification

1. Add a controller-level fake mouse monitor and reproduce the missing immediate
   dismissal before changing production behavior.
2. Assert that Copy preserves review actions, an inside click does nothing, and
   the first outside click hides the presentation and invokes cleanup once.
3. Run focused and full tests.
4. Rebuild/install the signed Debug app.
5. Use the isolated notch fixture to visually verify the outside click removes
   the notch review and Scribe HUD.
