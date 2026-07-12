# App environments, preset families, and custom-guidance contract

Date: 2026-07-11
Wayfinder ticket: [Define app environments, preset families, and custom prompt precedence](https://github.com/darshshah981/Cadence/issues/41)
Baseline: Adaptive Scribe PR #34 at `04391d3`

## Decision

Cadence resolves Scribe behavior locally from an application configuration into one reusable environment family, one bundled preset, and optional additive custom guidance. Application identity, environment family, preset, and custom guidance are separate domain concepts.

The bundled families are General, Messaging, and Coding. Slack defaults to Messaging · Neutral. Codex/OpenAI Desktop and Cursor default to Coding · Precise. Unknown, disabled, missing, ambiguous, or invalid applications resolve to General · Neutral without custom guidance.

Presets and custom guidance shape expression only. They cannot change Scribe from meaning-preserving dictation into composition, response generation, execution, or editing; cannot authorize ambient context; and cannot weaken privacy, exact-literal, target-verification, review, or insertion rules.

## Canonical model

### Application configuration

A local configuration for one persisted `ApplicationReference` from the installed-app identity contract:

- Stable configuration ID
- Application reference
- Enabled state
- Environment-family selection
- Preset selection
- Optional custom guidance
- Configuration schema/revision

Application identity answers “which local application?” It does not itself contain provider instructions.

### Environment family

A release-bundled, versioned namespace of compatible presets for a broad writing context:

- `general`
- `messaging`
- `coding`

A family is reusable across applications. Slack is not an environment family; it is an application whose bundled template selects Messaging. Codex and Cursor remain different applications while sharing Coding.

Environment families are code-owned release data. Users choose among them but cannot create arbitrary families or edit their immutable definitions in the first release.

### Preset

A release-bundled, versioned behavior inside exactly one environment family. Preset identifiers are stable and family-qualified, such as `messaging.neutral` and `coding.precise`.

A preset controls tone, concision, and structure within the meaning-preserving boundary. It never supplies facts, task content, app identity, provider routing, or permission to inspect surrounding content.

### Preset selection

Each application configuration records either:

- `familyDefault`: follow the selected family’s current bundled default; or
- `explicit(presetID)`: keep the user-selected compatible preset.

Built-in application templates initially use `familyDefault`. Choosing a preset materializes an explicit override. A family change selects the new family default because presets do not cross family boundaries; it preserves the app’s custom guidance.

### Custom guidance

Optional, persisted, app-specific preferences supplied by the user. Settings labels this field **Custom guidance**, not **system prompt** or **custom prompt**, so it does not imply equal authority with Cadence’s safety contract.

Custom guidance is additive preference data. Examples include:

- “Use British spelling.”
- “Keep messages to three short paragraphs when possible.”
- “For multi-step coding requests, prefer a short bulleted structure.”

It cannot authorize Cadence or the provider to read selected text, clipboard contents, files, window content, prior turns, or other ambient context. It cannot ask Scribe to answer, execute, invent, silently insert, bypass review, change exact literals, or broaden a dictated task.

### Resolved Scribe guidance

An immutable, in-memory action snapshot containing:

- Environment-family ID and definition version
- Preset ID and definition version
- Compiled preset instructions
- Optional normalized custom guidance
- Resolution source
- Literal-normalization capability flags needed by the processed-dictation pipeline

It contains no application identifier, path, display name, icon, process identifier, or configuration ID in the provider-safe representation.

## Bundled family and preset catalog

### General

Default preset: **Neutral**

#### General · Neutral

- Clear, natural prose.
- Correct grammar, punctuation, and structure.
- Keep length proportional to the dictated content.
- Do not add unsupported warmth, urgency, formality, or technical structure.
- Preserve all claims, requested actions, factual detail, ambiguity, and exact literals.

General · Neutral is the total fallback and is always available.

### Messaging

Default preset: **Neutral**

#### Messaging · Neutral

- Clear, conversational wording with natural contractions.
- Lead with the dictated point, request, or update.
- Keep warmth moderate and directness natural.
- Prefer short paragraphs; use a list only when the dictation contains distinct items.
- Do not add greetings, sign-offs, emoji, urgency, enthusiasm, promises, or slang the user did not dictate.

#### Messaging · Formal

- Polished, measured wording and complete sentences.
- Restrained warmth and neutral punctuation.
- Make dictated requests, owners, and deadlines explicit without inventing them.
- Avoid legalistic, ceremonial, or excessively verbose phrasing.

#### Messaging · Casual

- Relaxed, direct wording and shorter sentences or fragments where clear.
- Natural contractions are preferred.
- Do not force lowercase styling, slang, emoji, exclamation marks, or exaggerated enthusiasm.

### Coding

Default preset: **Precise**

Coding presets polish instructions for a coding agent. They never perform the coding task and never widen the user’s authorization.

#### Coding · Precise

- State the dictated task first.
- Preserve the action boundary: inspect, explain, diagnose, review, plan, implement, test, commit, and publish remain distinct.
- Preserve all supplied files, identifiers, flags, commands, errors, constraints, non-goals, and expected outcomes.
- Format technical literals conservatively.
- Ask the downstream coding agent to inspect available repository context only when the user’s dictation already delegates that judgment; do not invent repository facts or implementation choices.

#### Coding · Concise

- Produce a compact, task-first instruction.
- Remove repetition and speech filler.
- Preserve every dictated constraint, literal, authorization boundary, and expected outcome even when shortening.
- Do not collapse multi-part work into a broader or less precise request.

#### Coding · Structured

- Organize a genuinely multi-part dictated request for scanning.
- Use short sections or bullets such as Goal, Context, Constraints, and Verification only when corresponding material was dictated.
- Omit empty headings.
- Never synthesize missing acceptance criteria, commands, files, tests, or non-goals.

“Plan,” “Implement,” and “Fix” are not presets. They are task authorizations carried by the processed dictation. Making them presets would let style selection alter meaning.

## Built-in application defaults

Cadence ships versioned local template overlays:

| Application/surface | Family | Preset | Notes |
|---|---|---|---|
| Slack | Messaging | Family default: Neutral | User may choose Formal or Casual. |
| Codex/OpenAI Desktop | Coding | Family default: Precise | UI uses the live installed display name and may show “Codex default” secondarily. |
| Cursor | Coding | Family default: Precise | User may choose Concise or Structured. |
| Certified Claude Code prompt in Claude Desktop | Coding | Family default: Precise | Preserve PR #34’s narrow certified-surface behavior; do not broaden or migrate it to Codex. |
| Other applications | General | Family default: Neutral | Total fallback. |

Built-in templates are overlays rather than duplicated user records. A user override wins for that exact application. Resetting an app removes its materialized override and reveals the current built-in template, or General · Neutral if no built-in template exists.

The PR #34 Claude Code behavior remains a narrowly certified target-surface default. It is not evidence that the whole Claude Desktop app should use Coding, and no Claude preference is remapped to Codex. A future explicit whole-app Claude configuration is a user-authored application choice, not a migration inference.

## Resolution and precedence

Cadence resolves a new Scribe action once, locally, in this order:

1. Pin and resolve the active application identity and insertion target.
2. If app adaptation is globally disabled, resolve General · Neutral with no custom guidance.
3. If the application reference is missing, ambiguous, invalid, or not configured, resolve General · Neutral with no custom guidance.
4. If an exact user application configuration exists:
   - disabled configuration → General · Neutral with no custom guidance;
   - enabled valid configuration → its selected family, preset selection, and custom guidance.
5. Otherwise apply an exact bundled application template.
6. Otherwise apply an eligible certified target-surface template, such as the existing narrow Claude Code rule.
7. Otherwise use General · Neutral.
8. Compile the result into the immutable action snapshot before provider egress.

An exact user application configuration has higher local selection precedence than a bundled application template. A disabled exact configuration is an explicit opt-out and must not fall through to a bundled template.

A retry reuses the exact resolved snapshot. Settings changes, app movement, focus changes, catalog updates, and template-version changes affect only a new Scribe action.

## Provider instruction order

The provider input remains exactly:

1. Cadence’s immutable privacy, target, literal, and meaning-preservation contract.
2. The resolved bundled preset instructions.
3. Optional app-specific custom guidance, labelled as lower-priority preference data.
4. Processed dictation, serialized as data to polish and never as provider instructions.

The environment family is a local taxonomy and contributes no separate free-form prompt layer. The application default only selects a preset. This prevents hidden instruction stacking.

Custom guidance is treated as untrusted lower-priority data. Cadence does not claim it can perfectly classify semantic prompt conflicts. Instead:

- The immutable contract explicitly denies lower-layer overrides.
- Guidance is structurally separated and labelled as preferences.
- Known unsupported capabilities are explained beside the field.
- Output still passes empty-result and exact-literal validation.
- Meaning preservation remains subject to mandatory human review and the Scribe quality corpus.
- Conflicting guidance has no authority and is ignored in favor of higher layers.

Application name, icon, bundle identifier, path, process identifier, configuration ID, family label, and preset display name are not sent. Only compiled preset instructions and the optional custom-guidance text cross the provider boundary.

## Custom-guidance lifecycle

- One optional custom-guidance value exists per materialized application configuration.
- Trim leading and trailing whitespace; an empty result is stored as absent.
- Maximum encoded size is 2,000 UTF-8 bytes.
- Reject NUL and unsupported control characters.
- Do not silently truncate.
- Do not support variables, templates, placeholders, files, URLs to fetch, tool calls, role messages, or raw provider JSON.
- Preserve line breaks for short readable guidance.
- Show a live byte counter and inline validation.
- Saving guidance does not trigger a provider request.
- The field states: “Sent with your dictated text to the active Scribe provider for this app. Cadence does not send the app’s identity or surrounding content.”
- Clearing guidance removes only that app’s guidance.
- Changing family retains guidance; the review screen and Settings preview make the resulting family/preset/guidance combination visible.
- Removing the app configuration deletes its custom guidance after confirmation while leaving provider configuration, shortcuts, Dictation data, and other apps untouched.

## Settings behavior

Each app card on the Apps page shows:

- Local app icon and live display name
- Installed, Missing, or Needs Attention state
- Enabled toggle
- Environment family dropdown
- Preset dropdown filtered to the selected family
- Recommended/default marker
- **Add Custom Guidance** button when absent
- Editable custom-guidance field and disclosure when present
- Reset to Recommended
- Remove Configuration where applicable

Preset names remain concise; descriptions explain their boundaries. The dropdown never presents incompatible cross-family presets.

For built-in overlays, Settings shows the recommendation without creating persisted user state. The first family, preset, enabled-state, or guidance change materializes an override.

The local Scribe review cue uses the resolved app presentation name and preset, for example `Slack · Formal` or `ChatGPT · Precise`. General fallback shows `Other apps · Neutral`. This cue remains local and appears once; it is not serialized into the provider request.

## Invalid and missing state

- Unknown/future application-configuration schema: preserve unreadable bytes, apply General · Neutral without custom guidance, and offer scoped recovery.
- Duplicate configuration IDs or duplicate exact application references: reject the configuration library rather than choosing by order.
- Unknown family or preset ID: mark the affected configuration Needs Attention; do not silently substitute a similarly named preset.
- A missing explicit preset may be repaired by a versioned migration mapping. Without such a mapping, use General · Neutral without custom guidance until the user chooses again.
- `familyDefault` follows the current default of a still-valid family and is not considered a missing selection.
- Missing or ambiguous application reference: preserve the configuration and guidance locally but do not apply either until identity resolves.
- Missing bundled template: fall back to General · Neutral; never infer from the display name.
- Invalid custom guidance: preserve the last valid saved value when an edit fails; do not save partial or truncated content.
- Invalid state never blocks ordinary Scribe fallback and never causes a provider call during Settings recovery.

## Migration

Use the schema-versioned `ApplicationConfigurationStore` established by the installed-app identity contract as the new source of truth. Do not extend PR #34’s closed `WritingEnvironmentID` enum or keep `WritingEnvironmentStore` as a competing active resolver.

Migration is additive, idempotent, and rollback-safe:

1. Preserve the existing writing-environment and personalization bytes unchanged for at least one rollback release line.
2. Map a valid Slack environment preference to the exact Slack application template:
   - `formal` → Messaging · Formal
   - `neutral` → Messaging · Neutral
   - `casual` → Messaging · Casual
   - disabled → disabled Slack configuration
3. If Slack is uniquely installed, bind the migrated override to its resolved application reference. If it is missing, retain a missing reference using the known Slack identity. If duplicate installations are ambiguous, preserve the pending migration and require selection.
4. Do not map `claude-code` or Claude Desktop state to Codex, Cursor, or a whole-app Claude configuration. Preserve the PR #34 certified Claude Code surface rule separately until it is explicitly superseded.
5. Do not auto-map legacy `WritingStyleProfile` axes into presets or custom guidance. Their tone/length/punctuation/formatting fields are not semantic aliases for the new curated definitions.
6. Preserve legacy writing profiles byte-for-byte for rollback and retain the existing one-time notice/removal scope.
7. Personal shortcuts remain local preprocessing and retain their application scopes; replacing their editor with the app picker does not turn them into provider guidance.
8. Use a separate application-configuration migration ledger/version. Write the new store first and the completion marker last.
9. Re-running after interruption produces the same configurations without duplicates.
10. A downgrade reads the untouched PR #34 and personalization stores and ignores the new application configuration.

## Privacy and diagnostics

- Application inventory, identity, family selection, preset selection, custom guidance, and resolution source remain local configuration.
- Only compiled preset instructions, custom guidance, and processed dictation may enter the provider request.
- Custom guidance is user content. Never write it to OSLog, analytics, diagnostic rings, crash metadata, support exports, or release evidence.
- Do not log app names, bundle identifiers, paths, family IDs, preset IDs, configuration IDs, or guidance length precise enough to fingerprint use.
- Diagnostics use closed outcomes such as `bundled_default`, `user_override`, `general_fallback`, `configuration_invalid`, or `guidance_invalid`.
- Analytics may record only coarse settings actions such as guidance added/removed or preset changed, without application, family, preset, length, or content.
- No background validation or model request occurs when saving, migrating, displaying, or resolving configuration.

## Required implementation seams

- Replace `WritingEnvironmentID`/`WritingBehaviorID` with stable family-qualified catalog models rather than adding more application cases.
- Make the application-configuration resolver a pure service that consumes active identity, optional certified target signature, built-in templates, user configuration load state, and adaptation enablement.
- Keep bundled definitions and template overlays in a versioned catalog separate from persisted user selections.
- Generalize `ScribeLiteralNormalizer` from the hard-coded `.claudeCode` condition to explicit capability flags on the resolved Coding preset.
- Replace `ScribeRequestPolicy.behaviorInstructions` with the polished-dictation compiler: immutable contract, preset, custom guidance, processed dictation.
- Remove legacy `WritingStyleProfile` from active Scribe resolution; keep it rollback-readable only.
- Snapshot the complete resolved Scribe guidance in `ScribeCoordinator` before egress and reuse it for Retry Polish.
- Keep `AppModel` as coordinator; catalog validation, configuration resolution, guidance normalization, and migration belong in models/services.

## Required test contract

### Catalog and domain

- Stable unique family-qualified preset IDs.
- Every family has one valid default.
- Every preset belongs to exactly one family.
- General · Neutral always exists.
- Bundled instructions contain no app identity, ambient-context request, composition authorization, or provider-specific routing.
- Preset definition changes are versioned and deterministic.

### Resolution

- Slack → Messaging · Neutral.
- Codex/OpenAI Desktop and Cursor → Coding · Precise.
- Certified Claude Code surface → Coding · Precise without broad whole-app inference.
- Unknown app → General · Neutral.
- Explicit valid app override beats bundled template.
- Disabled exact app configuration falls directly to General · Neutral with no guidance.
- Global adaptation disabled removes app preset and guidance.
- Missing, ambiguous, malformed, duplicate, future, unknown-family, and unknown-preset states fail to General · Neutral with no guidance.
- Duplicate app installations use exact runtime URL and never first-match ordering.
- Retry remains byte-for-byte stable after Settings or focus changes.

### Preset behavior

Quality fixtures cover ordinary prose, Slack messages, Codex/Cursor coding-agent instructions, and the three presets in each non-General family.

For every fixture, assert:

- Every dictated claim, requested action, number, identifier, constraint, and exact literal remains.
- No fact, requirement, action, code, command, deadline, greeting, sign-off, emoji, warmth, or verification step is invented.
- Coding · Concise does not drop constraints.
- Coding · Structured does not invent empty headings or missing sections.
- Coding presets preserve inspect/explain/diagnose/review/plan/implement/test/commit/publish boundaries.
- Dictated instructions remain instructions rather than being executed or answered.

### Custom guidance

- Whitespace normalization and empty-to-absent behavior.
- UTF-8 boundary at 2,000 bytes, multi-byte characters, control-character rejection, and no truncation.
- Line-break preservation.
- Failed edit preserves the previous valid value.
- Guidance persists per exact application configuration.
- Family changes retain guidance and reset preset selection to the new default.
- Clear/reset/remove actions affect only declared scope.
- Guidance cannot add app identity or ambient context to the provider-safe payload.
- Adversarial guidance cannot override the immutable contract in representative provider and policy fixtures.

### Migration

- Exact Slack preset and enabled-state mapping.
- Missing and duplicate Slack installation handling.
- No Claude-to-Codex, Claude-to-Cursor, or broad Claude-app mapping.
- Legacy profile bytes unchanged and not compiled.
- Personal shortcuts unchanged.
- Idempotence, interruption, rollback, malformed/future source preservation, and scoped reset.
- PR #34 old-store and new-store coexistence never creates two active resolvers.

### Privacy and UI

- Provider payload contains only immutable contract, compiled preset, optional guidance, processed dictation, and required literal data.
- No app name, bundle ID, URL, PID, configuration ID, family/preset label, icon, shortcut catalog, or legacy profile enters the payload.
- Logs, analytics, diagnostics, and exports exclude guidance and identity.
- App cards, family/preset dropdowns, Add Custom Guidance, disclosure, errors, Recommended markers, local review cue, keyboard behavior, VoiceOver, and narrow Settings width have deterministic fixtures.

## Acceptance contract

- Slack defaults to Neutral and offers Formal and Casual without changing message meaning.
- Codex/OpenAI Desktop and Cursor default to Precise and offer Concise and Structured coding-oriented polish.
- Users may choose another compatible preset or add bounded app-specific guidance without exposing the app identity to the provider.
- Unknown, disabled, missing, ambiguous, and invalid apps always retain usable General · Neutral Scribe behavior and never leak stale guidance.
- Presets and custom guidance cannot turn Scribe into a composing or executing assistant, authorize ambient context, bypass review, alter exact literals, or widen a dictated task.
- A Scribe action and every Retry Polish use one immutable resolution snapshot.
- Migration preserves rollback data and maps only semantically exact Slack state; it never guesses from legacy profiles or maps Claude state to Codex.
- The new application configuration is the only active app-aware Scribe resolver; PR #34’s closed enum model does not survive as a competing source of truth.

## Domain glossary additions

Add these implementation-free terms to `CONTEXT.md` through the repository’s delegated documentation workflow:

**Application configuration**:
The local Scribe preferences attached to one installed application reference: enabled state, environment family, preset selection, and optional custom guidance.

**Environment family**:
A reusable category of compatible Scribe presets. The first families are General, Messaging, and Coding. An environment family is not an application identity.

**Preset**:
A release-bundled, versioned expression style within one environment family. It may shape tone, concision, and structure but cannot change dictated meaning or task authorization.

**Custom guidance**:
Optional app-specific expression preferences applied below the selected preset and below Cadence’s immutable meaning-preservation and privacy contract.

**Resolved Scribe guidance**:
The immutable per-action snapshot of the selected family, preset, compiled instructions, and optional custom guidance used for a polish attempt and every retry.

## Map impact

No new Wayfinder ticket is required. The focused-app correctness ticket completes runtime identity freshness and HUD icon presentation. Once both tickets close, the cross-cutting acceptance ticket can specify implementation sequencing, migration ownership, rollout, and rollback from the now-settled provider, Scribe, Settings, app-identity, and app-guidance contracts.
