# Compose Test Host

This standalone macOS development app provides controlled native and WebKit targets for roadmap U5. It lets an integration runner measure the text that actually arrived, including missing or duplicate insertion, without treating posted key events as proof of success. It contains no Cadence model, microphone, provider, history, or production application integration.

The host is deliberately separate from the shipping app and Xcode project. Building it does not install or launch it. Running it explicitly opens and activates its synthetic test window. Do not type personal content into this app.

## Build and check without opening a window

From the repository root:

```sh
bash tools/ComposeTestHost/build.sh
Build/ComposeTestHost/ComposeTestHost.app/Contents/MacOS/ComposeTestHost --self-test
python3 -B -m unittest discover -s tools/ComposeTestHost -p 'test_hostctl.py' -v
```

The build uses `xcrun swiftc`, targets macOS 14+, and ad-hoc signs `Build/ComposeTestHost/ComposeTestHost.app`. An optional first build-script argument changes the output directory. This is a local test artifact, not a distributable Cadence build.

The Swift self-test checks synthetic-only result summaries, duplicate counting, Unicode, the one-character partial-event fixture, and redaction. The Python tests check exact-value verification, Return detection, secure-field exclusions, stale acknowledgements, process changes, and private directory validation. These checks do **not** establish that Accessibility or real insertion works.

## Surfaces and identifiers

| Target identifier | Surface | Expected role/capability intent |
| --- | --- | --- |
| `native-field` | `NSTextField` | Standard editable single-line field |
| `native-editor` | Plain `NSTextView` | Standard editable multiline editor |
| `native-secure` | `NSSecureTextField` | Secure input; Cadence must exclude it |
| `native-button` | `NSButton` | Definite non-editor; focusable independent of keyboard-navigation settings |
| `web-textarea` | HTML `textarea` | WebKit editable multiline field |
| `web-contenteditable` | HTML `contenteditable` with textbox role | WebKit rich editor with plain synthetic input |
| `web-button` | HTML `button` | Definite non-editor |
| `web-cursor-button` | Focusable HTML element with button role and `cursor-text` class | Deliberately uncertain custom editor; no editable ancestor and keyboard-driven synthetic text storage |

Native targets expose the listed `AXIdentifier`. The window exposes `compose-test-window`, and the WebKit container exposes `web-container`. Web targets have stable DOM IDs and static accessibility labels. WebKit may expose IDs through `AXDOMIdentifier` rather than `AXIdentifier`; a future runner must inspect the actual AX tree on the test OS.

The cursor-button fixture is designed to exercise the existing `AXButton` plus `AXDOMClassList` text-cursor branch. Its actual exposed role and DOM class availability need platform verification; the host does not claim that WebKit reproduces Muse's exact accessibility tree. It is not a normal contenteditable field, so keyboard insertion must be measured separately from role detection.

## Explicit launch and control

Use a **new, empty, private directory for each app process**. The host requires user ownership and mode 0700, refuses a directory with existing files, and has no network listener. Do not reuse a previous run directory when restarting the process.

Example for an explicitly authorized integration session:

```sh
run_dir="$(mktemp -d /tmp/cadence-compose-host.XXXXXX)"
open -n Build/ComposeTestHost/ComposeTestHost.app --args --control-directory "$run_dir"
python3 tools/ComposeTestHost/hostctl.py --directory "$run_dir" wait-ready
python3 tools/ComposeTestHost/hostctl.py --directory "$run_dir" reset
python3 tools/ComposeTestHost/hostctl.py --directory "$run_dir" focus native-field
```

At this point the integration runner must invoke Cadence's production capture/insert path with a published synthetic fixture. `hostctl.py` does not inject text itself. For the short fixture, the exact input is `SYNTHETIC alpha 314.`. Retrieve the allowed inputs with the `fixtures` command. The other fixtures cover Unicode, including an emoji, a newline, and the one-character prefix expected after the injected partial failure.

```sh
python3 tools/ComposeTestHost/hostctl.py --directory "$run_dir" expect native-field --fixture short --no-return
python3 tools/ComposeTestHost/hostctl.py --directory "$run_dir" expect native-editor
python3 tools/ComposeTestHost/hostctl.py --directory "$run_dir" expect native-secure --no-return
python3 tools/ComposeTestHost/hostctl.py --directory "$run_dir" quit
```

