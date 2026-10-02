# Cadence current development status

Updated October 2, 2026. This page is the authoritative current status. The [full roadmap](plans/2026-09-22-0042-feat-compose-feature-roadmap-plan.md) describes future scope; [archived evidence](archive/compose-roadmap-history-2026-10-02.md) records historical checks and failures.

## Authoritative workspace

Develop in `/Users/darshshah/Documents/My Projects/Coding Projects/Cadence` on `codex/stabilize-cadence`. The recovery clone at `/tmp/cadence-compose-git-recovery/Cadence` becomes an archived, non-development copy after consolidation. `main` remains the last published baseline; this local branch contains the reconciled work and is not yet pushed.

The original pre-consolidation source is recoverable at `codex/preserve-pre-consolidation-2026-10-02` (`fd35540147847b4f34a324841b595c18c4b14411`). The prior recovery head is preserved at `codex/preserve-recovery-2026-10-02` (`5ee468f68a30900ce89aa6bd9247e4c8a83593b0`). Private snapshots, file reconciliation decisions, verification logs and complete Git bundles are under `/Users/darshshah/.codex/cadence-compose-staging-2026-09-30/evidence/stabilization-2026-10-02/`. Existing unrelated branches and the Calendar worktree are retained.

The original files were compared against the first recovery checkpoint and the latest recovery version. Matching work is retained; earlier policy and test variants are preserved in the snapshot rather than replacing later fixes. Original historical documentation is retained in that snapshot, and the recovery chronology is archived here. The generated Xcode project is rebuilt from `project.yml`.

## Available core behavior

| Feature | Current evidence | Limit |
| --- | --- | --- |
| Local Dictation | Existing WhisperKit capture/transcription/insertion pipeline retained. | Consolidation does not establish every microphone/device condition. |
| Direct Compose using OpenAI | Installed connection and enabled provider observed. Frozen 20-request supported-family reserve yielded 20 useful results, including 18 model generations and two prepared notes. | No universal or novel-family writing-quality claim. |
| Compose review and guarded insertion | 48 focused insertion/context checks and 18 controlled editor cases passed at the preceding checkpoint. Installed Muse retry showed one unsent result exactly matching saved history; user confirmed no foreground jump. | One live Muse trial; automation did not observe microphone capture or the pre-insertion review. |
| TextEdit insertion | Prior single exact editor/history match observed. | That trial's trigger-time foreground behavior remains unconfirmed. This is a historical live-check limitation, not a stabilization blocker. |

## Unfinished previews

Ordinary Dictation and direct Compose remain enabled. Context, memory, conversation-adapter and persistent-memory rollout defaults are off. Explicit existing rollout overrides remain respected. Rollout overrides never grant content capture, retention or transmission: those require their separate consent settings. No new background collection is introduced.

| Roadmap area | Groundwork retained | Remaining delivery |
| --- | --- | --- |
| U1–U4 Writing quality/provider routing | Evaluation exports, direction parsing, meaning guards, provider setup and immutable task budgets. | Broader provider quality and semantic coverage. |
| U5–U6 Insertion/responsiveness | Focus-preserving insertion, duplicate/target guards, timing and presentation tests. | Broader live app coverage and measured end-to-end latency/frame evidence. |
| U7 Voice refinement | Local-provider revision/Undo and stale-version protection. | OpenAI refinement and installed interaction certification. |
| U8–U10 Context capture | Separate consent, TextEdit selection and explicit window/OCR recovery. | Live permission/picker certification, selected rewrite quality and cloud integration. |
| U11 Conversation identity | Saved TextEdit document adapter with isolation checks. | ChatGPT, Codex, Muse and browser conversation adapters. App names or titles are insufficient identity. |
| U12 Grounded replies | Local bounded source compiler and narrow reply/meaning checks. | Real conversation sources, broader grounded output and OpenAI context support. |
| U13 Session memory | Scoped explicit fact commands, correction/expiry/forget and local draft use. | Installed complete voice flow and OpenAI memory use. |
| U14 Saved memory | Encrypted local store, proposals and deletion/correction contracts. | Signed app save/reopen/correct/delete certification. Defaults remain off. |
| U15 Writing preferences | Saved global/TextEdit choices and precedence. | Reliable provider adherence and wider app/project profiles. |
| U16–U17 Quiet controls/app support | Context/fact inspectors and TextEdit pilot. | Installed focus/layout checks and certified additional apps. |
| U18 Release resilience | Feature gates, local evidence and build/install safeguards. | Complete distribution certification and notarization. Local signed builds are not distributable. |

## Stabilization verification

Verification is in progress. A final report will record canonical checkout/HEAD, recovery integrity, ignored-secret boundaries, project regeneration, build, existing automated checks and remaining live limitations. No new feature or test harness is being built. Installed Cadence remains the preceding working Release until a verified replacement is ready.

## Next work

Feature work remains paused until stabilization finishes. Memory is the user's preferred next area; choose one small goal and one supported workspace after this checkpoint. Keep capture, retention and OpenAI transmission separate, and verify conversation isolation before using facts in drafts. The overnight heartbeat remains paused.
