# Cadence Privacy

Cadence is a local-first macOS dictation and meeting-capture app. Optional Cloud Compose drafting has a separate, explicit provider-consent boundary.

## Audio

Cadence records audio only while you are using Dictation, Compose voice capture, or meeting capture. Audio is processed locally for transcription. Cadence does not send audio to a Compose provider or analytics.

## Transcripts

Cadence stores dictation transcripts locally on your Mac so you can copy them again from the menu bar. When you successfully insert or copy an ordinary transcript-only Compose result, Cadence also stores the final composed text and its original dictation together in local Dictation history. This lets the history preview show the final result while the entry detail preserves both versions. Choosing an unpolished fallback stores it as an ordinary dictation rather than labeling it as composed. Selected-text rewrites are excluded, as described below. Meeting notes, saved meeting audio, transcripts, and summaries stay local on your Mac. Transcript text is not sent to analytics.

Current Compose speech, provider request, generated draft, and retry payload remain only in the active in-memory Compose session until you successfully insert or copy the result. At that point, ordinary transcript-only Compose saves only the original dictation and chosen output to local Dictation history. The selected-text preview below does not save its source or generated result to history, including after Copy or Insert. Cadence does not save failed, discarded, cancelled, or merely reviewed Compose drafts, and it does not write a separate content-bearing Compose recovery journal.

## Optional Local Selected-Text Preview

Selected-text context is off by default. It requires both the local-context switch and the separate TextEdit allowance, under the current disclosure. Accessibility permission alone does not enable it. TextEdit native text fields are the first provisional adapter; real Accessibility behavior and generation quality still require controlled verification. Browsers, unknown surfaces, secure fields, and other apps are unsupported in this preview.

When enabled with Apple Intelligence selected, an explicit Compose invocation may read only the selection in its pinned TextEdit field. The microphone starts before the optional read. The read has byte, metadata, and time limits; incomplete or stale selections are discarded. A command such as “Make this shorter” may then rewrite that selection. Ordinary speech remains transcript-only, and reply context, nearby content, screenshots, and memory are not enabled by these controls.

The original source remains in memory for that action. It is not put in the spoken transcript, saved to history, logged, exported in diagnostics, or sent to a cloud provider. Its generated draft is also excluded from history because this capture permission does not authorize retention. Copy and Insert are explicit user actions; insertion rechecks the original selection after restoring its exact field. Changing or disabling either setting clears dependent work and reviewed drafts. Accessibility is checked at each use and monitored while the opted-in action is active. Cancelling ends capture immediately; late results cannot restore the draft. This preview does not support refining a contextual draft in place.

A failed contextual rewrite never offers the spoken edit command as replacement
text. Retry uses the same pinned source and consent; Cancel clears the action.
An unchanged generated selection is labeled as unchanged, not as a completed
writing improvement. Neither outcome grants a new retention permission.

The selected-rewrite compiler uses an invocation-only capture identity, which
cannot identify a continuing conversation or retrieve memory. Its source and
output budgets reject oversized work rather than truncate selected text. It
checks the selection snapshot's 120-second use lifetime before dispatch, result
acceptance, Copy and insertion preflight. Expired work cannot be retried against
the old snapshot; start a new Compose request. This expiry check does not promise
immediate background erasure or retention beyond the existing action lifetime.

The source indicator can show the exact selection used by the current reviewed
draft. Opening it rechecks access. Excluding that source applies only to the
current request: the previous draft remains labeled with its original source,
can be copied explicitly, and cannot be inserted or regenerated from that
excluded selection. Source inspection adds no capture, cloud transmission or
history retention. **Record new message** discards this draft and records a new
message without reading selected text for that action. Record Again also honors
exclusion; this does not change capture preferences for later independent requests.
Disabling access still clears the source and dependent draft.

**Refresh selection** explicitly discards the old draft and reads the current
selection from the original pinned field under the current local capture setting.
It creates a new action and source snapshot while reusing the spoken edit; it does
not record audio or insert text. The prior draft and selection are not input to
the new generation. Cancellation or revocation invalidates delayed refresh work,
and a failed refresh never exposes the editing instruction as a message fallback.

Existing cloud consent covers only the transcript-only fields below. Selecting a cloud provider does not send selected text or silently substitute cloud generation for local context. Local capture, retention, and cloud transmission remain separate permissions.

