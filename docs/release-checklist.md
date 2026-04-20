# GitHub Release Checklist

Cadence is distributed through GitHub Releases as a production macOS app.

## Artifact

Upload only:

```text
Build/Release/Cadence.dmg
```

Do not upload:

```text
Cadence Debug.app
Cadence Debug.dmg
Build/DerivedData
```

## Build

Create the release DMG:

```zsh
scripts/package_release.sh
```

The script must:

- Archive the Release configuration.
- Export `Cadence.app`.
- Sign with `Developer ID Application`.
- Submit to Apple notarization.
- Staple the notarization ticket.
- Verify Gatekeeper acceptance for the DMG.

## Release Notes

Include:

- One-line product description.
- Minimum macOS version.
- Permission setup note.
- Known issues.
- Screenshots and GIFs from `docs/media`.

## Minimum Release Notes Template

```markdown
## Cadence

Fast local dictation for macOS.

### Requirements

- macOS 14 or later
- Microphone, Accessibility, and Input Monitoring permissions

### Install

1. Download `Cadence.dmg`.
2. Open the DMG.
3. Drag `Cadence.app` to Applications.
4. Open Cadence and complete the permissions wizard.

### Known Notes

- The speech model may download on first use.
- macOS may ask you to restart Cadence after granting permissions.
```
