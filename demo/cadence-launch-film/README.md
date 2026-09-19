# Cadence — Write it out loud

A 52-second, 1920 × 1080 launch film rendered at **60 fps**. Fictional sample content moves through live transcription, locked recording, Command-to-Compose, draft review, and insertion. The title frame and every product surface use a neutral, authored workspace.

## Delivery

- `cadence-launch-60fps.mp4`: review film with ElevenLabs demo speech and original sound design; no explanatory narration.
- `cadence-launch-silent-60fps.mp4`: silent variant for autoplay placements.
- `poster.png`: opening brand frame.
- `contact-sheet.png`: scene overview for review.
- `captions.srt`: optional subtitle track.
- `index.html`: editable composition.
- `DESIGN.md` and `storyboard.md`: art direction and scene plan.

## What is real and what is illustrated

The user explicitly authorized a staged runtime and scripted real-time transcription. This film is **illustrative**, not a screen recording or performance benchmark of the shipping app. The Drafts window is fictional. No personal desktop, account, saved prompt, conversation, transcript history, credential, or microphone recording is included. The persistent on-screen label says “Illustrative demo · sample content.”

The icon comes from `Cadence/Assets.xcassets/AppIcon.appiconset/AppIcon.svg`, with transparent corners. The recording pills are **native SwiftUI renders of this checkout's actual HUDView, HUDViewModel, waveform motion, chrome, spinner, and lock components**, not CSS recreations. Source hashes are in `assets/native-hud-provenance.json`. The offline capture clock samples the real motion at 60 fps; the invisible mouse hit-target and unused expanded tray are omitted because this is a passive film. Omitting the hit-target fixes ImageRenderer's prohibited-symbol placeholder in the inactive pill. The fictional Drafts target uses a generic document symbol. This is source-rendered presentation, not a recording or benchmark of the installed app.

Speech uses ElevenLabs Eleven v3, Roger, with conversational and matter-of-fact tags. Only fictional dictation and its spoken Compose instruction are voiced. Both clips play at their original 1x speed (7.36 and 6.40 seconds), with no time-stretching. Text appears using returned word-end timestamps. The waveform responds to the generated voice, using Cadence's envelope formula and native attack/release smoothing. All surrounding graphics and the music bed were authored for this film.

**Commercial release gate:** The API identified this account as free-tier. This audio is for private review, not a commercial launch. Regenerate both clips during a paid subscription before commercial distribution. See https://help.elevenlabs.io/hc/en-us/articles/13313564601361-Can-I-publish-the-content-I-generate-on-the-platform. A later upgrade does not retroactively license these generations.

## Reproduce

Run `bash render.sh` from this directory. The composition and audio assets are included; no API key is required to render them. `elevenlabs_speech.py` generates or reuses cached speech and mixes it with `assets/music-bed.wav`; it requires Python, numpy, soundfile, and ffmpeg. Supply a key through ELEVENLABS_API_KEY or stdin, never a source file. To regenerate under a paid subscription, archive the two `*-workplace.json` caches first. The script will make two new requests. If natural-speed speech outgrows a scene, the script stops so the scene can be extended instead of accelerating the voice. `audio_studio.py` is a legacy generator, not part of the current workflow.

To rebuild native HUD frames on macOS from this repository: run `node native_hud_build.mjs`, `.venv/bin/python native_hud_assets.py`, `.native-hud/render`, then `.venv/bin/python native_hud_assets.py --pack`. The Swift build reads production sources without changing them or launching/installing Cadence Debug. It requests no microphone, accessibility, or screen-recording access. Included atlas assets are sufficient for ordinary film renders.

The renderer is pinned to HyperFrames 0.4.34. The animation source uses a local GSAP asset. Native system fonts are used for the UI; the compiler embeds its resolved font faces for render consistency.

## Review boundaries

The live-text reveal, precise timing, and transitions are scripted presentation behavior. No speed, availability, model-performance, or end-to-end privacy promise is made. No app configuration or credentials were changed for the film. The earlier real-window tour remains separate under `demo/launch-2026-09-06` and is not used by this composition.
