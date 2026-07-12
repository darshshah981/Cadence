# U10 — Settings Shell, Providers, and Apps Management

## Scope

Deliver the Settings portion of the adaptive Scribe specification: seven responsive
categories (General, Dictation, Scribe, Apps, Providers, Privacy, Advanced), a
persisted router, provider setup/management for OpenAI Direct and OpenRouter plus
existing providers, and installed-app-driven app configuration.

## Non-goals

- Do not change dictation capture, review-first Scribe behavior, or U9 action routing.
- Do not expose manual bundle identifier entry or reintroduce selected-text/intent UI.
- Do not alter legacy configuration as a side effect of the v2 Apps UI.
- Do not persist credentials, model search text, or a setup session after dismissal.

## Evidence and ownership

- `SettingsView` is monolithic; `SettingsPresentationStore` and its strict category
  state already exist but are not wired to UI.
- `ApplicationConfigurationResolver` supports replace/rebind/guidance but needs an
  explicit validated add/upsert seam. `InstalledApplicationCatalogService` supplies
  the installed-app source of truth.
- Runtime provider support and consent-gated discovery for OpenAI Direct/OpenRouter
  already exist. `ScribeProviderSetupView` has not exposed them.
- Preserve U8 semantic control primitives and its exact 560pt compact breakpoint.

## Ordered tasks and dependencies

1. Create an AppModel presentation boundary backed by `SettingsPresentationStore`;
   add unit coverage for strict persistence and the 559/560 layout decision.
2. Build a Settings shell/router and category views. Its rail is 176pt at widths
   >=560; at smaller widths use a compact accessible category selector. Cancellation
   on navigation/window close must dismiss any provider setup session.
3. Add validated app-configuration creation/upsert and AppModel read/mutation APIs.
   Build an installed-app picker (catalog search, refresh, duplicate paths, chooser
   bridge) and Apps UI with General/Messaging/Coding-compatible presets, bounded
   custom guidance, missing/rebind status, and Codex recommendation.
4. Rebuild provider setup and management for OpenAI Direct, OpenRouter, DeepSeek,
   and Advanced. Discovery stays consent-gated; credentials/setup state stays
   ephemeral; active-provider changes require the existing explicit confirmation.
5. Correct stale provider disclosures, move diagnostics to Privacy/Advanced, and add
   compact navigation/provider/app fixture coverage. Run XcodeGen before verification
   if source structure requires a project update.

## Acceptance criteria

- Seven categories are reachable through responsive, semantic controls and category
  selection persists independently of feature availability.
- Apps derive identity from installed app selection or a `.app` chooser, never an
  editable bundle identifier; duplicate installations remain distinct.
- OpenAI Direct and OpenRouter can be configured and their models searched/selected
  only after consent; cancellation leaves no persisted setup state.
- No U9 privacy/intent regression and no native control regressions in the touched UI.

## Validation

1. `xcodegen generate && git diff --exit-code -- Cadence.xcodeproj/project.pbxproj`
2. Focused Settings, provider, application-config, and semantic-control XCTest suites.
3. Dedicated `CadenceUITests` scheme.
4. `./script/build_and_run.sh --test` and `./script/build_and_run.sh --verify`.

## Risks and rollback

The main risks are overlapping legacy/v2 persistence and provider credential leakage.
Keep writes isolated to the v2 configuration writer and cancel setup state on every
exit path. The work is additive at the store boundary, so rollback is the U10 commit.
