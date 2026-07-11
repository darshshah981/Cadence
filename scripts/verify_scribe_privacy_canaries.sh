#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: scripts/verify_scribe_privacy_canaries.sh <runtime-artifact-path> [...]" >&2
}

if [[ $# -eq 0 ]]; then
  usage
  exit 2
fi

for path in "$@"; do
  if [[ ! -e "$path" ]]; then
    echo "Privacy scan path does not exist: $path" >&2
    exit 2
  fi
done

DEFAULT_CANARIES=(
  "SCRIBE_TRANSCRIPT_CANARY_74A9"
  "SCRIBE_SELECTION_CANARY_38F2"
  "SCRIBE_KEY_CANARY_SK_91D0"
  "SCRIBE_ORIGIN_CANARY_55BC"
  "SCRIBE_MODEL_CANARY_0E27"
  "SCRIBE_APP_CANARY_6A44"
  "SCRIBE_PROMPT_CANARY_2CC1"
  "SCRIBE_RESPONSE_CANARY_8D13"
)

if [[ -n "${SCRIBE_PRIVACY_CANARIES:-}" ]]; then
  IFS=',' read -r -a CANARIES <<<"$SCRIBE_PRIVACY_CANARIES"
else
  CANARIES=("${DEFAULT_CANARIES[@]}")
fi

failed=0
for canary in "${CANARIES[@]}"; do
  if rg --hidden --no-ignore --text --fixed-strings --quiet "$canary" "$@"; then
    echo "Privacy canary leaked into runtime evidence: $canary" >&2
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "Scribe privacy canary scan passed for $# runtime artifact path(s)."
