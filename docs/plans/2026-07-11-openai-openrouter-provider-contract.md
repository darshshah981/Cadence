# OpenAI Direct and OpenRouter provider contract

Date: 2026-07-11  
Wayfinder ticket: [Define first-class OpenAI and OpenRouter provider and model contracts](https://github.com/darshshah981/Cadence/issues/38)  
Baseline: Adaptive Scribe PR #34 at `04391d3`

## Decision

OpenAI Direct and OpenRouter become explicit first-class Scribe provider kinds. Neither is represented as Custom OpenAI-Compatible, because their endpoint, request, model-discovery, routing, privacy-recipient, validation, error, and migration contracts differ.

Cadence stores one validated configuration per explicit provider kind and exactly one global active provider/model. Switching is explicit and affects only the next Scribe action; the action retains the immutable provider/model/recipient snapshot established by PR #34.

The provider set is:

- OpenAI Direct
- OpenRouter
- DeepSeek
- Custom OpenAI-Compatible, renamed from Advanced
- Legacy Local, retained as an explicit runtime option rather than a silent cloud failure fallback

Removing, disabling, or invalidating the active configuration leaves Scribe requiring selection or setup. Cadence never silently routes dictated content to another provider or model.

## Shared hardened contract

Preserve the PR #34 transport and credential foundation:

- API keys remain non-synchronizing, this-device-only Keychain items referenced by opaque random identifiers.
- Configuration changes remain validate → stage credential → atomically commit configuration → clean only superseded credentials.
- Redirects, shared cookies, URL cache, ambient credential storage, unlimited responses, implicit retries, and arbitrary headers remain prohibited.
- Every request has an absolute deadline, explicit cancellation, bounded response size, safe typed failure mapping, and late-result suppression.
- Validation uses synthetic non-user content through the exact production endpoint, serializer, headers, selected model, parser, and transport policy.
- Discovery success never proves generation compatibility; a model must pass synthetic generation validation before activation.
- Raw provider bodies, raw errors, keys, exact model IDs, account/project identifiers, custom origins, prompts, responses, and app identities never enter diagnostics or analytics.

Although provider documentation discusses retry/backoff, Cadence retains explicit user-controlled Retry Polish rather than automatically repeating content-bearing requests. OpenRouter may fail over between ZDR-compatible endpoints serving the same selected model, but Cadence never selects a different model automatically.

## Provider library

Replace the singular persisted configuration with a schema-versioned provider library:

- At most one saved configuration per explicit provider kind.
- Exactly one optional `activeConfigurationID`.
- Stable configuration identity, provider kind, user-visible provider name, enabled/readiness state, selected model, credential reference, disclosure/contract revision, validation timestamp, and non-secret provider-specific settings.
- An active Scribe action pins the complete validated provider snapshot. Settings changes never hot-swap an in-flight action.
- Adding or editing a provider does not activate it until validation succeeds and the user explicitly chooses it.
- Failed replacement preserves the prior working configuration and credential.
- Removing one configuration deletes only its credential. Orphan cleanup computes references across the entire valid library and runs only after the library loads successfully.

Multiple configurations of the same provider are deferred. One per kind keeps Settings understandable while still allowing users to switch among providers without re-entering keys.

## OpenAI Direct

### Endpoint and request

- Fixed recipient: OpenAI at `https://api.openai.com`.
- Generation: non-streaming `POST /v1/responses` because OpenAI recommends Responses for new integrations.
- Stateless request: `store: false`; no conversation, previous-response chaining, background mode, tools, files, images, or server-side content state.
- Authentication: bearer API key from Keychain.
- Optional organization and project identifiers may be entered under Advanced and persisted as non-secret configuration; only the fixed allowlisted OpenAI headers are sent.
- Cadence sends the polished-dictation safety instructions and processed dictation as a single-turn text request and extracts only completed text output.

OpenAI documents that Responses are stored by default unless storage is disabled. Cadence therefore sets `store: false` on validation and generation requests. The provider disclosure must still explain OpenAI's API abuse-monitoring retention and that OpenAI states API data is not used for training unless the customer opts in.

### Model discovery and recommendations

- Live discovery uses authenticated `GET /v1/models` only after provider consent and when the user opens model selection or presses Refresh Models.
- The live list is searchable but does not itself establish text-generation compatibility.
- A release-bundled, versioned catalog provides Cadence-reviewed recommendations and compatibility metadata. For the current planning baseline, the intended tiers are a small/fast model for routine polish, a balanced recommended model, and a high-quality model; exact release IDs must be refreshed from current OpenAI model guidance and pass the Scribe quality corpus before shipping.
- Live IDs outside the bundled catalog appear under Other Available and remain unverified until synthetic validation succeeds.
- Custom Model ID is available under Advanced, with local length/control-character validation followed by production-adapter validation.

Cadence must not present image, audio, embedding, moderation, fine-tuning-only, deprecated, or otherwise incompatible models as recommended merely because `/v1/models` returned them.

### Errors and diagnostics

- Map credential, permission, quota/billing, rate-limit, timeout, unavailable, invalid-request, unsupported-model, content-policy, malformed-output, cancellation, and unsafe-transport outcomes into the existing privacy-safe failure vocabulary.
- Preserve server `x-request-id` only in content-free local diagnostics if privacy review approves it; never record user-supplied request content or account/project headers.
- A missing or removed model marks the configuration Needs Attention. Cadence preserves the key and selected ID and requires explicit reselection.

## OpenRouter

### Endpoint and request

- Fixed recipient: OpenRouter at `https://openrouter.ai`.
- Generation: non-streaming `POST /api/v1/chat/completions` using OpenRouter's normalized Chat Completions contract.
- Authentication: bearer OpenRouter API key from Keychain.
- No arbitrary headers. Optional ranking/attribution headers are omitted in the first release because they are not required for Scribe.
- No plugins, tools, web search, model fallbacks, arbitrary provider ordering, or user-authored routing JSON.
- Provider routing is restricted to Zero Data Retention endpoints for the selected model. Requests set ZDR enforcement and disallow data-collecting endpoints. Same-model endpoint fallback may remain enabled within that privacy boundary.

OpenRouter must be disclosed as both the direct API recipient and a router to downstream model providers. The disclosure explains that endpoint-specific policies vary, that Cadence enforces ZDR-compatible routing, and that the selected model may be served by more than one eligible provider endpoint.

### Model discovery and recommendations

- Live discovery uses the authenticated user-filtered model endpoint so results respect the user's provider preferences and guardrails.
- Request only text-output models with ZDR-compatible endpoints.
- Use OpenRouter's returned ID, canonical slug, display name, modalities, context length, supported parameters, endpoint/privacy availability, and expiry metadata only for selection and validation.
- Search operates across provider, model name, and slug. Recommended entries are pinned above the full eligible catalog and are versioned, Scribe-tested release data rather than a permanent hard-coded claim about the market's best models.
- Custom Model ID is available under Advanced but must pass the same ZDR eligibility and exact-adapter synthetic validation. A custom ID cannot bypass the privacy routing contract.
- A user-initiated Refresh Models action updates the in-memory catalog. Ordinary Scribe never performs model discovery.

Cadence does not persist live OpenRouter or OpenAI catalog responses. Account-filtered model lists may expose private or organization-specific IDs. The app keeps the current-session catalog in memory, persists only the selected model ID and validation state, and falls back offline to the bundled recommendations plus the already selected model.

### Errors and routing

- Prefer OpenRouter's stable typed `error_type` when available; fall back to status mapping.
- Distinguish invalid credential, insufficient credits, permission/guardrail rejection, rate limit, timeout, model unavailable, no eligible ZDR provider, incompatible request, malformed response, and cancellation.
- Honor `Retry-After` only as explanatory UI metadata for explicit Retry Polish. Cadence does not schedule hidden automatic retries.
- A catalog or endpoint outage does not invalidate a previously validated configuration. A generation failure preserves processed dictation under the polished-dictation fallback contract.

## Model catalog lifecycle

- Bundled catalog: offline, versioned, reviewed, non-secret, and available before any network request.
- Live catalog: fetched only after consent and explicit model-management interaction; held in memory for the app session.
- Refresh: automatic once when opening model selection if the in-memory catalog is absent, plus an explicit Refresh Models control. No timed background refresh and no discovery during ordinary Scribe.
- Merge: deduplicate by exact provider model ID; live availability updates status while bundled metadata supplies Cadence recommendation tiers and compatibility claims.
- Validation: the chosen model must generate an acceptable result from synthetic content using the exact production adapter before Save/Activate.
- Disappearance: retain the configured ID, mark Needs Attention, never auto-switch, and keep the credential intact.
- Custom IDs: visibly labelled Custom until validated; validation success does not promote them to Cadence Recommended.

## Setup and Settings behavior

The provider flow is:

1. Add Provider.
2. Choose the explicit provider kind.
3. Review the named recipient, data sent, retention/routing disclosure, and provider-contract revision.
4. Enter the credential and optional provider-specific identifiers.
5. Load bundled recommendations and, after consent, refresh the live catalog.
6. Choose a recommended, live, or custom model.
7. Run synthetic validation through the exact production adapter.
8. Save the configuration.
9. Explicitly make it active, unless it is the first and only validated provider and the confirmation action clearly says Save and Use.

Provider management shows saved provider cards with provider, selected model, readiness, recipient, Active state, last successful validation, Edit Key, Change Model, Review Data Sent, Disable, and Remove. Disabled or invalid providers remain visible and recoverable.

## Disclosure and privacy

- Consent is stored per saved configuration against provider kind, fixed recipient, and disclosure/contract revision.
- Model changes within the same material recipient/routing contract do not require renewed consent. Recipient, origin, retention, routing, or data-policy changes do.
- OpenAI Direct names OpenAI and summarizes the reviewed API data controls.
- OpenRouter names OpenRouter and downstream model-provider routing, including Cadence's ZDR enforcement.
- Custom OpenAI-Compatible retains the unknown-operator warning and normalized custom origin.
- Provider/model choice cannot expand the central Scribe payload allowlist.

## Migration

- Bump the provider configuration schema and Adaptive Scribe migration ledger.
- A valid v1 DeepSeek or Advanced configuration migrates idempotently into a one-item provider library and becomes active without changing its key reference, model, origin, enabled state, or accepted disclosure revision.
- Write and verify the new library before retiring old preference storage or cleaning any credential.
- Rejected, malformed, or future v1 state remains fail-closed and untouched for recovery.
- Legacy Local remains a runtime provider option and is not silently selected when an explicit cloud provider becomes unavailable.
- Diagnostics and migration events identify only coarse provider kind/outcome, never model ID, origin, configuration ID, credential reference, or content.

## Required test contract

- Provider-library decoding: absent, valid, malformed, future schema, duplicate kinds/IDs, missing active ID, disabled active entry, and invalid per-provider fields.
- Migration: v1 DeepSeek and Advanced to one active v2 entry; byte/reference preservation; idempotence; atomic-write rollback; malformed/future source retained.
- Credentials: multiple provider references survive cleanup; replacing/removing one never deletes another; active removal never auto-routes.
- Consent: zero discovery or validation requests before affirmative recipient consent; contract-revision changes invalidate only affected consent.
- Catalogs: bundled/live merge, deduplication, in-memory lifecycle, offline display, malformed/oversized response, incompatible entries, custom IDs, disappearance with no fallback, and discovery-not-equal-validation.
- OpenAI adapter: exact Responses request with storage disabled, no tools/state, fixed origin/header allowlist, output extraction, errors, cancellation, and redirect refusal.
- OpenRouter adapter: exact Chat Completions request, ZDR/data policy, same-model eligible routing, typed errors, no plugins/model fallback, cancellation, and redirect refusal.
- Controller/coordinator: active snapshot pinning; provider/model changes affect only the next action; Retry Polish retains provider/model/recipient; invalidation preserves processed dictation.
- UI/accessibility: Add versus Edit, active selection, searchable dropdown, custom model path, offline/stale/error states, validation failure preserving the prior configuration, keyboard operation, VoiceOver, and narrow widths.
- Privacy/diagnostics: distinct disclosures and recipients; payload denylist; no secret, model, origin, account, app, prompt, response, or raw error leakage.
- Release evidence: live synthetic validation, Scribe quality corpus, latency/failure matrix, signed-candidate egress capture, and policy-review date for every explicit provider profile.

## Map impact

No new Wayfinder ticket is required. Provider-specific diagnostics UI remains a cross-cutting acceptance concern. Exact bundled recommendation IDs are release data and must be refreshed and quality-tested near implementation; the durable contract is the catalog, ranking, validation, and no-silent-fallback behavior.

## Primary sources

- [OpenAI: Migrate to the Responses API](https://developers.openai.com/api/docs/guides/migrate-to-responses)
- [OpenAI: List models](https://developers.openai.com/api/reference/resources/models/methods/list)
- [OpenAI: API authentication and request identifiers](https://developers.openai.com/api/reference/overview)
- [OpenAI: Data controls](https://developers.openai.com/api/docs/guides/your-data)
- [OpenAI: Current models](https://developers.openai.com/api/docs/models)
- [OpenRouter: Models API](https://openrouter.ai/docs/api/api-reference/models/get-models)
- [OpenRouter: User-filtered models](https://openrouter.ai/docs/api/api-reference/models/list-models-user)
- [OpenRouter: Authentication](https://openrouter.ai/docs/api/reference/authentication)
- [OpenRouter: Provider routing and ZDR](https://openrouter.ai/docs/guides/routing/provider-selection)
- [OpenRouter: Zero Data Retention](https://openrouter.ai/docs/guides/features/zdr)
- [OpenRouter: Errors and debugging](https://openrouter.ai/docs/api/reference/errors-and-debugging)
