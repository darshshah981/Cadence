# Cadence

Cadence is a native macOS menu-bar app for spoken work: fast local dictation and durable, private meeting capture. This glossary fixes the canonical language for the meeting-capture domain. Dictation has its own settled vocabulary and is out of scope here.

## Capture lifecycle

**Capture session**:
The root identity of a single meeting capture, durable from the first audio frame. Owns its recordings, its transcript, and its meeting note, and survives crashes.
_Avoid_: meeting (ambiguous with the note), capture (too generic)

**Ledger**:
The persisted, on-disk state of a capture session — the durable form that recovery reads. An internal architecture term only; never shown to users.
_Avoid_: record, log, database

**Recording**:
A single audio artifact (one CAF file and its metadata) produced during a capture session. A session owns one or more recordings (multi-source, or pause/resume).
_Avoid_: track, clip, capture

**Transcript**:
The sequence of transcript segments for a capture session. Owned by the session (segments carry the recording they came from); the meeting note composes and renders it rather than owning it.
_Avoid_: text, notes (collides with the note)

## Transcript lineage

**Live draft**:
Transcript segments produced during active capture, shown as the rolling preview. Both a segment origin and a state.
_Avoid_: draft, preview, partial

**Final pass**:
The process of re-transcribing saved audio after stop, scoped to one recording. Not its own output.
_Avoid_: finalization (vague), retranscription

**Final transcript**:
The output segments a completed final pass produces. A final pass replaces only live-draft segments from its own recording; empty output is failure, so the live draft is retained.
_Avoid_: final text, clean transcript

## The note

**Meeting note**:
The document that is a capture session's human-facing artifact, and a child of the session. Composes the transcript, the summary, and the working note.
_Avoid_: note (ambiguous), document

**Working note**:
The editable, human-authored and AI-augmented layer inside a meeting note, distinct from the machine-generated transcript.
_Avoid_: notes, scratch pad, summary (the summary is its own thing)

## Speakers

**Speaker**:
A real-world identity (a person) attached to speaker turns, editable, with a durable corrected name. Per-meeting to start; cross-meeting identity is a future graduation.
_Avoid_: participant, diarization label

**Speaker turn**:
A transcript segment attributed to a Speaker.
_Avoid_: utterance, chunk

**Capture-source proxy**:
The automatic label derived from capture source (you / system audio / mixed / unknown). Explicitly not a true Speaker — a placeholder a Speaker can be promoted into. Not diarization.
_Avoid_: speaker label (implies real identity)

**Speaker ledger**:
The per-meeting, editable store of Speakers and their turn assignments.
_Avoid_: speaker list, roster

## Trust UX

**Trust surface**:
The umbrella for all user-facing trust UX across first launch, prompts, active recording, export, and errors. User-facing.
_Avoid_: trust page, privacy settings

**Readiness**:
The pre-flight state of whether capture can start now — permissions granted, source selected, capture healthy.
_Avoid_: status, setup

**Data boundary**:
What stays on the Mac versus what leaves it: local storage by default; analytics opt-in and coarse-only; export and copy are the moments data leaves. The privacy axis, distinct from readiness.
_Avoid_: privacy (too broad), permissions (that is readiness)

**Recovery**:
The post-failure path after a crash, an interrupted final pass, or an orphaned recording — the mirror of readiness (before) applied after the fact.
_Avoid_: restore, repair

**Rehearsal**:
A private, user-run pre-flight capture test that exercises readiness and proves the data boundary before a real call. An action, not a state.
_Avoid_: test call, dry run (implies a live call)
