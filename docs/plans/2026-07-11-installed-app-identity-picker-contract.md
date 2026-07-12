# Installed-app identity and picker lifecycle contract

Date: 2026-07-11  
Wayfinder ticket: [Define installed-app identity and picker lifecycle](https://github.com/darshshah981/Cadence/issues/40)  
Baseline: Adaptive Scribe PR #34 at `04391d3`

## Decision

Cadence represents an application as a stable local reference, not a user-entered bundle identifier and not a persisted icon. Discovery, runtime focus identity, persisted app configuration, and presentation metadata are separate concepts with explicit resolution rules.

Users add apps through a searchable installed-app picker or Choose Application. Cadence stores technical identity internally, keeps it out of provider payloads and diagnostics, and preserves configurations when apps move or become temporarily unavailable.

## Canonical model

### Installed application descriptor

A transient discovery result:

- Canonical bundle URL
- Bundle identifier
- Localized display name from the installed bundle
- Optional version/build metadata for disambiguation
- Installed/running flags

The descriptor contains no persisted `NSImage`. Icons are resolved separately at presentation time.

### Application reference

The persisted identity inside an app configuration:

- Stable configuration UUID
- Bundle identifier
- Last-known standardized bundle URL
- Last-known localized display name
- Reference schema version

The bundle identifier establishes application lineage; the canonical URL distinguishes multiple installed copies that share an identifier. The display-name snapshot exists only so a missing app remains understandable in Settings.

### Active application identity

A runtime-only capture:

- Bundle identifier
- Canonical bundle URL
- Current localized display name
- Process identifier

It is sampled from `NSRunningApplication` and used locally for focused-target matching, app-configuration resolution, and icon presentation. It is never serialized into an LLM request.

### App configuration

An app configuration has its own stable ID and references:

- Application reference
- Reusable environment family
- Selected preset
- Optional additive custom Scribe guidance
- Enabled/customized state and configuration revision

Application identity is distinct from environment family. Codex, Cursor, and other coding apps may share Coding behavior without becoming the same application.

## Discovery contract

`InstalledApplicationCatalogService` owns discovery outside `AppModel`.

The service merges:

1. Application packages immediately under `/Applications`.
2. Application packages immediately under `/System/Applications` and `/System/Applications/Utilities`.
3. Application packages under `~/Applications`.
4. Currently running applications from `NSWorkspace.runningApplications`.
5. A user-selected application returned by Choose Application.

Directory traversal may descend through organizational folders but must stop at every `.app` package so nested helpers, XPC services, frameworks, and bundled secondary apps do not appear as installed applications.

Each candidate must:

- Resolve symlinks and standardize the bundle URL.
- Load as a bundle with a nonempty bundle identifier.
- Have an executable.
- Represent a macOS application bundle.
- Not be Cadence Debug or Release.

Spotlight metadata is not the authoritative catalog. Apple documents that indexed system coverage and user exclusions can omit results. A direct standard-root scan is deterministic; running apps and Choose Application cover nonstandard or currently active locations.

`NSWorkspace.urlForApplication(withBundleIdentifier:)` is a resolution hint, not the inventory source and not proof that only one copy exists.

## Deduplication and resolution

Descriptors deduplicate by canonical URL. Multiple URLs with the same bundle identifier remain separately selectable because beta/stable or copied installations may need different app-specific behavior.

A persisted reference resolves in this order:

1. Exact canonical URL exists and still has the same bundle identifier.
2. If that URL moved and exactly one discovered candidate has the bundle identifier, update the last-known URL automatically.
3. If multiple candidates share the identifier, mark the reference Ambiguous and require the user to choose; never select the first scan result.
4. At runtime, use the active process's bundle URL to select the exact configured copy.
5. If the configured app is unavailable, preserve the reference as Not Installed and use global fallback behavior.

Reinstalling a unique app with the same bundle identifier reconnects automatically. Missing configurations are never silently deleted. If multiple copies exist and no exact match can be established, app-specific preset and custom guidance are not applied.

Applications without a bundle identifier or executable are rejected with plain-language explanation. Cadence does not invent an unstable path hash identity for them.

## Picker experience

The Apps page presents an `InstalledApplicationPickerView` sheet:

- Search by localized app name.
- Recommended section followed by all installed applications.
- Row shows locally resolved icon, live display name, and version/path only when needed to disambiguate duplicates.
- Already-configured exact applications are disabled or marked Added.
- Duplicate identifiers remain separate rows with clear location metadata.
- Empty state offers Refresh and Choose Application.
- Full keyboard navigation, type-to-search, Return selection, Escape cancellation, VoiceOver row summaries, and visible focus are required.

Users never type a bundle identifier. Technical identifiers may appear only in an optional diagnostic detail, never as the primary label or editable field.

Choose Application uses a narrowly scoped `NSOpenPanel` bridge:

- One selection
- Files only
- `UTType.applicationBundle`
- Alias resolution enabled
- Validation against the same catalog rules
- Clear rejection for non-apps, Cadence itself, missing identifiers, or missing executables

SwiftUI owns picker state and selection. AppKit owns only the panel presentation and returned URL; no AppKit controller becomes a second source of truth.

## Built-in defaults

Cadence ships versioned, local templates keyed internally by known application identity:

- Codex/OpenAI desktop (`com.openai.codex`) → Coding family
- Cursor (`com.todesktop.230313mzl4w4u92`) → Coding family
- Slack (`com.tinyspeck.slackmacgap`) → Messaging family
- Other Apps → global Neutral fallback

On the audited Mac, the Codex bundle is `/Applications/ChatGPT.app`, its live display name is ChatGPT, and its bundle identifier is `com.openai.codex`. The UI uses the installed bundle's display name and icon, with a secondary “Codex default” label where helpful; it does not rename the application.

Built-in templates are overlays, not duplicated user records. They appear automatically when the matching app is uniquely installed. User state is materialized only after customization, disablement, or explicit removal, allowing future bundled-template updates without overwriting user choices.

Exact preset names and instruction content remain owned by the app-environment ticket. This ticket establishes only identity-to-family defaults.

## Icon lifecycle

Icons are local, runtime presentation data resolved in this order:

1. `NSRunningApplication.icon` for the active/running application.
2. `NSWorkspace.icon(forFile:)` for a resolved bundle URL.
3. Generic application glyph or Cadence logo fallback, depending on surface.

Do not persist icon bytes in UserDefaults or app-configuration JSON. A memory cache may hold resized images keyed by canonical URL and bundle modification/version metadata. Invalidate on explicit catalog refresh, moved-app rebind, application launch/termination, and bundle metadata change.

AppKit image access remains on the main actor. Views receive a presentation-ready image or a fallback state; models and stores remain value-only and testable.

The focused-app HUD contract is completed by the dedicated runtime-correctness ticket. This ticket establishes the identity and icon-resolution boundary it must use.

## Refresh and lifecycle

A full catalog refresh runs:

- At app startup after core initialization
- When the Apps Settings page first appears
- After Choose Application succeeds
- On explicit Refresh
- After a mounted volume containing a configured app becomes available

Launch, termination, and activation notifications update runtime state and may trigger targeted descriptor refreshes, but they are not treated as a complete installed-app change feed. macOS provides no dependable general notification that fully represents app installation and movement.

Catalog scans run off the main actor; descriptor publication and icon resolution return to the main actor. Repeated scans are cancellable and generation-tagged so stale completion cannot replace newer results.

## Persistence and migration

Create a schema-versioned `ApplicationConfigurationStore` rather than forcing dynamic applications into the closed `WritingEnvironmentStore` enum model.

Migration is additive and idempotent:

- Preserve existing writing-environment and personalization bytes for rollback.
- Map the existing Slack environment preference to the bundled Slack configuration because the identity and behavior are exact.
- Do not map Claude Desktop/Claude Code preferences to Codex; they are different application and recognition contracts.
- Keep existing shortcut/profile bundle-identifier scopes semantically intact while replacing their editors with the installed-app picker and resolving names/icons for display.
- Create missing references for unresolved legacy identifiers rather than deleting them.
- Deduplicate identical legacy application scopes without dropping shortcuts or guidance.
- Use a separate application-configuration migration version and outcome, not the already-completed Adaptive Scribe migration ledger.

Cadence is currently not App Sandbox-enabled; its entitlements contain microphone access only. Standard directory scanning and file-panel selection therefore require no security-scoped bookmark today. If sandboxing is introduced later, security-scoped persistence for nonstandard locations becomes a separate migration and release requirement.

## Privacy

- Installed-app inventory, bundle identifiers, paths, names, icons, running-process identity, and configuration IDs remain local.
- No provider request contains app identity; only locally resolved preset instructions and additive custom guidance may be transmitted.
- Do not log exact names, identifiers, paths, icons, or installed inventory.
- Diagnostics use closed outcomes such as found, missing, ambiguous, invalid, or refreshed and coarse count buckets only.
- Analytics receives no app identity, path, installed-app count, or configuration detail.
- Saved custom guidance is content and follows the separate disclosure and provider-egress contract.

## Required implementation seams

- Add value types for installed descriptors, persisted references, runtime identities, and resolution state under `Cadence/Models/`.
- Add `InstalledApplicationCatalogService`, `ApplicationIdentityResolver`, `ApplicationConfigurationStore`, and a narrow active-application monitor under `Cadence/Services/`.
- Keep `AppModel` as coordinator and published-state owner; do not embed scanning, bundle parsing, or icon logic inline.
- Replace raw identifier entry in `PersonalShortcutEditor` and `WritingStyleProfileEditor` with the shared picker.
- Replace static app-environment cards with resolved app configurations under the Apps Settings category.
- Let Scribe resolve configuration through the active application reference while preserving the provider payload denylist.
- Let the HUD consume the runtime identity/icon presentation state through its view model, finalized by the focused-app correctness ticket.

## Required test contract

- Catalog: standard roots, organizational folders, nested helpers excluded, symlink/canonical dedupe, invalid bundles, missing executable/identifier, Cadence exclusion, running-app merge, deterministic sorting and search.
- Duplicates: same bundle identifier at two URLs remains two descriptors; exact URL wins; ambiguous moved reference fails closed.
- Resolution: unique move rebind, missing state, reinstall recovery, runtime URL disambiguation, global fallback when unresolved.
- Store: absent, valid, malformed, future schema, duplicate configuration IDs/references, built-in overlay versus materialized override.
- Migration: Slack mapping, no Claude-to-Codex remap, unresolved legacy preservation, idempotence, rollback bytes unchanged.
- Panel validation: valid application, non-app rejection, Cadence rejection, nil identifier, missing executable, alias resolution.
- Icons: running icon preference, installed bundle icon, generic fallback, cache invalidation, no serialized image data.
- Runtime monitor: initial frontmost app, activation update, Cadence activation retaining the last external app, launch/termination refresh, nil metadata.
- Personalization: picker-selected references preserve existing shortcut/profile matching.
- Scribe privacy: resolved app identity chooses local configuration but no identifier, URL, name, process, icon, or configuration ID enters provider input or diagnostics.
- UI/accessibility: Recommended, search, Already Added, duplicates with paths, missing-app recovery, Refresh, Choose Application, keyboard, VoiceOver, focus, and narrow Settings width.

## Map impact

No new Wayfinder ticket is required. The focused-app ticket owns monitor-to-HUD freshness and icon correctness. The app-environment ticket owns preset taxonomy, custom-guidance precedence, and built-in family behavior. Implementation sequencing and migration boundaries are now substantially clearer but remain map fog until runtime correctness and app-environment decisions close.

## Primary Apple sources

- [NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace)
- [NSWorkspace application activation notification](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification)
- [NSRunningApplication bundle identity and presentation metadata](https://developer.apple.com/documentation/appkit/nsrunningapplication/bundleidentifier)
- [NSWorkspace file icons](<https://developer.apple.com/documentation/appkit/nsworkspace/icon(forfile:)>)
- [NSOpenPanel](https://developer.apple.com/documentation/appkit/nsopenpanel)
- [UTType.applicationBundle](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/applicationbundle)
- [NSMetadataQuery search scopes and limitations](https://developer.apple.com/documentation/foundation/nsmetadataquery/searchscopes)
