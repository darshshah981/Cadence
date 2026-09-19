# Cadence testing workflow

## Know which app is running

Debug is `/Applications/Cadence Debug.app` (`com.darshshah.Cadence.debug`). Release is `/Applications/Cadence.app` (`com.darshshah.Cadence`). They have independent privacy permissions. Run only the intended app during manual tests. Record its bundle path, executable SHA-256, signing authority, source revision, and whether the source tree was dirty; version `1.0` alone does not identify a build.

Build and verify a replacement before installing it. Preserve a rollback copy. Do not use an ad-hoc app to evaluate permission persistence: macOS uses code identity to identify permission recipients. Keep the QA bundle ID, install path, and signing requirements consistent across updates. An exact valid certificate can avoid ambiguous local certificate selection; certificate selection belongs in local build configuration, not a developer-specific committed hash. See [Apple's explanation of code-signing requirements and privacy](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

## Four checks, with different jobs

1. **Every change:** run deterministic service/model tests with mock transcription engines, isolated defaults, and volatile credentials. CI can disable signing. Run timing benchmarks with a quiet machine and investigate reproducible failures without loosening thresholds to make a run green.
2. **Every UI change:** exercise synthetic debug fixtures, keyboard-only use, narrow windows, expanded help, scrolled bottom states, and accessibility settings. Screenshots confirm layout; clicks and assertions confirm behavior. Fixtures must not write real history, credentials, or permission grants.
3. **Before accepting permission changes:** use a consistently signed installed build in a disposable macOS account or test machine. Test the actual OS dialogs and Settings switches, not only mocked booleans. Capture timestamps for click → Settings visible → switch changed → Cadence confirms. Verify responsiveness while Settings is open. Do not infer latency improvements from unit tests.
4. **Before release:** test the actual signed, notarized Release candidate on a Mac not used for development. Verify install, first launch, update, permission persistence, dictation insertion into another app, focus-change recovery, offline behavior, and meeting capture when enabled. See [Apple's Developer ID testing guidance](https://help.apple.com/xcode/mac/current/en.lproj/dev1cc22a95c.html).

Run the unit suite:

```sh
xcodebuild test -project Cadence.xcodeproj -scheme Cadence \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## Permission acceptance matrix

| Scenario | Required result |
| --- | --- |
| Fresh install | One deliberate action at a time; explanation before each prompt |
| Microphone denied | No surprise Settings launch; explicit recovery action |
| Already granted | Skip that step; never ask again unnecessarily |
| Slow Settings interaction | Continue checking during the handoff; confirm only the actual OS grant |
| Repeated click | No overlapping prompt or repeated immediate Settings launch |
| Settings cannot open | Show the manual Privacy & Security route and permit retry |
| App absent from list | Identify the exact app and offer Finder; explain adding it where supported |
| Switch on but not detected | Explain reopening the same app; allow rechecking without false success |
| Grant requires relaunch | Resume using the refreshed OS state after reopening |
| Permission revoked | Show the missing step again; recording/insertion remains gated |
| Managed/restricted Mac | Explain that administrator help may be needed |
| All three core grants | Explicit completion; user chooses Continue |
| Meeting system audio | Request Screen Recording contextually; never block dictation setup on it |
| Signed app update | Existing grants continue to work with the same code identity |

Use a disposable account or VM snapshot for fresh-state cases. If a tester deliberately resets permissions, scope the reset to the test app and specific service following [Apple's protected-resource reset guide](https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos). Never reset all of a user's permissions as routine debugging.

## September 6 permission implementation

The shared inline card now guides Microphone → Accessibility → Input Monitoring, skips existing grants, explains the currently running app, and offers recovery help. Onboarding content scrolls and no longer advances automatically after the last grant. Screen Recording stays contextual.

Settings handoff uses typed pane URLs without PermissionFlow's floating window tracker. Progress checks core permission state every 500 ms only during a user-initiated handoff, stopping on grant, cancellation, or roughly two minutes. This removes cross-process Settings window tracking from the path; it is not a measured latency guarantee.

Regression tests cover pane mapping, repeated/failed opening, step progression, delayed grant detection, cancellation, and bounded timeout. Real OS grant/relaunch and latency acceptance remain separate manual gates.

## Loading HUD visual regression — September 6

The long setup status used intrinsic text width inside a 112-point activity slot, so it could overlap the adjacent app label. Both steady and transitioning preparation states now use “Preparing…”, and status text respects its slot. The first-use companion message uses smaller theme-aware text and a width measured from its content. Its panel is clamped to the screen's visible bounds instead of extending past a corner.

The signed suite passed all **661 tests** with no failures or skips. New regressions check preparation text plus spinner spacing against the available slot, and subtitle containment at every HUD position on primary and negatively positioned secondary screens. The native loading preview was inspected: the status and app name were separate, and the entire companion message was readable.

Reproduce without recording or downloading a model using the Debug app with `--scribe-fixture settings --hud-fixture-preparing`. This uses the existing isolated fixture defaults. Close its main window to inspect the floating HUD. Quit the fixture app and reopen normally after testing; the fixture intentionally holds the loading state.

## Empty Compose recording recovery — September 6

An empty recording previously entered the persistent Compose failure surface. Whisper's `emptyAudio` and `noTranscript` errors also fell through to generic transcription failure, leaving the long “or use Dictation” message in the HUD indefinitely.

Empty transcripts and those two explicit engine outcomes now show only a compact “No speech” HUD for 1.5 seconds, then release transient context and return to idle. They do not open the draft recovery panel or call the writing provider. A request/generation guard prevents an old feedback timeout from dismissing a newer recording. Retained drafts and actual model/provider failures keep their recovery behavior.

The signed full suite passed **664 tests**, zero failed or skipped. Added mock-engine coverage for empty text, empty audio, no transcript, immediate recording reuse, stale timeout isolation, and a genuine model failure remaining available. This verifies the deterministic lifecycle without recording or transmitting ambient audio; a real microphone silence check remains a manual acceptance case.

### Verification record — September 6, 2026

**Follow-up: signing resolved and Debug installed.** The failing resource bundle signed successfully after the signing command's authorization wait, followed by a successful full signed build and strict nested signature verification. The signed test run passed all **659 tests** (zero skipped or failed). Computer Use could not inspect SecurityAgent; authentication remained local. No keychain trust override, certificate deletion, or TCC reset was performed.

The development scripts now read ignored `local/code-signing.env`. Set `CADENCE_DEBUG_SIGNING_IDENTITY` to an exact working development identity on the test Mac when generic certificate selection is ambiguous. `CADENCE_RELEASE_SIGNING_IDENTITY` is a separate optional override; the Debug identity does not replace Release signing. `CADENCE_DEVELOPMENT_TEAM` optionally overrides the existing project team. Both scripts pass matching manual signing settings to package targets as well as the app. Key access must be approved locally if macOS requests it; see [Apple's signing authorization guidance](https://developer.apple.com/forums/thread/712005).

The inline Accessibility and Input Monitoring steps now include a draggable app card using the running bundle's file URL and Finder-compatible filename representation. Its drag accepts the first mouse event from an inactive window and permits copy operations only. Microphone continues to use its native permission prompt. Finder and Settings “+” remain available for users who cannot drag or whose OS pane rejects the drop. The payload round-trip has a regression test; fresh-account OS drop/grant acceptance remains a manual check.

Installed Debug uses Apple Development signing, team `P3MT7UXJ5N`; the previous ad-hoc Debug app is preserved in `Build/InstallBackups/20260906-permissions/`. Release remains installed. Live installed UI was checked after launch: core setup is no longer shown because the existing grants are recognized. No permission switches were changed during verification.

Final installed executable SHA-256: `0eacf604e27dd78ffedb91578f4edd025c8f789f901a3c96ad77def7d9e220e9`. Debug implementation dylib SHA-256: `076c1a5a8d2e64a729ccdcadc442b42f827c1b6ca9696d4f597bfa4b054e8d9d`. The final first-mouse drag adjustment was rebuilt, signature-verified, installed, and launch-checked after the signed suite run. Shell changes passed `bash -n`; diff whitespace checks passed. Review stayed scoped to this follow-up; overlapping work remains uncommitted.

The entries below describe the earlier, pre-installation checkpoint:

- Full unsigned suite passed: 654 Swift Testing tests in 66 suites and four XCTest checks. One initial parser timing failure passed on rerun without changing its threshold.
- Fixed an application-catalog test race exposed during verification: a coalesced relocation test now waits for both events to enter its controlled debounce gate before releasing it. Production catalog behavior was not changed.
- Live isolated preview: verified the General permission card, expanded help, scrolling to recovery controls, onboarding permission content and fixed footer, rechecking, the Microphone Settings deep link, and waiting status. No permission switches were changed. Actual granted/denied/relaunch flows and comparative latency were not verified.
- A development-certificate signing probe succeeded; the full signed build failed with `errSecInternalComponent` on the `swift-transformers_Hub.bundle` dependency. The live preview was ad-hoc and is layout/handoff evidence only.
- Installed apps were preserved: Release executable SHA-256 `27d04960e2e8aa18868f3b3c5aae0109e45414b681bd777917225459a16a5f58`; Debug executable SHA-256 `2eeac9fa07045b2547c096fbeebc74a27f5a4072d7d1099a3a8f02948f3350f5`. Both report version 1.0; Release was running. The September 6 permission changes are not installed in either bundle.
- Quality review: targeted manual review because the branch contains overlapping pre-existing work. File-wide simplification and automatic commit/push were skipped to preserve those edits. Reviewed request deduplication, failed handoff cleanup, cancellation, main-thread polling, contextual Screen Recording, and privacy-safe logging.
