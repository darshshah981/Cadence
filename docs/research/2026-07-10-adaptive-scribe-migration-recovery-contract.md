# Adaptive Scribe Migration and Recovery Contract

**Date:** 2026-07-10
**Wayfinder ticket:** [Define Adaptive Scribe migration and recovery-journal semantics](https://github.com/darshshah981/Cadence/issues/31)

## Decision

Migration is additive, idempotent, and rollback-safe. New provider and writing-environment stores use new keys/types; Cadence does not rewrite or delete the current `Cadence.personalizationLibrary`, Dictation preferences, transcript history, meeting data, or hotkeys during release-one migration.

The first slice ships **no content-bearing on-disk Scribe recovery journal**. Literal transcript, selected text, generated draft, provider request, and retry payload remain in memory for the active Scribe session and are cleared on insert, copy-and-finish, discard, cancel, provider removal, review dismissal, or app termination.

This explicitly resolves a conflict between two closed decisions. The reliability audit proposed persisting one transcript/draft recovery record across relaunch, but the later BYOK privacy contract requires current Scribe request/selection/draft/retry content to remain memory-only, describes local Scribe retention as transient, and requires clearing at termination. The later, stricter privacy contract controls release one. Crash/relaunch recovery of Scribe content would require a new product/privacy decision and disclosure; it is not silently introduced by implementation.

Meeting audio/transcript recovery remains unchanged and separate. Dictation history remains unchanged and separate.

## Current-State Migration

### Scribe enablement and provider readiness

| Existing state | Migrated release-one state |
|---|---|
| Scribe shortcut disabled | Scribe remains disabled; no provider setup, network request, or consent record is created. |
| Scribe enabled and Foundation Models provider is available | Preserve the on-device provider as `legacyLocal` readiness behind the same new review/failure UI. Do not invent a cloud provider, credential, or consent record. Settings offers the guided DeepSeek setup separately. |
| Scribe enabled but no semantic provider is available | Keep the shortcut enabled but set readiness to `setupRequired`; first use opens guided setup or offers literal Dictation. No network request occurs. |
| Debug mock provider | Remains a debug-only preview dependency and is never migrated into release configuration. |

An existing user is never silently enrolled in DeepSeek or Advanced, never receives a synthetic validation request, and never gets a fabricated disclosure acceptance record. Switching from `legacyLocal` to a cloud provider uses the full provider choice/disclosure/validate flow.

The legacy local provider may remain only because the Product Contract expressly allows current Foundation Models behavior outside the first DeepSeek acceptance slice. It must use the same lifecycle/review controls so it does not create a parallel Scribe product.

### Personal shortcuts

`PersonalShortcut` records remain in `Cadence.personalizationLibrary` and continue to expand locally before generation. They are not writing-environment preferences and require no conversion. Invalid or future-version personalization data still fails closed; it must not block the built-in environment defaults.

### Legacy writing-style profiles

Do not auto-map `WritingStyleProfile` records into Slack Formal/Neutral/Casual or Claude Code Precise. The old axes are not semantic aliases for the new behavior definitions, duplicates are currently resolved by UUID order, and a broad app bundle mapping cannot satisfy the new recognition contract. Guessing would silently change user meaning.

Instead:

1. Leave the complete legacy library under its existing key, unchanged and read-only from the new environment implementation.
2. Create the new versioned writing-environment preference store with **no user overrides**. Absence is normal: Slack uses Neutral, Claude Code uses Precise, and Other apps uses Neutral.
3. Default **Adapt Scribe to the app** on once the user has a ready Scribe provider. This is a new Scribe preference and never reads or changes `Cadence.appAwarePolishingEnabled`.
4. Show a one-time local migration notice when legacy style profiles exist: “Writing environments now use release-tested Slack and Claude Code behaviors. Your previous writing profiles were kept for rollback but were not applied automatically.”
5. Offer a read-only Legacy profiles detail and an explicit **Remove legacy writing profiles** action. Removal affects only the retained style profiles; it preserves personal shortcuts and every other user data domain.
6. Keep the old key for at least one full release line. A downgraded app reads exactly the old data; it ignores the new provider/environment keys. Removal of the legacy format is a later release decision, not part of this migration.

The migration notice and counts stay local. Analytics/logs may record only a coarse result such as `none`, `retained`, or `failed`; never profile names, bundle identifiers, instructions, counts small enough to fingerprint a user, or raw encoded data.

## New Store Contracts

### Writing environment preferences

Use a separate versioned store with at most one record per stable environment ID:

- schema version;
- environment ID;
- enabled flag;
- selected behavior ID;
- definition/version last resolved by the app.

Missing storage means no overrides. A duplicate environment ID, unknown behavior, malformed payload, unknown/future schema, or missing bundled definition rejects the whole override set and resolves the current action to built-in **Other apps · Neutral** while Settings offers **Restore writing environment defaults**. Do not pick an arbitrary duplicate or overwrite the unreadable bytes automatically.

Restoring all writing environments deletes only the new preference override data. It does not delete provider credentials/configuration/acceptance, legacy profiles, personal shortcuts, vocabulary, Dictation settings/history, meetings/audio, permissions, onboarding, or the Scribe hotkey.

### Provider configuration

Provider kind, normalized origin, selected catalog/configuration ID, readiness, and disclosure version live in a versioned non-secret configuration store. Credentials live only in the provider-specific non-synchronizing Keychain item.

Malformed/future configuration produces `configurationInvalid`, makes zero provider requests, and preserves the Keychain item until the user reconnects or explicitly removes the provider. Cadence must not guess an origin/model or delete a potentially working credential during load recovery.

### Migration ledger

Use a small non-content migration ledger containing only migration version, coarse outcome, and completion date. Write new stores first and the completion marker last. If the app exits between writes, the next launch reruns the deterministic migration. Re-running must produce the same stores and notice without duplicating preferences, credentials, or acceptance records.

No raw legacy JSON, profile text, bundle identifier, credential, transcript, or draft is copied into the ledger, OSLog, analytics, or support export.

## Within-Session Recovery Contract

The coordinator owns one in-memory recovery envelope per active Scribe action:

- request and attempt identity;
- literal transcript;
- resolved writing-environment snapshot;
- provider/configuration snapshot without the plaintext credential;
- explicit selected-text artifact only for Respond/Edit;
- completed draft, if any;
- phase/failure and allowed recovery actions.

Required recovery behavior:

- Provider/setup failure keeps the spoken request available for manual retry or **Use spoken words**.
- Generation retry reuses the exact immutable envelope and does not recapture target/context or change provider/environment.
- Insertion verification failure keeps the completed draft visibly reviewable with **Return and Insert**, **Copy Draft**, and **Discard Draft**; it makes zero provider calls.
- A fresh Scribe action disposes the old envelope before pinning the new target.
- Provider removal invalidates the envelope and suppresses late callbacks.
- All terminal/dismissal paths clear content. App termination deliberately leaves no Scribe content to recover.

No Scribe recovery type may reuse meeting storage, Dictation history, `UserDefaults`, analytics, OSLog, crash/support payloads, URL caches, or provider-adapter disk state.

## Rollback and Failure Handling

- **New-store write failure:** retain legacy data, do not write the migration marker, keep Scribe in a safe disabled/setup-required state, and show a local recovery action.
- **New-store read failure:** do not overwrite; fail provider state closed and environment resolution to Other apps · Neutral.
- **Keychain failure:** preserve non-secret configuration but mark provider Needs attention; make no generation request.
- **Downgrade:** old app sees its original personalization/Scribe-enabled keys; it ignores new keys and cannot access cloud credentials through old provider code.
- **Reset:** explicit scoped reset only. No startup cleanup deletes legacy or new user state.

## Verification Contract

Tests must cover:

1. Every combination of old Scribe enabled/disabled and Foundation Models available/unavailable.
2. Zero cloud requests, credentials, or consent records created by migration.
3. Personal shortcuts continue unchanged; style profiles remain byte-for-byte available for rollback but do not become environment overrides.
4. Missing legacy data produces normal bundled defaults; malformed/future/duplicate data fails closed without crashing.
5. Migration is idempotent across repeated launches and interruption before the completion marker.
6. Dictation `appAwarePolishingEnabled`, transcript history, hotkeys, vocabulary, meeting notes/audio, permissions, onboarding, and analytics consent are unchanged.
7. Restore environment defaults and provider removal affect only their declared scopes.
8. Insertion failure/retry/fresh-action behavior preserves within-session content correctly and never crosses pipelines.
9. App termination leaves no transcript, selection, request, draft, or retry payload in UserDefaults, app-support files, caches, logs, analytics, crash/support data, or meeting/Dictation stores.
10. A downgrade fixture reads the untouched legacy library.

## Repository Evidence

- `Cadence/App/AppModel.swift` stores Scribe enablement and Dictation app-aware polishing under separate keys, hard-codes approved Scribe privacy, and selects the current provider at startup.
- `Cadence/Models/PersonalizationModels.swift` defines schema-v1 shortcuts and low-level style profiles.
- `Cadence/Services/PersonalizationStore.swift` currently maps malformed/future data to an empty library.
- `Cadence/Services/StyleProfileResolver.swift` chooses duplicate profiles by UUID ordering.
- `Cadence/Services/ScribeCoordinator.swift` already retains transcript/request/draft in memory and clears transient state; it needs stricter terminal/fresh-action behavior but no disk journal.
- `CadenceTests/PersonalizationTests.swift` supplies the current persistence, malformed/future, shortcut, and exact-app fallback baseline.
