# Cadence Privacy

Cadence is designed as a local dictation app for macOS.

## Audio

Cadence records audio only while you are using dictation or meeting capture. Audio is processed locally for transcription and is not sent to Cadence analytics.

## Transcripts

Cadence stores recent dictation transcripts locally on your Mac so you can copy them again from the menu bar. Meeting notes, saved meeting audio, transcripts, and summaries stay local on your Mac. Transcript text is not sent to analytics.

## Permissions

Cadence asks macOS for:

- Microphone access, so it can record while you dictate.
- Accessibility access, so it can insert text into the focused app.
- Input Monitoring access, so global shortcuts work when other apps are active.
- Screen Recording access, so meeting capture can capture system audio. Cadence excludes its own process audio from system-audio capture.

## Analytics

Analytics are optional and off by default. If enabled, Cadence sends privacy-safe product events such as:

- App launch.
- Permission setup status.
- Settings changes.
- Dictation started, completed, or failed.
- Meeting capture started, stopped, completed, or failed.
- Coarse duration and character-count buckets.

Analytics do not include:

- Audio.
- Transcript text.
- Vocabulary terms.
- Exact shortcut keys.
- Dictated app names.
- Raw error messages.
- Saved meeting audio.

Analytics can be turned off at any time in Cadence Settings.

## Contact

For questions about Cadence privacy, contact Darsh Shah.