## Local Document Session Memory Preview

The session-memory and TextEdit adapter controls are available by default, but
their separate Settings permissions are off by default. Earlier development
consent does not automatically activate this preview; it must be enabled again
under the current disclosure. After you enable the controls, Cadence can identify the
currently focused saved TextEdit document on an explicit Compose action. It
uses Accessibility document metadata and local file identity, without reading
document contents. Work starts after the microphone is live and is cleared
when the action ends or the preview settings change; subsequent use rechecks
Accessibility permission. Unsaved documents, other apps,
and cloud providers do not receive this preview.

An additional, default-off switch allows explicit spoken commands in that
verified TextEdit document: “Remember that …” saves the stated fact for the
current app session, “What do you remember for this document?” displays recent
facts, “Cadence, correct memory [old fact] should be [new fact]” supersedes one
matching recent fact, and “Forget this document” removes them. Facts expire within 30 minutes
and are cleared when the app session ends or identity/retention preferences
change. These commands are handled locally, without inserting text or saving a
Compose history entry. Ordinary speech and visible document text are never
mined for memory. A third, default-off switch may use relevant, explicitly
saved facts in a later draft for the same verified document. This use requires
the local Apple Intelligence provider; cloud providers receive no memory facts.
The fact set is bounded, checked again before generation, and frozen across
retries. If document access is unavailable, Compose continues with the spoken
request alone. Identity, retention, and local draft use have separate controls;
none authorizes cloud transmission. Changing local draft use preserves saved
session facts but invalidates any in-flight memory-backed draft.

A separate default-off switch can remember a reviewed local Compose draft
after a successful Copy or confirmed Insert in the same verified saved TextEdit
document. It does not record an unconfirmed insertion, a discarded draft, a
selected-text rewrite, or a draft made using memory facts. Copy and Insert do
not prove that a message was delivered or that its claims are true. These
records remain labeled as chosen drafts, appear only when the user asks to
inspect this document's session memory, and are not used as facts or added to
later generation. They remain in memory for this app session, expire within
30 minutes of inactivity, and are removed by the voice forget command.
Turning the chosen-draft switch off clears all session memory. This switch
does not authorize cloud transmission.

## Optional Cloud Compose

Compose can use spoken directions about tone, length, formatting, or wording
to draft the intended message. These directions are part of the same processed
dictation already disclosed below. This adds no screen reading, selected-text
capture, cross-session memory, or new provider input category.

Cadence does not choose or contact a cloud provider until you complete guided setup. Setup first identifies the recipient and shows the data-use disclosure. Cadence creates a setup-only consent receipt only after you affirm that disclosure; a recipient change, provider switch, or setup dismissal clears it. A network request begins only after you choose **Connect and validate**. The first request is a synthetic compatibility check containing only:

- System: `Return only OK.`
- User: `Cadence provider compatibility check.`

After successful validation, a Compose generation request may contain only:

- Cadence's fixed writing instructions.
- Text dictated for the current Compose action, transcribed locally.
- The compiled behavior for the current writing environment.
- Exact literals identified locally in the current request.
- The configured model and minimum generation controls.

Cadence does not send audio, selected text, window titles, nearby text, general clipboard contents, screen content, transcript history, meetings, or your Cadence analytics ID. It also excludes document titles, cursor-adjacent text, vocabulary or shortcut catalogs, exact shortcut keys, bundle identifiers, Accessibility signatures, device or account identifiers, and prior Compose turns.

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
- Disabling a provider stops new Compose requests but retains its configuration and Keychain item.
- **Remove {provider} from Cadence** stops new requests, cancels and suppresses in-flight work, and removes the local key, provider configuration, acceptance record, and current Compose buffers. It preserves Dictation history, meetings, audio, writing preferences, permissions, and shortcuts.
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

Compose's local diagnostic ring is separate from analytics. It contains at most 200 events and seven days of minute-rounded, closed-enum setup/generation/recovery outcomes. It contains no content, app or writing-environment identity, key, endpoint/model detail, prompt/response, raw error, stable device/account ID, or exact timestamp. It is never uploaded automatically. Settings lets you inspect the disclosure, export the JSON to a location you choose, or clear the ring.

Release one sends no remote Compose telemetry through the persistent PostHog identity. If a future release adds remote Compose telemetry, it must use the documented typed allowlist and a per-launch identity, and it remains subordinate to the analytics opt-in.

