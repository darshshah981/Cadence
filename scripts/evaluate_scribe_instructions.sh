#!/bin/bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: scripts/evaluate_scribe_instructions.sh requests.json results.json" >&2
  exit 2
fi

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_tmp="$(mktemp -d "${TMPDIR:-/tmp}/cadence-scribe-eval.XXXXXX")"
trap 'rm -rf "$task_tmp"' EXIT

# The production evaluator accepts only a versioned synthetic request envelope.
# Legacy request arrays remain unbound and are rejected rather than assigned a
# corpus identity after the fact.
generator_source="$task_root/Cadence/Services/OnDeviceScribeGeneration.swift"
generator_hash="$(shasum -a 256 "$generator_source" | awk '{print $1}')"

# Exercise the same on-device generation implementation used by the app.
xcrun swiftc -parse-as-library \
  "$generator_source" \
  "$task_root/scripts/evaluate_scribe_instructions.swift" \
  -o "$task_tmp/evaluate"
"$task_tmp/evaluate" "$1" "$2" "$generator_hash"
