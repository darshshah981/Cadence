# Scribe Insert, Settings, and Transcribing-State Alignment

## Goal

Make the reviewed Scribe draft insert reliably into the originally captured
editable app, remove duplicated app-adaptation controls from the Scribe
Settings page, and make the notch review surface reuse the pill's transcribing
state instead of presenting a separate empty state.

## Diagnosis

- Scribe currently restores the pinned Accessibility element and writes through
  `kAXSelectedTextAttribute`.
- Some macOS and Electron-style editors can return a successful Accessibility
  write without visibly inserting text.
- Normal dictation already uses Cadence's tested Unicode `CGEvent` insertion
  service after target validation.
- App-specific behavior currently appears in both Scribe Settings and
  Apps & Integrations, weakening ownership and wayfinding.
- The notch projection labels both the pill and box as transcribing, but the box
  renders its own empty/loading treatment instead of the pill's established
  transcribing visual language.

## Implementation

1. Keep Scribe's pinned process/window focus restoration and 500 ms activation
   handoff.
2. Re-read the active target after restoration and require the original process
   identity before emitting text.
3. Insert through `TextInsertionServing`, the same Unicode event path used by
   normal dictation, rather than trusting an unobservable AX selected-text
   write.
4. Add a regression test where the AX replacement seam would report success but
   only the shared text-insertion seam is accepted as completion.
5. Keep global Scribe controls on the Scribe page. Move the app-adaptation
   switch and all app-specific configuration ownership to App Profiles under
   Apps & Integrations; remove the duplicate legacy app rows from Scribe.
6. Render the notch box's transcribing content with the same state component and
   label used by the pill, with Reduce Motion behavior preserved.

## Verification

- Targeted Scribe context/coordinator/notch/settings tests.
- Full `./script/build_and_run.sh --test`.
- `./script/build_and_run.sh --verify`.
- Inspect the installed Settings page and Scribe notch fixture.
- Verify the installed app signature and relaunch the normal Debug app.
