# Cadence Privacy

Cadence is a local-first macOS dictation and meeting-capture app. Optional Cloud Scribe drafting has a separate, explicit provider-consent boundary.

## Audio

Cadence records audio only while you are using Dictation, Scribe voice capture, or meeting capture. Audio is processed locally for transcription. Cadence does not send audio to a Scribe provider or analytics.

## Transcripts

Cadence stores recent dictation transcripts locally on your Mac so you can copy them again from the menu bar. Meeting notes, saved meeting audio, transcripts, and summaries stay local on your Mac. Transcript text is not sent to analytics.

Current Scribe speech, selected text, provider request, generated draft, and retry payload remain only in the active in-memory Scribe session. Cadence clears them after insert, copy-and-finish, discard, cancel, provider removal, review dismissal, or app termination. Release one does not write a content-bearing Scribe recovery journal. Dictation history and meeting recovery remain separate and unchanged.

## Optional Cloud Scribe

Cadence does not choose or contact a cloud provider until you complete guided setup. Setup first identifies the recipient and shows the data-use disclosure. Cadence creates a setup-only consent receipt only after you affirm that disclosure; a recipient change, provider switch, or setup dismissal clears it. A network request begins only after you choose **Connect and validate**. The first request is a synthetic compatibility check containing only:

- System: `Return only OK.`
- User: `Cadence provider compatibility check.`

After successful validation, a Scribe generation request may contain only:

- Cadence's fixed writing instructions.
- Text dictated for the current Scribe action, transcribed locally.
- The compiled behavior for the current writing environment.
- Exact literals identified locally in the current request.
- The configured model and minimum generation controls.

Cadence does not send audio, selected text, window titles, nearby text, general clipboard contents, screen content, transcript history, meetings, or your Cadence analytics ID. It also excludes document titles, cursor-adjacent text, vocabulary or shortcut catalogs, exact shortcut keys, bundle identifiers, Accessibility signatures, device or account identifiers, and prior Scribe turns.

### DeepSeek

The first bundled profile sends requests directly to `https://api.deepseek.com/chat/completions` for DeepSeek V4 Flash. DeepSeek—not Cadence—controls provider-side processing and retention. DeepSeek's policy says it may collect inputs, use personal data to improve or train its technology, retain some inputs while an account is active, and process or store personal data in the People's Republic of China. DeepSeek also describes privacy rights including training opt-out and deletion requests. [Review the DeepSeek Privacy Policy](https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html), reviewed for this contract on 10 July 2026.

Cadence does not promise zero provider retention, no training, immediate deletion, or request-level erasure.

### OpenAI Direct

OpenAI Direct sends generation requests to `https://api.openai.com` using the configured model. Cadence sets request storage disabled where the API allows it and does not use server-side conversation state. OpenAI—not Cadence—controls provider-side processing, abuse monitoring, and retention. Inputs may be subject to OpenAI's abuse-monitoring retention even when training use is off by default. [Review the OpenAI Privacy Policy](https://openai.com/policies/privacy-policy/) before connecting. Policy review date for this contract: 12 July 2026.

Cadence does not promise zero provider retention, immediate deletion, or request-level erasure at OpenAI.

### OpenRouter

OpenRouter routes selected-model requests through `https://openrouter.ai` with Cadence's zero-data-retention oriented setup. OpenRouter may still retain limited router metadata. The downstream model operator—not Cadence—controls that model's processing and retention. Prefer zero-data-retention-compatible routes and review OpenRouter's data policies before connecting. [Review OpenRouter privacy documentation](https://openrouter.ai/docs) for current routing and retention terms. Policy review date for this contract: 12 July 2026.

Cadence does not promise that every OpenRouter model is zero-retention end to end; only the configured route and operator policies apply.

### Advanced OpenAI-compatible endpoints

Advanced setup accepts one user-entered HTTPS API base URL, model identifier, and bearer key for a narrow, non-streaming Chat Completions request. “OpenAI-compatible” describes the request format only. It does not mean OpenAI operates the endpoint or that OpenAI's privacy, security, retention, training, or deletion terms apply. Cadence cannot verify the endpoint operator. Review that operator's policies before connecting.

## Provider Credentials and Consent

- Candidate API keys remain in process memory and are not saved if validation fails or is cancelled.
- After validation succeeds, Cadence stores the key as an app-scoped, non-synchronizing generic-password item in macOS Keychain. Non-secret provider configuration and the accepted disclosure version are stored separately.
- Replacing a key or endpoint validates the candidate before swapping the working configuration.
- Disabling a provider stops new Scribe requests but retains its configuration and Keychain item.
- **Remove {provider} from Cadence** stops new requests, cancels and suppresses in-flight work, and removes the local key, provider configuration, acceptance record, and current Scribe buffers. It preserves Dictation history, meetings, audio, writing preferences, permissions, and shortcuts.
- Local removal does not revoke a key at the provider, retract requests already sent, or delete data the provider holds. Use the provider's own key-management and privacy routes for those actions.
- A recipient-origin change or material egress-contract change requires a new local acknowledgment before another provider request.

## Permissions

Cadence asks macOS for:

- Microphone access, so it can record while you dictate.
- Accessibility access, so it can insert text into the focused app.
- Input Monitoring access, so global shortcuts work when other apps are active.
- Screen Recording access, so meeting capture can capture system audio. Cadence excludes its own process audio from system-audio capture.

## Analytics

Analytics are optional and off by default. If enabled, Cadence sends privacy-safe product events such as:

- App launch.
- Permission setup status.
- Settings changes.
- Dictation started, completed, or failed.
- Meeting capture started, stopped, completed, or failed.
- Coarse duration and character-count buckets.

Analytics do not include:

- Audio.
- Transcript text.
- Vocabulary terms.
- Exact shortcut keys.
- Dictated app names.
- Raw error messages.
- Saved meeting audio.

Analytics can be turned off at any time in Cadence Settings.

Scribe's local diagnostic ring is separate from analytics. It contains at most 200 events and seven days of minute-rounded, closed-enum setup/generation/recovery outcomes. It contains no content, app or writing-environment identity, key, endpoint/model detail, prompt/response, raw error, stable device/account ID, or exact timestamp. It is never uploaded automatically. Settings lets you inspect the disclosure, export the JSON to a location you choose, or clear the ring.

Release one sends no remote Scribe telemetry through the persistent PostHog identity. If a future release adds remote Scribe telemetry, it must use the documented typed allowlist and a per-launch identity, and it remains subordinate to the analytics opt-in.

## Contact

For questions about Cadence privacy, contact Darsh Shah.
