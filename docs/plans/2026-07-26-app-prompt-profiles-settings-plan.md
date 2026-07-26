# App prompt profiles settings plan

## Goal

Replace the verbose inline App profiles form with the same compact row language used elsewhere in Settings:

- configured apps appear as icon + app name + enable switch + pencil;
- Add app opens a searchable sheet backed by Cadence's installed-application catalog;
- selecting an installed app creates its profile and opens a focused editor;
- the editor shows the exact app-specific writing prompt Cadence will send and lets the user override it;
- the fixed safety/system prompt remains owned by Cadence and is not editable.

## Data contract

Add an optional, validated `promptOverride` to `ApplicationConfiguration`.
When present, it replaces the selected preset's compiled writing instructions for
that app. When absent, the selected preset remains the source of the prompt.
Existing `customGuidance` remains additive and backward compatible.

The installed-app identity boundary remains unchanged: users select descriptors
discovered from application bundles rather than typing bundle identifiers.

## UI structure

1. App profiles card
   - one compact row per configured app;
   - app icon and name on the left;
   - enable switch and pencil action on the right;
   - no bundle path or long prompt text in the row.
2. Add app row
   - opens a sheet;
   - searchable list of installed, user-facing applications with icons;
   - already configured apps are marked and cannot be duplicated.
3. App prompt editor sheet
   - app icon and name;
   - compact writing-style selector;
   - prompt preview by default;
   - pencil enters editing in place;
   - Save persists an override; Restore preset removes the override.

## Verification

- legacy configuration JSON without `promptOverride` still loads;
- an override round-trips and replaces compiled preset instructions;
- restoring the preset removes the override;
- installed-app picker projection stays bounded/searchable and excludes helpers;
- Settings fixtures render list, picker, prompt preview, editor, switch, and icons;
- full XCTest suite and `./script/build_and_run.sh --verify` pass.
