#!/bin/bash
set -euo pipefail

if [[ "$#" -lt 3 ]]; then
  echo "Usage: scripts/replay_scribe_evaluation.sh requests.json results.json Build/report.json [--generator-source saved.swift] [--refinement [--corpus corpus.json] [--refinement-policy saved.swift]]" >&2
  exit 2
fi

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_tmp="$(mktemp -d "${TMPDIR:-/tmp}/cadence-scribe-replay.XXXXXX")"
trap 'rm -rf "$task_tmp"' EXIT

requests="$1"
results="$2"
report_input="$3"
shift 3
[[ "$report_input" = /* ]] || report_input="$task_root/$report_input"
corpus="$task_root/CadenceTests/Fixtures/AdaptiveScribe/instruction-following.json"
generator="$task_root/Cadence/Services/OnDeviceScribeGeneration.swift"
refinement=0
refinement_policy="$task_root/Cadence/Services/ScribeDraftRefinementPolicy.swift"
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --generator-source) generator="$2"; shift 2 ;;
    --refinement) refinement=1; corpus="$(dirname "$requests")/corpus.json"; shift ;;
    --corpus) corpus="$2"; shift 2 ;;
    --refinement-policy) refinement_policy="$2"; shift 2 ;;
    *) echo "Unknown replay option." >&2; exit 2 ;;
  esac
done
request_policy="$task_root/Cadence/Services/ScribeRequestPolicy.swift"
recipient_policy="$task_root/Cadence/Services/ScribeRecipientRestrictionPolicy.swift"

for input in "$requests" "$results" "$corpus" "$generator" "$request_policy" "$recipient_policy" "$refinement_policy"; do
  [[ -f "$input" ]] || { echo "Replay input is unavailable." >&2; exit 2; }
done

# Replay always executes the current compiled guard. A historical policy source
# may be supplied only when its bytes equal that guard, so its hash cannot be
# mistaken for code that was actually executed.
if [[ "$refinement" -eq 1 ]] && ! cmp -s "$refinement_policy" "$task_root/Cadence/Services/ScribeDraftRefinementPolicy.swift"; then
  echo "Refinement policy source must match the current executed guard bytes." >&2
  exit 2
fi

# Resolve through existing symlinks and reject paths outside the ignored Build
# archive before creating any caller-selected directory. Also reject aliases or
# hardlinks between inputs and the destination.
report="$(python3 - "$task_root" "$report_input" "$requests" "$results" "$corpus" "$generator" "$request_policy" "$recipient_policy" "$refinement_policy" <<'PY'
import os
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
candidate = Path(sys.argv[2]).resolve(strict=False)
build = (root / "Build").resolve(strict=False)
try:
    candidate.relative_to(build)
except ValueError:
    raise SystemExit("Report must resolve under Build/.")

inputs = [Path(value).resolve() for value in sys.argv[3:]]
if len(set(inputs)) != len(inputs):
    raise SystemExit("Replay inputs must be distinct files.")
for index, source in enumerate(inputs):
    for other in inputs[index + 1:]:
        if os.path.samefile(source, other):
            raise SystemExit("Replay inputs must not alias or hardlink each other.")
if candidate in inputs:
    raise SystemExit("Report must not overwrite an input.")
if candidate.exists():
    for source in inputs:
        if os.path.samefile(candidate, source):
            raise SystemExit("Report must not alias or hardlink an input.")
print(candidate)
PY
)" || { echo "Unsafe replay report path." >&2; exit 2; }
git -C "$task_root" check-ignore -q "$report" || { echo "Report must resolve under ignored Build/." >&2; exit 2; }

# Preserve exact input bytes for provenance. The native test receives only
# staged paths; supplied generator source is hashed as evidence and never run.
cp "$requests" "$task_tmp/requests.json"
cp "$results" "$task_tmp/results.json"
cp "$corpus" "$task_tmp/corpus.json"
cp "$generator" "$task_tmp/generator.swift"
cp "$request_policy" "$task_tmp/request-policy.swift"
cp "$recipient_policy" "$task_tmp/recipient-policy.swift"
cp "$refinement_policy" "$task_tmp/refinement-policy.swift"
staged_report="$task_tmp/replay-report.json"

# The test defaults to a no-op. Set both the test-runner namespace and the
# current native-test keys explicitly, then require a newly staged report.
TEST_RUNNER_CADENCE_REPLAY_SCRIBE_EVALUATION="$((1-refinement))" \
TEST_RUNNER_CADENCE_REPLAY_SCRIBE_REFINEMENT="$refinement" \
TEST_RUNNER_CADENCE_REPLAY_REFINEMENT_CORPUS="$task_tmp/corpus.json" \
TEST_RUNNER_CADENCE_REPLAY_INSTRUCTION_CORPUS="$task_tmp/corpus.json" \
TEST_RUNNER_CADENCE_REPLAY_REFINEMENT_POLICY_SOURCE="$task_tmp/refinement-policy.swift" \
TEST_RUNNER_CADENCE_REPLAY_REQUESTS="$task_tmp/requests.json" \
TEST_RUNNER_CADENCE_REPLAY_RESULTS="$task_tmp/results.json" \
TEST_RUNNER_CADENCE_REPLAY_GENERATOR="$task_tmp/generator.swift" \
TEST_RUNNER_CADENCE_REPLAY_OUTPUT="$staged_report" \
TEST_RUNNER_CADENCE_REPLAY_REQUEST_POLICY_SOURCE="$task_tmp/request-policy.swift" \
TEST_RUNNER_CADENCE_REPLAY_RECIPIENT_POLICY_SOURCE="$task_tmp/recipient-policy.swift" \
CADENCE_REPLAY_SCRIBE_EVALUATION="$((1-refinement))" \
CADENCE_REPLAY_SCRIBE_REFINEMENT="$refinement" \
CADENCE_REPLAY_REFINEMENT_CORPUS="$task_tmp/corpus.json" \
CADENCE_REPLAY_INSTRUCTION_CORPUS="$task_tmp/corpus.json" \
CADENCE_REPLAY_REFINEMENT_POLICY_SOURCE="$task_tmp/refinement-policy.swift" \
CADENCE_REPLAY_REQUESTS="$task_tmp/requests.json" \
CADENCE_REPLAY_RESULTS="$task_tmp/results.json" \
CADENCE_REPLAY_GENERATOR="$task_tmp/generator.swift" \
CADENCE_REPLAY_OUTPUT="$staged_report" \
CADENCE_REPLAY_REQUEST_POLICY_SOURCE="$task_tmp/request-policy.swift" \
CADENCE_REPLAY_RECIPIENT_POLICY_SOURCE="$task_tmp/recipient-policy.swift" \
xcodebuild test -project "$task_root/Cadence.xcodeproj" -scheme Cadence -configuration Debug \
  -destination 'platform=macOS' -only-testing:CadenceTests/$([[ "$refinement" -eq 1 ]] && echo ScribeRefinementEvaluationReplayTests || echo ScribeEvaluationReplayTests) \
  -derivedDataPath "$task_root/.derived-data-contracts" CODE_SIGNING_ALLOWED=NO

python3 - "$staged_report" "$task_tmp/corpus.json" "$task_tmp/requests.json" "$task_tmp/generator.swift" "$task_tmp/results.json" "$task_tmp/request-policy.swift" "$task_tmp/recipient-policy.swift" "$task_tmp/refinement-policy.swift" "$refinement" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

report_path, corpus_path, requests_path, generator_path, results_path, request_policy_path, recipient_policy_path, refinement_policy_path, refinement = sys.argv[1:]
report_path, corpus_path, requests_path, generator_path, results_path, request_policy_path, recipient_policy_path, refinement_policy_path = map(Path, [report_path, corpus_path, requests_path, generator_path, results_path, request_policy_path, recipient_policy_path, refinement_policy_path])
if not report_path.is_file() or report_path.stat().st_size == 0:
    raise SystemExit("Replay test did not produce a report.")
try:
    report = json.loads(report_path.read_text(encoding="utf-8"))
    corpus = json.loads(corpus_path.read_text(encoding="utf-8"))
except (OSError, UnicodeDecodeError, json.JSONDecodeError):
    raise SystemExit("Replay report is not valid staged evidence.")
expected_schema = 1 if refinement == "1" else 2
if not isinstance(report, dict) or report.get("schemaVersion") != expected_schema or report.get("semanticQuality") != "NOT_EVALUATED":
    raise SystemExit("Replay report has an unsupported schema.")
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
expected_hashes = {
    "corpusSHA256": digest(corpus_path), "requestsSHA256": digest(requests_path),
    "generatorSHA256": digest(generator_path), "resultsSHA256": digest(results_path),
    "requestPolicySourceSHA256": digest(request_policy_path),
    "recipientRestrictionPolicySourceSHA256": digest(recipient_policy_path),
}
if refinement == "1":
    expected_hashes["refinementPolicySourceSHA256"] = digest(refinement_policy_path)
if any(report.get(key) != value for key, value in expected_hashes.items()):
    raise SystemExit("Replay report hashes do not match staged inputs.")
cases = corpus.get("cases") if isinstance(corpus, dict) else None
rows = report.get("rows")
if not isinstance(cases, list) or not isinstance(rows, list):
    raise SystemExit("Replay report is incomplete.")
case_ids = {case.get("id") for case in cases if isinstance(case, dict)}
row_ids = [row.get("id") for row in rows if isinstance(row, dict)]
if not case_ids or len(case_ids) != len(cases) or set(row_ids) != case_ids or len(row_ids) != len(cases):
    raise SystemExit("Replay report does not cover each expected case once.")
readiness_key = "readiness" if refinement == "1" else "reviewReadiness"
if any(row.get(readiness_key) not in ("READY", "REJECTED", "NOT_GENERATED") for row in rows):
    raise SystemExit("Replay report has an invalid readiness outcome.")
if refinement != "1" and any(row.get("executionKind") not in ("MODEL_GENERATION", "PREPARED_DRAFT") for row in rows):
    raise SystemExit("Replay report has an invalid execution kind.")
PY

# Archive only a verified, newly staged report; a preexisting destination is
# untouched on an xcodebuild failure, skipped test, or malformed output.
mkdir -p "$(dirname "$report")"
archive_tmp="$(mktemp "$(dirname "$report")/.scribe-replay.XXXXXX")"
cp "$staged_report" "$archive_tmp"
mv -f "$archive_tmp" "$report"
