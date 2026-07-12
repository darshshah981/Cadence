#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="collect"
EXPECTED_COMMIT=""
DMG_PATH="$ROOT_DIR/Build/Release/Cadence.dmg"
OUTPUT_DIR="$ROOT_DIR/Build/AdaptiveScribeEvidence"
EVIDENCE_ARTIFACTS=()
EVIDENCE_PATHS=()

usage() {
  cat >&2 <<EOF
Usage:
  scripts/collect_adaptive_scribe_evidence.sh --check
  scripts/collect_adaptive_scribe_evidence.sh --commit <sha> [--dmg <path>] [--output <dir>] [--artifact <label>=<path>]...

Collection is release-only. It refuses a dirty tree, a commit mismatch, a missing
Release DMG, or a Debug-labelled artifact. --check validates the collector and
versioned synthetic corpus without claiming release evidence.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      MODE="check"
      shift
      ;;
    --commit)
      EXPECTED_COMMIT="${2:-}"
      shift 2
      ;;
    --dmg)
      DMG_PATH="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --artifact)
      ARTIFACT="${2:-}"
      LABEL="${ARTIFACT%%=*}"
      PATH_VALUE="${ARTIFACT#*=}"
      if [[ "$ARTIFACT" != *=* || ! "$LABEL" =~ ^[A-Za-z0-9._-]+$ || -z "$PATH_VALUE" ]]; then
        echo "--artifact must use a safe label=path value." >&2
        exit 2
      fi
      EVIDENCE_ARTIFACTS+=("$LABEL=$PATH_VALUE")
      EVIDENCE_PATHS+=("$PATH_VALUE")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

CORPUS="$ROOT_DIR/CadenceTests/Fixtures/AdaptiveScribe/quality-corpus.json"
CORPUS_MANIFEST="$ROOT_DIR/CadenceTests/Fixtures/AdaptiveScribe/manifest.json"
python3 -m json.tool "$CORPUS" >/dev/null
python3 -m json.tool "$CORPUS_MANIFEST" >/dev/null

if [[ "$MODE" == "check" ]]; then
  bash -n "$ROOT_DIR/scripts/verify_scribe_privacy_canaries.sh"
  bash -n "$ROOT_DIR/scripts/collect_adaptive_scribe_evidence.sh"
  bash -n "$ROOT_DIR/scripts/verify_live_scribe_providers.sh"
  bash -n "$ROOT_DIR/scripts/verify_scribe_real_apps.sh"
  bash -n "$ROOT_DIR/scripts/package_release.sh"
  "$ROOT_DIR/scripts/verify_live_scribe_providers.sh" --check
  "$ROOT_DIR/scripts/verify_scribe_real_apps.sh" --check
  echo "Adaptive Scribe evidence tooling check passed. No release gate was marked complete."
  exit 0
fi

if [[ -z "$EXPECTED_COMMIT" ]]; then
  echo "--commit is required for evidence collection." >&2
  exit 2
fi

cd "$ROOT_DIR"
CURRENT_COMMIT="$(git rev-parse HEAD)"
EXPECTED_FULL="$(git rev-parse "$EXPECTED_COMMIT^{commit}")"
if [[ "$CURRENT_COMMIT" != "$EXPECTED_FULL" ]]; then
  echo "Commit mismatch: HEAD=$CURRENT_COMMIT expected=$EXPECTED_FULL" >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing evidence collection from a dirty worktree." >&2
  exit 1
fi
if [[ ! -f "$DMG_PATH" ]]; then
  echo "Release DMG not found: $DMG_PATH" >&2
  exit 1
fi
if [[ "$(basename "$DMG_PATH")" != "Cadence.dmg" ]]; then
  echo "Refusing a noncanonical or Debug-labelled DMG: $DMG_PATH" >&2
  exit 1
fi
if ! hdiutil verify "$DMG_PATH" >/dev/null; then
  echo "Refusing an invalid DMG: $DMG_PATH" >&2
  exit 1
fi

MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cadence-evidence.XXXXXX")"
cleanup_mount() {
  hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  rmdir "$MOUNT_DIR" 2>/dev/null || true
}
trap cleanup_mount EXIT
if ! hdiutil attach "$DMG_PATH" -readonly -nobrowse -mountpoint "$MOUNT_DIR" >/dev/null; then
  echo "Could not mount release DMG for identity verification." >&2
  exit 1
fi
APP_PATH="$MOUNT_DIR/Cadence.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Refusing a DMG without Cadence.app at its root." >&2
  exit 1
fi
DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
EMBEDDED_COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :CadenceSourceCommit' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$DISPLAY_NAME" != "Cadence" || "$BUNDLE_ID" != "com.darshshah.Cadence" || "$EXECUTABLE_NAME" != "Cadence" ]]; then
  echo "Refusing a non-Release app identity inside the DMG." >&2
  exit 1
fi
if [[ -n "$EMBEDDED_COMMIT" && "$EMBEDDED_COMMIT" != "unknown" && "$EMBEDDED_COMMIT" != "$CURRENT_COMMIT" ]]; then
  echo "Embedded CadenceSourceCommit ($EMBEDDED_COMMIT) does not match collection commit ($CURRENT_COMMIT)." >&2
  exit 1
