#!/bin/bash
set -euo pipefail

if [[ "$#" -ne 5 ]]; then
  echo "Usage: scripts/replay_selected_text_evaluation.sh corpus.json requests.json results.json generator.swift Build/report.json" >&2
  exit 2
fi

task_root="$(cd "$(dirname "$0")/.." && pwd)"
corpus="$1"; requests="$2"; results="$3"; generator="$4"; report_input="$5"
[[ "$report_input" = /* ]] || report_input="$task_root/$report_input"
for input in "$corpus" "$requests" "$results" "$generator"; do
  [[ -f "$input" ]] || { echo "Replay input is unavailable." >&2; exit 2; }
done
policy_paths=(
  Cadence/Services/ComposeContextCompiler.swift
  Cadence/Models/ComposeGroundedRequestModels.swift
  Cadence/Models/ComposeContextSnapshot.swift
  Cadence/Services/ComposeSelectedTextContextController.swift
  Cadence/Services/ScribeContextPolicy.swift
  Cadence/Models/ScribeContextPolicyModels.swift
  Cadence/Services/ComposePreferenceResolver.swift
  Cadence/Models/ComposeWritingPreferenceModels.swift
  Cadence/Services/ComposeSelectedTextRewritePolicy.swift
  Cadence/Services/ScribeRequestPolicy.swift
  Cadence/Models/ScribeModels.swift
  Cadence/Services/ScribeRecipientRestrictionPolicy.swift
  Cadence/Services/ScribeWritingDirectionParser.swift
  Cadence/Models/ScribeWritingRequest.swift
  Cadence/Services/ScribeLiteralNormalizer.swift
  Cadence/Models/ScribeProviderCapabilityModels.swift
  Cadence/Services/ScribeProviderCapabilityPolicy.swift
  Cadence/Services/ScribeCoordinator.swift
)
policy_inputs=()
for source in "${policy_paths[@]}"; do policy_inputs+=("$task_root/$source"); done

# Resolve output symlinks before creating directories, and prevent overwriting
# any input or current policy via aliases/hardlinks. Only ignored Build output.
report="$(python3 - "$task_root" "$report_input" "$corpus" "$requests" "$results" "$generator" "${policy_inputs[@]}" <<'PY'
import os
from pathlib import Path
import sys
root = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve(strict=False)
inputs = [Path(x).resolve() for x in sys.argv[3:]]
try: output.relative_to((root / 'Build').resolve(strict=False))
except ValueError: raise SystemExit('Report must resolve under Build/.')
for index, source in enumerate(inputs):
    if not source.is_file(): raise SystemExit('Replay source unavailable.')
    if output == source or (output.exists() and os.path.samefile(output, source)):
        raise SystemExit('Report must not overwrite an input or policy source.')
    if any(os.path.samefile(source, other) for other in inputs[index + 1:]):
        raise SystemExit('Replay inputs must be distinct files.')
print(output)
PY
)"
git -C "$task_root" check-ignore -q "$report" || { echo "Report must resolve under ignored Build/." >&2; exit 2; }
# Keep all native-read inputs outside Documents to avoid test-host TCC stalls.
task_tmp="$(mktemp -d "/tmp/cadence-selected-replay.XXXXXX")"
trap 'rm -rf "$task_tmp"' EXIT
mkdir "$task_tmp/policies"
cp "$corpus" "$task_tmp/corpus.json"
cp "$requests" "$task_tmp/requests.json"
cp "$results" "$task_tmp/results.json"
cp "$generator" "$task_tmp/generator.swift"
for source in "${policy_paths[@]}"; do cp "$task_root/$source" "$task_tmp/policies/$(basename "$source")"; done

# Only the trusted shell reads checkout policy files. Native replay compares
# staged bytes with this expected hash manifest and exercises compiled behavior;
# source hashes do not cryptographically identify the binary that runs.
python3 - "$task_root" "$task_tmp" "${policy_paths[@]}" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
root, stage = map(Path, sys.argv[1:3])
paths = sys.argv[3:]
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
expected = {p: digest(stage / 'policies' / Path(p).name) for p in paths}
if any(digest(root / p) != expected[p] for p in paths):
    raise SystemExit('Current policy changed while staging replay.')
(stage / 'policy-hashes.json').write_text(json.dumps(expected, sort_keys=True), encoding='utf-8')
PY

# Saved generator bytes are hashed as evidence, never executed. This invokes
# only the saved-result replay and integrity tests, with no model/capture calls.
CADENCE_REPLAY_SCRIBE_SELECTED_TEXT=1 \
CADENCE_REPLAY_SELECTED_CORPUS="$task_tmp/corpus.json" \
CADENCE_REPLAY_REQUESTS="$task_tmp/requests.json" \
CADENCE_REPLAY_RESULTS="$task_tmp/results.json" \
CADENCE_REPLAY_GENERATOR="$task_tmp/generator.swift" \
CADENCE_REPLAY_SELECTED_POLICY_DIRECTORY="$task_tmp/policies" \
CADENCE_REPLAY_SELECTED_POLICY_HASH_MANIFEST="$task_tmp/policy-hashes.json" \
CADENCE_REPLAY_SELECTED_TEMP_DIRECTORY="$task_tmp" \
CADENCE_REPLAY_OUTPUT="$task_tmp/report.json" \
TEST_RUNNER_CADENCE_REPLAY_SCRIBE_SELECTED_TEXT=1 \
TEST_RUNNER_CADENCE_REPLAY_SELECTED_CORPUS="$task_tmp/corpus.json" \
TEST_RUNNER_CADENCE_REPLAY_REQUESTS="$task_tmp/requests.json" \
TEST_RUNNER_CADENCE_REPLAY_RESULTS="$task_tmp/results.json" \
TEST_RUNNER_CADENCE_REPLAY_GENERATOR="$task_tmp/generator.swift" \
TEST_RUNNER_CADENCE_REPLAY_SELECTED_POLICY_DIRECTORY="$task_tmp/policies" \
TEST_RUNNER_CADENCE_REPLAY_SELECTED_POLICY_HASH_MANIFEST="$task_tmp/policy-hashes.json" \
TEST_RUNNER_CADENCE_REPLAY_SELECTED_TEMP_DIRECTORY="$task_tmp" \
TEST_RUNNER_CADENCE_REPLAY_OUTPUT="$task_tmp/report.json" \
xcodebuild test -project "$task_root/Cadence.xcodeproj" -scheme Cadence -configuration Debug \
  -destination 'platform=macOS' -only-testing:CadenceTests/ScribeSelectedTextEvaluationReplayTests \
  -derivedDataPath "$task_root/.derived-data-contracts" CODE_SIGNING_ALLOWED=NO

# A skipped opt-in test, stale report, changed source, or incomplete result may
# not overwrite an earlier report. Verify the new staged report before archive.
python3 - "$task_root" "$task_tmp" "${policy_paths[@]}" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
root, stage = map(Path, sys.argv[1:3])
paths = sys.argv[3:]
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
report_path = stage / 'report.json'
if not report_path.is_file(): raise SystemExit('Replay did not produce a fresh report.')
report = json.loads(report_path.read_text())
corpus = json.loads((stage / 'corpus.json').read_text())
if report.get('schemaVersion') != 1 or report.get('semanticQuality') != 'NOT_EVALUATED':
    raise SystemExit('Replay report schema is invalid.')
for key, filename in [('corpusSHA256', 'corpus.json'), ('requestsSHA256', 'requests.json'), ('resultsSHA256', 'results.json'), ('generatorSHA256', 'generator.swift')]:
    if report.get(key) != digest(stage / filename): raise SystemExit('Replay evidence hash mismatch.')
expected = {p: digest(stage / 'policies' / Path(p).name) for p in paths}
if json.loads((stage / 'policy-hashes.json').read_text()) != expected:
    raise SystemExit('Expected policy hash manifest changed during replay.')
if report.get('currentPolicySourceSHA256') != expected:
    raise SystemExit('Replay policy hash mismatch.')
if any(digest(root / p) != expected[p] for p in paths):
    raise SystemExit('Current policy changed during replay; rerun from a frozen snapshot.')
case_ids = [case['id'] for case in corpus['cases']]
rows = report.get('rows', [])
if len(case_ids) != len(set(case_ids)) or len(rows) != len(case_ids) or {row.get('id') for row in rows} != set(case_ids):
    raise SystemExit('Replay report does not cover every case exactly once.')
for row in rows:
    if row.get('compilerMatchesCurrent') is not True or row.get('executionKind') != 'MODEL_GENERATION' or row.get('reviewReadiness') not in ('READY', 'REJECTED', 'NOT_GENERATED'):
        raise SystemExit('Replay row is invalid or compiled against stale input.')
PY
mkdir -p "$(dirname "$report")"
archive_tmp="$(mktemp "$(dirname "$report")/.selected-replay.XXXXXX")"
cp "$task_tmp/report.json" "$archive_tmp"
mv -f "$archive_tmp" "$report"
