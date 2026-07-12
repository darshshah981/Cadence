# Cross-cutting privacy, migration, validation, and rollout acceptance contract

Date: 2026-07-11
Wayfinder ticket: [Define cross-cutting privacy, migration, validation, and rollout acceptance](https://github.com/darshshah981/Cadence/issues/43)
Baseline: Adaptive Scribe PR #34 at `04391d3`

## Decision

The implementation ships only when deterministic CI, signed-candidate checks, live provider calls, real installed-app behavior, accessibility review, privacy inspection, and bounded dogfood all pass on the same manifest-bound Release candidate. A green pull request proves only the deterministic tier.

Migration is additive, independently versioned by data domain, idempotent, and rollback-readable. Feature flags switch readers and surfaces; they do not delete old or new data. A rollback may disable cloud polish and fall back to processed dictation, but it must never restore PR #34's selected-text Compose/Edit/Respond product because that contract is explicitly retired.

No new Wayfinder ticket is required. The remaining work is synthesis in [Synthesize the implementation-ready specification](https://github.com/darshshah981/Cadence/issues/44).

## Reconciled contract authority

The resolved contracts apply in this order when older PR #34 evidence conflicts:

1. The polished-dictation contract controls Scribe meaning, payload, review, retry, and fallback.
2. The provider contract controls provider kinds, recipients, catalog lifecycle, credentials, and wire profiles.
3. The installed-app and focused-app contracts control persisted and runtime identity.
4. The environment contract controls family, preset, and custom-guidance resolution.
5. The Settings contract controls navigation and Cadence-owned controls.
6. PR #34 remains authoritative for hardened transport, consent, credential staging, target verification, late-result suppression, content clearing, diagnostics, migration discipline, and separation of deterministic from live release evidence.

Consequences:

- Replace every Compose/Respond/Edit, selected-text, Slack/Claude-only, singular-provider, and manual-bundle-ID row in `docs/adaptive-scribe-release-evidence.md`; do not retain it as a hidden compatibility suite.
- Preserve certified Claude Code recognition only as a narrow legacy template until deliberately removed. Never map a broad Claude application configuration to Codex or Cursor.
- `Other apps · Neutral` is renamed `General · Neutral`; invalid, missing, disabled, ambiguous, and unknown app resolution all converge there with no custom guidance.
- Diagnostics add OpenAI Direct, OpenRouter, Custom OpenAI-Compatible, and local closed-enum kinds, but never gain arbitrary strings or exact model/app identity.

## Privacy and data-flow boundary

### Local-only data

The following stay on the Mac and out of providers, analytics, OSLog, crash metadata, support exports, and release evidence:

- audio and raw recognizer output;
- vocabulary and shortcut catalogs;
- selected, clipboard, window, screen, nearby, prior-turn, or accessibility content;
- installed-app inventory, app names, bundle IDs, bundle URLs, PIDs, icons, focus history, and application configuration IDs;
- provider credentials, credential references, account/project identifiers, custom origins, exact model IDs, raw headers/bodies/errors, request/response text, and provider request IDs;
- custom-guidance text and legacy writing-profile content;
- processed dictation and polished drafts, except for the explicit provider payload described below.

Scribe content remains memory-only for an active action. Insert, Copy, Insert Unpolished, Discard, cancellation, provider removal, app termination, or a superseding fresh action clears every content-bearing snapshot. Scribe does not write a recovery journal and never reuses meeting storage or Dictation history.

### Provider egress

After provider-specific affirmative consent and fresh target verification, the selected recipient receives only:

1. the immutable meaning-preserving/privacy/literal contract;
2. the compiled preset instructions;
3. optional app-specific custom guidance;
4. processed dictation as inert text to polish;
5. the minimal adapter fields required by the selected provider/model.

OpenAI Direct is a fixed `https://api.openai.com/v1/responses` recipient with `store: false`, no tools, files, images, background mode, previous-response state, or arbitrary headers. OpenAI documents that API data is not used for model training unless a customer opts in, while abuse-monitoring and endpoint-specific retention still apply; disclosure must state the reviewed policy rather than promise zero retention.

OpenRouter is a distinct recipient/router. The request uses one selected model, `provider.zdr: true`, `provider.data_collection: "deny"`, no cross-model fallbacks, tools, plugins, or arbitrary routing JSON. Same-model routing may use only eligible ZDR endpoints. OpenRouter documents that ZDR can be enforced per request and that endpoint policies vary, so both the router and downstream-provider relationship must be disclosed.

Model discovery uses synthetic/no-user content only after consent and only in model-management UI. Live catalogs stay in memory. Normal Scribe never performs discovery.

### Logs, diagnostics, analytics, and documents

- Production logging accepts closed enums and coarse buckets only. `privacy: .private` is not permission to log prohibited fields.
- The local Scribe diagnostic ring remains content-free, bounded to 200 events and seven days, minute-rounded, and user-cleared/exported. Export is never uploaded automatically.
- Remote Scribe analytics remains opt-in. If it cannot avoid Cadence's persistent PostHog identity, its sink is no-op. It receives only closed event/phase/provider/outcome and coarse latency/attempt fields.
- Exact app identity, exact model/origin, guidance, prompt/response, raw errors, keys, and stable request/account/device IDs are prohibited in every telemetry path.
- `docs/privacy.md`, provider disclosure, Settings privacy copy, and release notes must describe that local transcription precedes explicit cloud Scribe polish, name the recipient/routing boundary, distinguish local diagnostics from opt-in analytics, and explain clearing/retention accurately before release.

## Credential and preference migrations

### Credential lifecycle

Reuse PR #34's generic-password Keychain service with opaque random account references, `kSecUseDataProtectionKeychain`, `kSecAttrSynchronizable = false`, and `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Apple documents that this accessibility class does not migrate to a new device; it is compatible with the required this-device-only boundary.

For every provider add or edit:

1. Obtain consent and validate the candidate with synthetic text through the production adapter.
2. Stage a new Keychain item only after validation.
3. Persist and read back the complete provider library referencing the staged item.
4. Commit the active selection only after the entry is valid and the user explicitly selects it.
5. Delete only the superseded credential after successful commit and cross-library reference calculation.

Cancellation or validation/persistence failure removes only the staged item and preserves the old working library/key. Disable retains the key. Remove deletes only that provider's entry and key. Malformed/future library state performs no orphan cleanup.

### Independent versioned stores

Use distinct new envelopes and completion markers for:

- provider library v2;
- application configuration v1;
- preset/catalog selection v1;
- Settings navigation/control preferences v1;
- top-level rollout state.

Runtime focus, PID, launch discriminator, icons, catalog responses, and active action snapshots are never persisted.

Migration order is deterministic:

1. Read and retain the untouched PR #34 stores and bytes.
2. Write one new envelope to a new key.
3. Decode and semantically validate the value just written.
4. Write that domain's completion marker last.
5. Repeat independently for the next domain.
6. Enable a new reader only after its valid marker exists.

An interrupted migration reruns without duplicates. Malformed/future source or destination bytes are preserved and fail closed. Startup migration performs no network request, synthetic validation, Keychain creation/deletion, catalog refresh, or app scan whose results mutate configuration.

### Exact mappings and non-mappings

- Valid PR #34 DeepSeek or Advanced configuration becomes one active DeepSeek or Custom OpenAI-Compatible provider-library entry without changing its credential reference, selected model, normalized origin, enabled state, or accepted disclosure revision.
- Legacy Local remains explicit; it is never selected as a silent cloud-failure fallback.
- An exact, uniquely resolved legacy Slack preference maps to Slack's application configuration and the semantically matching Messaging preset/enabled state.
- Legacy writing profiles remain byte-for-byte rollback-readable and are not compiled or guessed into presets/guidance.
- Personal shortcuts remain unchanged local preprocessing.
- Claude data never auto-maps to Codex or Cursor. Missing or duplicate app matches produce preserved migration state plus General · Neutral at runtime.
- Missing/uninstalled application configurations remain visible and recoverable; they do not leak stale guidance into active actions.

### Rollback and scoped reset

Rollback changes active readers/feature flags only. It does not downgrade schemas, delete Keychain items, erase provider/app configurations, or rewrite legacy bytes. If a disabled reader cannot safely interpret a configuration, Scribe becomes setup-required or offers Insert Unpolished/Copy; it never guesses a provider, model, app, target, or preset.

Reset actions declare their scope in UI and tests. Reset Apps must not affect providers; Remove Provider must not affect other credentials; Reset Settings appearance must not affect Scribe content; none may affect Dictation history, vocabulary, hotkeys, meetings/audio, Google OAuth, permissions, onboarding, or analytics consent.

## Feature flags and phased rollout

Use local, versioned rollout gates with no remote configuration dependency:

- `providerLibraryV2`: new provider/configuration/catalog reader and provider UI;
- `applicationIntelligenceV2`: installed-app store, environment resolver, focused-app monitor, and icon presentation;
- `settingsControlSystemV2`: nested Settings shell and app-wide Cadence control visuals;
- `polishedDictationV2`: new meaning-preserving Scribe lifecycle and payload compiler;
- `adaptiveScribeV2`: master eligibility gate requiring the safety-critical dependencies above.

Flags are build-owned defaults with a debug override, not arbitrary user-facing switches. `polishedDictationV2` may not activate without provider/request privacy tests and target checks. `applicationIntelligenceV2` may not activate insertion if target verification is unavailable. The Settings visual flag may roll back independently. Disabling the master gate leaves Dictation and Meeting unchanged and Scribe content-safe/setup-required; it does not revive Compose/Edit/Respond.

Rollout phases:

1. **Migration dark launch:** write/read-back new stores with all new runtime readers off; prove idempotence and downgrade fixtures.
2. **Deterministic adapters:** provider library, serializers, catalogs, resolver, monitor, and controls enabled only in tests/debug fixtures.
3. **Internal live verification:** installed Debug app with synthetic OpenAI/OpenRouter calls and Cursor/Slack/Codex app flows; no genuine content.
4. **Signed candidate:** all flags on in Release candidate; execute full matrix and collect manifest-bound evidence.
5. **Bounded dogfood:** five workdays, at least 40 genuine Scribe actions spanning General, Messaging, and Coding; retain only aggregates and incidents.
6. **Release:** default flags on only after every mandatory gate passes on the same commit/DMG. Any critical privacy, stale-target, silent-fallback, migration-loss, or accessibility blocker fails the candidate.

## Deterministic test contract

### Pure model, store, and migration tests

- Every provider-library decode state: absent, valid, malformed, future, duplicate kind/ID, invalid active ID, disabled active entry, invalid provider fields.
- Every app-store identity state: duplicate URL/ID, move, reinstall, missing, ambiguity, unsigned/incomplete bundle, and explicit file selection.
- Store interruption at every write/marker boundary; repeated launch; downgrade; byte/reference preservation; no cleanup on rejected load.
- Exact Slack mapping and every forbidden mapping; legacy profiles and shortcuts untouched.
- Independent reset scope and feature-flag combinations, including master on with a dependency off.

### Provider contract tests

- Byte-level OpenAI serializer asserts fixed origin/path, bearer-only auth, `store: false`, no tools/state/background/arbitrary headers, bounded response, completed-text extraction, redirect refusal, cancellation, and typed errors.
- Byte-level OpenRouter serializer asserts fixed origin/path, one model, `stream: false`, `provider.zdr: true`, `provider.data_collection: "deny"`, no model fallback/plugins/tools/routing JSON, redirect refusal, cancellation, and typed errors.
- Catalog fixtures prove explicit-consent gating, authenticated user filtering, in-memory-only lifecycle, compatibility filtering, deduplication, custom-ID validation, disappearance without fallback, and discovery not equaling activation.
- Credential fakes prove validate-stage-commit-cleanup across multiple references and every failure/cancellation edge.

### Scribe and privacy tests

- Payload allowlist contains only immutable contract, compiled preset, optional guidance, processed dictation, and required literal metadata; serialization rejects all identity/ambient/selected fields.
- Quality/adversarial fixtures cover General, Messaging Neutral/Formal/Casual, and Coding Precise/Concise/Structured. Every claim, number, identifier, constraint, requested action, and literal remains; nothing is invented or executed.
- Retry is byte-for-byte stable after focus/settings/provider changes; re-record creates a new snapshot.
- Every failure preserves processed dictation, inserts nothing silently, suppresses late results, and clears content on terminal exit.
- Recursive canaries cover transcript, key, origin, model, app, prompt, response, custom guidance, path/user, bundle URL/ID, PID, and request identifiers across logs, defaults, app support, diagnostics, analytics captures, xcresults, screenshots, and evidence.

### Installed-app and runtime tests

- Discovery, refresh, deduplication, exact-URL resolution, moved-app rebind, and missing-state preservation.
- Monitor startup sample, activation, self activation, termination, wake/resample, rapid out-of-order revisions, and observer teardown.
- Running icon over bundle icon over generic fallback; cache invalidation; no image bytes persisted.
- Dictation and Scribe pin one exact process/bundle URL; app switch or termination prevents insertion and preserves text.

### UI and accessibility tests

- Deterministic fixtures for all Settings categories, provider/app rows, picker search, dropdowns, Advanced disclosure, empty/loading/offline/stale/error/success/destructive states, and long text.
- Keyboard-only traversal, visible focus ring, Return default only for safe actions, Escape cancellation, no destructive default, and menu semantics for discrete selectors.
- VoiceOver label/value/hint/state for every custom control; technical IDs/paths never spoken as normal labels.
- 520-, 560-, 720-point detail widths plus minimum main-window width; labels stack and top category selector replaces the rail at the specified breakpoint without clipping.
- Light/dark, larger text, Increase Contrast, Reduce Transparency, Reduce Motion, and color-independent status. Apple recommends testing with assistive technologies and Accessibility Inspector, sufficient contrast, keyboard access, and reduced motion; automated assertions do not replace the manual pass.

## Live acceptance and evidence retention

### Real providers without secret artifacts

For OpenAI Direct and OpenRouter, use release-owner API keys entered through the app's Keychain-backed setup UI. Run synthetic validation and a fixed synthetic meaning-preservation corpus through the installed candidate. Never pass keys in commands, environment snapshots, shell history, logs, screenshots, xcresults, or manifests.

The credential-free result artifact records only:

- candidate commit/DMG hash;
- provider kind and reviewed contract/catalog revision;
- UTC date rounded to the day;
- pass/fail for consent-before-network, production-adapter validation, request-policy assertions, response parsing, cancellation, timeout/failure preservation, and privacy-canary scan;
- coarse latency bucket and bounded quality score;
- a SHA-256 of the selected model ID only when proof of stable selection is needed.

It contains no key/reference, exact model/origin, organization/project, prompt/output, raw header/body/error, request ID, balance, or user content. A separate human witness records that the network request reached the named provider. OpenRouter evidence additionally proves a successful ZDR-routed response or a typed no-eligible-ZDR failure; either behavior must match the selected model's current eligibility, never silently relax policy.

### Real applications

On the same candidate:

1. Launch with Cursor already frontmost; HUD immediately shows Cursor's real icon/name.
2. Switch Cursor → Slack → Cursor rapidly; latest identity wins.
3. Dictate in Cursor, switch to Slack before insertion; Cursor remains pinned and Slack receives nothing.
4. Run Scribe in Cursor and Codex/ChatGPT Desktop; Coding defaults resolve locally and provider capture contains no identity.
5. Verify Slack Messaging Neutral/Formal/Casual and unknown-app General Neutral.
6. Quit/relaunch Cursor; stale process/icon cannot survive.
7. Test two copies sharing a bundle ID; exact runtime URL selects presentation/configuration.
8. Bring Settings forward and drag the nonactivating HUD; last external history is never promoted to current target.
9. Use Choose Application, search, missing-app recovery, and explicit Refresh.
10. Inspect OSLog, diagnostics export, analytics capture, defaults/app support, Keychain attributes, provider instrumentation, screenshots, and evidence with all privacy canaries.

### Evidence policy

Extend `scripts/collect_adaptive_scribe_evidence.sh` rather than hand-building evidence. It must continue refusing a dirty tree, commit mismatch, noncanonical DMG, Debug identity, or mutable artifact. The manifest hashes credential-free artifacts without copying their contents and leaves unrun gates explicitly `NOT_RUN`.

Evidence lives under `Build/` or the release system, never as committed genuine content. Retain manifest, hashes, synthetic corpus/version, test summaries, accessibility checklist, policy-review dates, coarse live-provider results, real-app checklist, and final PASS/FAIL. Never retain dogfood text/audio, provider payloads, keys, app inventory, custom guidance, or exact identities. Any privacy canary match invalidates and destroys the affected evidence bundle after recording a content-free incident.

## Exact validation matrix

Commands marked **existing** run from the PR #34 worktree. Commands marked **implementation** must be added by the implementation plan with those stable interfaces.

| Gate | Command or action | Required result |
|---|---|---|
| Project generation | **existing** `xcodegen generate && git diff --exit-code -- Cadence.xcodeproj` | Generated project is idempotent. |
| Full deterministic suite | **existing** `xcodebuild test -project Cadence.xcodeproj -scheme Cadence -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | All unit/integration tests pass without credentials/network. |
| Native UI suite | **existing** `xcodebuild test -project Cadence.xcodeproj -scheme CadenceUITests -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` | All synthetic UI fixtures and screenshots pass. |
| Installed Debug launch | **existing** `./script/build_and_run.sh --verify` | Installed Debug app stays running and main window appears. |
| Meeting regression | **existing** `./script/build_and_run.sh --audio-smoke` | System-audio capture still produces frames. |
| Evidence tooling | **existing** `scripts/collect_adaptive_scribe_evidence.sh --check` | Corpus and evidence scripts validate without claiming live gates. |
| Focused suites | **implementation** `scripts/test_adaptive_scribe_contracts.sh` | Provider/store/migration/Scribe/app-monitor/picker/control suites pass and emit xcresult paths. |
| Runtime privacy | **existing interface** `SCRIBE_PRIVACY_CANARIES='<comma-separated generated canaries>' scripts/verify_scribe_privacy_canaries.sh <xcresults> <logs> <defaults-snapshot> <app-support-snapshot> <diagnostics-export> <analytics-capture> <evidence-dir>` | No prohibited value appears recursively. |
| Debug live providers | **implementation** `scripts/verify_live_scribe_providers.sh --app '/Applications/Cadence Debug.app' --provider openai` then `--provider openrouter` | Script prompts for UI/Keychain setup, uses synthetic fixtures, and writes only credential-free summaries. |
| Real apps | **implementation** `scripts/verify_scribe_real_apps.sh --app '/Applications/Cadence Debug.app' --apps cursor,slack,codex` | Ten real-app scenarios pass with privacy-safe results. |
| Accessibility | Manual VoiceOver, Accessibility Inspector, Full Keyboard Access, larger text, appearance, contrast, transparency, and motion checklist attached to candidate | No critical issue; all custom controls expose correct semantics. |
| Release package | **existing** `scripts/package_release.sh` | Produces only notarized/stapled `Build/Release/Cadence.dmg`. |
| Signature | **existing tools** `codesign --verify --deep --strict Build/Release/Cadence.app` where exported app is available, and `spctl --assess --type open --context context:primary-signature -v Build/Release/Cadence.dmg` | Developer ID signature and Gatekeeper pass. |
| Manifest | **existing** `scripts/collect_adaptive_scribe_evidence.sh --commit "$(git rev-parse HEAD)" --artifact deterministic=<path> --artifact ui=<path> --artifact providers=<path> --artifact real-apps=<path> --artifact accessibility=<path>` | Clean canonical candidate manifest created; unrun gates remain explicit. |
| CI | GitHub macOS 15 build, unit, and native UI jobs | Required checks green on candidate SHA. |
| Dogfood | Human release-owner checklist for five workdays and at least 40 General/Messaging/Coding actions | Zero privacy/stale-target/silent-fallback/data-loss incidents; bounded quality threshold passes. |

Run release validation from a clean isolated worktree at the exact candidate commit. `codesign` verification of the exported app must use the mounted/exported Release app path rather than assume it remains under `Build/Release` after packaging; the collector already verifies the canonical app inside the DMG.

## Failure recovery and release blockers

The candidate fails and does not ship if any of these occur:

- prohibited content appears in any provider payload field beyond the allowlist or in any log/diagnostic/analytics/evidence sink;
- network occurs before consent, a redirect is followed, or OpenRouter relaxes ZDR/data-collection policy;
- provider/model/app/preset silently changes, or provider failure loses processed dictation;
- stale/ambiguous/terminated targets receive insertion;
- migration changes legacy bytes, duplicates entries, deletes a credential, or cannot rerun after interruption;
- rollback revives selected-text/instruction-driven Scribe or crosses Dictation/Meeting storage;
- Settings/custom controls fail keyboard, VoiceOver, contrast, reduced-motion, or responsive acceptance;
- live provider, real Cursor/Codex/Slack, signed distribution, privacy, or dogfood evidence is missing or belongs to a different candidate.

Recovery is fail-closed: preserve old stores and credentials, disable only the failing new reader, keep processed dictation available in memory, offer explicit copy/Insert Unpolished/setup recovery, and require a fresh candidate after correction. Evidence is never edited from FAIL to PASS; rerun creates a new manifest bound to the corrected commit/DMG.

## Risks and settled mitigations

- **Provider policies and model catalogs drift.** Review primary policy/model sources and refresh bundled recommendations near every release; consent revision changes when recipient, routing, retention, or data policy materially changes.
- **UserDefaults is not a multi-key transaction.** Use new single-envelope values, immediate decode/read-back, marker-last ordering, and idempotent reruns; never coordinate deletion across domains during migration.
- **Keychain cleanup can destroy recoverability.** Calculate references only from a successfully decoded complete library and perform cleanup after commit, never during load rejection/migration.
- **AppKit notifications and icons are timing-sensitive.** Main-actor value snapshots, startup sampling, revision checks, exact URL/process identity, and live Cursor tests prevent stale presentation from becoming authority.
- **Custom controls can regress native behavior.** Keep semantic Button/Menu/TextField/Toggle foundations and require both deterministic semantics and human assistive-technology review.
- **Feature flags can create unsafe partial combinations.** Master eligibility requires safety dependencies; unsafe partial states disable Scribe/insertion rather than choose an old path.

## Repository evidence

- PR #34 already provides typed provider/configuration seams, non-synchronizing this-device-only Keychain storage, validate-stage-commit-cleanup, hardened HTTP transport, diagnostics, migration ledger, privacy canaries, native UI tests, and a manifest-bound evidence collector.
- `docs/adaptive-scribe-release-evidence.md` explicitly separates deterministic CI from live, signed, real-app, accessibility, privacy, and five-day dogfood gates, but its Compose/Respond/Edit and Slack/Claude rows are now stale and must be replaced.
- `.github/workflows/ci.yml` runs generated-project build, full tests, and ad-hoc-signed native UI tests on macOS 15.
- `project.yml` is the structural source of truth and defines separate Debug/Release product identities.
- `docs/privacy.md` currently says transcript text stays local; it must be revised before cloud polished dictation ships so observed behavior and user disclosure agree.
- `scripts/package_release.sh` and `scripts/collect_adaptive_scribe_evidence.sh` already enforce canonical Release identity, signing/notarization/Gatekeeper flow, clean-tree/candidate matching, artifact hashes, and explicit `NOT_RUN` gates.

## Primary sources

- [OpenAI data controls](https://developers.openai.com/api/docs/guides/your-data)
- [OpenAI Responses migration and stateless storage control](https://developers.openai.com/api/docs/guides/migrate-to-responses)
- [OpenAI model listing API](https://developers.openai.com/api/reference/resources/models/methods/list)
- [OpenRouter Zero Data Retention](https://openrouter.ai/docs/guides/features/zdr)
- [OpenRouter provider routing](https://openrouter.ai/docs/guides/routing/provider-selection)
- [OpenRouter user-filtered models](https://openrouter.ai/docs/api/api-reference/models/list-models-user)
- [OpenRouter data collection](https://openrouter.ai/docs/guides/privacy/data-collection)
- [Apple `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)
- [Apple `kSecAttrAccessible`](https://developer.apple.com/documentation/security/ksecattraccessible)
- [Apple `kSecAttrSynchronizable`](https://developer.apple.com/documentation/security/ksecattrsynchronizable)
- [Apple `NSWorkspace.frontmostApplication`](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication)
- [Apple workspace activation notification](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification)
- [Apple `NSWorkspace` icon APIs](https://developer.apple.com/documentation/appkit/nsworkspace)
- [Apple `NSOpenPanel`](https://developer.apple.com/documentation/appkit/nsopenpanel)
- [Apple accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [SwiftUI accessibility fundamentals](https://developer.apple.com/documentation/swiftui/accessibility-fundamentals)

## Map impact

No new ticket or fog surfaced. Closing this ticket unblocks the final synthesis ticket. Its implementation specification should preserve this gate structure and order implementation so migrations and pure seams land before UI activation, then live provider/app verification, then signed release evidence.
