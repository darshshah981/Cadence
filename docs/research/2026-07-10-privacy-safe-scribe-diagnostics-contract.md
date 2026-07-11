# Privacy-Safe Scribe Diagnostics and Support Evidence

**Date:** 2026-07-10
**Wayfinder ticket:** [Define privacy-safe Scribe diagnostics and support evidence](https://github.com/darshshah981/Cadence/issues/32)

## Decision

Scribe diagnostics use a closed, typed, content-free event schema. Cadence keeps a small local ring for support and release evidence; it never records transcript/draft/selection content, app or writing-environment identity, credentials, exact endpoint/model, prompts, responses, raw errors, audio, meetings, shortcuts/vocabulary, stable account/device identity, or local file/user names.

The local ring is not analytics and never leaves the Mac automatically. Remote Scribe telemetry is permitted only when the existing global analytics opt-in is on **and** the event can be sent without Cadence's persistent PostHog distinct ID. It uses a random per-launch identifier solely to de-duplicate events within one app run. If the sink cannot guarantee that identity boundary, release one sends no remote Scribe telemetry.

This is stricter than the current generic `AnalyticsService`, whose PostHog sink adds a persistent `Cadence.analyticsDistinctID` and whose string sanitizer only truncates arbitrary values. Scribe must use a typed allowlist, not sanitization of caller-supplied strings.

## Typed Event Model

No Scribe diagnostic API accepts arbitrary names, property keys, or string values. The event is composed only from closed enums and bounded numbers:

### Event kind

- readiness changed
- setup opened/closed
- validation started/completed
- capture/transcription started/completed
- generation started/completed
- manual retry requested
- review fallback chosen
- insertion verification completed
- provider removed
- migration completed

### Phase

- readiness
- setup
- validation
- capture
- transcription
- generation
- review
- insertion
- migration

### Provider kind

- none
- DeepSeek
- Advanced
- legacy local

Provider kind is the entire provider dimension. Exact origin, path, model/catalog ID, key metadata, account/balance value, and response-reported model are prohibited.

### Outcome category

- success
- cancelled
- permission denied
- setup required
- configuration invalid
- credential rejected
- balance required
- rate limited
- offline/transport unavailable
- timed out
- provider unavailable
- provider rejected
- invalid response
- transcription empty/failed
- target changed
- insertion failed
- migrated/retained/failed
- other safe category

Raw `Error`, `localizedDescription`, HTTP body/header values except validated coarse `Retry-After`, endpoint strings, AX values, and provider messages never enter the event initializer.

### Bounded dimensions

- latency bucket: `<1s`, `1-4s`, `4-8s`, `8-15s`, `15-30s`, `>30s`;
- attempt ordinal: `1`, `2`, `3+`;
- retry disposition: none, manual now, manual after wait, reconnect, update Cadence, change configuration;
- booleans: app adaptation enabled, selected-text intent, fallback used, late result suppressed;
- app version/build and macOS **major** version for local support export only.

No request UUID, exact timestamp, persistent session ID, bundle ID, environment/behavior ID, permission prompt text, or exact duration/count is recorded.

## Local Diagnostic Ring

Store at most 200 typed events and at most seven days of history in a Scribe-specific app-support file. The file contains:

- schema version;
- events with UTC timestamps rounded to the minute;
- event kind, phase, provider kind, safe outcome, latency bucket, attempt bucket, retry disposition, and allowlisted booleans;
- no free-form strings other than fixed enum raw values.

Write asynchronously after state transitions; diagnostic persistence must never block audio capture, transcription, dictation insertion, meeting capture, provider cancellation, or UI recovery. Use atomic replacement and fail silently to an in-memory ring if storage is unavailable. A diagnostics failure never changes Scribe readiness or user content state.

Retention is enforced on every load/write. **Clear Scribe diagnostics** deletes the local file and in-memory ring. Provider removal does not need to erase coarse diagnostics because they contain no recipient/model/content identity, but the removal confirmation links to the clear action.

Do not duplicate content into OSLog. Production logs may include only the same fixed event/phase/outcome enums and buckets. Even `privacy: .private` is not permission to pass content or raw errors into `Logger`.

## Support Export

Settings exposes **Export Scribe diagnostics…** and **Clear Scribe diagnostics** under the managed provider/recovery area.

Export is a user-initiated, pretty-printed JSON file selected through the native save panel. Nothing is uploaded or attached automatically. Before saving, Cadence shows:

> This export contains Cadence and macOS major versions, Scribe readiness and permission states, provider kind, and coarse setup/generation/recovery outcomes. It does not contain dictated or selected text, app names, writing environments, API keys, endpoint/model details, prompts, responses, audio, meetings, shortcuts, raw errors, or a device/account identifier.

The export includes:

- export schema version and generated-at date rounded to the minute;
- Cadence version/build and macOS major version;
- current Scribe readiness category;
- Microphone, Accessibility, and Input Monitoring granted booleans;
- provider kind only;
- app-adaptation enabled boolean;
- the bounded event ring.

It excludes Screen Recording state because ordinary Scribe does not require it, and excludes usernames, home paths, hardware/serial information, locale/time zone, network/IP details, Keychain metadata, analytics distinct ID, request/session IDs, exact timestamps, exact error/status text, and all other app state.

The user can inspect the JSON before sharing it. Support documentation must say that sharing is the user's action and identify the recipient outside the app; Cadence does not embed an upload endpoint in release one.

## Remote Analytics Boundary

Remote Scribe analytics is optional and subordinate to the existing opt-in toggle.

- Send only a deliberately smaller subset: event kind, phase, provider kind, safe outcome, latency bucket, attempt bucket, and retry/cancel booleans.
- Use a random per-launch identifier; do not attach the existing persistent PostHog `distinct_id`, device/account identifiers, or person profiles.
- Do not send app/build/OS fields if they would be combined with a persistent identity elsewhere in the same event path.
- Never forward the local support ring or export.
- Changing analytics consent takes effect immediately. Disabling analytics stops new remote sends but does not alter the local ring; the UI explains the distinction.
- If the analytics SDK/API cannot omit its persistent identifier, the Scribe remote sink is `NoopAnalyticsSink` for release one.

## Performance and Pipeline Boundaries

- Record Scribe events after the authoritative state transition, never inside microphone/audio callbacks.
- Use a dedicated actor/serial queue and bounded in-memory buffer.
- Do not add diagnostics to Dictation or meeting models/stores as part of this work.
- Meeting durability and Dictation latency tests run with diagnostics enabled and with storage failure injected.
- Diagnostic write/export failure is nonfatal and never holds a voice-session lease.

## Verification Contract

Tests must prove:

1. The typed API cannot accept free-form names/values or raw `Error` objects.
2. Canary transcript, selected text, API key, exact origin/model, prompt/response, app/environment name, bundle ID, shortcut, raw error, username/path, and request UUID never appear in local files, OSLog captures, analytics payloads, crash/support payloads, or exports.
3. Retention prunes over 200 events and over seven days; timestamps are minute-rounded and no stable session/device ID is stored.
4. Export contains only the documented schema and is never sent automatically.
5. Clear removes file and memory state.
6. Analytics off produces zero remote Scribe events. Analytics on uses a per-launch identity and never the persistent PostHog ID; an incompatible sink sends nothing.
7. Late-result suppression, timeout, cancel, target mismatch, migration failure, and provider removal map to fixed categories without raw errors.
8. Storage corruption/future schema fails closed to an empty ring and never blocks Scribe.
9. Diagnostics enabled, disk-full/write failure, and export failure do not regress Dictation latency, Scribe cancellation, or meeting capture/durability.
10. The signed Release build passes a recursive string/byte leak scan using distinct canary secrets in every prohibited field.

## Repository Evidence

- `Cadence/Services/AnalyticsService.swift` accepts arbitrary event/property strings, logs them publicly after truncation, and adds a persistent PostHog distinct ID.
- `Cadence/App/AppModel.swift` already maps some local errors into coarse categories; that closed-enum pattern should replace raw string sanitization for Scribe.
- `Cadence/Services/ScribeCoordinator.swift` has authoritative phase transitions and coarse OSLog calls suitable for typed instrumentation after transitions.
- `docs/privacy.md` currently describes opt-in analytics and must add the local-diagnostics/remote-telemetry distinction before Cloud Scribe release.
