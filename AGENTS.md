# AGENTS.md

Guidance for ZCode agents working in this repository. Read this before editing.

## What This Is

Cadence is a native macOS menu-bar app (SwiftUI/AppKit hybrid) with two product surfaces:

- **Dictation** — push-to-talk: capture mic, transcribe locally with WhisperKit, insert text into the focused app.
- **Meeting capture** — record system or mic audio, show live draft transcript, run a final pass, summarize, export Markdown.

- macOS 14.0+, Swift 5.10, AppKit + SwiftUI hybrid.
- Xcode project is **generated** from `project.yml` via XcodeGen. Do not hand-edit `Cadence.xcodeproj/project.pbxproj` for structural changes — edit `project.yml` then run `xcodegen generate`.
- Debug product is `Cadence Debug` (bundle `com.darshshah.Cadence.debug`); Release product is `Cadence` (bundle `com.darshshah.Cadence`). Never distribute the Debug build.

## Build, Test, Run

```zsh
xcodegen generate                                      # regenerate Xcode project after project.yml changes
./script/build_and_run.sh                              # build + install debug app + launch
./script/build_and_run.sh --test                       # run XCTest suite (Debug)
./script/build_and_run.sh --verify                     # build, launch, assert main window appears
./script/build_and_run.sh --audio-smoke                # verify system-audio capture produces frames
./script/build_and_run.sh --logs | --telemetry         # stream OSLog for the app / subsystem
./script/build_and_run.sh --debug                      # build, then lldb the executable
scripts/install_dev_app.sh                             # install debug app to /Applications
scripts/package_release.sh                             # archive Release, sign Developer ID, notarize, staple
```

Bare `xcodebuild` equivalent used by CI:

```zsh
xcodebuild test -project Cadence.xcodeproj -scheme Cadence -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

CI (`.github/workflows/ci.yml`) runs `xcodegen generate` → build → test on macOS 15. Keep `project.yml` + `CadenceTests/` passing. Code signing is disabled in CI (`CODE_SIGNING_ALLOWED=NO`).

## Architecture & Layer Rules

`AppModel` (`Cadence/App/AppModel.swift`, `@MainActor ObservableObject`) is the central orchestrator — UI reads state from it and calls methods on it. It is already large: **prefer putting new behavior in a Service and letting AppModel coordinate**, rather than growing inline logic.

Layered boundaries — do not cross these:

- **App** (`Cadence/App/`): `CadenceApp` (SwiftUI scenes: `MenuBarExtra`, `Settings`), `AppDelegate` (activation policy, Dock reopen), `AppModel` (orchestrator).
- **Models** (`Cadence/Models/`): value types only. `DictationModels`, `MeetingModels`, `AppAppearance`.
- **Services** (`Cadence/Services/`): all platform/IO/ML work. Capture, transcription, insertion, persistence, analytics, hotkeys, Google Calendar.
- **UI** (`Cadence/UI/`): SwiftUI views. `MainWindowView` (primary window, sidebar+detail), `MenuContentView` (menu-bar popover), `MeetingNotesWindow`, `SettingsView`, `HUDView`, `PermissionGuideWindow`/`PermissionsView`.

Key invariants:

- **Window ownership**: the main window is owned by `MainWindowController` in `MainWindowView.swift`. Do **not** add a `WindowGroup` in `CadenceApp` — that caused duplicate windows. `AppModel.showMainWindow()` is the single route to reveal it.
- **Dictation vs Meeting are separate pipelines.** Dictation must stay short/responsive and must not depend on meeting storage or the meeting final-pass transcriber.
- **Meeting recording durability**: every recording has a `recordingID`. Live draft segments are `origin = .liveDraft`; final segments are `origin = .final`, both tagged with that `recordingID`. The final pass **only** replaces live-draft segments with a matching `recordingID`. An empty final-pass output is treated as failure so live-draft text is retained. Keep raw capture durable before any lossy processing.
- **`TranscriptionEngine`** (protocol in `Cadence/Services/TranscriptionEngine.swift`) is the seam between production WhisperKit and test mocks. Tests use mock engines — do not load WhisperKit in unit tests.
- **Permissions**: `PermissionsSnapshot.allRequiredGranted` = Microphone + Accessibility + Input Monitoring. Screen Recording is **not** in "all required" — it is only requested contextually for meeting system-audio capture via `AppModel.requestMeetingCaptureSourcePermissions()`.

`docs/codebase-guide.md` is the authoritative deeper reference (flows, file map, debugging playbook, known design risks). Read it before touching dictation, meeting capture, permissions, or window lifecycle.

## Coding Conventions

- Swift files begin with a focused `import` set, then a `private let <name>Logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "<Area>")` from `OSLog`. Match this when adding a file.
- Core runtime types are `@MainActor final class` (e.g. `AppModel`, `DictationCoordinator`). Data models are structs/value types.
- `UserDefaults` preference keys live as `static let` constants inside `AppModel`'s private `PreferenceKey` enum. Note: many still use the legacy `FlowState.*` prefix (historical product name) while newer keys use `Cadence.*`. Keep an existing key's prefix when editing it.
- Settings are loaded in `AppModel.init()` and mutated only through explicit setters (`setWhisperModel`, `setShortcut`, `setAnalyticsEnabled`, `setMeetingCaptureSource`, …).
- Logging: use `Logger` (OSLog) with a `category`. Do **not** `print()` from production code. The app subsystem is the bundle id.

## Privacy Boundary (strict)

Analytics (`AnalyticsService`) is opt-in and off by default. Never send to analytics, logs, or any remote service: **audio, transcript text, vocabulary terms, exact shortcut keys, dictated app names, raw error messages, or saved meeting audio.** See `docs/privacy.md`. When adding any analytics/telemetry call, confirm it carries only coarse, privacy-safe fields.

## Local State & Storage Locations

- WhisperKit models: `~/Library/Application Support/Cadence/WhisperKit`
- Meeting notes (JSON): `~/Library/Application Support/Cadence/MeetingNotes` via `MeetingStore`
- Meeting audio (CAF): `~/Library/Application Support/Cadence/MeetingAudio` via `MeetingAudioStore`
- Google OAuth tokens: Keychain via `KeychainGoogleCalendarTokenStore`
- Settings + transcript history: `UserDefaults` via `AppModel`

## Secrets & Google OAuth

Google Calendar uses a **desktop-app loopback OAuth flow** (temporary `127.0.0.1` listener during sign-in only). Client credentials are **not** committed. For local dev, create the git-ignored `local/google-oauth.env` (also auto-loaded from `~/.cadence/google-oauth.env`):

```sh
GOOGLE_OAUTH_CLIENT_ID=…apps.googleusercontent.com
GOOGLE_OAUTH_CLIENT_SECRET=…
```

Check config with `./script/build_and_run.sh --google-config`. `local/` is git-ignored — never commit credentials or a real `.env`.

## Release / Distribution

Only `Build/Release/Cadence.dmg` (Developer ID Application, notarized + stapled, `spctl`-verified) is distributable. Never upload `Cadence Debug.*` or `Build/DerivedData`. See `docs/release-checklist.md`. `scripts/package_release.sh` supports `--skip-notarization` for local packaging checks, but a real release needs a Developer ID cert + configured `notarytool` keychain profile.
