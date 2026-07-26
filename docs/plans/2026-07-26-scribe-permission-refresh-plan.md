# Scribe Permission Refresh Fix

## Problem

Scribe checks `AppModel.permissions`, which can lag behind the current macOS
privacy state. Normal dictation refreshes permissions when recording begins.
Scribe also reports every otherwise-unclassified startup failure as a
microphone problem, even when microphone access is already granted.

## Change

1. Evaluate Scribe permission readiness from a fresh `PermissionsService`
   snapshot at activation time.
2. If microphone access is genuinely missing, use the existing macOS request
   path and evaluate the resulting fresh snapshot.
3. Report only the permissions that remain missing.
4. Use a neutral recording-start failure for non-permission errors.

Scribe will continue to require Microphone, Accessibility, and Input Monitoring,
matching the existing insertion and global-shortcut safety contract.

## Verification

- Regression tests cover exact missing-permission reporting, including a
  granted microphone with another permission missing.
- Run the focused tests and the full test suite.
- Rebuild, install, and verify `/Applications/Cadence Debug.app`.