## Contact

For questions about Cadence privacy, contact Darsh Shah.

### Built-in on-device Compose

New installations select Apple Intelligence as the Compose provider. It uses
`SystemLanguageModel.default` on this Mac, without an API key, cloud account,
HTTP transport, or remote consent receipt. It requires macOS 26 or later and an
available Apple Intelligence model. Cadence checks availability again before
acquiring and dispatching requests. Unavailability does not select a cloud
provider automatically.

Existing cloud selections, disabled configurations, and removals are retained.
Choosing Apple Intelligence in Settings retains saved cloud configurations.
A cloud provider still requires the existing explicit setup and disclosure.
Ordinary on-device Compose receives the current processed speech, writing
guidance, and exact literals. An explicit local Refine action additionally sends
the current in-memory draft and the new voice instruction to the local model.
The separately enabled TextEdit selected-text preview can send its approved
selection to that same local model. With separate default-off controls, an
explicitly saved fact from the same verified TextEdit document can also enter
a local draft. These local context paths are not enabled for cloud providers.
No active provider path receives screen pixels, app identity, saved history, or
cross-session conversation memory. A fact-backed draft is excluded from ordinary
Compose history and is invalidated if its source fact changes or access is
revoked before Copy or Insert.
From that draft's fact inspector, an explicit **Regenerate without facts**
action discards the old draft and makes a new local request from the same
speech without reading or sending session facts. Retry of that new request
also stays fact-free. **Regenerate without this fact** instead makes a new
local draft with the other facts from the same frozen source. Further exclusions
accumulate, and retries preserve them. Cadence checks the original fact set
before using the replacement; if it changes or access is revoked, the draft is
invalidated. Neither action deletes saved facts.

For recognized on-device style and reply-drafting commands, Cadence separates the writing direction
from the message before requesting a rewrite. It retains the full original
transcript locally for existing history and recovery. This does not capture a new
data category, send text to a cloud provider, or add cross-session memory.

### Roadmap context and memory boundaries

The source tree includes screenshot/OCR adapters, conversation identity, scoped
session-memory and encrypted-memory services. The screen-capture adapter is
unregistered and denies access by default. OCR verification uses synthetic images.
Session facts have a separate, default-off voice retention flow for verified
saved TextEdit documents and last only for the current app session.

The encrypted persistent-memory preview has a separate default-off rollout
gate and Settings confirmation. Confirmation can create an encrypted local
store and Keychain key for verified saved TextEdit documents; activation alone
does not capture or save a fact. Exact voice phrases can prepare a fact to save,
inspect current facts, propose an exact correction, or propose forgetting facts
for the verified document. Save, correction, and forget require a visible
confirmation. These commands do not contact a writing provider, insert their
spoken text, or enter Compose history. A forget confirmation is rejected if
saved facts change after its review. A separate default-off control can allow
relevant saved facts from that same verified document into an Apple Intelligence
draft. Cloud writing providers never receive them. Draft review, Copy, and
Insert recheck the exact local fact set; a changed or forgotten fact invalidates
the draft. Turning the preview
off stops access without erasing
records. A separately confirmed Forget all action removes Cadence's current
encrypted records even while the preview is off. Older encrypted copies may
remain in device or system backups. No cloud provider receives durable facts.
Encrypted-file and key-lifecycle tests still use synthetic data and injected
key stores; no real Keychain integration has been certified.

A content-free namespace owner preserves the identifiers needed to reopen the
encrypted store. Reading it grants no capture or retention permission; explicit
creation does not provision a Keychain key by itself. Missing or corrupt
identity metadata cannot silently replace an existing encrypted store. See
[memory storage ownership](scribe-memory-storage.md).
The implementation ledger records which user-facing integrations remain open.

### Explicit global writing defaults

Global tone and concision choices are saved only through the Settings Save action
and remain until Reset. They start disabled and are not inferred from drafts.
Their local versioned payload contains only fixed style choices, without content
or app/account identities. Compose snapshots them for a new recording and sends
only their compiled writing guidance to the selected provider under its existing
setup boundary. They do not activate screen capture, memory, or cloud providers.
Malformed or newer records are preserved and not applied; an explicit recovery
action can remove the unreadable global-default record.
