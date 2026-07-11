# Spoken Code-Literal Capture and Normalization Contract

**Date:** 2026-07-10
**Wayfinder ticket:** [Define spoken code-literal capture and normalization](https://github.com/darshshah981/Cadence/issues/33)

## Decision

Code-literal normalization is local, deterministic, and Scribe-only. It runs after local transcription and before provider request construction. It never reads screen/window/clipboard/nearby text, never calls a provider, never changes the Dictation pipeline, and never guesses an identifier's casing or spelling from ambiguous ordinary speech.

Release one has two layers:

1. **Conservative automatic token patterns** in a resolved Claude Code environment for unambiguous flags and path punctuation.
2. **Explicit literal spans** for exact identifiers, paths, flags, commands, and casing, with user vocabulary aliases as the shortest path for recurring project-specific terms.

The exactness guarantee applies when the local transcript already contains the literal, a user vocabulary alias canonicalizes it, or the explicit literal grammar resolves it. Ordinary phrases that could map to several identifiers remain ordinary text; the cloud model is instructed to preserve them but is not trusted to reconstruct missing casing.

## Pipeline Boundary

The Scribe transcript path becomes:

1. WhisperKit returns local cleaned text.
2. Apply the existing filler/vocabulary policy locally so aliases such as `parse eye dee: parseID` resolve to the user's canonical value.
3. Parse explicit literal spans and conservative Claude Code token patterns into a structured `NormalizedScribeTranscript`.
4. Apply personal shortcut expansion only to non-literal text. User-authored shortcut replacements are kept separate from recognized exact-literal spans.
5. Construct the provider-safe request from normalized prose plus an exact-literal list.

The implementation may use different names, but the value must preserve:

- normalized prose for the spoken request;
- ordered exact literals with stable per-request IDs and source ranges;
- provenance: already exact, user vocabulary, explicit grammar, or safe automatic pattern;
- parse status: clean or needs local repair.

Original and normalized text remain only in the in-memory Scribe session. Neither enters transcript history, recovery files, analytics, OSLog, crash/support payloads, or meeting/Dictation stores.

## Conservative Automatic Patterns

Automatic conversion runs only when the resolved writing environment is Claude Code and the token boundaries are unambiguous:

- `dash dash <one token>` or `double dash <one token>` -> `--<token>`;
- `<token> dot <known extension>` -> `<token>.<extension>`;
- path chains composed of alphanumeric tokens plus spoken `slash`, `dot`, `underscore`, `dash`, `colon`, or `equals`, when at least one structural word appears and every segment is non-empty;
- an already-transcribed token containing code punctuation is preserved exactly.

The bundled extension set is small and release-versioned: Swift, common source/config formats already used by Cadence, and extensions exercised by fixtures. Unknown extensions are not inferred.

Automatic conversion does **not**:

- turn “parse ID” into `parseID`, `parse_id`, or `ParseID`;
- turn “API client” into `APIClient`;
- infer an acronym, capitalize letters, remove spaces between ordinary words, or create a command the user did not mark;
- transform prose in Slack or Other apps;
- modify selected text.

For example, “dash dash verbose” may safely become `--verbose`, while “API client dot swift” can become `API client.swift` only if those are the transcribed tokens. Exact `APIClient.swift` requires a vocabulary alias or explicit literal span.

## Explicit Literal Grammar

The user begins with **literal** and ends with **end literal**. Within the span Cadence recognizes:

- casing modes: `camel case`, `pascal case`, `snake case`, `kebab case`, `lower case`, `upper case`;
- spelling tokens: `capital <letter>`, `lower <letter>`, spoken digits, and already-transcribed single letters;
- symbols: `dot`, `slash`, `backslash`, `underscore`, `dash`, `double dash`, `colon`, `semicolon`, `comma`, `equals`, `at`, `hash`, and paired parentheses/brackets/braces;
- `flag <words>` as `--` plus lower-kebab words;
- quoted/verbatim mode for text that should preserve spaces and punctuation rather than apply identifier casing.

Examples:

| Spoken form | Exact local value |
|---|---|
| `literal camel case parse capital I capital D end literal` | `parseID` |
| `literal pascal case capital A capital P capital I client dot swift end literal` | `APIClient.swift` |
| `literal flag verbose end literal` | `--verbose` |
| `literal snake case user capital I capital D end literal` | `user_id` |
| `literal lower case src slash auth dot swift end literal` | `src/auth.swift` |

The parser is a closed grammar. Nested spans, unknown directives, missing symbol operands, unmatched pairs, an empty span, or an unclosed span produce **needs local repair**. Cadence does not send the request. The Scribe panel keeps the local transcript and offers **Use spoken words**, **Record request again**, and **Cancel Scribe**. “Use spoken words” removes the unresolved literal instruction and proceeds with the original local transcript; it never invents an exact value.

## User Vocabulary and Shortcuts

The existing vocabulary format is the preferred recurring-term mechanism:

```text
parseID: parse eye dee, parse I D
APIClient.swift: API client dot swift
--verbose: dash dash verbose
```

Vocabulary aliases canonicalize locally before literal parsing and never leave the Mac as a vocabulary list. Only the canonical term that appears in the current request may be sent.

Personal shortcuts remain a separate template feature. They expand only after literal parsing so a shortcut trigger cannot match inside an exact span. A shortcut's replacement is not automatically labelled as a code literal; users who require provider-level exact preservation should make the canonical replacement an explicit literal or vocabulary term.

## Provider Request Contract

The normalized value replaces the spoken form in the `Spoken request` section. When exact literals exist, append:

```text
Exact literals — preserve each value byte-for-byte:
- <literal id="1">parseID</literal>
- <literal id="2">--verbose</literal>
```

The fixed system message already requires preservation of code literals, paths, identifiers, flags, and commands. Provider output still passes `ScribeOutputPolicy`; additionally, every exact literal required by the task must remain present byte-for-byte unless the user's task explicitly asks to remove or rename it. A missing or altered required literal is an invalid provider result and stays out of insertion.

The review surface shows one accessible, non-editable summary such as **Exact literals: `parseID`, `--verbose`**. It does not expose the original spoken aliases to the provider. Retry reuses the exact same normalized transcript and literal list.

## Responsiveness and Pipeline Isolation

- The parser is a pure, linear local transformation with a bounded input and no I/O. The target budget is under 5 ms for the maximum Scribe transcript fixture.
- Run it after transcription, never in microphone/audio callbacks.
- Do not change `DictationCoordinator`, Dictation insertion spacing, meeting transcription, or meeting storage as part of this feature.
- Scribe continues using its separate transcription engine and voice-session lease.
- Parser failure is a local Scribe recovery state; it never becomes a provider error.

## Verification Contract

Tests must cover:

1. Table-driven parsing of every grammar mode, symbol, path/flag pattern, acronym spelling, casing rule, and example above.
2. No transformation of ambiguous “parse ID”/“API client” prose, Slack/Other apps text, selected context, or unrelated uses of words such as “dot” and “dash.”
3. User vocabulary canonicalization precedes parsing; shortcut matching cannot alter literal spans.
4. Malformed/unclosed/nested/empty literal spans make zero provider calls and expose the three local recovery actions.
5. Provider request snapshots contain normalized text/exact-literal list and no vocabulary/alias catalog, app identity, or ambient context.
6. Retry reuses identical literals; a new action discards them.
7. Provider results that unexpectedly alter a required literal never reach insertion; a rename/remove task may change it only when the task explicitly authorizes that change.
8. Real-audio fixtures across the supported Whisper models for `parseID`, `APIClient.swift`, `--verbose`, paths, commands, numbers, URLs, and mixed prose.
9. Parser timing under the 5 ms target and no regression in Dictation latency or meeting durability.
10. Canary literals never appear in history, stores, logs, analytics, support exports, or crash payloads.

## Repository Evidence

- `Cadence/Services/ScribeCoordinator.swift` currently takes WhisperKit `cleanedText`, applies personal shortcuts, and sends the string to the provider; it does not apply the existing vocabulary post-processor or preserve literal provenance.
- `Cadence/Models/DictationModels.swift` already defines `VocabularyEntry` and deterministic alias replacement suitable for reuse as a pure local helper.
- `Cadence/Services/ShortcutExpansionService.swift` provides token-boundary and scope-aware local replacement but currently returns an unstructured string.
- `Cadence/Services/WhisperKitTranscriptionEngine.swift` returns local cleaned text and does not require a remote literal service.
- `CadenceTests/PersonalizationTests.swift` and `CadenceTests/CadenceTests.swift` provide current shortcut/vocabulary fixtures to extend.
