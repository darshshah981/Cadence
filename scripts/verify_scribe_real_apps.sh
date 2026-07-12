#!/usr/bin/env bash
# Real-app recognition/insertion gates (Cursor, Slack, Codex) for release candidates.
# Never writes PASS without an explicit proof flag from a release owner.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="execute"
OUTPUT_DIR="${CADENCE_EVIDENCE_DIR:-$ROOT_DIR/Build/AdaptiveScribeEvidence}"
GATE_ID="real-apps"
SCHEMA_REVISION="2"
CORPUS_REVISION="2"
POLICY_REVISION="2026-07-12"
GATE_REVISION="1"

usage() {
  cat >&2 <<EOF
Usage:
  scripts/verify_scribe_real_apps.sh --check
  scripts/verify_scribe_real_apps.sh [--output <dir>]

Environment (execute mode):
  CADENCE_REAL_APP_PROOF=1   # release owner asserts interactive proof completed
  CADENCE_SOURCE_COMMIT      # optional; defaults to git HEAD
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
  echo "real-app verifier check ok"
  exit 0
fi

COMMIT="${CADENCE_SOURCE_COMMIT:-$(git -C "$ROOT_DIR" rev-parse HEAD)}"
mkdir -p "$OUTPUT_DIR"
OUT="$OUTPUT_DIR/real-apps-result.json"

status="NOT_RUN"
if [[ "${CADENCE_REAL_APP_PROOF:-}" == "1" ]]; then
  # Interactive app proof is still human-owned; the flag records that the
  # operator completed the checklist, producing a closed aggregate only.
  status="PASS_OPERATOR_ATTESTED"
fi

python3 - "$OUT" "$COMMIT" "$status" "$SCHEMA_REVISION" "$CORPUS_REVISION" "$POLICY_REVISION" "$GATE_REVISION" "$GATE_ID" <<'PY'
import json, sys
path, commit, status, schema_rev, corpus_rev, policy_rev, gate_rev, gate_id = sys.argv[1:]
envelope = {
    "schemaVersion": 2,
    "gateId": gate_id,
    "status": status,
    "schemaRevision": schema_rev,
    "corpusRevision": corpus_rev,
    "policyRevision": policy_rev,
    "gateRevision": gate_rev,
    "commit": commit,
    "apps": {
        "cursor": status,
        "slack": status,
        "codex": status,
    },
    "aggregateOnly": True,
    "notes": "Does not inventory installed apps or capture content; operator-attested closed outcomes only.",
}
# Never claim automated PASS without attestation path.
if status == "PASS":
    raise SystemExit("real-app verifier does not emit raw PASS")
with open(path, "w", encoding="utf-8") as handle:
    json.dump(envelope, handle, indent=2, sort_keys=True)
    handle.write("\n")
print(path)
print(f"status={status}")
PY
