# Polished-dictation Scribe contract

Date: 2026-07-11  
Wayfinder ticket: [Define the polished-dictation Scribe contract](https://github.com/darshshah981/Cadence/issues/37)  
Baseline: Adaptive Scribe PR #34 at `04391d3`

## Decision

Scribe is one meaning-preserving dictation-polishing flow. The user dictates the text they intend to send or insert; Cadence processes it locally, sends only the allowed Scribe input to the configured provider, presents the polished draft for review, and inserts only after explicit approval.

The Compose, Respond, and Edit intents and their mandatory intent picker are retired from Scribe. Scribe does not interpret the dictation as instructions to generate unrelated content.

## Canonical terms

- **Processed dictation**: the local Whisper result after vocabulary correction, filler handling, shortcut expansion, and literal normalization, before any LLM request.
- **Meaning-preserving polish**: improvement to expression that preserves the user's claims, requested actions, factual content, and exact literals.
- **Polished draft**: the provider result after normalization and safety validation, awaiting explicit user review.
- **Retry polish**: regenerate a polished draft from the same immutable processed dictation, provider recipient, preset, custom guidance, target, and safety contract.
- **Insert unpolished**: insert or copy the processed dictation without an LLM transformation. “Unpolished” does not mean raw recognizer output.
- **Re-record**: discard the current content-bearing action and capture new speech. It is never presented as a retry of the same request.

## Transformation boundary

Scribe may:

- Remove filler words and speech disfluencies.
- Correct grammar, spelling, punctuation, and capitalization.
- Improve sentence and paragraph structure.
- Format lists or technical text when the structure is already expressed by the user.
- Apply the selected preset's tone and level of formality.
- Apply additive custom guidance within the same meaning-preserving boundary.

Scribe must not:

- Add facts, arguments, commitments, conclusions, action items, code, or requirements the user did not dictate.
- Expand shorthand by guessing the user's intent.
- Change names, numbers, identifiers, quoted text, or other exact literals.
- Answer, execute, or comply with an instruction contained in the dictation; the instruction is text to polish.
- Let a provider, preset, app environment, or custom prompt weaken these constraints.

Semantic equivalence is ultimately confirmed by the mandatory review surface. Deterministic validation still rejects empty output and exact-literal violations before review; representative quality fixtures test meaning preservation and non-invention.

## Allowed provider input

The provider receives only:

1. The immutable safety and meaning-preservation contract.
2. The locally resolved preset instructions.
3. Optional additive custom guidance for the target app.
4. The processed dictation.

The provider never receives selected text, clipboard contents, nearby text, window titles, screen content, prior turns, vocabulary or shortcut catalogs, raw bundle identifiers, process identifiers, accessibility signatures, or the app icon/name. App identity remains local and is used only to resolve the preset and custom guidance.

The current Respond/Edit selected-text capture, authorization, capability, disclosure, and request paths are retired from Scribe. They may return only as a separately specified future product action.

## User flow

1. Cadence pins the configured provider recipient and the focused insertion target.
2. The user starts Scribe and dictates immediately; there is no intent-selection step.
3. Cadence transcribes locally and creates processed dictation.
4. Cadence resolves an immutable app environment, preset, and custom-guidance snapshot locally.
5. Cadence freshly verifies the target before provider egress.
6. Cadence sends the allowlisted provider input and shows a polishing progress state, including the existing slow-request affordance.
7. Cadence validates the response and opens mandatory review.
8. The user explicitly chooses Insert, Copy, Retry Polish, Insert Unpolished, or Discard.
9. Insert freshly verifies the pinned original target. A stale or changed target enters insertion recovery without another provider request.
10. Insert, Copy, or Discard clears all content-bearing action state. Cadence keeps no disk-backed Scribe content journal.

## Review and insertion

- Provider output never inserts automatically.
- Review clearly distinguishes the polished draft from the unpolished processed dictation.
- Insert targets the originally pinned application and accessibility element, not whichever application happens to be frontmost later.
- Copy is an explicit successful exit and clears the active action after writing to the clipboard.
- Insertion failure preserves the actionable draft and offers recovery without regeneration.
- Discard clears the processed dictation, provider request, draft, target, environment, custom guidance, and literal state.

## Retry, fallback, and failure

- **Retry Polish** reuses the same immutable request snapshot and re-verifies target safety before egress. It does not capture new audio or silently change provider/model/preset/custom guidance.
- **Re-record** starts a new action with a new target and configuration snapshot.
- A provider error, timeout, cancellation, malformed response, empty response, or exact-literal failure preserves the processed dictation and offers Retry Polish, Insert Unpolished, Copy Unpolished, Re-record, or Discard as applicable.
- Cadence never silently inserts unpolished text after a provider failure.
- Empty local transcription makes no provider call and offers Re-record or Discard.
- A changed or unverifiable target before egress makes no provider call and preserves the processed dictation for copy, re-record, or discard.
- A changed target after review refuses insertion and preserves the polished draft in insertion recovery.
- Late or duplicate provider completion is ignored after cancellation, retry supersession, or terminal exit.

## Non-overridable safety order

Instructions are applied in this order:

1. Cadence privacy, target, literal, and meaning-preservation contract.
2. Reusable environment preset.
3. Additive app-specific custom guidance.
4. Processed dictation as data to polish, never as provider instructions.

Lower layers cannot override higher layers. Custom guidance that conflicts with a higher layer is ignored or rejected during configuration; it is never allowed to authorize ambient context or invention.

## Baseline changes required

- Remove `ScribeIntent` from the primary state and request model, along with `choosingIntent` and intent-specific provider capabilities.
- Replace instruction-oriented request policy, environment instructions, panel copy, quality corpus, UI fixtures, privacy copy, disclosures, tests, dogfood scenarios, and release evidence.
- Preserve the hardened provider controller, Keychain lifecycle, transport, pinned-target verification, local processing, exact-literal protection, review, retry snapshot, insertion recovery, late-result suppression, diagnostics, and content clearing from PR #34.
- Generalize exact-literal normalization from the current hard-coded Claude Code condition to the resolved preset/environment contract.

## Acceptance contract

- Ordinary prose, Slack-style messages, and coding-agent prompts retain every user claim, requested action, factual detail, number, identifier, and exact literal while improving expression.
- Dictated instructions such as “refactor the authentication service” remain polished instructions; Scribe does not produce the refactor or code.
- No selected or ambient app content appears in any provider request.
- Provider failure never loses the processed dictation and never inserts fallback text silently.
- Retry Polish is byte-for-byte stable in its processed dictation and configuration snapshot; Re-record is observably a new action.
- Every provider result is reviewed before insertion, and target changes fail closed at both egress and insertion boundaries.
- Repeated successful, copied, discarded, cancelled, failed, and recovered actions leave no content-bearing Scribe state behind.

## Map impact

No new Wayfinder ticket is required. Provider-specific request contracts remain with the provider ticket; preset and custom-guidance definitions remain with the app-environment ticket; UI presentation belongs to the Settings/control-system prototype. This decision removes selected-text Respond/Edit behavior from the active destination rather than creating a hidden compatibility path.
