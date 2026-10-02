#!/usr/bin/env bash
# Recursive privacy canary scan for Adaptive Scribe evidence.
# Any match fails closed and is a release blocker (U12).
set -euo pipefail

usage() {
  echo "Usage: scripts/verify_scribe_privacy_canaries.sh <runtime-artifact-path> [...]" >&2
  echo "Scans the given paths recursively for fixed synthetic canary strings." >&2
}

if [[ $# -eq 0 ]]; then
  usage
  exit 2
fi

for path in "$@"; do
  if [[ ! -e "$path" || -L "$path" ]]; then
    echo "Privacy canary scan refused: a requested artifact path is missing or is a symlink." >&2
    exit 2
  fi
  if ! nested_symlink="$(find "$path" -type l -print -quit 2>/dev/null)"; then
    echo "Privacy canary scan could not inspect a requested artifact tree." >&2
    exit 2
  fi
  if [[ -n "$nested_symlink" ]]; then
    echo "Privacy canary scan refused: an artifact tree contains a symlink." >&2
    exit 2
  fi
done

# Taxonomy from the U12 verification contract: transcript, selection/secret,
# origin, model, app, guidance, request/response, PID, user-path, identifier.
DEFAULT_CANARIES=(
  "SCRIBE_TRANSCRIPT_CANARY_74A9"
  "SCRIBE_SELECTION_CANARY_38F2"
  "SCRIBE_KEY_CANARY_SK_91D0"
  "SCRIBE_ORIGIN_CANARY_55BC"
  "SCRIBE_MODEL_CANARY_0E27"
  "SCRIBE_APP_CANARY_6A44"
  "SCRIBE_GUIDANCE_CANARY_9B18"
  "SCRIBE_PROMPT_CANARY_2CC1"
  "SCRIBE_RESPONSE_CANARY_8D13"
  "SCRIBE_PID_CANARY_7E19"
  "/tmp/SCRIBE_PATH_CANARY_6F31"
  "com.example.ScribeCanary_3D72"
)

if [[ -n "${SCRIBE_PRIVACY_CANARIES:-}" ]]; then
  IFS=',' read -r -a CANARIES <<<"$SCRIBE_PRIVACY_CANARIES"
else
  CANARIES=("${DEFAULT_CANARIES[@]}")
fi

scan_for_canary() {
  local canary="$1"
  shift
  if command -v rg >/dev/null 2>&1; then
    rg --hidden --no-ignore --text --fixed-strings --quiet -- "$canary" "$@" 2>/dev/null
    return $?
  fi
  # Fallback when ripgrep is unavailable (local shells without brew rg).
  # Uses recursive binary-safe fixed-string search.
  grep -R -F -a -q -- "$canary" "$@" 2>/dev/null
}

failed=0
scan_error=0
matched_count=0
for canary in "${CANARIES[@]}"; do
  if scan_for_canary "$canary" "$@"; then
    matched_count=$((matched_count + 1))
    failed=1
  else
    scan_status=$?
    if [[ "$scan_status" -ne 1 ]]; then
      scan_error=1
    fi
  fi
done

if [[ "$failed" -ne 0 ]]; then
  echo "Privacy canary scan FAILED ($matched_count match(es)). Evidence bundle is invalid." >&2
  exit 1
fi

if [[ "$scan_error" -ne 0 ]]; then
  echo "Privacy canary scan could not inspect every requested artifact." >&2
  exit 2
fi

echo "Scribe privacy canary scan passed for $# runtime artifact path(s)."
