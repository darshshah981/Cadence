# Define shared domain language

Type: grilling
Status: resolved
Claimed by: opencode
Blocked by:
Parent: ../map.md

## Question

What canonical domain terms should the plan use for Cadence's capture, transcript, note, speaker, trust, and rehearsal concepts?

Resolve overloaded language before feature contracts are written. At minimum, decide the meaning and boundary of capture session, recording, meeting note, crash-first ledger, live draft, final pass, working note, speaker ledger, trust surface, readiness, recovery, and rehearsal. If terms are settled, update `CONTEXT.md` per the domain-modeling skill.

## Comments

## Answer

Shared domain language is now fixed in [CONTEXT.md](../../../CONTEXT.md). The decisions that shaped it:

- **Capture session is the root identity**, durable from the first audio frame; recordings and the meeting note are its children. This inverts today's code, where the session points at a noteID and recording metadata only lands on the note after stop.
- **Ledger** = the capture session's persisted on-disk state (what recovery reads). Internal term only, never user-facing. Not a synonym for the live session, and not a full event log.
- **Recording** = one CAF audio artifact + metadata; a session owns one or more (multi-source, or pause/resume). Segment `recordingID` scopes final-pass replacement.
- **Transcript is owned by the session** (via recordingID → recording → session); the meeting note composes/renders it, not the other way around.
- **Meeting note** = the document (child of session), composing transcript + summary + working note. **Working note** = the editable human + AI layer inside it. Two layered nouns, not synonyms.
- **Live draft** = during-capture segments; **final pass** = the re-transcription process; **final transcript** = its output. Process/output split, invariant retained (empty output = failure, live draft kept).
- **Speaker ledger is per-meeting to start**; cross-meeting identity graduates later. **Speaker** = real-world identity; **speaker turn** = an attributed segment; **capture-source proxy** = today's `TranscriptSpeaker` auto-label, explicitly not diarization; **speaker ledger** = the per-meeting store of Speakers and turn assignments.
- **Trust surface** = umbrella for all trust UX. Internally it splits into **readiness** (pre-flight state), **data boundary** (what stays local vs. leaves — privacy as its own noun), and **recovery** (post-failure). **Rehearsal** = a distinct user-run action that exercises readiness and proves the data boundary.

Frontier change: closing this ticket newly unblocks [Research speaker attribution options](08-research-speaker-attribution-options.md) (it was blocked only by 02).
