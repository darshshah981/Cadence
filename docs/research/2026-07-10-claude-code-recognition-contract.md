# First-Slice Claude Code Recognition Contract

**Date:** 2026-07-10
**Wayfinder ticket:** [Define first-slice Claude Code recognition under the app-identity-only boundary](https://github.com/darshshah981/Cadence/issues/30)

## Decision

Release one recognizes **only the prompt field in the Code tab of Claude Desktop for macOS**. It does not recognize the Claude Code CLI inside Terminal/iTerm/Warp, the VS Code or JetBrains extensions, browser sessions, generic IDE editors, Claude Desktop Chat/Cowork prompts, or Claude Desktop's integrated terminal and file editor.

Claude Code officially spans CLI, Desktop, VS Code, JetBrains, web, and other integrations. Those surfaces share host applications with unrelated work. A Terminal bundle identifier cannot prove that its focused field is a Claude Code CLI prompt; a VS Code bundle identifier cannot distinguish the Claude Code panel from a source editor, integrated terminal, search box, or another extension; and Claude Desktop itself contains distinct Chat, Cowork, and Code tabs. Bundle-only recognition would therefore create false positives and violate the approved fail-closed context boundary.

## Supported Recognition Rule

A target resolves to **Claude Code · Precise** only when every condition holds:

1. The pinned target's bundle identifier exactly matches the release-bundled Claude Desktop identifier. The first catalog candidate is `com.anthropic.Claude`; the signed app's `CFBundleIdentifier` must be captured and asserted during release certification rather than inferred from its display name.
2. The focused accessibility element matches a release-certified **Code prompt signature** made only from non-content UI metadata:
   - AX role and subrole;
   - stable `AXIdentifier` values for the focused prompt and the minimum necessary ancestor chain;
   - the opaque focused element/window identity already pinned for insertion safety.
3. Exactly one recognition rule matches. A missing identifier, unsupported role, conflicting match, or changed/unknown signature resolves to **Other apps · Neutral**.
4. The same pinned target signature supplies both environment recognition and later insertion verification. Recognition is resolved once per Scribe action and never re-read or hot-swapped during generation/retry.

The recognizer must never read or match `AXTitle`, `AXValue`, `AXDescription`, window titles, nearby text, project names, file paths, conversation content, clipboard data, pixels, OCR, shell process arguments, terminal contents, or selected text except through the separately authorized Respond/Edit path. The signature stays on the Mac and is absent from provider requests, analytics, support exports, and logs.

## Release-Bundled Recognition Catalog

The catalog entry should contain:

- stable environment ID `claude-code`;
- exact bundle identifier;
- one or more tested Code-prompt accessibility signatures;
- the Claude Desktop version/build on which each signature was captured;
- the Cadence version that introduced/certified it;
- a human-readable supported-surface label: **Claude Code in Claude Desktop**;
- negative fixture signatures for Chat, Cowork, integrated terminal, file editor, diff, search, settings, and generic text fields.

An app update may continue to match when the certified non-content signature is unchanged. If it changes, Cadence fails to Other apps rather than guessing. Recognition updates ship only with a Cadence release; there is no remote signature catalog.

The implementation may use different Swift names, but the model needs an explicit `TargetRecognitionSignature` separate from `ScribeTargetIdentity`. `ScribeTargetIdentity` currently contains only PID and bundle ID; the new signature adds only the allowlisted AX metadata above. It is not a context artifact and carries no authority to read content.

## Explicitly Unsupported First-Slice Surfaces

| Surface | First-slice result | Reason |
|---|---|---|
| Claude Code CLI in Terminal, iTerm, Warp, or an IDE terminal | Other apps · Neutral | Host app identity and generic terminal AX metadata cannot prove the foreground command/session is Claude Code. |
| VS Code Claude Code extension | Other apps · Neutral | `com.microsoft.VSCode` and a generic editor/webview field do not prove the active field is the Claude Code prompt without a separately certified extension signal. |
| JetBrains Claude Code extension | Other apps · Neutral | Same ambiguity across editor, terminal, search, and plugin surfaces. |
| Claude Code on the web | Other apps · Neutral | Browser bundle identity cannot prove site, tab, or focused web app without reading URL/title/content. |
| Claude Desktop Chat or Cowork prompt | Other apps · Neutral | The same Claude app hosts non-Code products with different writing needs. |
| Claude Desktop integrated terminal/file editor/diff | Other apps · Neutral | These are work panes, not the Code conversational prompt. |
| Claude Desktop Code prompt with a certified signature | Claude Code · Precise | Exact local app plus exact non-content surface signature. |

No manual “treat all of Terminal/VS Code/Claude as Claude Code” toggle ships in release one. It would persist a known false-positive mapping. Future support for CLI/IDE/web requires a separate integration signal—for example an extension-owned local handshake or user-invoked one-action scope—not broader AX/content inspection.

## User Experience and Recovery

- Settings names the supported surface **Claude Code in Claude Desktop** and says other Claude Code surfaces currently use Other apps behavior.
- If a previously recognized Claude Desktop update no longer matches, Scribe remains usable with **Other apps · Neutral** and Settings shows a privacy-safe recovery: “This Claude Code surface is not recognized by this Cadence version. Update Cadence or use Other apps behavior.”
- The review cue says **Claude Code · Precise** only for a certified match. It never derives from the app display name.
- A retry reuses the original resolved snapshot. A new action re-pins and re-evaluates the current target.

## Verification Contract

Implementation and release evidence must prove:

1. The signed current Claude Desktop app exposes the catalogued bundle identifier and Code-prompt signature.
2. Dictating in the Code prompt resolves Claude Code · Precise and sends only compiled instructions, never identity/signature fields.
3. Chat, Cowork, integrated terminal, file editor, diff, search, Settings, and generic Claude text fields all resolve Other apps · Neutral.
4. Terminal/iTerm/Warp, VS Code, JetBrains, and supported browsers resolve Other apps even while a Claude Code process/extension/session exists.
5. Missing/changed/duplicate signatures fail closed and surface the Settings recovery without blocking Scribe.
6. Focus changes during a request do not hot-swap the environment; stale insertion is rejected; a new action resolves afresh.
7. The recognition path performs no screen capture, clipboard read, window-title read, general AX text read, process-argument inspection, network request, or analytics emission containing app identity.
8. Release certification records the tested Claude Desktop version and reruns the negative matrix before shipping.

If the signed app does not expose a stable non-content Code-prompt signature, the release gate fails. Cadence must not broaden recognition to the whole Claude app to make the test pass.

## Repository Evidence

- `Cadence/Models/ScribeModels.swift` models target identity as PID plus optional bundle identifier.
- `Cadence/Services/ScribeContextService.swift` pins an AX element/window, reads the running app bundle identifier, and currently keeps role/subrole local for secure-field checks.
- `Cadence/Services/ScribeCoordinator.swift` resolves app-scoped behavior once and retains the immutable request for retry.
- `CadenceTests/ScribeCoordinatorTests.swift` already proves local style can affect a request without sending app identity.

## Primary Sources

- [Anthropic — Platforms and integrations](https://code.claude.com/docs/en/platforms) documents Claude Code across CLI, Desktop, VS Code, JetBrains, web, and other surfaces.
- [Anthropic — Get started with the desktop app](https://code.claude.com/docs/en/desktop-quickstart) documents the single Claude app's distinct Chat, Cowork, and Code tabs.
- [Anthropic — Use Claude Code Desktop](https://code.claude.com/docs/en/desktop) documents Code-tab prompt/session behavior and the `com.anthropic.Claude` macOS preference domain used for managed configuration.
- [Anthropic — Use Claude Code in VS Code](https://code.claude.com/docs/en/ide-integrations) documents the extension panel alongside editors and the integrated terminal.
- [Apple — NSRunningApplication](https://developer.apple.com/documentation/appkit/nsrunningapplication) documents bundle identity as fixed application metadata.
- [Apple — AXUIElement](https://developer.apple.com/documentation/applicationservices/axuielement_h) documents the local accessibility element interface used by the existing target seam.
