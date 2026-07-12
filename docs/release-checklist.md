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

## Adaptive Scribe Release Gate

A green pull request proves deterministic implementation checks; it does not certify Cloud Scribe for release. Before describing Adaptive Scribe as release-ready, complete `docs/adaptive-scribe-release-evidence.md` on one immutable candidate and attach its manifest.

The same candidate must prove:

- A signed, notarized, stapled, Gatekeeper-accepted Release DMG with matching `CadenceSourceCommit` on minimum macOS 14 and the current stable macOS, covering every packaged architecture.
- Live OpenAI Direct and OpenRouter synthetic checks against the installed app from the same DMG
- The live DeepSeek V4 Flash quality and latency matrix (when DeepSeek remains a packaged profile), including 72 scored drafts and 100 production-shaped latency requests.
- Cursor, Slack, and Codex/OpenAI Desktop recognition and insertion checks
- Exact Slack behavior checks and the positive/negative certified Claude Code prompt signature in the signed current Claude Desktop build.
- Keyboard, VoiceOver, Increase Contrast, Reduce Transparency, and Reduce Motion checks.
- No-pre-consent-network, Keychain lifecycle, redirect refusal, egress allowlist, and privacy-canary evidence.
- Five workdays of dogfood with at least 40 genuine tasks and zero stale/misdirected insertion, silent environment switch, lost actionable draft, or privacy incident.
- One manifest binding every artifact and PASS/FAIL decision to the same git commit and DMG SHA-256.

Before attaching any evidence, run `scripts/test_adaptive_scribe_contracts.sh` on the candidate source, then `scripts/verify_scribe_privacy_canaries.sh` over the XCTest results, UI-test results, captured logs, diagnostics exports, and evidence directory. The scan includes transcript, selection, credential, origin, model, app, guidance, prompt, response, process-ID, filesystem-path, and bundle-identifier canaries; any match is a release blocker.

Do not weaken or mark an unrun gate complete. If the signed Claude Desktop app lacks a stable non-content Code-prompt signature, Claude Code recognition stays fail-closed to Other apps and the release gate fails.

## Minimum Release Notes Template

```markdown
## Cadence

Fast local dictation for macOS.

### Requirements

- macOS 14 or later
- Microphone, Accessibility, and Input Monitoring permissions for dictation
- Screen Recording permission for system audio meeting capture

### Install

1. Download `Cadence.dmg`.
2. Open the DMG.
3. Drag `Cadence.app` to Applications.
4. Open Cadence and complete the permissions wizard.
5. For system audio meeting capture, grant Screen Recording when prompted.

### Known Notes

- The speech model may download on first use.
- macOS may ask you to restart Cadence after granting permissions.
```
