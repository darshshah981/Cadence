# Speaker Attribution Options (ticket 08)

Research asset for [Research speaker attribution options](../issues/08-research-speaker-attribution-options.md). Compares options for a local-first macOS app built on WhisperKit with saved meeting audio. Terms per [CONTEXT.md](../../../CONTEXT.md). External specifics (model sizes, packaging) are flagged for verification at implementation time.

## Repo constraints (facts)

- Transcript segments already carry `speaker: TranscriptSpeaker` — but the values are **capture-source proxies** (`.user`/`.systemAudio`/`.mixedAudio`/`.unknown`), set by `AppModel.transcriptSpeaker(for:)` from the capture source. Not identity (`MeetingModels.swift:311`, `AppModel.swift:1770`).
- No diarization runs today; no speaker-identity store exists.
- WhisperKit is already a dependency and downloaded on demand to `~/Library/Application Support/Cadence/WhisperKit`. Any second model pipeline (diarization) would need its own packaging/download story.
- Privacy boundary (strict): audio, transcript text, and vocabulary never leave the Mac or reach analytics. Any diarization must be **fully local** — no cloud speaker-ID.
- Segments already carry `startTime`/`endTime`/`recordingID`/`origin`, so turn boundaries and source are available for an editable layer without new capture.

## Options compared

| Option | Feasibility | Privacy | Packaging | Perf | UX risk | Testing |
|---|---|---|---|---|---|---|
| **1. Editable source-aware labels** (today's proxy, user-renamed) | High — exists | Local ✓ | None | None | Low, but overclaims if shown as identity | Easy |
| **2. Manual speaker turns** (user split/merge/relabel turns into Speakers) | High — pure UI over existing segments | Local ✓ | None | None | Low; honest ("you assign") | Easy |
| **3. Local diarization** (pyannote/WhisperX-style, ONNX/CoreML) | Medium — new model pipeline | Local ✓ | **Heavy** — new model download, CoreML conversion uncertain | Medium-high (extra pass over saved audio) | Medium — auto labels still need correction | Hard (needs fixtures) |
| **4. WhisperX alignment + diarization** (word timestamps + diarization) | Lower — heaviest | Local ✓ | Heaviest | High | Medium | Hard |
| **5. Hybrid: editable turns now, diarization as optional assist later** | High now, graduates later | Local ✓ | None now | None now | Lowest | Easy now |

## Detail

- **Option 1** is what exists; it is honest only if the UI never presents a capture-source proxy as a real person. Useful as the *seed* for editable turns, not as identity.
- **Option 2** is the editable-speaker-ledger primitive: turns are segments; the user creates/renames/merges/splits Speakers and assigns turns. No model, no overclaim. This is the foundation 02 named (Speaker / speaker turn / capture-source proxy / per-meeting speaker ledger).
- **Option 3** is the "true diarization" prize but carries the most cost: a second downloadable model, a CoreML/ONNX packaging path Cadence doesn't have yet, an extra offline pass over each saved recording, and fixtures for testing. pyannote Community-1 and WhisperX are the cited priors (ideation sources). Packaging/perf numbers **must be verified** before commitment.
- **Option 4** adds word-level alignment — valuable for readability but the heaviest; not justified before option 2 proves the correction workflow.
- **Option 5** sequences 2 → 3: ship editable turns first; add local diarization as an *optional assist* only after the correction workflow is strong. Matches the ideation's explicit staging ("editable turns first, local diarization only after the correction workflow is strong").

## Recommendation (for ticket 09 to consume)

**Stage it: options 1+2 first (editable turns over capture-source proxies, no model), diarization (3) deferred.** Rationale: it ships honest value with zero new model/packaging risk, it is the foundation the domain model already names, and it avoids overclaiming identity Cadence can't back. Local diarization graduates later as an optional assist, gated on a verified packaging/perf spike (verify ONNX/CoreML feasibility, model size, and offline-pass cost before building).

Cross-meeting speaker identity stays out (per 02, per-meeting to start).

## Verify before implementation

- pyannote/WhisperX model availability under a license compatible with distribution; CoreML/ONNX conversion path on macOS 14+.
- Offline diarization pass time vs. recording length on the supported model set.
- That no option requires network egress (privacy boundary).
