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

existing_paths=()
for path in "$@"; do
  if [[ ! -e "$path" ]]; then
    echo "Privacy scan path does not exist (skipped): $path" >&2
    continue
  fi
  existing_paths+=("$path")
done

if [[ ${#existing_paths[@]} -eq 0 ]]; then
  echo "Privacy canary scan found no existing artifact paths to inspect." >&2
  exit 2
fi

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
    rg --hidden --no-ignore --text --fixed-strings --quiet -- "$canary" "$@"
    return $?
  fi
  # Fallback when ripgrep is unavailable (local shells without brew rg).
  # Uses recursive binary-safe fixed-string search.
  grep -R -F -a -I -q -- "$canary" "$@" 2>/dev/null
}

failed=0
matched=()
for canary in "${CANARIES[@]}"; do
  if scan_for_canary "$canary" "${existing_paths[@]}"; then
    echo "Privacy canary leaked into runtime evidence: $canary" >&2
    matched+=("$canary")
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  echo "Privacy canary scan FAILED (${#matched[@]} match(es)). Evidence bundle is invalid." >&2
  exit 1
fi

echo "Scribe privacy canary scan passed for ${#existing_paths[@]} runtime artifact path(s)."
