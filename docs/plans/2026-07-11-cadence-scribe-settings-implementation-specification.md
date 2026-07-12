# Cadence Scribe and Settings implementation-ready specification

Date: 2026-07-11
Wayfinder destination: [Cadence Scribe providers, app intelligence, and settings implementation-ready specification](https://github.com/darshshah981/Cadence/issues/35)
Synthesis ticket: [Synthesize the Cadence Scribe and Settings implementation-ready specification](https://github.com/darshshah981/Cadence/issues/44)
Extension baseline: Adaptive Scribe PR #34, branch `codex/adaptive-scribe-writing-environments`, commit `04391d3`

## Executive decision

Extend PR #34 rather than rebuilding Scribe. Preserve its hardened credential, transport, consent, target-verification, exact-literal, mandatory-review, diagnostics, migration, privacy-canary, native-UI-test, and release-evidence foundations. Replace the parts of that baseline that no longer match the product:

- Scribe becomes one `dictate → process locally → polish → review → insert or copy` flow. Compose, Respond, Edit, selected-text capture, and the intent picker are retired.
- OpenAI Direct and OpenRouter become explicit provider kinds alongside DeepSeek, Custom OpenAI-Compatible, and Legacy Local. Cadence saves at most one configuration per kind and has one explicit global active provider/model.
- App adaptation resolves locally from an installed application reference to General, Messaging, or Coding, a compatible preset, and optional additive Custom guidance. App identity never enters the provider payload.
- Users choose installed applications by searchable name and icon; they never type bundle identifiers in normal configuration.
- One focused-application monitor owns live application identity. Dictation and Scribe pin immutable targets for safety; the HUD displays the same target presentation and therefore shows Cursor and other app icons correctly.
- Settings becomes a nested category rail with card-based pages. All Cadence-owned buttons and compatible controls adopt a shared semantic visual system; operating-system-owned dialogs stay native.
- Migration is additive and reader-gated. Rollback disables new readers without deleting new or legacy data and never revives Compose, Respond, or Edit.
- Shipping requires deterministic CI, live OpenAI/OpenRouter and real-app verification, a signed/notarized candidate, accessibility and privacy review, and bounded dogfood on one manifest-bound artifact.

This specification is complete enough to become the input to an implementation plan. Exact recommended model IDs are intentionally release data, not an unresolved architecture decision: refresh them from current primary provider guidance and validate them against the versioned Scribe corpus before release.

### Decision sources

This synthesis is authoritative when read with these resolved evidence artifacts:

- `docs/plans/2026-07-11-adaptive-scribe-pr34-baseline-research.md`
- `docs/plans/2026-07-11-polished-dictation-scribe-contract.md`
- `docs/plans/2026-07-11-openai-openrouter-provider-contract.md`
- `docs/plans/2026-07-11-saas-settings-control-system-contract.md`
- `docs/plans/2026-07-11-installed-app-identity-picker-contract.md`
- `docs/plans/2026-07-11-app-environments-presets-guidance-contract.md`
- `docs/plans/2026-07-11-focused-app-identity-icon-correctness-contract.md`
- `docs/plans/2026-07-11-cross-cutting-acceptance-rollout-contract.md`

When an older PR #34 artifact conflicts, the authority order is polished-dictation semantics; provider contracts; installed/focused identity; app guidance; Settings/control behavior; then PR #34 for the preserved hardened implementation seams.

## Scope

### In scope

- Extend PR #34's Adaptive Scribe implementation and tests.
- First-class OpenAI Direct and OpenRouter generation, discovery, validation, disclosure, error, and model-selection contracts.
- Provider library persistence, multiple saved provider kinds, one active provider/model, and isolated Keychain credentials.
- Meaning-preserving polished dictation with mandatory review, immutable retry, explicit unpolished fallback, re-record, copy, discard, and insertion recovery.
- Installed-app discovery, searchable picker, file-panel fallback, stable local references, missing/moved/duplicate handling, and runtime-only icons.
- General, Messaging, and Coding preset families; Slack, Cursor, Codex/OpenAI Desktop, and the certified Claude Code surface defaults; app-specific Custom guidance.
- Focused-app monitoring, target pinning, target verification, icon resolution, and HUD data flow.
- SaaS-style Settings information architecture and an app-wide Cadence-owned control system.
- Additive migrations, local feature gates, privacy-safe diagnostics, tests, scripts, release evidence, and documentation.

### Non-goals

- Changing local WhisperKit audio transcription, the Dictation/Meeting pipeline separation, meeting storage, or meeting final-pass behavior.
- Sending selected text, clipboard data, nearby text, windows, screens, files, prior turns, or app identity to a provider.
- Per-app provider/model routing or multiple saved configurations of the same provider kind.
- Turning Scribe into a chat, coding, editing, responding, tool-use, web-search, or ambient-context assistant.
- User-authored environment families, raw provider JSON, routing policy, templates, variables, tool definitions, or system prompts.
- Persisting icons, runtime PIDs, focus history, provider catalogs, provider payloads, or Scribe content journals.
- Restyling macOS permission prompts, `NSOpenPanel`, save panels, Keychain dialogs, alerts owned by the OS, or other system security surfaces.
- Implementing, merging, distributing, or releasing as part of the Wayfinder map itself.

## Canonical terminology and domain model

Use the existing Scribe terms in `CONTEXT.md` and add the implementation-free app-guidance terms during implementation.

### Scribe action terms

- **Processed dictation**: local Whisper output after vocabulary correction, filler handling, shortcut expansion, and literal normalization. It is the source of truth for provider input and unpolished fallback; it is not the raw recognizer output.
- **Meaning-preserving polish**: expression improvements that preserve every claim, requested action, fact, ambiguity, constraint, number, identifier, and exact literal.
- **Polished draft**: validated provider output awaiting mandatory user review.
- **Retry polish**: a new provider attempt from the same immutable processed dictation, provider/model/recipient, resolved guidance, target, and literal contract.
- **Insert unpolished**: insert processed dictation without provider transformation. It never means raw transcript insertion.
- **Re-record**: discard the content-bearing action and start a new capture with new target and configuration snapshots.

### Provider terms

- **Provider kind**: `openAIDirect`, `openRouter`, `deepSeek`, `customOpenAICompatible`, or `legacyLocal`.
- **Provider configuration**: one schema-versioned, stable record for a provider kind, including selected model, credential reference, consent/contract revision, enabled/readiness state, validation metadata, and allowlisted non-secret settings.
- **Provider library**: one envelope containing zero or one configuration per provider kind and an optional active configuration ID.
- **Provider action snapshot**: the immutable validated provider/model/recipient/configuration contract captured for one Scribe action and reused by Retry polish.
- **Bundled model catalog**: versioned, reviewed release data with compatibility and recommendation tiers.
- **Live model catalog**: consent-gated, authenticated, in-memory discovery results for the current app session.

### Application and guidance terms

- **Installed application descriptor**: transient canonical URL, bundle ID, localized name, optional version/build, and installed/running state discovered locally.
- **Application reference**: persisted bundle lineage plus last-known canonical URL/name and its own schema version. Bundle ID establishes lineage; canonical URL distinguishes installed copies.
- **Active application identity**: runtime-only PID, bundle ID, canonical bundle URL, localized name, launch discriminator where available, and monitor revision.
- **Captured application target**: immutable per-action identity plus capture revision/time/source and Scribe's optional Accessibility verification token.
- **Application presentation**: main-actor local display name, identity/revision, resolved `NSImage` or fallback, and availability. It is UI state, never persistence.
- **Application configuration**: stable application reference, enabled state, environment family, preset selection, optional Custom guidance, and schema/revision.
- **Environment family**: release-bundled namespace of compatible presets: General, Messaging, or Coding.
- **Preset**: stable family-qualified release definition controlling tone, concision, or structure without changing meaning or authorization.
- **Custom guidance**: optional app-specific expression preferences, lower priority than every Cadence safety rule and preset constraint.
- **Resolved Scribe guidance**: immutable provider-safe action snapshot of family/preset versions, compiled preset instructions, normalized Custom guidance, resolution source, and literal capability flags. It contains no app identity or user-facing labels.

### Identity boundaries

The following are deliberately different:

1. Installed discovery answers which bundles exist.
2. Persisted references answer which installed lineage/copy owns user configuration.
3. Live focus identity answers which process is currently eligible.
4. Captured targets answer where this action may egress and insert.
5. Application presentation answers what name/icon the UI shows.
6. Resolved guidance is the only app-derived data allowed into provider-safe input.

No layer may substitute display name for identity, bundle ID alone for an exact duplicate copy, or last-external history for the current insertion target.

## Resolved cross-contract decisions

These rules settle overlaps that could otherwise produce competing implementations.

1. **PR #34 is the code baseline, not the final product semantics.** Preserve its safety seams and extend its types. Remove its active intent-driven flow and closed app-environment resolver; do not maintain a hidden compatibility route.
2. **Selected-text safety is preserved by deletion, not by dormant capability.** Retire selected-text capture/authorization/request code from Scribe. The privacy denylist and target-verification tests continue to prove selected and ambient content cannot egress. A future selected-text feature requires a separate specification.
3. **Legacy Local is explicit only.** It remains selectable but is never an automatic failure fallback for any cloud provider.
4. **Unknown app fallback is not target fallback.** A valid captured target with no usable app configuration gets General · Neutral. If target identity/focus cannot be verified, provider egress or insertion fails closed; General · Neutral cannot make an unsafe target valid.
5. **One provider/model is global.** App configurations select only family, preset, and Custom guidance. No app may change recipient or model.
6. **One provider configuration per kind.** OpenAI Direct and OpenRouter are not Custom OpenAI-Compatible profiles. Custom endpoints retain the unknown-operator disclosure.
7. **Model discovery is not activation.** Discovery can populate search; only exact production-adapter synthetic generation validation permits Save/Activate. A missing model remains selected but Needs Attention, with no silent switch.
8. **Custom guidance is untrusted preference data.** Structural separation and immutable higher-priority instructions are authoritative. Deterministic literal checks and mandatory human review remain required because prompt-conflict classification cannot be perfect.
9. **Slack migration is exact; Claude migration is not.** Map legacy Slack formal/neutral/casual/disabled state. Preserve the certified Claude Code surface rule but do not map Claude state to Codex, Cursor, or all Claude Desktop fields. Legacy writing-style profiles remain rollback-readable and never compile into new guidance.
10. **Runtime app state is never persisted.** Only `ApplicationReference` and configuration are durable. Icons, PIDs, launch identity, focus revisions, and captured targets are memory-only.
11. **The focused monitor observes; capture authorities decide.** Dictation samples the frontmost process at accepted hotkey start. Scribe's focused Accessibility element/PID remains authoritative. The monitor can enrich matching presentation but cannot override either action target.
12. **The idle HUD shows only current focus.** `lastExternalApplication` is explanatory/return-to-target history and is never promoted into current presentation or action capture when Cadence is frontmost.
13. **Settings visuals roll back independently.** `adaptiveScribeV2` eligibility requires `providerLibraryV2`, `applicationIntelligenceV2`, and `polishedDictationV2`. `settingsControlSystemV2` changes presentation only and may be disabled independently while functionally complete management/recovery remains available.
14. **Every persistence domain has one independent envelope.** Provider library, application configuration, preset/catalog state, Settings presentation preferences, and rollout state each have their own schema and migration marker. App-specific preset selection remains inside its application configuration; the preset/catalog envelope owns only the fixed General fallback identifier plus catalog revision/readiness. Marker-last migration and validated read-back provide idempotence; legacy bytes, decoders, and Keychain references remain available for the supported rollback horizon.
15. **Existing privacy copy must change before activation.** `docs/privacy.md` currently says transcripts stay local. It must distinguish local transcription from explicit Scribe provider egress, identify the allowed payload, and remain consistent with in-app disclosure and observed requests.
16. **Exact recommended model IDs are refreshed at release.** Architecture, ranking, validation, disappearance, and fallback behavior are fixed here; current model IDs and policy-review dates are evidence-bound release data.
17. **The v1 Other Apps fallback is fixed to General · Neutral.** The Scribe page presents its explanation and readiness; it has no configurable global-preset control. The independent preset/catalog envelope records the fixed fallback identifier plus catalog revision/readiness, while app-specific selections remain in application configurations. Adding another General preset later requires a versioned catalog decision.
18. **The existing global adaptation preference remains compatible.** Continue reading and writing `Cadence.adaptScribeToApp`. The Apps page owns the **Adapt Scribe to apps** toggle. Off always resolves General · Neutral without Custom guidance; it never disables target verification. Resetting one app does not change it. **Reset All App Settings** restores it to enabled and removes only materialized app overrides/guidance, leaving providers, shortcuts, Dictation, Meeting, and other settings untouched.
19. **Rollback compatibility has a release horizon.** Preserve legacy environment/personalization bytes and their decoders through the first v2 release and at least one subsequent rollback-capable release line. Removing a legacy decoder/key is a later explicit migration change, allowed only after the release policy declares every supported downgrade target v2-aware and release evidence proves no supported build or feature-gate rollback still reads the legacy format.

## Product behavior

### First Scribe setup

1. The user enables Scribe or opens Providers.
2. If no valid active provider exists, Cadence shows setup rather than beginning capture.
3. The user chooses a named provider kind.
4. Cadence shows the recipient, exactly what is sent, retention/routing summary, and contract revision. No network request occurs before affirmative consent.
5. The user enters the credential and any provider-specific allowlisted fields.
6. Cadence loads bundled recommendations. After consent, opening model selection may refresh the live catalog once; Refresh Models is explicit thereafter.
7. The user searches recommended/live models or enters a Custom Model ID under Advanced.
8. Cadence holds the entered credential only in the setup model's memory and validates synthetic non-user content through the exact production adapter, model, parser, and transport policy. Failed/cancelled validation creates no Keychain item.
9. After validation succeeds, Cadence stages a new Keychain item, writes and reads back the complete candidate provider library, then commits/activates the selected configuration. A first configuration may use a clearly named **Save and Use** action; otherwise activation remains explicit.
10. Only after successful persistence/read-back and activation does Cadence calculate and delete superseded orphan credentials. A post-stage persistence/activation failure deletes only the newly staged item and preserves the prior library and credential.

### OpenAI Direct contract

- Fixed recipient and origin: `https://api.openai.com`.
- Non-streaming `POST /v1/responses` with bearer authentication and `store: false`.
- No conversation chaining, previous response ID, background mode, tools, files, images, server-side state, arbitrary headers, redirects, shared cache/cookies, or automatic retry.
- Optional organization/project values live under Advanced and map only to the fixed allowlisted headers.
- Live discovery uses authenticated `GET /v1/models`; it does not prove generation compatibility.
- Output parsing accepts completed text only. Errors map to closed privacy-safe categories.
- Disclosure names OpenAI and explains reviewed API retention/training controls without claiming zero retention.

### OpenRouter contract

- Fixed recipient and origin: `https://openrouter.ai`.
- Non-streaming `POST /api/v1/chat/completions` with bearer authentication, one exact model, and `stream: false`.
- Requests enforce Zero Data Retention-compatible routing with `provider.zdr: true` and `provider.data_collection: "deny"`.
- No plugins, tools, web search, different-model fallback, arbitrary provider ordering, arbitrary routing JSON, attribution headers, redirects, shared state, or automatic retry.
- Same-model endpoint failover is allowed only among eligible endpoints inside the ZDR/data-collection boundary.
- Live discovery uses the authenticated user-filtered model endpoint and filters to text-output models with eligible endpoints.
- Disclosure names OpenRouter as recipient and router and explains downstream endpoint variation plus Cadence's enforced routing boundary.
- No eligible ZDR endpoint is a typed failure, never permission to relax policy.

### Other provider behavior

- Preserve DeepSeek's explicit wire/disclosure contract from PR #34.
- Rename Advanced to **Custom OpenAI-Compatible** and preserve normalized-origin, fixed-path, header allowlist, redirect refusal, validation, and unknown-operator disclosure.
- Preserve Foundation Models/Legacy Local as an explicitly selected runtime provider where available.
- Disabling or removing a provider is an explicit destructive Settings action. While a Scribe action is active, require confirmation that the action will be cancelled; confirmed removal cancels and clears that action before changing the library. Runtime invalidation or provider failure that the user did not request preserves already captured Processed dictation for local recovery.

### Model-selection states

- **Bundled/offline**: recommended reviewed entries plus the already selected ID.
- **Loading**: search field and prior selection remain stable; no Scribe request waits on discovery.
- **Live**: exact-ID dedupe; live availability enriches bundled metadata.
- **Offline/error**: existing validated configuration is not invalidated merely by catalog failure.
- **Custom**: local length/control-character validation followed by production-adapter validation; remains labelled Custom.
- **Disappeared**: preserve ID and credential, mark Needs Attention, require explicit choice.
- **Refresh**: only in model-management UI; never timed/background or on an ordinary Scribe action.

Live catalogs remain memory-only because they may expose account/private IDs. Persist only selected ID and validation state. Do not put exact model IDs, origins, account/project fields, or raw errors into analytics, diagnostics, or evidence.

### Normal Scribe action

1. At accepted Scribe shortcut activation, ensure permissions and a valid active provider.
2. Capture the Accessibility-focused element and PID; enrich it with an exact running bundle identity and pin `CapturedApplicationTarget` plus provider action snapshot.
3. Start microphone capture immediately. There is no intent-selection step.
4. Transcribe locally and produce Processed dictation by vocabulary correction, filler handling, local shortcut expansion, and capability-driven literal normalization.
5. Resolve one immutable guidance snapshot locally:
   - adaptation off → General · Neutral, no Custom guidance;
   - exact enabled user configuration → selected family/preset/guidance;
   - exact disabled configuration → General · Neutral, no guidance;
   - exact built-in app template → its family default;
   - eligible certified target-surface template → its default;
   - missing, ambiguous, invalid, unknown, or unconfigured → General · Neutral, no guidance.
6. Freshly verify the pinned target before egress. Failure makes no provider request.
7. Compile only: immutable Cadence contract, compiled preset, optional normalized Custom guidance, Processed dictation, and required literal metadata.
8. Show polishing progress and existing slow-request affordance while the bounded request runs.
9. Reject empty/malformed output and literal violations; ignore late/duplicate completion.
10. Present the Polished draft in mandatory review with the local app/preset cue.
11. Offer Insert, Copy, Retry Polish, Insert Unpolished, Copy Unpolished when applicable, Re-record, and Discard with clear semantic hierarchy.
12. Insert only after fresh verification of the original target. Failure preserves actionable text in insertion recovery and never regenerates automatically.
13. Insert, Copy, or Discard clears all content-bearing action state. No disk-backed Scribe journal or Dictation history entry stores provider content.

### Failure states

| Failure | Network/insertion behavior | Preserved recovery |
|---|---|---|
| Empty local transcription | No network | Re-record or Discard |
| Missing/invalid active provider | No network | Setup; if text already exists, Insert/Copy Unpolished |
| Target changed or unverifiable before egress | No network | Processed dictation for Copy, Re-record, Discard |
| Timeout, cancellation, rate limit, quota, policy, unavailable model, no ZDR route | No insertion, no hidden retry | Same Processed dictation and immutable snapshot for explicit Retry, unpolished recovery |
| Malformed/empty provider response | No insertion | Same recovery as provider failure |
| Exact-literal violation | No polished insertion | Processed dictation, literal explanation, Retry or unpolished recovery |
| Target changed/terminated after review | Refuse insertion | Polished draft and Processed dictation for Copy/return-to-target/discard |
| Late completion after cancel/retry/exit | Ignore | Newer state remains authoritative |
| Invalid app configuration | Do not apply stale guidance | General · Neutral if target itself is safe |

Provider output never inserts automatically. Cadence never silently inserts unpolished text and never changes provider, model, target, family, preset, or guidance under the same action.

### Preset catalog

Stable family-qualified IDs and versioned definitions:

- General · Neutral: natural, clear, proportional length; preserves ambiguity and adds no unsupported tone or structure.
- Messaging · Neutral: conversational, moderate warmth, short paragraphs; no invented greetings, sign-offs, emoji, urgency, promises, or slang.
- Messaging · Formal: measured complete sentences and restrained warmth; no invented owner/deadline or legalistic verbosity.
- Messaging · Casual: relaxed, direct, shorter phrasing; no forced lowercase, slang, emoji, or enthusiasm.
- Coding · Precise: task first; preserve inspect/explain/diagnose/review/plan/implement/test/commit/publish boundaries and every technical literal/constraint.
- Coding · Concise: remove repetition while retaining every authorization boundary, constraint, literal, and expected outcome.
- Coding · Structured: create short sections/bullets only from dictated material; omit empty headings and invent no files/tests/commands/acceptance criteria.

Default mappings:

| Application/surface | Family and preset |
|---|---|
| Slack (`com.tinyspeck.slackmacgap`) | Messaging · Neutral |
| Codex/OpenAI Desktop (`com.openai.codex`, installed display name may be ChatGPT) | Coding · Precise |
| Cursor (`com.todesktop.230313mzl4w4u92`) | Coding · Precise |
| Certified Claude Code prompt surface | Coding · Precise |
| Other/unknown/disabled/missing/ambiguous | General · Neutral, no Custom guidance |

The certified Claude Code default remains surface-narrow and uses only the existing non-content Accessibility signature. It does not classify every Claude Desktop field as Coding and sends no signature/app identity to a provider.

### Custom guidance

- Label the field **Custom guidance**, not custom/system prompt.
- One optional value per materialized application configuration.
- Trim outer whitespace; empty becomes absent; preserve internal line breaks.
- Maximum 2,000 UTF-8 bytes; reject NUL/unsupported control characters; never truncate.
- No variables, placeholders, file/URL fetching, role messages, tools, templates, or provider JSON.
- Saving is local and triggers no provider call.
- Failed edits preserve the last valid value.
- Family changes retain guidance and move the preset selection to the new family default.
- The field discloses: “Sent with your dictated text to the active Scribe provider for this app. Cadence does not send the app's identity or surrounding content.”
- Removing a materialized app configuration deletes only that app's Custom guidance after confirmation.

### Installed-app discovery and picker

`InstalledApplicationCatalogService` scans standard roots (`/Applications`, `/System/Applications`, `/System/Applications/Utilities`, and `~/Applications`), merges currently running apps and an explicitly selected app, descends through organizational directories, and stops at each `.app` bundle. It standardizes and resolves symlinks, validates a nonempty bundle ID and executable, rejects Cadence itself, and deduplicates by canonical URL.

Register an injected mounted-volume event source for `NSWorkspace.didMountNotification` when the catalog service starts. A mount event does not trust notification metadata as inventory: debounce it, start a generation-tagged full catalog refresh, and publish only the newest completion. This reconnects configurations whose application becomes available on an external volume. Explicit refresh, Apps-page first appearance, startup, and successful Choose Application use the same cancellable refresh pipeline. Stop the observer and cancel pending debounce/scan work when the service shuts down.

Multiple URLs sharing a bundle ID remain separate. Resolution order is exact canonical URL and bundle ID, then a unique same-ID moved app rebind, then explicit ambiguity. Runtime bundle URL selects the exact configured copy. Missing configurations remain visible and use General · Neutral. A unique reinstall with the same bundle ID reconnects; a duplicate never resolves by scan order.

The picker provides:

- Search by localized name.
- Recommended apps followed by all installed apps.
- Local icon/name and version/path only when needed for duplicate disambiguation.
- Added/disabled state for exact configured apps.
- Refresh and Choose Application empty-state actions.
- Keyboard search/navigation, Return, Escape, visible focus, and VoiceOver summaries.
- An `NSOpenPanel` bridge restricted to one `UTType.applicationBundle`, with the same validation rules.

The user never types a bundle ID. Personal shortcut/profile editors reuse this picker while preserving existing bundle-scoped data semantics.

### Focused application and HUD

`FocusedApplicationMonitor` is `@MainActor` and publishes current external identity, last confirmed external history, and a monotonic revision. Register workspace observers, then immediately sample `frontmostApplication`. Activation is primary; launch/termination invalidate targeted metadata/icons; wake/session activation resamples. Cadence activation clears current but preserves last as nonauthoritative history. Every async result is revision-tagged; late resamples/icons cannot overwrite newer focus.

Dictation samples the current frontmost process at accepted hotkey start and pins PID, canonical URL, launch discriminator, and identity. Scribe keeps its Accessibility PID/element as authority and enriches only with a matching running application. Retry never recaptures. Immediately before insertion, Dictation verifies the same process instance/canonical URL and Scribe retains its stronger Accessibility token/window/element/selection checks.

The HUD shows the current external app icon/name while idle, Cadence branding when no target exists, and the pinned action presentation during capture through terminal cleanup. A known target without an icon uses a generic app glyph, not the Cadence logo. Resolution order is matching running icon, exact bundle icon, generic app glyph, then Cadence branding only for no target. Cache copied/resized images in memory by exact URL/version and process launch; invalidate on launch, termination, move, metadata/version change, and explicit refresh. Never persist image bytes.

### Settings and app-wide controls

Keep the global 220-point app sidebar. Inside Settings, use a 176-point category rail and a centered 680–720-point ideal detail column. Below roughly 560 points, stack row labels over controls and replace the nested rail with a compact top category menu. Preserve per-category scroll position where practical and announce category/page changes.

Categories and ownership:

- General: permissions/readiness, appearance/launch, Calendar/meeting integration, onboarding.
- Dictation: shortcuts/recording, Whisper quality/model, vocabulary/filler, HUD/audio/waveform sensitivity.
- Scribe: readiness, active provider/model link, polished-dictation explanation, review/fallback behavior, and the fixed Other Apps → General · Neutral fallback explanation/readiness. It exposes no global-preset selector.
- Apps: the global **Adapt Scribe to apps** toggle, installed app cards, family/preset, Custom guidance, missing-app recovery, Other Apps fallback, and scoped **Reset All App Settings**.
- Providers: provider library, active provider, models, credentials/validation, recipient/data disclosure, lifecycle actions.
- Privacy: local/cloud boundary, payload/recipient explanation, analytics, diagnostics export/clear.
- Advanced: low-frequency transcription/audio controls, migration/recovery, Custom OpenAI-Compatible endpoint, Custom Model ID.

Use compact system typography, warm `FlowTheme` tokens, dynamic light/dark mappings, eight-point continuous corners, one-point borders, solid surfaces, no card shadows, 12-point card insets, and inset dividers.

All Cadence-owned buttons declare one role: Primary, Secondary, Quiet, Destructive, Icon, Navigation row, or Menu item. Shared primitives preserve native `Button`, `Menu`/`Picker`, `Toggle`, `TextField`, and `Slider` semantics while supplying Cadence visuals, focus rings, loading, disabled, hover, pressed, default/cancel, and reduced-motion states. Use at most one safe default Return action per task surface; destructive actions are never Return defaults and require confirmation when state/credentials/content would be lost.

Convert discrete segmented controls to dropdowns. Keep waveform sensitivity as the continuous custom-styled slider. Replace the misaligned Advanced `DisclosureGroup` with a full-width disclosure button row: label stack, fixed 24×24 trailing chevron centered to the row, shared rotation/opacity motion, one hit target, and explicit expanded/collapsed accessibility value. Reuse it only where provider/meeting information has the same hierarchy.

Audit Settings, Scribe, Main Window, Meeting Notes, onboarding, permissions, menu content, and HUD controls. Preserve purpose-built drag regions, menu semantics, text-editor affordances, and OS-owned controls where the shared action role is not appropriate.

## Architecture and file ownership

Structural project changes go through `project.yml`, followed by `xcodegen generate`. Do not hand-edit `Cadence.xcodeproj/project.pbxproj`.

### Models

- Modify `Cadence/Models/ScribeModels.swift`: remove `ScribeIntent`, picker result, selected-context scopes/capabilities, and intent-bearing session/request states; define polished-dictation review/failure states without persistence.
- Modify `Cadence/Models/ScribeRequestModels.swift`: make provider-safe input the immutable contract + preset + optional guidance + Processed dictation + literal metadata; remove selected/ambient artifacts.
- Modify `Cadence/Models/ScribeProviderModels.swift`: add explicit OpenAI Direct/OpenRouter kinds, stable provider-library envelope/configuration IDs, active ID, catalog/model availability, provider-specific settings, consent/validation state, and schema v2 rejection states.
- Modify `Cadence/Models/ScribeProviderDisclosure.swift`: distinct named recipients and revisioned material-contract disclosures.
- Replace active use of `Cadence/Models/WritingEnvironmentModels.swift` with new `Cadence/Models/ApplicationConfigurationModels.swift`: descriptors, references, resolution/missing states, application configuration envelope, environment families, family-qualified presets, app-specific selection, guidance, and resolved guidance. Keep legacy models only for rollback decode/migration until the rollback window ends.
- Add `Cadence/Models/ScribePresetCatalogStateModels.swift` for the independent fixed-fallback/catalog-revision envelope; it has no user-configurable global preset and does not duplicate app-specific selections.
- Add `Cadence/Models/ApplicationIdentityModels.swift`: `ActiveApplicationIdentity`, `CapturedApplicationTarget`, identity keys/revisions, and value-only availability. Keep AppKit images out.
- Extend `Cadence/Models/DictationModels.swift`: replace narrow `DictationTargetApplication` use with captured target identity; keep persisted history identity-free.
- Modify `Cadence/Models/ScribeDiagnosticModels.swift`: add only closed provider/app/migration/control outcomes and coarse buckets; never exact model/app/config/guidance values.

### Provider and Scribe services

- Evolve `Cadence/Services/ScribeProviderConfigurationStore.swift` into the single-envelope provider-library v2 store. Either rename to `ScribeProviderLibraryStore.swift` with a migration shim or keep the filename and change the type deliberately; do not keep two active stores.
- Preserve and extend `Cadence/Services/ScribeCredentialStore.swift`: multiple opaque references, this-device-only/non-synchronizing attributes, reference-set cleanup only after a valid library commit.
- Modify `Cadence/Services/ScribeProviderConnectionManager.swift`: validate-stage-commit-cleanup against a candidate library; failed edits preserve the prior configuration/key.
- Modify `Cadence/Services/ScribeProviderController.swift`: load one library, expose readiness/active snapshot, build exact adapters, and refuse silent fallback.
- Preserve `Cadence/Services/ScribeHTTPTransport.swift`: ephemeral/no-cache/no-cookie/no-redirect/no-automatic-retry, deadline, response bound, cancellation, typed failures.
- Add `Cadence/Services/OpenAIDirectScribeProvider.swift`: Responses request/response serializer and typed error mapping.
- Add `Cadence/Services/OpenRouterScribeProvider.swift`: Chat Completions/ZDR request/response serializer and typed error mapping.
- Preserve `Cadence/Services/DeepSeekScribeProvider.swift`, `Cadence/Services/OpenAICompatibleScribeProvider.swift`, `Cadence/Services/FoundationModelsScribeProvider.swift`, and `Cadence/Services/UnavailableScribeProvider.swift` with explicit-kind behavior.
- Add `Cadence/Services/ScribeModelCatalogService.swift`: bundled catalog, consent-gated live discovery, exact-ID merge/search/filtering, in-memory lifecycle, compatibility and disappearance state.
- Modify `Cadence/Services/ScribeRequestPolicy.swift`: compile polished-dictation instructions and enforce the provider payload allowlist; delete intent/selected-context behavior instructions.
- Modify `Cadence/Services/ScribeLiteralNormalizer.swift`: select capabilities from resolved guidance instead of hard-coding Claude Code.
- Modify `Cadence/Services/ScribeCoordinator.swift`: one action flow, immutable target/provider/guidance snapshot, Retry polish, unpolished fallback, re-record distinction, target checks, late-result suppression, and terminal clearing.
- Modify `Cadence/Services/ScribeContextService.swift`: retain Accessibility authority and verification, enrich exact running identity locally, remove selected-text capture/authorization from Scribe.

### Application intelligence services

- Add `Cadence/Services/InstalledApplicationCatalogService.swift`: off-main scanning/validation/merge, cancellation, generation ordering, standard-root refresh, and injected filesystem/workspace/mounted-volume seams. Its lifecycle registers a debounced mount observer, routes mount/startup/Apps-page/file-selection/explicit triggers through one generation-tagged refresh pipeline, and tears down observers/tasks deterministically.
- Add `Cadence/Services/ApplicationIdentityResolver.swift`: exact URL, moved unique ID, duplicate ambiguity, missing/reinstall, runtime exact-copy matching.
- Add `Cadence/Services/ApplicationConfigurationStore.swift`: single schema-versioned envelope, built-in overlays versus materialized overrides, load rejection and scoped reset.
- Add `Cadence/Services/ScribeGuidanceCatalog.swift`: General/Messaging/Coding definitions, stable/versioned preset IDs, default/template overlays, immutable compiled instructions.
- Add `Cadence/Services/ScribePresetCatalogStateStore.swift`: independent fixed-fallback/catalog-revision envelope and strict load validation, with no user-facing global-preset setter.
- Replace active `WritingEnvironmentCatalog`, `WritingEnvironmentResolver`, `WritingEnvironmentStore`, and broad `WritingEnvironmentRecognizer` use with `Cadence/Services/ApplicationConfigurationResolver.swift`; retain the narrow certified Claude Code signature adapter only as an input to this resolver.
- Add `Cadence/Services/CustomGuidanceValidator.swift`: 2,000-byte/control-character rules and normalization.
- Add `Cadence/Services/FocusedApplicationMonitor.swift`: main-actor workspace observer/value snapshot/revision lifecycle.
- Add `Cadence/Services/ApplicationIconResolver.swift`: main-actor exact-process/exact-bundle icon lookup and memory cache.
- Modify `Cadence/Services/DictationCoordinator.swift`: pin exact target at action start; use it for local shortcut/polish selection, HUD, and pre-insertion verification.
- Modify `Cadence/Services/ShortcutExpansionService.swift` and `Cadence/Services/PersonalizationStore.swift` only as required to resolve legacy bundle scopes through the shared app picker; do not send their catalogs to providers.

### Migration and orchestration

- Add `Cadence/Services/ProviderLibraryMigrationService.swift` for v1 singular provider → v2 provider library.
- Add `Cadence/Services/ApplicationConfigurationMigrationService.swift` with its own ledger/marker for Slack/app data.
- Modify `Cadence/Services/AdaptiveScribeMigrationService.swift` to orchestrate versioned services without reusing a completed marker for new domains. Preserve source bytes, write/read-back destination, then write each marker last.
- Add `Cadence/Services/AdaptiveScribeFeatureGates.swift`: build defaults, debug override, dependency eligibility, and privacy-safe state.
- Add `Cadence/Services/SettingsPresentationStore.swift`: schema-versioned selected-category, per-category scroll/disclosure, and control-presentation preferences only; no content, credentials, app identity, or Scribe configuration.
- Modify `Cadence/App/AppModel.swift`: add all new UserDefaults key constants to the private `PreferenceKey` enum while retaining `Cadence.adaptScribeToApp`, inject them into the stores/migrations, instantiate/bind services, publish view state, expose the Apps-page adaptation toggle and scoped reset, coordinate feature gates, and remove inline `NSRunningApplication` ownership. Do not move scanning, icon logic, request compilation, store validation, or migration decisions into `AppModel`.
- Keep the legacy `WritingEnvironmentStore`, `WritingEnvironmentModels`, personalization decoders, and source keys buildable/readable for the first v2 release plus at least one subsequent rollback-capable release line. Mark them compatibility-only after migration, not dead code. Their eventual removal requires a separate release-gated change with retained golden-byte fixtures and evidence that no supported downgrade/flag path needs them.
- Modify `Cadence/App/ScribeLaunchFixtures.swift`: deterministic provider, Settings, app-picker, focus/icon, failure, and accessibility fixtures with synthetic content only.

### UI and controls

- Expand `Cadence/UI/CadenceActionButton.swift` into semantic role descriptors and Cadence-owned button styles while retaining native Button behavior.
- Add `Cadence/UI/CadenceControls.swift` for shared dropdown trigger/menu row, toggle, slider, field, disclosure row, card, status, focus, and loading primitives.
- Refactor `Cadence/UI/SettingsView.swift` into the shell/category router; split category pages into `Cadence/UI/Settings/GeneralSettingsView.swift`, `DictationSettingsView.swift`, `ScribeSettingsView.swift`, `AppsSettingsView.swift`, `ProvidersSettingsView.swift`, `PrivacySettingsView.swift`, and `AdvancedSettingsView.swift` to stop further growth of the existing file.
- Replace `Cadence/UI/WritingEnvironmentsView.swift` with `Cadence/UI/ApplicationConfigurationsView.swift` and `Cadence/UI/InstalledApplicationPickerView.swift`.
- Refactor `Cadence/UI/ScribeProviderManagementView.swift` and `Cadence/UI/ScribeProviderSetupView.swift` for library cards, searchable models, exact disclosures, edit/activate/disable/remove, offline/stale/error states, and shared disclosure controls.
- Refactor `Cadence/UI/ScribePanel.swift`: remove intent picker; add listen/process/polish/review/recovery states, app/preset cue, correct fallback labels, and shared actions.
- Modify `Cadence/Services/HUDWindowController.swift`, `Cadence/UI/HUDView.swift`, and `Cadence/UI/IdleExpandedTray.swift`: publish/bind live or pinned `ApplicationPresentation`, replace hardcoded target branding, preserve nonactivating panel behavior.
- Audit and migrate compatible controls in `Cadence/UI/MainWindowView.swift`, `MeetingNotesWindow.swift`, `OnboardingView.swift`, `PermissionsView.swift`, `PermissionGuideWindow.swift`, and `MenuContentView.swift`. Treat specialized menu/drag/editor controls intentionally rather than mechanically replacing every plain Button.

### Tests, fixtures, documentation, and release tooling

- Extend existing focused suites in `CadenceTests/` rather than replacing PR #34 coverage.
- Add `CadenceTests/ScribeProviderLibraryTests.swift`, `OpenAIDirectScribeProviderTests.swift`, `OpenRouterScribeProviderTests.swift`, `ScribeModelCatalogTests.swift`, `ApplicationConfigurationTests.swift`, `InstalledApplicationCatalogTests.swift`, `FocusedApplicationMonitorTests.swift`, `ApplicationIconResolverTests.swift`, `ScribeGuidanceTests.swift`, `CustomGuidanceTests.swift`, and `CadenceControlSemanticsTests.swift` as separate ownership surfaces.
- `InstalledApplicationCatalogTests` injects mount events and proves debounce/coalescing, external-volume app recovery, stale-generation rejection, cancellation, duplicate mount handling, observer teardown, and no refresh publication after shutdown.
- Update `CadenceTests/ScribeCoordinatorTests.swift`, `ScribeContextServiceTests.swift`, `ScribeActionPolicyTests.swift`, `ScribeLiteralNormalizerTests.swift`, migration/diagnostic/privacy suites, and `CadenceUITests/AdaptiveScribeUITests.swift`.
- Replace Compose/Respond/Edit and closed Slack/Claude fixtures in `CadenceTests/Fixtures/AdaptiveScribe/quality-corpus.json` and its manifest with synthetic polished-dictation General/Messaging/Coding fixtures.
- Modify `project.yml` for any new source/test target structure, then regenerate the project.
- Update `docs/privacy.md`, `docs/release-checklist.md`, `docs/adaptive-scribe-release-evidence.md`, and `CONTEXT.md` after behavior/tests settle.
- Extend `scripts/collect_adaptive_scribe_evidence.sh` and `scripts/verify_scribe_privacy_canaries.sh`; add `scripts/test_adaptive_scribe_contracts.sh`, `scripts/verify_live_scribe_providers.sh`, and `scripts/verify_scribe_real_apps.sh` with the stable interfaces below.
- Modify `scripts/package_release.sh` and `project.yml` so the archive injects the clean full Git commit as a non-secret `CadenceBuildCommit` Release Info.plist value before signing. Packaging and collection reject a missing or mismatched value; this binds the mounted signed app to the claimed source commit rather than trusting the current worktree alone.
- Update `.github/workflows/ci.yml` only through reviewable deterministic jobs; no live credentials or provider calls in CI.

## Persistence, Keychain, migration, and feature gates

### Durable stores

Declare these keys in `AppModel.PreferenceKey` and inject them into their owning services:

- Provider library: new `Cadence.scribeProviderLibrary.v2` single Codable envelope. Preserve `Cadence.scribeProviderConfiguration` unchanged through the rollback window.
- Application configurations: new `Cadence.applicationConfigurationLibrary.v1` single Codable envelope.
- Preset/catalog state: new `Cadence.scribePresetCatalogState.v1` single Codable envelope. In v1 it validates the fixed General · Neutral fallback plus catalog revision/readiness; it owns no user-configurable global preset, per-app override, or bundled definition text.
- Settings presentation: new `Cadence.settingsPresentation.v1` single Codable envelope for navigation/control presentation state only.
- Top-level rollout/debug overrides: new `Cadence.adaptiveScribeFeatureGates.v2` single Codable envelope; release defaults remain build-owned.
- Provider, application, preset, Settings, and rollout completion markers use separate keys and versions; do not overload `Cadence.adaptiveScribeMigrationLedger`.
- Preserve the existing `Cadence.adaptScribeToApp` Bool key and its absent/default semantics; do not rename or wrap it during this compatibility release.
- Existing `Cadence.writingEnvironmentPreferences`, `Cadence.personalizationLibrary`, shortcut scopes, legacy profile bytes, and the decoders needed to read them remain unchanged through the defined rollback horizon.

These exact keys are compatibility contracts. Tests reference injected store keys/constants rather than duplicating strings.

### Store load policy

- Absent store is a typed absent state.
- Malformed/future schema, duplicate IDs/kinds/references, invalid active ID, or internally invalid fields reject the entire envelope; never choose the first valid record.
- A rejected store remains byte-for-byte untouched and produces setup-required or General · Neutral fallback as appropriate.
- Writes encode one envelope, write, decode/read back, compare normalized value, then mark migration complete.
- No rejected load authorizes Keychain cleanup.

### Provider migration

1. Decode legacy provider state without modification.
2. Valid DeepSeek or Advanced becomes one provider-library entry with the same credential reference, model, normalized origin, enabled state, and accepted disclosure revision; it becomes active.
3. Legacy Local availability is represented explicitly, not auto-selected.
4. Write/read-back the new library.
5. Write the provider migration marker last.
6. Never delete the old key or credential during the rollback window.

### Application, preset, and Settings migrations

1. Preserve old environment and personalization bytes.
2. Map exact Slack preference: formal → Messaging Formal, neutral → Messaging Neutral, casual → Messaging Casual, disabled → disabled exact Slack configuration.
3. Bind unique installed Slack; otherwise preserve a known missing reference or pending ambiguous migration.
4. Do not map Claude state to Codex, Cursor, or broad Claude Desktop.
5. Do not compile `WritingStyleProfile` axes into presets/guidance.
6. Preserve personal shortcuts and their bundle scopes; unresolved bundle IDs become missing references in the editor rather than deletion.
7. Read `Cadence.adaptScribeToApp` with the legacy default behavior and continue using the same key. Do not make migration completion depend on changing its bytes.
8. Write/read-back application envelope; marker last; reruns deduplicate deterministically.
9. Independently write/read-back the fixed fallback/catalog-state envelope, then its marker. Do not copy app-specific choices into it or expose a global-preset setter.
10. Independently write/read-back Settings presentation defaults, then its marker. It contains no content or domain configuration.
11. Write rollout/debug state and its marker last; no reader activates until its own domain marker and semantic validation succeed.

Compatibility tests cover the adaptation key absent (legacy default enabled), explicit true, explicit false, wrong-type recovery, on/off resolution, individual-app reset preservation, and Reset All App Settings restoring enabled. The false path always produces General · Neutral with no Custom guidance while retaining target verification and provider safety.

### Keychain lifecycle

- One opaque random credential reference per saved cloud configuration.
- Use non-synchronizing, this-device-only accessibility from PR #34.
- Hold the entered candidate credential only in setup memory while synthetic validation runs through the production adapter. Failed or cancelled validation creates no Keychain item.
- After successful validation, stage one new Keychain item, persist and read back the complete candidate library, then activate/commit the selected configuration. A failure after staging deletes only that staged item and preserves the prior working library/key.
- Only after successful activation/commit calculate the full referenced set and remove superseded orphan credentials.
- Disable retains the credential. Remove deletes only that configuration's credential after library commit.
- Orphan cleanup computes the full referenced set only from a successfully decoded library.
- Keys/references never enter command lines, environment snapshots, logs, screenshots, diagnostics exports, analytics, xcresults, or evidence manifests.

### Feature-gate behavior

- `providerLibraryV2`: provider library/catalog/adapters and management readers.
- `applicationIntelligenceV2`: app store/resolver/monitor/icon readers.
- `polishedDictationV2`: one-flow coordinator/request compiler/review UI.
- `settingsControlSystemV2`: nested Settings and app-wide visuals only.
- `adaptiveScribeV2`: master runtime gate requiring the first three safety gates.

Unsafe partial combinations fail closed. Disabling the master keeps Dictation and Meeting unchanged and makes Scribe setup-required or offers local unpolished recovery for an in-memory action. It never chooses old intent semantics. Disabling the Settings visual gate does not disable safe provider/app management. Rollback changes readers/defaults only; it never downgrades schemas or deletes stores/credentials.

Legacy decoder/key removal is not part of this implementation. After the first v2 release and one subsequent rollback-capable release line, a later change may propose removal only when the supported-version policy excludes every legacy-reader downgrade, shipped rollback flags no longer select the old reader, golden legacy fixtures still prove migration, and a release-evidence record identifies the last supported downgrade build and why it is no longer supported.

## Ordered implementation work packages

### Package 0 — Establish the baseline and guardrails

Depends on: none.

- Land or rebase onto PR #34 at `04391d3`; record the resulting baseline SHA.
- Run PR #34 deterministic tests and evidence-tool check before behavior changes.
- Add this specification to the implementation branch and keep Dictation/Meeting regressions explicit.

Acceptance: baseline is clean, generated project is idempotent, PR #34 tests pass, and no implementation begins from the pre-PR main branch.

### Package 1 — Domain models, stores, migrations, and gates

Depends on: Package 0.

- Add provider-library, application-reference/configuration, fixed fallback/catalog-state, Settings presentation, rollout, guidance, and runtime identity value models.
- Add strict independent single-envelope stores and load rejection.
- Add separate provider/application migrations and marker-last interruption tests.
- Preserve the legacy environment/personalization decoders and exact `Cadence.adaptScribeToApp` compatibility path.
- Add local feature-gate dependency rules.

Acceptance: exhaustive pure decode/migration/downgrade tests pass; adaptation-key compatibility/reset tests pass; legacy bytes, decoders, and credential references are unchanged and retained for the stated release horizon; no runtime reader is active yet.

### Package 2 — Provider adapters and catalogs

Depends on: Package 1.

- Implement provider library controller/connection lifecycle.
- Implement OpenAI Direct and OpenRouter exact adapters.
- Implement bundled/live catalog merge, search, validation, offline/disappearance states.
- Extend disclosures, diagnostics, credential cleanup, and provider fixtures.

Acceptance: byte-level adapter, transport, consent, catalog, validation, cancellation, error, credential, and no-fallback tests pass.

Independent write surface: provider models/services/tests. It may proceed in parallel with Packages 3 and 4 after shared Package 1 models freeze.

### Package 3 — Installed-app intelligence and focused-target correctness

Depends on: Package 1.

- Implement discovery, canonical references, duplicate/move/missing resolution, mounted-volume refresh lifecycle, picker bridge, and app store.
- Implement guidance catalog/resolver and exact built-in templates.
- Implement focused monitor, runtime capture, icon resolver/cache, Dictation/Scribe identity enrichment, and HUD presentation.

Acceptance: catalog/resolver/migration, startup/activation/termination/mounted-volume/race, target pinning, duplicate-copy, icon fallback/invalidation, adaptation on/off/reset, and no-identity-egress tests pass; Cursor icon works in an installed Debug smoke flow and again in the exact signed Release-candidate evidence flow.

Independent write surface: app models/services/HUD tests. Coordinate `DictationCoordinator`, `ScribeContextService`, `HUDWindowController`, and `AppModel` sequentially with Packages 5–7 because they are integration hotspots.

### Package 4 — Cadence control primitives

Depends on: Package 1 for gate state only.

- Implement tokens, semantic button roles, dropdown/toggle/slider/field/card/status/disclosure primitives.
- Add keyboard, VoiceOver, contrast, reduced-motion, loading, and destructive-confirmation semantics.
- Build deterministic component fixtures before migrating pages.

Acceptance: component semantics and state matrix pass independent unit/UI fixtures.

Independent write surface: shared UI primitives/tests. It may proceed in parallel with Packages 2 and 3, but consumers migrate only after the primitive API freezes.

### Package 5 — Polished-dictation Scribe lifecycle

Depends on: Packages 2 and 3; uses Package 4 controls.

- Remove intent/selected-context state and request paths.
- Compile the allowlisted polished-dictation payload.
- Snapshot provider, target, guidance, literals, and processed dictation once.
- Implement mandatory review, immutable Retry polish, Insert/Copy unpolished, Re-record, recovery, late-result suppression, and clearing.
- Replace quality/adversarial corpus and panel fixtures.

Acceptance: lifecycle, privacy, target-race, literal, failure, retry byte-stability, insertion recovery, and content-clearing suites pass across all provider kinds and preset families.

### Package 6 — Settings shell, Providers, and Apps

Depends on: Packages 2, 3, and 4.

- Build nested category rail/responsive top menu and card pages.
- Build Provider library/setup/model management and exact disclosure states.
- Build Apps list/picker/family/preset/Custom guidance/missing recovery.
- Move diagnostics to Privacy and low-frequency controls to Advanced.

Acceptance: all category, width, search, loading/offline/stale/error, destructive, keyboard, VoiceOver, appearance, and Custom guidance fixtures pass.

### Package 7 — App-wide control migration and HUD integration

Depends on: Packages 3, 4, 5, and 6.

- Audit and migrate Cadence-owned controls across all named surfaces.
- Finish live/pinned HUD icon binding and expanded-tray cue.
- Preserve native OS surfaces, nonactivating HUD behavior, menu semantics, and specialized editor/drag controls.

Acceptance: source audit finds no unintended native bordered product buttons; semantic exceptions are documented; manual and automated accessibility/motion checks pass.

### Package 8 — Privacy, deterministic integration, and tooling

Depends on: Packages 2–7, though focused tests land with each package.

- Update privacy/disclosure/release docs and `CONTEXT.md`.
- Add focused test wrapper and live-provider/real-app scripts.
- Extend recursive canaries, evidence collector schema, CI fixtures, and manifest gates. Every live result envelope must embed candidate commit, canonical Release bundle identity, and DMG SHA-256; the collector validates these fields against the mounted DMG before it hashes or accepts the artifact.
- Run full project generation/build/test/UI/launch/meeting regression.

Acceptance: every deterministic command below passes from a clean worktree; documentation matches observed payloads and UI.

### Package 9 — Signed candidate and release evidence

Depends on: Package 8.

- Refresh current provider policy/model sources and bundled recommendation IDs.
- Package/notarize one Release candidate.
- Mount and run the exact signed Release app from the candidate DMG, then run live synthetic provider, real-app, accessibility, privacy, and five-day dogfood gates against that same commit/DMG. Debug runs remain pre-release smoke evidence only.
- Collect credential-free evidence and make an explicit PASS/FAIL decision.

Acceptance: all gates pass on one manifest-bound candidate. Any critical incident creates a new corrected candidate; evidence is never edited from FAIL to PASS.

### Shared write-surface rule

Do not run parallel writers against `Cadence/App/AppModel.swift`, `Cadence/UI/SettingsView.swift`, `Cadence/UI/ScribePanel.swift`, `Cadence/Services/ScribeCoordinator.swift`, `project.yml`, the quality corpus/manifest, or release evidence scripts. Integrate provider, app-intelligence, and control branches sequentially through these hotspots. Parallel work is safe only for isolated new services/models/tests with frozen shared interfaces.

## Acceptance criteria

### Provider and model

- OpenAI Direct serializes the fixed Responses contract with `store: false`; OpenRouter serializes one-model non-streaming Chat Completions with enforced ZDR/data-collection denial.
- No content request occurs before consent; redirects and hidden retries are impossible.
- Searchable bundled/live/custom catalogs work offline and online without persisting live responses.
- Exact production validation gates activation; missing/invalid models never auto-switch.
- Each provider kind has at most one saved configuration; changing the global active provider affects only the next action.
- Credentials survive failed edits and isolated remove/cleanup tests.

### Scribe

- Scribe begins dictation without Compose/Respond/Edit selection and never captures selected or ambient content.
- Every result is reviewed; no automatic polished or unpolished insertion exists.
- Retry is byte-for-byte stable in processed dictation and all configuration snapshots.
- Provider/target/literal failure preserves Processed dictation and offers explicit safe recovery.
- Every claim, request, fact, constraint, number, identifier, and exact literal survives quality fixtures; no unsupported content or task execution is introduced.
- Terminal actions clear all content-bearing in-memory state and create no content journal.

### Apps, presets, and identity

- Installed apps are searchable by name/icon; Choose Application validates one app bundle; no normal bundle-ID text field remains.
- Exact URL wins, unique move/reinstall rebinds, duplicates become explicit ambiguity, missing configurations persist.
- Mounting an external volume triggers the injected, debounced, generation-tagged catalog refresh; a newly available configured app reconnects, stale scan completion cannot win, and observer/task teardown is deterministic.
- Slack defaults Messaging Neutral; Cursor and Codex/OpenAI Desktop default Coding Precise; unknown/invalid/disabled use General Neutral without guidance.
- `Cadence.adaptScribeToApp` absent/true/false remains compatible; the Apps toggle owns it, off resolves fixed General Neutral without guidance, individual reset preserves it, and Reset All App Settings restores enabled without touching unrelated domains.
- Preset dropdowns are family-compatible only; bounded Custom guidance is local until a Scribe action and cannot expand payload authority.
- Cursor already frontmost at launch appears in the HUD; rapid app changes publish latest identity; an in-flight action remains pinned.
- Target switch/termination blocks insertion; app identity/icons never enter provider/log/analytics/evidence sinks.

### Settings and controls

- Seven Settings categories render in nested rail/card architecture and responsive top selector below the breakpoint.
- Scribe Settings shows the fixed Other Apps → General Neutral fallback explanation/readiness and contains no configurable global-preset control.
- Discrete selectors are dropdowns; waveform sensitivity remains a semantic continuous slider.
- The Advanced chevron is fixed-frame and center-aligned in collapsed/expanded states.
- Cadence-owned controls expose roles, focus, hover/pressed, disabled/loading, default/cancel, destructive confirmation, VoiceOver, contrast, and reduced-motion behavior.
- 520-, 560-, and 720-point detail widths; larger text; light/dark; Increase Contrast; Reduce Transparency; Reduce Motion; and keyboard-only traversal pass.
- OS-owned dialogs retain native appearance and behavior.

### Migration, privacy, and rollback

- Provider/app migrations are additive, idempotent, interruption-safe, marker-last, downgrade-readable, and never mutate legacy bytes or unrelated domains.
- Legacy environment/personalization bytes and decoders remain in the first v2 release plus at least one subsequent rollback-capable release line. Deletion is blocked until supported-version policy and release evidence prove no supported downgrade or flag path requires them.
- No malformed/future/duplicate store causes first-match selection or credential cleanup.
- Privacy copy, in-app disclosures, wire captures, diagnostics, analytics, and evidence agree.
- Reset Apps cannot alter providers; Remove Provider cannot alter other credentials; visual reset cannot alter Scribe; nothing touches Dictation history/vocabulary/hotkeys, meetings/audio, Google OAuth, permissions, onboarding, or analytics consent.
- Feature-gate rollback never restores retired intent semantics or chooses a different recipient/model/target/preset.

## Exact validation commands and evidence gates

Run deterministic and release validation from the implementation branch after PR #34 has been integrated. Release validation must run from a clean isolated worktree at the exact candidate commit.

```zsh
# Generated project is source-idempotent.
xcodegen generate
git diff --exit-code -- Cadence.xcodeproj

# Full deterministic unit/integration suite.
xcodebuild test -project Cadence.xcodeproj -scheme Cadence -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

# Native synthetic UI fixtures.
xcodebuild test -project Cadence.xcodeproj -scheme CadenceUITests -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=

# Focused stable wrapper added by this implementation.
scripts/test_adaptive_scribe_contracts.sh

# Installed Debug launch and Meeting regression.
./script/build_and_run.sh --verify
./script/build_and_run.sh --audio-smoke

# Evidence scripts and corpus syntax without claiming live gates.
scripts/collect_adaptive_scribe_evidence.sh --check
```

Recursive privacy scan interface:

```zsh
SCRIBE_PRIVACY_CANARIES='<comma-separated generated canaries>' \
  scripts/verify_scribe_privacy_canaries.sh \
  <xcresults> <logs> <defaults-snapshot> <app-support-snapshot> \
  <diagnostics-export> <analytics-capture> <evidence-dir>
```

The canary set covers transcript, credential, origin, exact model, app name/ID/path, Custom guidance, request/response, PID, user path, and request identifiers. Any recursive match invalidates and destroys the affected evidence bundle after a content-free incident record.

Debug verification is a pre-release smoke pass only. It prompts for credentials through the app's Keychain-backed UI and never accepts keys as arguments or environment variables:

```zsh
scripts/verify_live_scribe_providers.sh --app '/Applications/Cadence Debug.app' --provider openai
scripts/verify_live_scribe_providers.sh --app '/Applications/Cadence Debug.app' --provider openrouter
scripts/verify_scribe_real_apps.sh --app '/Applications/Cadence Debug.app' --apps cursor,slack,codex
```

Real-app verification covers startup with Cursor frontmost, rapid Cursor/Slack switching, pinned-target rejection, Cursor/Codex Coding presets, Slack presets, unknown fallback, termination/relaunch, duplicate bundle copies, Cadence/Settings focus behavior, picker refresh/file selection/missing recovery, and privacy inspection.

Package, mount, verify, and install the exact Release candidate before any release gate. The release owner first removes or archives an existing `/Applications/Cadence.app`; the commands refuse to overwrite it:

```zsh
scripts/package_release.sh

CANDIDATE_COMMIT="$(git rev-parse HEAD)"
CANDIDATE_DMG="$PWD/Build/Release/Cadence.dmg"
CANDIDATE_DMG_SHA256="$(shasum -a 256 "$CANDIDATE_DMG" | awk '{print $1}')"
CANDIDATE_MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/cadence-release.XXXXXX")"

hdiutil attach "$CANDIDATE_DMG" -readonly -nobrowse -mountpoint "$CANDIDATE_MOUNT"
MOUNTED_RELEASE_APP="$CANDIDATE_MOUNT/Cadence.app"
codesign --verify --deep --strict "$MOUNTED_RELEASE_APP"
spctl --assess --type open --context context:primary-signature -v "$CANDIDATE_DMG"

test ! -e '/Applications/Cadence.app'
ditto "$MOUNTED_RELEASE_APP" '/Applications/Cadence.app'
codesign --verify --deep --strict '/Applications/Cadence.app'
test "$(defaults read '/Applications/Cadence.app/Contents/Info' CFBundleIdentifier)" = 'com.darshshah.Cadence'
test "$(defaults read '/Applications/Cadence.app/Contents/Info' CFBundleDisplayName)" = 'Cadence'
test "$(defaults read '/Applications/Cadence.app/Contents/Info' CadenceBuildCommit)" = "$CANDIDATE_COMMIT"
hdiutil detach "$CANDIDATE_MOUNT"
rmdir "$CANDIDATE_MOUNT"
open -n '/Applications/Cadence.app'
```

Run every live release gate against `/Applications/Cadence.app` from that mounted DMG, not `Cadence Debug.app`:

```zsh
scripts/verify_live_scribe_providers.sh \
  --app '/Applications/Cadence.app' --provider openai \
  --candidate-commit "$CANDIDATE_COMMIT" \
  --candidate-dmg-sha256 "$CANDIDATE_DMG_SHA256" \
  --output Build/AdaptiveScribeEvidence/providers/openai/result.json

scripts/verify_live_scribe_providers.sh \
  --app '/Applications/Cadence.app' --provider openrouter \
  --candidate-commit "$CANDIDATE_COMMIT" \
  --candidate-dmg-sha256 "$CANDIDATE_DMG_SHA256" \
  --output Build/AdaptiveScribeEvidence/providers/openrouter/result.json

scripts/verify_scribe_real_apps.sh \
  --app '/Applications/Cadence.app' --apps cursor,slack,codex \
  --candidate-commit "$CANDIDATE_COMMIT" \
  --candidate-dmg-sha256 "$CANDIDATE_DMG_SHA256" \
  --output Build/AdaptiveScribeEvidence/real-apps/result.json
```

Each live provider, real-app, accessibility, privacy, and dogfood result is a credential-free JSON envelope containing exactly the candidate binding needed for admission:

```json
{
  "candidate": {
    "commit": "<full SHA>",
    "bundleIdentifier": "com.darshshah.Cadence",
    "bundleDisplayName": "Cadence",
    "bundleExecutable": "Cadence",
    "releaseDMGSHA256": "<SHA-256>"
  }
}
```

The evidence collector mounts the supplied DMG itself, recomputes its SHA-256, reads `CadenceBuildCommit` and the canonical Release identity from the signed mounted app, and compares the embedded app commit, `--commit`, DMG hash, and bundle identity with every live envelope. It rejects a missing/malformed field, Debug identity, app/worktree/artifact commit mismatch, or DMG-hash mismatch **before** hashing, recording, or accepting that artifact. Directories are accepted only when their required `result.json` envelope passes this check.

After all live envelopes exist, collect them while the same candidate variables remain in scope:

```zsh
scripts/collect_adaptive_scribe_evidence.sh \
  --commit "$CANDIDATE_COMMIT" \
  --dmg "$CANDIDATE_DMG" \
  --artifact deterministic=<path> \
  --artifact ui=<path> \
  --artifact providers=Build/AdaptiveScribeEvidence/providers \
  --artifact real-apps=Build/AdaptiveScribeEvidence/real-apps \
  --artifact accessibility=Build/AdaptiveScribeEvidence/accessibility \
  --artifact privacy=Build/AdaptiveScribeEvidence/privacy \
  --artifact dogfood=Build/AdaptiveScribeEvidence/dogfood
```

CI on macOS 15 must pass generated-project build, unit/integration tests, and ad-hoc-signed native UI tests on the candidate SHA. The installed Release app, all live result envelopes, and the collector manifest must bind to that same SHA and DMG hash.

Manual candidate gates:

- VoiceOver, Accessibility Inspector, Full Keyboard Access, larger text, both appearances, Increase Contrast, Reduce Transparency, and Reduce Motion.
- Live synthetic OpenAI/OpenRouter validation and fixed meaning-preservation corpus with credential-free bounded results.
- Same-candidate policy review dates and model recommendation refresh.
- Five workdays and at least 40 genuine Scribe actions spanning General, Messaging, and Coding; retain only aggregate counts and content-free incidents.
- Zero privacy, stale-target, silent-fallback, migration-loss, accessibility-critical, or data-loss incidents.

## Evidence retention

Extend `scripts/collect_adaptive_scribe_evidence.sh`. It must refuse dirty trees, commit mismatch, noncanonical/Debug DMGs, mutable/missing artifacts, or any live artifact whose embedded full commit, canonical Release bundle identity, or DMG SHA-256 differs from the candidate it independently verifies. Candidate-binding validation occurs before artifact hashing or manifest admission; rejected artifacts never appear in the manifest. Unrun gates remain explicitly `NOT_RUN`.

Retain only manifest, hashes, candidate identity, synthetic corpus/version, deterministic summaries, policy-review dates, coarse live-provider results, real-app checklist, accessibility checklist, dogfood aggregates, and final PASS/FAIL. Do not retain genuine text/audio, provider payloads, credentials/references, app inventory, Custom guidance, exact identities, raw errors, or screenshots containing sensitive content. A separate human witness may attest that the named provider received the synthetic request without recording secret/request detail.

## Risks and mitigations

- **PR #34 changes before implementation.** Rebase this file map against the landed commit before Package 1; preserve contracts, not stale line numbers.
- **Provider APIs/policies/catalogs drift.** Keep adapters typed and origins fixed; review primary sources and refresh release data near every candidate; bump disclosure revision for material recipient/routing/retention changes.
- **UserDefaults lacks transactions.** Use one envelope per domain, immediate decode/read-back, marker-last migration, preserved source bytes, and idempotent interruption tests.
- **Keychain cleanup destroys recovery.** Clean only after a complete valid library commit and only references proven orphaned across the whole library.
- **App discovery is incomplete or ambiguous.** Merge standard roots, running apps, and explicit file selection; preserve missing state; fail duplicates closed.
- **AppKit focus/icon events race.** Main-actor value snapshots, startup sampling, revisions, exact process/URL keys, cancellation, and real rapid-switch tests make latest state authoritative.
- **Custom guidance prompts conflict.** Treat it as lower-priority untrusted data, structurally isolate it, preserve literal/output validation, and require review; never claim perfect prompt-injection classification.
- **Custom visual controls regress native behavior.** Build on semantic native controls, freeze primitives before migration, add deterministic semantics fixtures, and require manual assistive-technology review.
- **Feature combinations become unsafe.** Compute master eligibility from safety dependencies and disable Scribe/insertion for invalid combinations; keep visual rollback independent.
- **A large integration diff hides regressions.** Land packages in dependency order, keep isolated new-file ownership parallel, serialize shared hotspots, and run focused plus full tests after each integration.

## Rollback and release blockers

Rollback disables failing readers or visuals and preserves both old and new stores/credentials. It never schema-downgrades, deletes migration source, crosses Dictation/Meeting storage, or restores Compose/Respond/Edit. If a safe provider/app/target cannot be resolved, Scribe becomes setup-required or preserves in-memory Processed dictation for Copy/Insert Unpolished.

Do not ship if any of the following is true:

- Content beyond the provider allowlist appears on the wire or prohibited data appears in logs, diagnostics, analytics, persistence, screenshots, xcresults, or evidence.
- Network occurs before consent, a redirect is followed, or OpenRouter relaxes ZDR/data-collection policy.
- Any provider, model, app, target, family, preset, or guidance changes silently under an action.
- Provider failure loses Processed dictation or inserts a fallback automatically.
- A stale, ambiguous, changed, or terminated target receives insertion.
- Migration alters legacy bytes, duplicates records, deletes a credential, cannot resume, or affects an unrelated domain.
- Custom controls fail critical keyboard, VoiceOver, contrast, responsive, or reduced-motion acceptance.
- Live provider, real Cursor/Slack/Codex, signed/notarized distribution, privacy, accessibility, or dogfood evidence is missing or bound to another commit/DMG.

A failed candidate remains FAIL. Correct the defect and produce a new manifest-bound candidate; never edit evidence into PASS.

## Destination status

All Wayfinder product and technical questions represented by the child tickets are resolved in this specification. No additional fog or decision ticket is required. The next artifact should be a Compound Engineering implementation plan that decomposes Packages 0–9 into reviewable execution slices while preserving their dependency and evidence gates.