`expect` takes a new snapshot and compares the **entire** UTF-8 value by its synthetic hash. Omitting `--fixture` verifies emptiness. `--copies 2` explicitly expects two copies; the default one-copy check rejects duplicates. Secure fields permit only an empty expectation. `--no-return` checks the relevant observed Return-event counter. Check every other field for emptiness to prove that insertion did not also reach another editor.

Commands are `reset`, `focus TARGET`, `snapshot`, `close-window`, `reopen-window`, `wait-ready`, and `quit`. `reopen-window` creates a new window with fresh controls; await readiness and reset before the next fixture. Closing the window does not terminate the process. Relaunching with a new directory creates a new process identity for restart tests. `focus` explicitly activates the test app; `snapshot`, `expect`, and `reset` do not request activation.

Successful commands/expectations exit 0; an observed value mismatch exits 1; a malformed request, unavailable host, or timeout exits 2. Default command timeout is 5 seconds. `--instance-id ID` rejects results from a different process instance. There must be only one controller per run directory.

## Local protocol and privacy

The controller atomically replaces `command.json` with a schema-1 command containing a fresh UUID, action, and optional target. The host polls it on its main run loop and atomically replaces mode-0600 `state.json`. Commands are serial, duplicate UUIDs are ignored, and a controller accepts only its own acknowledgement. This prevents a stale result being mistaken for completion.

Snapshots include process/instance identity, window generation and visibility, readiness, focus hints, sequence number, field summaries, and Return/button counts. The host reads **only its own controls**. It never reads another app, the system clipboard, or a user's saved data. WebKit uses an ephemeral data store, bundled inline HTML, a restrictive content security policy, and blocked external navigation.

No raw editor value is written to a file, stdout, or OSLog. Empty values and exact concatenations of the three published synthetic fixtures expose SHA-256 hashes and fixture counts. Any other value is redacted and has no hash or fixture counts. Secure fields always redact hashes and counts, even for a synthetic value. Length and emptiness remain available to detect an unintended write. In-memory raw values exist briefly to produce these summaries; `reset` clears them. Logs contain only a fixed snapshot-write failure message.

This synthetic readback is **not** authorization for production Cadence to read user editor contents. Production confirmation requires its own content-access policy.

## Opt-in production integration harness

`CadenceTests/ComposeInsertionIntegrationTests.swift` exercises real `ScribeContextService`, `SystemScribeAccessibilityReader`, `RuntimeApplicationProcessAuthority`, capability assessment, and `TextInsertionService`. It is disabled in ordinary test runs unless `CADENCE_COMPOSE_INSERTION_INTEGRATION=1` reaches the actual test process.

To run an explicitly authorized interactive-desktop session, with no competing app automation:

```sh
bash tools/ComposeTestHost/integration-run.sh --run
```

The script builds the host, regenerates the Xcode project, and runs only the integration suite without parallel test execution. It stages the signed host app into a fresh `cadence-compose-U5.*` directory beneath `${TMPDIR:-/tmp}`; the native process uses only these temporary paths for app launch, reports, and controls. This avoids Documents-folder TCC prompts during native evidence IO. After the test, the shell copies the complete evidence directory into `Build/ComposeRoadmap/` and prints both paths. It does not install Cadence. The test checks Accessibility trust **before** launching or focusing the synthetic host. Missing trust writes `status: blocked_permission`, records a test failure, and the wrapper exits 3. It never prompts for or changes macOS permissions. A skipped, undiscovered, incomplete, or failed test cannot satisfy the wrapper's 18-case evidence check.

The 18 cases cover seven actual insertion combinations (native/web fields, multiline text, Unicode, and a button-role text-cursor editor), one repeated-success refusal, three secure/noneditable refusals, changed field, another synthetic host process, a separate system editor process opened on a synthetic document, recreated window, cleared capture, terminated process, and an injected event-emitter failure after one character. Each supported insertion must produce exactly one complete fixture in its intended field while all other fields stay empty. Single-line fixtures must produce zero Return events. Refusal cases require production rejection and zero additional calls to the production event-emitting service. The failure case must report insertion as unconfirmed, refuse another post for the same capture, and leave exactly the published one-character prefix in the host editor.