fi
hdiutil detach "$MOUNT_DIR" >/dev/null
rmdir "$MOUNT_DIR"
trap - EXIT

for path in "${EVIDENCE_PATHS[@]}"; do
  if [[ ! -e "$path" ]]; then
    echo "Evidence artifact does not exist: $path" >&2
    exit 1
  fi
  if [[ -L "$path" ]]; then
    echo "Refusing symlink evidence path: $path" >&2
    exit 1
  fi
done

DMG_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
CORPUS_SHA="$(shasum -a 256 "$CORPUS" | awk '{print $1}')"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:00Z)"

mkdir -p "$OUTPUT_DIR"
MANIFEST_PATH="$OUTPUT_DIR/manifest.json"
python3 - "$MANIFEST_PATH" "$CURRENT_COMMIT" "$DMG_SHA" "$CORPUS_SHA" "$GENERATED_AT" "${EMBEDDED_COMMIT:-}" "${EVIDENCE_ARTIFACTS[@]}" <<'PY'
import hashlib
import json
import os
import sys

path, commit, dmg_sha, corpus_sha, generated_at, embedded_commit, *artifact_specs = sys.argv[1:]

if os.path.isfile(path):
    with open(path, encoding="utf-8") as handle:
        existing = json.load(handle)
    if existing.get("finalDecision") in {"PASS", "FAIL"}:
        raise SystemExit(f"Refusing to overwrite finalized manifest ({existing.get('finalDecision')}) at {path}")

def hash_path(candidate):
    if os.path.islink(candidate):
        raise SystemExit(f"Refusing symlink: {candidate}")
    digest = hashlib.sha256()
    if os.path.isfile(candidate):
        with open(candidate, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    for root, directories, files in os.walk(candidate):
        directories.sort()
        files.sort()
        for filename in files:
            full_path = os.path.join(root, filename)
            if os.path.islink(full_path):
                raise SystemExit(f"Refusing symlink inside evidence: {full_path}")
            relative = os.path.relpath(full_path, candidate).replace(os.sep, "/")
            digest.update(relative.encode("utf-8"))
            digest.update(b"\0")
            with open(full_path, "rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
    return digest.hexdigest()

DOGOFOOD_ALLOWLIST = {
    "actionsTotal",
    "actionsGeneral",
    "actionsMessaging",
    "actionsCoding",
    "workdays",
    "incidentCodes",
}

artifacts = []
for spec in artifact_specs:
    label, candidate = spec.split("=", 1)
    if ".." in os.path.normpath(candidate).split(os.sep):
        raise SystemExit(f"Refusing path escape in evidence artifact: {candidate}")
    artifacts.append({
        "label": label,
        "pathBasename": os.path.basename(os.path.normpath(candidate)),
        "sha256": hash_path(candidate),
    })
    if label == "dogfood" and os.path.isfile(candidate):
        with open(candidate, encoding="utf-8") as handle:
            dogfood = json.load(handle)
        extra = set(dogfood) - DOGOFOOD_ALLOWLIST
        if extra:
            raise SystemExit(f"Dogfood artifact has non-allowlisted keys: {sorted(extra)}")

manifest = {
    "schemaVersion": 2,
    "generatedAtMinuteUTC": generated_at,
    "commit": commit,
    "embeddedSourceCommit": embedded_commit or None,
    "releaseDMGSHA256": dmg_sha,
    "qualityCorpusSHA256": corpus_sha,
    "schemaRevision": "2",
    "corpusRevision": "2",
    "policyRevision": "2026-07-12",
    "gateRevision": "1",
    "evidenceArtifacts": artifacts,
    "sourceReviewDates": {
        "deepSeekWireProfile": "2026-07-10",
        "deepSeekPrivacyPolicy": "2026-07-10",
        "openAIDirectPrivacyPolicy": "2026-07-12",
        "openRouterPrivacyPolicy": "2026-07-12",
        "claudeRecognitionContract": "2026-07-10",
    },
    "artifactKind": "Release",
    "gates": {
        "deterministicPRGates": "NOT_RECORDED",
        "signedCandidateGate": "NOT_RUN",
        "liveOpenAIDirectGate": "NOT_RUN",
        "liveOpenRouterGate": "NOT_RUN",
        "liveDeepSeekGate": "NOT_RUN",
        "realAppGate": "NOT_RUN",
        "accessibilityGate": "NOT_RUN",
        "privacyGate": "NOT_RUN",
        "fiveWorkdayDogfoodGate": "NOT_RUN",
    },
    "finalDecision": "NOT_RUN",
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(tmp, path)
PY

"$ROOT_DIR/scripts/verify_scribe_privacy_canaries.sh" "$OUTPUT_DIR" "${EVIDENCE_PATHS[@]}"
echo "Created manifest: $MANIFEST_PATH"
echo "All live, signed, accessibility, real-app, privacy, and dogfood gates remain NOT_RUN."
