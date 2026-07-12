# Focused-app identity and icon correctness contract

- Date: 2026-07-11
- Wayfinder ticket: [Diagnose and specify focused-app identity and icon correctness](https://github.com/darshshah981/Cadence/issues/42)
- Baseline: Adaptive Scribe PR #34 at `04391d3`
- Depends on: [Installed-app identity and picker lifecycle contract](./2026-07-11-installed-app-identity-picker-contract.md)

## Decision

The missing or stale active-app logo is a state-ownership defect, not a Cursor bundle or icon defect. Cadence must introduce one local, main-actor focused-application monitor that publishes value snapshots, make each Dictation or Scribe action pin an immutable target snapshot from the authoritative focus source, and bind the HUD to a presentation derived from that same snapshot.

Live idle presentation follows the current eligible external application. Once an action begins, its name and icon remain pinned to that action until it ends. App switches never silently relabel or retarget an in-flight action. If Cadence cannot prove that the insertion destination still matches the pinned target, it fails closed and preserves the text for copy/retry instead of inserting into another app.

Application identity, display metadata, and icons remain local. No app identity enters provider input, logs, analytics, or persisted transcript history.

## Diagnosis

### Confirmed local facts

- `/Applications/Cursor.app` is a valid application bundle with bundle identifier `com.todesktop.230313mzl4w4u92`, display name `Cursor`, and declared icon file `Cursor.icns`. The reported failure is therefore not explained by a missing Cursor icon resource.
- PR #34 is the inspected baseline in both the active checkout and `/Users/darshshah/.codex/worktrees/5792/Cadence`, at commit `04391d3`.

### Exact broken path

1. `AppModel` retains `lastExternalApplication` as an `NSRunningApplication`, but the property is private and exists only as an imperative convenience (`Cadence/App/AppModel.swift:178`).
2. The only update path listens to `NSWorkspace.didActivateApplicationNotification`, ignores Cadence, and assigns the received object to that property (`Cadence/App/AppModel.swift:2005-2025`). It does not seed state from `frontmostApplication` at launch, observe launch or termination, check `isTerminated`, or publish a value snapshot.
3. The sole consumer of `lastExternalApplication` is the setup demo insertion path, which attempts to reactivate it (`Cadence/App/AppModel.swift:1545-1553`). It is never passed to `HUDWindowController`, `HUDViewModel`, `HUDState`, Dictation, or Scribe.
4. Dictation independently samples `NSWorkspace.shared.frontmostApplication` when recording begins (`Cadence/Services/DictationCoordinator.swift:258`, `Cadence/Services/DictationCoordinator.swift:795-802`). This snapshot is used for local shortcut expansion and deterministic polishing (`Cadence/Services/DictationCoordinator.swift:401-410`) and then cleared at the end. It never reaches the HUD.
5. `DictationTargetApplication` retains only a required bundle identifier and display name (`Cadence/Models/DictationModels.swift:322-340`). It loses the process identifier and bundle URL needed to distinguish launches and duplicate copies, and it has no presentation/icon key.
6. Scribe has a stronger but separate authority: Accessibility pins the focused element and derives PID plus bundle identifier from that element (`Cadence/Services/ScribeContextService.swift:208-217`, `Cadence/Services/ScribeContextService.swift:241-297`). Its target model likewise lacks bundle URL, display name, and icon (`Cadence/Models/ScribeModels.swift:113-121`).
7. `HUDState` contains only lifecycle, subtitle, waveform, and visibility fields (`Cadence/Models/DictationModels.swift:824-852`). `HUDViewModel` publishes no application presentation (`Cadence/Services/HUDWindowController.swift:1007-1029`). There is consequently no state that could trigger an app-icon refresh.
8. The collapsed HUD unconditionally renders the bundled Cadence asset with `Image("HUDLogo")` (`Cadence/UI/HUDView.swift:93-132`). It does not attempt to render an `NSRunningApplication.icon` or bundle icon.
9. The HUD panel is correctly nonactivating (`Cadence/Services/HUDWindowController.swift:576-593`), so ordinary HUD interaction need not steal focus. The focus-preserving panel is not the bug; the absent identity-to-view binding is.
10. Cadence already proves that `NSWorkspace.icon(forFile:)` works in this process for its own permission-guide drag view (`Cadence/UI/PermissionGuideWindow.swift:334-357`). That code is surface-specific and not reusable by the HUD.
11. Existing HUD tests cover visibility, morphing, waveform behavior, geometry, and pointer interaction, but there is no monitor, target-to-presentation, icon fallback, invalidation, or active-app switching test. Examples are `CadenceTests/CadenceTests.swift:2514-2525`, `CadenceTests/CadenceTests.swift:2804-2901`, and `CadenceTests/CadenceTests.swift:3222-3334`.

### Root cause

The primary cause is **missing data flow**: no application identity or icon exists in the HUD state graph, while the view hardcodes the Cadence logo.

Three secondary defects would make a superficial icon patch stale or incorrect:

- **Fragmented ownership:** `AppModel`, Dictation, and Scribe each obtain target information differently, with no shared runtime presentation boundary.
- **Incomplete lifecycle:** the retained `NSRunningApplication` is not initialized, invalidated, or re-resolved. Apple documents that an `NSRunningApplication` remains valid after exit even though most of its properties lose significance, so retaining the object is not proof that the app is still active.
- **Insufficient identity:** bundle ID plus display name cannot distinguish duplicate installed copies, relaunches, or a running bundle URL. It also cannot bind a late icon result to the action that requested it.

## Canonical runtime model

Use the identity vocabulary established by the installed-app contract and add two ephemeral concepts.

### `ActiveApplicationIdentity`

A value-only, runtime snapshot:

- Process identifier
- Bundle identifier
- Standardized, symlink-resolved bundle URL
- Current localized display name
- Launch discriminator when available, such as launch date
- Monotonic monitor revision

Bundle identifier and canonical URL together identify application lineage and the exact installed copy. PID plus launch discriminator identify the current process instance. The snapshot contains no `NSRunningApplication` or `NSImage` and is `Equatable` and `Sendable`.

Incomplete applications without a bundle identifier or bundle URL may remain an explicit `.unavailable` presentation state, but they are not eligible for app-specific configuration. Cadence never fabricates an identity from name alone.

### `CapturedApplicationTarget`

An immutable per-action record:

- `ActiveApplicationIdentity`
- Capture revision and timestamp
- Capture source (`workspaceFrontmost` for Dictation or `accessibilityFocusedElement` for Scribe)
- Optional Accessibility verification token owned by Scribe

This is the authority for the action's local app configuration, preset, HUD name/icon, retry, and insertion verification. It is cleared when the action reaches a terminal cleanup path. It is never persisted.

### `ApplicationPresentation`

A local, main-actor presentation value:

- Identity key and monitor/action revision
- Display name
- `NSImage` presentation copy or explicit fallback kind
- Availability (`running`, `installed`, `unavailable`)

The image is UI state, not a model or persistence field. Views receive this prepared presentation rather than calling `NSWorkspace` themselves.

## Ownership and state propagation

### Focused-application monitor

Add an `@MainActor FocusedApplicationMonitor` service. `AppModel` owns one instance and coordinates consumers; it must not absorb the notification and icon logic inline.

The monitor publishes:

- `currentExternalApplication`: the eligible non-Cadence application that is currently frontmost, or nil.
- `lastExternalApplication`: the most recently confirmed external value snapshot, retained only for explanatory UI and explicit return-to-target actions.
- A monotonic revision that changes whenever identity or availability changes.

The monitor never exposes a retained `NSRunningApplication` as authoritative state. It may use one transiently to construct a value snapshot.

### Startup and notification contract

1. Register observers on `NSWorkspace.shared.notificationCenter` on the main actor.
2. Immediately sample `NSWorkspace.shared.frontmostApplication` after registration, so startup cannot wait for a future activation and the registration/snapshot window cannot miss the latest event.
3. Treat `didActivateApplicationNotification` as the primary update. Build a fresh snapshot from the notification's `NSRunningApplication` and publish only if it is eligible and not Cadence.
4. Cadence activation sets `currentExternalApplication` to nil but preserves `lastExternalApplication`. Last-external state is never silently promoted into a current insertion target.
5. Observe launch and termination for targeted metadata/icon invalidation. Apple notes that these notifications omit background and `LSUIElement` apps; correctness therefore cannot rely on them as a complete process inventory.
6. When a process matching either current or last identity terminates, mark the running presentation invalid immediately, evict the process-specific icon, and resample `frontmostApplication` on the next main-run-loop turn. A later activation with the same bundle identifier is a new process snapshot.
7. Resample on user-session activation and system wake. An active-Space change may cause a resample but does not itself name a target.
8. Notification and resample updates carry monotonically increasing revisions. A delayed resample or icon result may publish only if its originating revision still matches; latest focus always wins.
9. Deinitialization cancels all observers. Tests inject a workspace event source rather than posting global AppKit notifications.

### Action capture

Dictation and Scribe keep their safety-specific capture authorities but share identity enrichment and presentation:

- **Dictation:** at accepted hotkey start, synchronously sample the current frontmost application on the main actor. Require a non-Cadence, nonterminated application with usable identity, pin it as `CapturedApplicationTarget`, and use it for the entire action. Do not fall back to `lastExternalApplication` when Cadence is frontmost.
- **Scribe:** the focused Accessibility element remains authoritative. After obtaining its PID, resolve `NSRunningApplication(processIdentifier:)` and require the resulting identity to match that PID. The monitor's live value may enrich presentation only when it matches; it may not override the Accessibility target.
- **Retries:** reuse the original captured target and provider/action snapshot. Never recapture a newer frontmost app under the same action.
- **Insertion:** immediately before insertion, verify that the current focus still matches the captured target. Scribe retains its strict Accessibility token/window/element/selection checks. Dictation at minimum requires the same process instance and canonical bundle URL; if that cannot be proven, retain the processed text and offer a safe copy/return-to-target recovery instead of posting key events.

This preserves the distinction between a live idle observation and an action target. A fast app switch may change the idle icon, but it cannot relabel or redirect a recording already pinned to Cursor.

## HUD binding contract

- When Dictation and Scribe are idle, the collapsed HUD presents the live `currentExternalApplication` icon and accessible display name.
- If there is no eligible external application, the HUD uses the Cadence `HUDLogo` and the existing “Cadence is ready” accessibility label.
- When an action begins, `HUDViewModel` pins the `ApplicationPresentation` built from that action's `CapturedApplicationTarget`. Recording, transcription, provider wait/review where the HUD participates, insertion, success, cancellation, and error states keep that presentation.
- Returning to idle releases the action presentation and resumes the latest live monitor presentation in one state transition. A stale action completion cannot overwrite a newer idle revision.
- The expanded tray and any app cue use the same presentation value. No surface performs an independent lookup by bundle identifier or display name.
- The accessible idle label becomes “Cadence is ready for {localized app name}” when a current app is known. Action labels identify the pinned destination without exposing a technical identifier.
- Changing only the application presentation must publish a view-model change even when `HUDState.visualState` remains `.idle`; icon freshness cannot depend on a lifecycle-state transition.

## Icon resolution and cache

Add a main-actor `ApplicationIconResolver`, shared with the installed-app picker where practical.

Resolution order:

1. `NSRunningApplication.icon` for the matching, nonterminated process instance.
2. `NSWorkspace.icon(forFile:)` for the exact resolved canonical bundle URL.
3. A generic macOS application glyph when an external identity is known but no icon is available.
4. Cadence `HUDLogo` only when there is no eligible external identity.

Never use display name or bundle identifier alone to select an icon when duplicate bundle copies exist. The canonical bundle URL is the installed-icon key; PID plus launch discriminator is the running-icon key.

The resolver makes a presentation copy before resizing so it never mutates a shared `NSImage`. It may cache resized images in memory. Cache entries include canonical URL and bundle version/build or modification metadata. Invalidate on:

- Matching app launch or termination
- Installed-catalog refresh or moved-app rebind
- Bundle version/build or modification change
- Explicit Apps refresh
- Identity resolution changing to a different canonical URL

Icons are never encoded into UserDefaults, app-configuration JSON, diagnostics, or analytics. Cache misses and fallback kinds may be tested or counted locally only as closed enums.

## Race and failure policy

- Main-actor serialization plus revision checks establishes ordering; it does not pretend AppKit focus can never change between reads.
- Capture must reject a terminated process and may re-read `frontmostApplication` after constructing the snapshot. A mismatched PID means focus changed during capture and the action does not start against the stale target.
- Every asynchronous result carries the identity key and revision that requested it. If either differs at completion, discard it.
- Nil bundle URL, nil identifier, nil localized name, or nil icon is a typed availability/fallback outcome, never a force unwrap.
- A known display name with a generic icon is preferable to a wrong app icon. A technical bundle identifier is never used as normal user-facing copy.
- Rapid Cursor → Slack → Cursor changes publish the final Cursor process revision. Intermediate icon work may complete but cannot win.
- If the pinned target terminates mid-action, preserve the transcript/draft, mark the target unavailable, and prevent automatic insertion. Relaunching an app with the same bundle ID does not satisfy the original process-instance check.

## Persistence and migration

No runtime focus, PID, launch discriminator, icon, monitor revision, or captured target is persisted. There is therefore no user-data migration for this ticket.

Replace the private `lastExternalApplication: NSRunningApplication?` with the focused-application monitor during implementation. The installed-app `ApplicationReference` store from the picker contract remains the only persisted identity boundary. A runtime identity may resolve against that store by exact canonical URL and bundle identifier, but it never mutates a user configuration merely because an app became frontmost.

## Privacy and diagnostics

- Exact app names, bundle identifiers, bundle URLs, process identifiers, icons, installed-app inventory, and focus-switch histories remain local and content-free.
- Do not log or send them to analytics, Scribe diagnostics, or providers. This extends the existing privacy rule in `docs/privacy.md:31` and `docs/privacy.md:73-85`.
- Allowed diagnostics are closed outcomes such as `captured`, `self`, `unavailable`, `changed`, `terminated`, `iconRunning`, `iconBundle`, `iconGeneric`, and coarse latency buckets.
- Provider requests receive only the locally resolved preset instructions and additive custom guidance defined by the app-environment contract. They never receive `ActiveApplicationIdentity`, `CapturedApplicationTarget`, or `ApplicationPresentation` fields.
- Accessibility labels may use the local display name because they are on-device UI, not telemetry.

## Required implementation seams

- Extend the installed-app value model with runtime `ActiveApplicationIdentity` and `CapturedApplicationTarget` types under `Cadence/Models/`.
- Add `FocusedApplicationMonitor` and `ApplicationIconResolver` under `Cadence/Services/`.
- Have `AppModel` own and bind the monitor, publishing presentation state to the HUD and app-aware Settings surfaces.
- Replace Dictation's private `currentTargetApplication()` and narrow `DictationTargetApplication` use with a captured runtime target. Keep app-aware polishing outside `AppModel`.
- Enrich Scribe's PID-authoritative target locally without weakening its Accessibility verification token or provider denylist.
- Add application presentation to `HUDViewModel` separately from content-free `HUDState`, or add an equivalent value-only identity key to state plus a main-actor image field. Do not place `NSImage` in persisted/value domain models.
- Replace the hardcoded `Image("HUDLogo")` branch with an app-presentation view that retains the Cadence asset as the no-target fallback.
- Reuse the installed-app contract's resolver and cache rules rather than creating a second bundle-ID-only icon service.

## Required automated tests

### Monitor

- Seeds an already-frontmost Cursor-equivalent app at startup without waiting for activation.
- Activation publishes exact PID, bundle ID, canonical URL, localized name, and a new revision.
- Cadence activation clears current but preserves last external only as nonauthoritative history.
- Nil metadata and self activation fail safely.
- Termination invalidates the matching process and stale retained objects are not reused.
- Relaunch with the same bundle ID produces a distinct process snapshot.
- Launch/terminate notification gaps are recovered by frontmost resampling.
- Rapid out-of-order activation/resample events publish only the newest revision.
- Observer teardown releases the monitor and cancels delayed work.

### Capture and target safety

- Dictation pins the same identity used by app configuration, HUD presentation, and insertion verification.
- Dictation refuses to reuse `lastExternalApplication` while Cadence is frontmost.
- Scribe enriches only the PID from its Accessibility snapshot and rejects a mismatching monitor value.
- Retry retains the original target after the user switches apps.
- A target switch or termination before insertion prevents key-event insertion and preserves the processed text.
- Duplicate copies with one bundle identifier resolve by canonical URL, not the first bundle-ID match.

### Icons and HUD

- Running icon wins over bundle icon; bundle icon wins over generic fallback.
- No-target state uses `HUDLogo`; known-target-without-icon uses a generic app glyph, not Cadence branding presented as the target.
- Cache keys distinguish canonical URLs and process launches; launch, termination, move, version change, and explicit refresh invalidate as specified.
- A late Cursor icon cannot overwrite a newer Slack presentation.
- Idle app changes publish while visual state remains `.idle`.
- An in-flight action keeps its pinned icon/name through recording and terminal states, then resumes the latest idle app.
- Accessibility labels use localized display name and never expose bundle ID or path.
- No image bytes appear in persistence fixtures.

### Privacy

- Provider serialization rejects all runtime identity and presentation fields.
- Analytics and diagnostic allowlists contain no name, identifier, path, PID, icon, focus history, or configuration ID.
- Log-privacy canaries cover monitor, resolver, failure, and insertion-mismatch paths.

## Live acceptance contract

Deterministic tests are necessary but do not prove macOS integration. Release evidence must include a signed or installed Debug-app pass for these cases:

1. Launch Cadence while Cursor is already frontmost. The idle HUD shows Cursor's actual icon and localized name without requiring an app switch.
2. Switch Cursor → Slack → Cursor repeatedly. The idle HUD follows the latest frontmost app within the next visible update and never shows a prior app after the sequence stops.
3. Start Dictation in Cursor, switch to Slack before completion, and finish. The HUD remains labelled for Cursor and Cadence refuses automatic insertion into Slack while preserving the processed text.
4. Start and complete Dictation in Cursor without switching. The same captured Cursor identity selects local configuration, labels the HUD, and passes insertion verification.
5. Start Scribe in Cursor. Its local app configuration and UI presentation come from the same PID pinned by Accessibility, while the provider payload contains no Cursor identity.
6. Quit Cursor while it is the current idle target. The running icon disappears without showing stale state; relaunch and activation recover a new Cursor process and icon.
7. Exercise a copied/beta app with the same bundle identifier at a second URL. The active process's exact bundle URL selects the correct icon/configuration.
8. Click and drag the nonactivating HUD. The external target remains frontmost and presentation remains correct.
9. Bring Cadence Settings to the front. The UI does not claim that the last external app is currently focused, and starting an action cannot silently target it.
10. Review OSLog, exported Scribe diagnostics, analytics payloads, and provider request capture; none contains exact app identity or icon data.

## Map impact and remaining risks

No new Wayfinder ticket is required. The installed-app contract already owns discovery, persisted references, and general icon caching. The app-environment ticket owns family/preset/custom-guidance selection. The cross-cutting acceptance ticket should incorporate the live cases above.

Remaining implementation risks:

- AppKit workspace notifications are not a complete lifecycle feed for background or `LSUIElement` apps. Snapshot/resample and explicit action capture are therefore required rather than assuming notifications alone are exhaustive.
- `NSRunningApplication` properties can be nil and time-varying. The implementation must retain value snapshots and revisions, not treat a long-lived object reference as truth.
- Dictation currently posts key events without the Scribe pipeline's strict Accessibility verification. Adding fail-closed target verification needs a recovery UI that preserves its low-latency flow.
- `NSImage` behavior and app-icon rendering require real-app visual evidence; unit tests should use resolver fakes and compare keys/fallback decisions rather than image pixels.

## Primary Apple sources

- [NSWorkspace and `frontmostApplication`](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication)
- [`didActivateApplicationNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification)
- [`didLaunchApplicationNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/didlaunchapplicationnotification)
- [`didTerminateApplicationNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/didterminateapplicationnotification)
- [NSRunningApplication lifecycle and race behavior](https://developer.apple.com/documentation/appkit/nsrunningapplication)
- [NSRunningApplication bundle URL](https://developer.apple.com/documentation/appkit/nsrunningapplication/bundleurl)
- [NSRunningApplication localized name](https://developer.apple.com/documentation/appkit/nsrunningapplication/localizedname)
- [NSRunningApplication icon](https://developer.apple.com/documentation/appkit/nsrunningapplication/icon)
- [NSRunningApplication termination state](https://developer.apple.com/documentation/appkit/nsrunningapplication/isterminated)
