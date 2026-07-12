# Adaptive Scribe PR #34 baseline research

Date: 2026-07-11  
Wayfinder ticket: [Inventory and reconcile the Adaptive Scribe PR #34 baseline](https://github.com/darshshah981/Cadence/issues/36)  
Source PR: [feat: ship adaptive Scribe on the hardened voice HUD](https://github.com/darshshah981/Cadence/pull/34)

## Resolution

Use PR #34 (`codex/adaptive-scribe-writing-environments` at `04391d3`) as the exact baseline for the implementation-ready specification. The PR is open, mergeable, clean, and green in deterministic CI, but it is not merged. It is directly atop the HUD correctness work, so the eventual implementation plan must either target that branch before merge or rebase its file-level guidance after the PR lands.

PR #34 already establishes the safety-critical Scribe foundation. The new effort should extend those contracts while replacing the product semantics and UI assumptions that conflict with the agreed destination.

## Preserve

- Keep Dictation, Scribe, and Meeting as separate pipelines, following `docs/codebase-guide.md`.
- Keep consent before provider egress and recipient/version-bound disclosures from `Cadence/Models/ScribeProviderDisclosure.swift` and `docs/privacy.md`.
- Keep non-synchronizing, this-device-only Keychain credentials and the validate-stage-commit-cleanup lifecycle in `Cadence/Services/ScribeCredentialStore.swift` and `Cadence/Services/ScribeProviderConnectionManager.swift`.
- Keep the hardened ephemeral HTTP transport: no cache, cookies, shared credentials, redirects, or automatic retry; bounded deadline and response size; explicit cancellation.
- Keep provider-safe request serialization and the ambient-context denylist. Raw bundle identifiers, accessibility signatures, and unauthorized content must never enter provider requests.
- Keep pinned target identity and fresh focus/selection verification before egress, retry, and insertion in `Cadence/Services/ScribeContextService.swift` and `Cadence/Services/ScribeCoordinator.swift`.
- Keep immutable per-action provider recipient and resolved environment snapshots.
- Keep review before insertion, copy, literal fallback, insertion recovery without regeneration, late-result suppression, and post-action content clearing.
- Keep exact-literal normalization and protection, app-local shortcut expansion, and fail-closed malformed-literal handling.
- Keep `Other apps · Neutral` as the total fallback for unknown apps and invalid preferences.
- Keep content-free diagnostics, privacy canaries, the idempotent migration ledger, deterministic tests, the UI-test target, and the separation between CI and signed/live release evidence.

## Revise

### Providers and models

- Extend `ScribeProviderKind` and related configuration, disclosure, diagnostics, migration, and test contracts in `Cadence/Models/ScribeProviderModels.swift` rather than routing OpenAI Direct or OpenRouter through `.advanced`.
- Add provider-specific authentication, endpoint behavior, request/response profiles, validation, searchable model discovery, recommended-model presentation, saved-model disappearance handling, and custom-ID fallback.
- Preserve DeepSeek, local, and generic OpenAI-compatible options. Rename the user-facing Advanced option to Custom OpenAI-Compatible.
- Resolve whether Cadence continues to store exactly one configured provider or maintains multiple saved configurations with one active selection.
- Treat OpenAI Direct and OpenRouter as distinct privacy recipients. OpenAI must not inherit the unknown-operator disclosure, and OpenRouter must not masquerade as OpenAI.

### Scribe semantics

- Replace the instruction-driven contract in `ScribeIntent`, `ScribeRequestPolicy`, `ScribeCoordinator`, and `Cadence/UI/ScribePanel.swift` with direct `dictate → locally normalize → LLM polish → review` behavior.
- Remove the mandatory Compose/Edit/Respond picker from the primary Scribe flow. Decide explicitly whether selected-text Respond/Edit survive as separate actions rather than disappearing accidentally.
- Update prompt policy, fallback copy, review labels, fixtures, and quality corpus so the model polishes dictated content and cannot interpret it as a request to invent unrelated text.
- Define whether Insert Unpolished uses the raw Whisper transcript or the locally cleaned, vocabulary-expanded transcript.

### Apps, environments, and personalization

- Replace the closed Slack/Claude Code/Global assumption in the environment catalog with a model that supports installed-app identities and reusable environment/preset families.
- Add Cursor and Codex behavior deliberately. Cursor currently exists only in deterministic Dictation classification; Codex has no identity or preset at all.
- Extend target identity beyond PID and optional bundle ID to a local app descriptor supporting stable identity, display name, bundle URL, icon lookup, and installed/missing state while keeping those fields out of provider requests.
- Replace normal manual bundle-ID entry in `PersonalShortcutEditor` and `WritingStyleProfileEditor` with a searchable installed-app picker and a Choose Application fallback.
- Add persisted custom Scribe guidance with explicit additive precedence, validation, length limits, migration, and disclosure that it is sent to the configured provider.
- Decide how legacy `WritingStyleProfile` data migrates or retires. Spoken shortcuts remain useful and should survive.

### Settings and the app-wide control system

- Replace the single scrolling `SettingsView` with the agreed category-sidebar and card-detail information architecture.
- Preserve the semantic hierarchy and keyboard-default policy of `CadenceActionButton`, but replace its native bordered implementation with Cadence-owned visuals and interaction states.
- Apply the control system app-wide, including Settings, Scribe, Main Window, Meeting Notes, onboarding, permissions, and menu/HUD surfaces; leave operating-system-owned dialogs native.
- Convert discrete segmented selectors to dropdowns. Keep waveform sensitivity as a custom-styled continuous slider.
- Replace the Settings Advanced `DisclosureGroup` row with an aligned disclosure primitive; evaluate provider and meeting disclosures for the same shared pattern.
- Specify narrow-width layout, keyboard navigation, focus rings, VoiceOver labels, contrast, reduced motion, destructive confirmation, loading, disabled, and default-action states.

## Retire

- Retire manual bundle-identifier entry as the normal app-configuration workflow.
- Retire the native `.borderedProminent`, `.bordered`, and `.borderless` implementation inside `CadenceActionButton`; retain its role semantics.
- Retire instruction-driven Compose as the primary Scribe contract.
- Retire or migrate legacy `WritingStyleProfile` as a competing Scribe-style concept.
- Do not silently retire DeepSeek, Custom OpenAI-Compatible, local fallback, explicit selected-text safety, or the hardened provider/target/privacy contracts.

## Test and release baseline

PR #34 already contains dedicated suites for provider configuration and credential lifecycle, transport, wire profiles and error mapping, setup, request privacy, literal handling, target races, coordinator lifecycle, environments, recognition, migration, diagnostics, action hierarchy, performance, privacy documentation, and native UI fixtures. Structural project changes continue through `project.yml` and `xcodegen generate`.

The new specification must extend these tests rather than replacing them with generic coverage. It must also retain the distinction recorded in `docs/adaptive-scribe-release-evidence.md`: signed DMG, live-provider calls, real-app recognition, accessibility review, privacy review, and multi-day dogfood are release gates that deterministic CI does not prove.

## Newly sharp downstream decisions

The baseline makes these existing Wayfinder tickets concrete:

- Provider research must decide first-party API contracts, model-catalog lifecycle, configuration coexistence, and privacy recipient semantics.
- The polished-dictation contract must settle selected-text actions and the exact unpolished fallback representation.
- Installed-app identity research must cover application discovery sources, duplicate bundle IDs, moves, uninstall/reinstall, unsigned apps, missing apps, and icon refresh.
- App environments must distinguish app identity from reusable preset family and define coding preset names beyond the current single Precise behavior.
- Focused-app diagnosis must separate target capture correctness, display metadata/icon lookup, and UI refresh ownership.
- The Settings prototype must cover the full app-wide button surface and shared disclosure behavior, not only Settings styling.

No additional Wayfinder ticket is required yet: each newly sharp question belongs to an existing child ticket. The map's remaining fog about implementation sequencing, migration boundaries, diagnostics surfaces, and rollback should remain until those contracts resolve.
