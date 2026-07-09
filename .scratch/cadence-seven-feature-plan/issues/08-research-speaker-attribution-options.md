# Research speaker attribution options

Type: research
Status: resolved
Claimed by: opencode
Blocked by: 02
Parent: ../map.md

## Question

What speaker-attribution options are realistic for a local-first macOS app built around WhisperKit and saved meeting audio?

Research repo constraints and current external options such as editable source labels, manual speaker turns, local diarization, WhisperX-style alignment, pyannote-style diarization, and hybrid approaches. Produce a linked markdown asset comparing feasibility, privacy, packaging, performance, UX risk, and testing implications.

## Comments

## Answer

Research asset: [research/08-speaker-attribution-options.md](../research/08-speaker-attribution-options.md).

Recommendation for ticket 09: **stage it — editable speaker turns over capture-source proxies first (no model), local diarization deferred.** Today's `TranscriptSpeaker` is a capture-source proxy, not identity; the honest, zero-packaging-risk move is the editable-speaker-ledger primitive (option 2): user creates/renames/merges/splits Speakers and assigns turns over existing segments. Local diarization (pyannote/WhisperX-style) is the future prize but carries a new model pipeline, CoreML/ONNX packaging Cadence doesn't have, an offline pass over saved audio, and fixture-based testing — gated on a verified packaging/perf spike before building. All options are local-first (privacy boundary holds); cross-meeting identity stays out (per-meeting, ticket 02).

External specifics (model sizes, CoreML conversion, pass-time vs. recording length) flagged for verification at implementation time.
