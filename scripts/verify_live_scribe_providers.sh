#!/usr/bin/env bash
# Live OpenAI Direct / OpenRouter gates for Adaptive Scribe release candidates.
# Never writes PASS without explicit live credentials. CI uses --check only.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="execute"
OUTPUT_DIR="${CADENCE_EVIDENCE_DIR:-$ROOT_DIR/Build/AdaptiveScribeEvidence}"
GATE_ID="live-providers"
SCHEMA_REVISION="2"
CORPUS_REVISION="2"
POLICY_REVISION="2026-07-12"
GATE_REVISION="1"

usage() {
  cat >&2 <<EOF
Usage:
  scripts/verify_live_scribe_providers.sh --check
  scripts/verify_live_scribe_providers.sh [--output <dir>]

Environment (execute mode only; never commit secrets):
  CADENCE_LIVE_OPENAI_KEY
  CADENCE_LIVE_OPENROUTER_KEY
  CADENCE_SOURCE_COMMIT   (optional; defaults to git HEAD)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "$MODE" == "check" ]]; then
  bash -n "$0"
  python3 - <<'PY'
import json
envelope = {
  "schemaVersion": 2,
  "gateId": "live-providers",
  "status": "NOT_RUN",
  "schemaRevision": "2",
  "corpusRevision": "2",
  "policyRevision": "2026-07-12",
  "gateRevision": "1",
  "commit": "0" * 40,
  "providers": {"openAIDirect": "NOT_RUN", "openRouter": "NOT_RUN"},
}
assert envelope["status"] != "PASS"
print("live provider verifier check ok")
PY
  exit 0
fi

COMMIT="${CADENCE_SOURCE_COMMIT:-$(git -C "$ROOT_DIR" rev-parse HEAD)}"
mkdir -p "$OUTPUT_DIR"
OUT="$OUTPUT_DIR/live-providers-result.json"

openai_status="NOT_RUN"
openrouter_status="NOT_RUN"
final="NOT_RUN"

if [[ -n "${CADENCE_LIVE_OPENAI_KEY:-}" || -n "${CADENCE_LIVE_OPENROUTER_KEY:-}" ]]; then
  # Live network execution is intentionally not automated here: release owners
  # run synthetic validation through the installed app. Presence of keys alone
  # upgrades status to BLOCKED_PENDING_MANUAL_APP_RUN, never PASS.
  [[ -n "${CADENCE_LIVE_OPENAI_KEY:-}" ]] && openai_status="BLOCKED_PENDING_MANUAL_APP_RUN"
  [[ -n "${CADENCE_LIVE_OPENROUTER_KEY:-}" ]] && openrouter_status="BLOCKED_PENDING_MANUAL_APP_RUN"
  final="BLOCKED_PENDING_MANUAL_APP_RUN"
fi

python3 - "$OUT" "$COMMIT" "$openai_status" "$openrouter_status" "$final" \
  "$SCHEMA_REVISION" "$CORPUS_REVISION" "$POLICY_REVISION" "$GATE_REVISION" "$GATE_ID" <<'PY'
import json, sys
path, commit, openai, openrouter, final, schema_rev, corpus_rev, policy_rev, gate_rev, gate_id = sys.argv[1:]
envelope = {
    "schemaVersion": 2,
    "gateId": gate_id,
    "status": final,
    "schemaRevision": schema_rev,
    "corpusRevision": corpus_rev,
    "policyRevision": policy_rev,
    "gateRevision": gate_rev,
    "commit": commit,
    "providers": {
        "openAIDirect": openai,
        "openRouter": openrouter,
    },
    "notes": "PASS requires release-owner app-mediated synthetic runs; this script never auto-PASS.",
}
if final == "PASS":
    raise SystemExit("live provider verifier refused to emit PASS without app-mediated proof")
with open(path, "w", encoding="utf-8") as handle:
    json.dump(envelope, handle, indent=2, sort_keys=True)
    handle.write("\n")
print(path)
print(f"status={final}")
PY

if [[ "$final" == "PASS" ]]; then
  echo "Refusing unexpected PASS from live provider verifier." >&2
  exit 1
fi
exit 0
