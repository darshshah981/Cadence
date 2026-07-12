# Advanced OpenAI-Compatible Wire Contract

**Date:** 2026-07-10
**Wayfinder ticket:** [Define the Advanced OpenAI-compatible wire contract and interoperability floor](https://github.com/darshshah981/Cadence/issues/29)

## Question

What exact URL/path normalization, authentication shape, minimal request fields, generic response/error mapping, redirect behavior, timeout/retry policy, feature negotiation, and narrow user-facing interoperability claim should the first-slice Advanced OpenAI-compatible provider support?

## Decision

The first slice supports one explicit compatibility profile: a user-supplied HTTPS API base URL, model identifier, and bearer API key that can complete a non-streaming, text-only OpenAI Chat Completions request. Cadence does not negotiate parameters, discover models, follow redirects, or claim general OpenAI API compatibility.

This profile is intentionally narrower than either OpenAI's full current API or the universe of third-party APIs described as compatible. OpenAI's current Chat Completions reference defines a broad and evolving schema, including multiple message roles, streaming, tools, multimodal content, and both current and deprecated token-limit fields. A successful Cadence probe proves only the subset Cadence sent and parsed; it cannot prove provider identity, privacy, security, model fidelity, future availability, or support for unrelated API features.

## Configuration Contract

### API base URL

The user enters an **API base URL**, not an arbitrary request URL.

- Accept only an absolute `https` URL with a non-empty host.
- Reject user information, query, fragment, backslashes, percent-encoded slashes/backslashes, and `.` or `..` path segments.
- Permit an explicit port. Normalize scheme and host case; omit the default HTTPS port in the stored/displayed origin; preserve the path's case and percent-encoding semantics.
- Treat the path as a fixed API prefix. Remove only redundant trailing slashes, then append exactly one `chat/completions` path component. Do not infer or insert `/v1`.
- Reject a value that already ends in `/chat/completions` with a targeted explanation to enter the base prefix instead. This keeps stored configuration and path joining unambiguous.
- Show both the normalized recipient origin and derived request endpoint before the affirmative connect action.

Examples:

| Entered base URL | Derived endpoint |
|---|---|
| `https://provider.example/v1` | `https://provider.example/v1/chat/completions` |
| `https://gateway.example/openai/v1/` | `https://gateway.example/openai/v1/chat/completions` |
| `https://provider.example` | `https://provider.example/chat/completions` |

[RFC 3986](https://datatracker.ietf.org/doc/html/rfc3986/) defines the scheme, authority, path, query, and fragment components and dot-segment handling. [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html) states that HTTP scheme and host are case-insensitive, path comparison remains case-sensitive, and user information in HTTP(S) URIs should be treated as an error because it can obscure the true authority.

Private, loopback, and local-network hosts remain allowed when they use HTTPS with normal macOS trust validation. Cadence does not disable certificate checks or add a trust-bypass path.

### Model and credential

- The model identifier is required, trimmed, non-empty, free of control characters, and bounded to 256 UTF-8 bytes. Cadence sends it verbatim and stores it only as local configuration.
- The credential is a required bearer API key. Arbitrary headers, alternate authentication schemes, query-string keys, embedded URL credentials, request templates, and response extraction rules remain out of scope.
- Candidate credentials remain memory-only until validation succeeds. The approved Keychain, disclosure, replacement, removal, and logging rules from the BYOK contract apply unchanged.

Any base URL, model, or key change requires a new synthetic validation. A changed normalized origin also requires renewed recipient disclosure; a path or model change at the same origin requires validation but not a new disclosure unless the data-use contract changed.

## Wire Profile

Cadence sends a direct HTTPS `POST` to the derived endpoint with only:

- `Authorization: Bearer <Keychain credential>`
- `Content-Type: application/json`
- `model`: the configured model identifier
- `messages`: exactly one `system` text message and one `user` text message
- `stream: false`
- `max_tokens`: `1024` for production or `8` for validation

Cadence omits temperature, top-p, tools, tool choice, response format, log probabilities, stop sequences, penalties, reasoning/thinking controls, prior assistant turns, storage flags, user identifiers, and provider-specific extensions. `max_tokens` is the deliberate legacy Chat Completions compatibility floor for this Advanced path: OpenAI's current reference still documents it and shows it in examples, but marks it deprecated in favor of `max_completion_tokens`. An endpoint or model that rejects this exact profile is not supported in the first slice; Cadence does not silently retry with a different field.

The [official OpenAI Chat Completions reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create) documents `POST /chat/completions`, bearer authorization, `model`, `messages`, streaming, token limits, and the returned `choices`/`message`/`finish_reason` shape. That reference is the shape source, not a warranty for third-party endpoints.

### Synthetic validation request

Validation runs only after the approved disclosure and affirmative connect action. It uses the production endpoint, authentication, serializer, parser, and redirect policy with no user content:

- system message: `Return only OK.`
- user message: `Cadence provider compatibility check.`
- configured model identifier
- `stream: false`
- `max_tokens: 8`

Do not call `/models`, probe alternate paths, remove rejected fields, change roles, or retry automatically. Validation succeeds on wire compatibility and a safe non-empty completion; exact `OK` punctuation is not required.

## Response Contract

Accept a response only when all conditions hold:

1. HTTP status is exactly `200` and the raw response stays within a 1 MiB transport cap.
2. The body is valid JSON in a non-streaming Chat Completions shape.
3. `choices` contains exactly one item with `index == 0`.
4. `finish_reason == "stop"`.
5. `message.content` is a string that passes `ScribeOutputPolicy` normalization, control-character rejection, and the 64 KiB output limit.
6. The coordinator binds the result to its own active request and attempt identity; provider response identifiers are never trusted as local authority.

Reject `length`, `tool_calls`, `content_filter`, null/non-string content, multiple choices, malformed JSON, oversized bodies, and any streamed/event response. Unknown extra response fields may be ignored. The provider-reported model may be retained transiently for validation diagnostics but does not override the configured model and must not enter analytics or logs.

## Transport, Redirect, and Retry Contract

- Use a dedicated ephemeral `URLSession` configuration with no disk cache, cookie store, or URL credential persistence. Apple's [URLSession documentation](https://developer.apple.com/documentation/foundation/urlsession) and [ephemeral configuration reference](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/ephemeral) explicitly distinguish ephemeral sessions from default sessions that persist caches, cookies, or credentials.
- Use normal system TLS trust. Do not accept invalid certificates or implement certificate-pinning bypasses.
- Refuse **every HTTP redirect**, including same-origin redirects. The user approved one derived endpoint, and the request contains both a bearer credential and content. Apple's [`willPerformHTTPRedirection` delegate](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession%28_%3Atask%3Awillperformhttpredirection%3Anewrequest%3Acompletionhandler%3A%29) lets the client return no request to refuse a redirect; [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html) warns that automatic redirection of unsafe requests and sensitive fields such as `Authorization` requires care.
- Validation has a 15-second absolute deadline. Generation has an 8-second soft UI threshold and a 30-second absolute deadline. Idle-timeout configuration alone is insufficient because Apple documents that its request timeout resets when new data arrives; enforce the product deadline by cancelling the underlying task and invalidating the attempt.
- User cancel, timeout, provider removal, or a superseding attempt cancels the URLSession task and provider task, then suppresses all late callbacks.
- There are no automatic network retries. A manual retry is one new single-flight attempt using the exact immutable request/configuration snapshot and never retries insertion.
- A valid `Retry-After` value may delay or annotate the manual retry control, but correctness must not depend on it.

## Safe Error Mapping

Never parse a third party's raw error body into user-visible copy, logs, or analytics. Map only transport facts and HTTP status:

| Signal | Safe category | Recovery |
|---|---|---|
| Redirect response | Endpoint redirected | Edit the base URL; do not resend |
| 400, 405, 413, 415, 422 | Request/profile incompatible | Edit endpoint/model or use another provider |
| 401, 403 | Credential or access rejected | Replace the key or check access |
| 404 | Endpoint or model not found | Edit base URL/model |
| 408, 429 | Temporarily unavailable/rate limited | Manual retry after recovery/wait |
| Other 4xx | Provider rejected request | Do not retry unchanged |
| 500-599 | Provider unavailable | Manual retry |
| Offline, DNS, TLS, connection failure | Transport unavailable/unsafe | Repair connectivity or endpoint trust, then retry |
| 15s/30s absolute deadline | Timed out | Manual retry |
| Malformed/oversized/incompatible 200 | Invalid provider response | Manual retry once; repeated failure marks Needs attention |
| Explicit user cancel | Cancelled | Terminal; no request starts automatically |

Provider kind (`Advanced`), coarse phase/category, latency bucket, and retry/cancel state are the only eligible telemetry dimensions. Exact origin, path, model, key, prompt, response, environment/app name, selected text, and raw errors remain excluded.

## User-Facing Interoperability Claim

After validation, Cadence may say:

> Connection test succeeded. Cadence received one compatible, non-streaming text completion from this endpoint and model configuration.

It must also preserve the approved warning:

> “OpenAI-compatible” describes the request format only. It does not mean OpenAI operates this service or that OpenAI's privacy, security, retention, training, or deletion terms apply.

Do not say the provider, model, or endpoint is certified, secure, private, fully OpenAI-compatible, permanently available, or compatible with tools, streaming, images, reasoning, or other OpenAI features. A successful probe is a time-bounded configuration check, not a vendor or policy attestation.

## Implementation and Verification Implications

The implementation-ready plan should assign:

- a value type that validates/canonicalizes the Advanced base URL and derives the endpoint;
- a provider-configuration model that keeps normalized origin, base path, model, disclosure version, and Keychain reference separate;
- one central provider-safe request serializer shared by DeepSeek and Advanced, with provider-specific wire profiles layered after the egress allowlist;
- an Advanced adapter using the transport, response, deadline, cancellation, and safe-error contracts above;
- setup/Settings copy that shows the normalized origin and derived endpoint before validation;
- fixtures for accepted/rejected URL forms, exact validation/production JSON, redirects, every status category, timeout/cancel/late callback, response-shape failures, 1 MiB raw cap, 64 KiB output cap, and analytics/log redaction;
- live validation against at least one controlled OpenAI-compatible fixture endpoint, while release claims remain limited to the exact profile tested.

The existing `ScribeProvider` protocol and `ScribeProviderError` enum are too coarse for this contract, while `ScribeOutputPolicy` is a foundation to preserve. Relevant local seams are `Cadence/Services/ScribeProvider.swift`, `Cadence/Models/ScribeModels.swift`, `Cadence/Services/ScribeCoordinator.swift`, and `CadenceTests/ScribeCoordinatorTests.swift`.

## Sources

- [OpenAI API Reference — Create chat completion](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)
- [RFC 3986 — Uniform Resource Identifier: Generic Syntax](https://datatracker.ietf.org/doc/html/rfc3986/)
- [RFC 9110 — HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html)
- [Apple — URLSession](https://developer.apple.com/documentation/foundation/urlsession)
- [Apple — URLSessionConfiguration.ephemeral](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/ephemeral)
- [Apple — URLSessionTaskDelegate redirect handling](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession%28_%3Atask%3Awillperformhttpredirection%3Anewrequest%3Acompletionhandler%3A%29)
- `Cadence/Services/ScribeProvider.swift`
- `Cadence/Models/ScribeModels.swift`
- `Cadence/Services/ScribeCoordinator.swift`
- `CadenceTests/ScribeCoordinatorTests.swift`