A narrow wrapper around the real `TextInsertionService` checks the owned host's bundle, bundle path, live PID, instance, window generation, and frontmost process immediately before delegating insertion. It does not fake insertion or produce successful observations. If this test boundary intervenes, the case **fails**; its rejection is never credited to production. This prevents a test from typing into an unrelated app if desktop focus changes. Use a quiet desktop during the run because system focus remains inherently shared.

The report includes a hash of the host binary, OS version, actual test executable path/PID, host process/instance, completed-case counts, and fixed outcome codes. It includes no raw editor values, raw exceptions, or secure-field hashes. The per-run host-control directory contains only the redacted host snapshots described above. `TestResults.xcresult` and `xcodebuild.log` are retained alongside `integration-report.json`; inputs are exclusively the published synthetic fixtures.

`CADENCE_INTEGRATION_DERIVED_DATA` can select a different build directory. Changing build/executable identity can affect Accessibility trust; the test's preflight is authoritative. Do not run this script while another build or agent owns the same derived-data directory.

### Standalone production runner

The XCTest host may lack Accessibility trust even when an unbundled development
process is trusted. The separate `integration-cli-run.sh` compiles the **same**
18-case test source against the current Debug Cadence module and production
dynamic library. It does not simulate AX reads or insertion. It uses the same
synthetic host and exact-value checks, but the command-line executable performs
its own Accessibility and desktop-unlock preflights before opening any window.

```sh
bash tools/ComposeTestHost/integration-cli-run.sh --check  # build only
bash tools/ComposeTestHost/integration-cli-run.sh --run    # unlocked desktop, opt-in
```

The check builds the current Debug app, host, and runner without launching them.
The run writes `integration-report.json` and a redacted runner log in a private
temporary directory, then archives that directory under `Build/ComposeRoadmap/`.
It exits nonzero unless all 18 cases pass; a locked desktop is `blocked_desktop`
and missing trust is `blocked_permission`, both with zero passed editor cases.
The standalone process is a test tool only. Its trust does not establish that
the installed Cadence app has the same permission or that Muse is certified.
The console preflight requires a logged-in, on-console session and rejects an
explicit `CGSSessionScreenIsLocked` value of true. An unlocked session may omit
that key, as observed on the September 25 controlled run.

## Integration evidence boundaries

The host and harness source alone do not complete U5. A successful **executed** integration report must establish the relevant checks below; unexecuted source and compile-only checks are infrastructure evidence:

1. Launch the host deliberately, verify actual AX capabilities and the cursor-text hint, and record OS/build and host binary hash.
2. Use production target capture, capability assessment, target verification, and insertion services. Mock insertion or setting field values directly cannot count as insertion evidence.
3. Verify exact one-copy insertion for native and supported web editors, Unicode integrity, unchanged non-target fields, no Return on uncertain targets, and empty secure fields.
4. Capture a target, then switch fields/apps, close/reopen its window, or restart its process. Assert no wrong-target write and an honest retained-draft recovery outcome. The current harness checks field/window changes, another foreground synthetic host process, a newly launched system editor on a synthetic document, and terminated-process refusal; it does not switch to a user document or force OS PID reuse.
5. Exercise duplicate Insert activation, late callbacks, clipboard failure, and partial-event failure with appropriate injected seams. The controlled host now tests both a repeated successful post and refusal of a retry after one-character partial posting. Duplicate Compose UI activation and clipboard failure still need separate integration checks.
6. Preserve command acknowledgements and summarized observations as evidence. Distinguish confirmed insertion from an attempted insertion and report unsupported AX surfaces explicitly.

The host itself needs no Accessibility grant because it reads its own controls. The process exercising production AX/CGEvent APIs does need the appropriate macOS trust. An XCTest runner or standalone executable has a different executable identity from installed Cadence; Cadence's grant does not prove that runner is trusted. Before any integration attempt, check `AXIsProcessTrusted()` in the **actual runner process** and record a distinct `blocked_permission` result if false. A blocked/omitted attempt must not increment passed cases or be represented as successful insertion. Do not grant or prompt for broader access from a compile-only check. The real runner should also record host readiness/focus failures separately from insertion failures.

Real Muse testing remains supplemental and version-specific. This fixture cannot certify every custom editor or establish provider quality, microphone behavior, or animation smoothness.
