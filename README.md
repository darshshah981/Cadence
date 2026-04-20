# Cadence

Fast local dictation for macOS.

![Cadence hero](docs/media/hero.png)

Cadence is a small menu bar app for push-to-talk dictation. Hold a shortcut, speak, release, and Cadence inserts the text into the app you were already using.

## Demo

| Dictate anywhere | Guided permissions |
| --- | --- |
| ![Cadence dictation demo](docs/media/demo-dictation.gif) | ![Cadence permissions demo](docs/media/demo-permissions.gif) |

## Screenshots

| Transcripts | Settings | Permissions |
| --- | --- | --- |
| ![Transcripts](docs/media/screenshot-transcripts.png) | ![Settings](docs/media/screenshot-settings.png) | ![Permissions](docs/media/screenshot-permissions.png) |

## Features

- Hold-to-talk and press-to-start dictation modes.
- Local WhisperKit transcription.
- Direct text insertion into the focused Mac app.
- Guided setup for Microphone, Accessibility, and Input Monitoring permissions.
- Simple quality presets with advanced model/audio controls when needed.
- Optional privacy-safe analytics. Audio and transcript text are not sent to analytics.

## Download

Cadence will be distributed through GitHub Releases.

The release artifact should always be the production app:

```text
Cadence.app
```

Do not distribute:

```text
Cadence Debug.app
```

Once the Developer ID certificate is available, create the GitHub release zip with:

```zsh
scripts/package_release.sh
```

The script builds the Release configuration, notarizes the app, staples the notarization ticket, validates Gatekeeper acceptance, and writes:

```text
Build/Release/Cadence.zip
```

## Setup

On first launch, Cadence asks for the permissions macOS requires for dictation:

- **Microphone** to record while you dictate.
- **Accessibility** to insert text into the focused app.
- **Input Monitoring** so global shortcuts work outside Cadence.

Cadence may ask you to restart the app after granting permissions because macOS sometimes requires a relaunch before new trust settings take effect.

## Privacy

Cadence processes dictation locally. Optional analytics are disabled by default and do not include audio, transcript text, vocabulary terms, exact shortcut keys, or dictated app names.

Read the privacy note: [docs/privacy.md](docs/privacy.md)

## Development

Install the debug app locally:

```zsh
scripts/install_dev_app.sh
```

Run tests:

```zsh
xcodebuild test -project Cadence.xcodeproj -scheme Cadence -configuration Debug -destination 'platform=macOS' -quiet
```

Regenerate the Xcode project after changing `project.yml`:

```zsh
xcodegen generate
```

## Release Checklist

Before publishing a GitHub Release:

- Build `Release`, not `Debug`.
- Confirm the app name is `Cadence.app`, not `Cadence Debug.app`.
- Sign with `Developer ID Application`.
- Notarize and staple.
- Verify with `spctl`.
- Upload `Build/Release/Cadence.zip`.
- Include the screenshots and GIFs from `docs/media`.
