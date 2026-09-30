# Compose surface capability record

This record separates generic Compose behavior from verified app-specific
context. An app name or window title never grants conversation memory. The
capabilities below are development status, not a claim that every editor in an
app works. A locally signed, unnotarized Release candidate from this dirty
checkout replaced the single installed Cadence app on September 27 for a trial;
the prior app remains backed up under `Build/Goal1Trial/`. This does not certify
the live Compose or Muse insertion paths.

## TextEdit saved documents: candidate surface

Observed local candidate on September 27, 2026: Apple TextEdit at
`/System/Applications/TextEdit.app`, bundle identifier `com.apple.TextEdit`,
version 1.20 (415), signed by macOS Software Signing. These details came from
the local app bundle; a changed app version requires renewed surface evidence.

| Capability | Current boundary | Evidence and certification state |
| --- | --- | --- |
| Generic draft | Voice can make a draft without reading TextEdit content. | Existing Compose path; provider quality gates remain open. |
| Insertion | The generic guarded AX/CGEvent path may insert into a verified focused editor. | Controlled native/WebKit host passed 18/18. The reusable current-source production-service probe passed exact synthetic insertion in TextEdit 1.20 (415); report: `Build/ComposeRoadmap/U17-textedit-surface/current-source-insertion-report.json`. Signed installed-app certification remains. |
| Selected-text rewrite | Requires a separately enabled TextEdit selection grant and a fresh pinned selection. | A current-source standalone probe used a fresh synthetic saved TextEdit document and passed actual selected-text capture, revalidation, guarded replacement, and exact AX readback. Report: `Build/ComposeRoadmap/U17-textedit-surface/run.6OMg4K/report.json`. This is development Debug-module evidence; installed-app and model-written rewrites remain unverified. |
| Conversation identity | Only a saved regular file in the focused `AXTextArea` of Apple's system TextEdit path can yield a durable document key. | Prior controlled TextEdit probes verified A→B→A, close/reopen, process restart and same-path replacement fencing. Current path and surface-signature changes pass 9 focused native tests. A current-source synthetic saved-document probe passed against TextEdit 1.20 (415); its content-free report is `Build/ComposeRoadmap/U17-textedit-surface/current-source-report.json`. Broader current-source live cases and a signed Cadence candidate remain. |
| Session facts and chosen drafts | Explicit voice save/inspect/forget/correct for facts, plus a separate default-off control that remembers reviewed local drafts after successful Copy or confirmed Insert. Both are scoped to the verified saved document; chosen drafts are labeled without delivery proof and never become facts. | Synthetic lifecycle, consent and coordinator tests pass; installed-app voice and choice flows remain unverified. |
| Persistent facts | Separately confirmed encrypted local store and per-fact proposals, default off. | Synthetic store and Keychain-backend tests pass; signed-app Keychain and live confirmation flow remain unverified. |
| Screenshot context | No TextEdit window capture adapter is registered. | Unsupported. |
| Cloud transmission of saved facts | No cloud provider receives saved memory facts. | Explicitly denied by the current policy. |

An unsaved document, search field, navigation control, editor belonging to a
different process, nonfocused window, or app merely claiming TextEdit's bundle
identifier cannot establish document memory identity. The adapter now requires
the canonical system TextEdit bundle path. Unsupported identity leaves generic
drafting available only under its existing target and provider rules; it never
falls back to title-based memory lookup.

The next certification gate uses synthetic files in a fresh TextEdit instance
and records the app version, Cadence build identity, and content-free outcomes.
It must separately confirm editor insertion; selected-text rewrite; refusal on
search, navigation, unsaved and unrelated windows; A/B document isolation;
same-path replacement; and no provider or memory access after opt-out. A signed
Cadence candidate then needs the same intended version and permission state.
No private document or customer conversation is a fixture.

ChatGPT, Codex, Muse and browser support threads have no conversation-identity
adapter or memory certification in this record. They retain only the generic
Compose paths that individually pass their target and provider checks. Each
surface needs its own identity and insertion evidence before a support claim.
In one September 30 probe of the active Codex desktop app (bundle
`com.openai.codex`, version 26.928.20755), the focused window's `AXDocument`
was empty and 11 inspected accessibility descendants exposed no nonempty URL,
document, or identifier attribute. No conversation content or title was
recorded. That view cannot provide a verified per-thread memory key through
the current native AX adapter seam; other Codex views and browser integrations
remain untested. The content-free report is
`Build/ComposeRoadmap/U11-codex-native-metadata/report.json`.
