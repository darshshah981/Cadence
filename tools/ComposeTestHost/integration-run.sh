#!/bin/bash
# Explicit, interactive-desktop integration. Build-only checks use build.sh.
set -euo pipefail
if [[ "${1:-}" != "--run" || "$#" -ne 1 ]]; then
  printf '%s\n' 'Usage: bash tools/ComposeTestHost/integration-run.sh --run' >&2
  printf '%s\n' 'This opt-in run may activate only the synthetic Compose Test Host after Accessibility preflight.' >&2
  exit 2
fi

source_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$source_dir/../.." && pwd)"
cd "$repo_dir"
bash "$source_dir/build.sh"
xcodegen generate
mkdir -p "$repo_dir/Build/ComposeRoadmap"
temporary_root="${TMPDIR:-/tmp}"
evidence_dir="$(mktemp -d "${temporary_root%/}/cadence-compose-U5.XXXXXX")"
archive_dir="$repo_dir/Build/ComposeRoadmap/$(basename "$evidence_dir")"
report_path="$evidence_dir/integration-report.json"
host_app="$evidence_dir/ComposeTestHost.app"
ditto "$repo_dir/Build/ComposeTestHost/ComposeTestHost.app" "$host_app"
test_derived_data="${CADENCE_INTEGRATION_DERIVED_DATA:-$repo_dir/.derived-data-contracts}"

printf 'Temporary integration evidence: %s\n' "$evidence_dir"
printf 'Post-run evidence archive: %s\n' "$archive_dir"
set +e
TEST_RUNNER_CADENCE_COMPOSE_INSERTION_INTEGRATION=1 \
TEST_RUNNER_CADENCE_COMPOSE_INSERTION_REPORT="$report_path" \
TEST_RUNNER_CADENCE_COMPOSE_TEST_HOST_APP="$host_app" \
TEST_RUNNER_CADENCE_COMPOSE_TEST_HOST_RUN="$evidence_dir/host-control" \
xcodebuild test \
  -project Cadence.xcodeproj -scheme Cadence -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$test_derived_data" \
  -parallel-testing-enabled NO \
  -only-testing:CadenceTests/ComposeInsertionIntegrationTests \
  -resultBundlePath "$evidence_dir/TestResults.xcresult" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$evidence_dir/xcodebuild.log"
build_status=${PIPESTATUS[0]}
set -e

# A skipped, undiscovered, interrupted, or permission-blocked test must never be
# interpreted as a successful integration run, even if xcodebuild exits zero.
set +e
python3 - "$report_path" "$build_status" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
build_status = int(sys.argv[2])
try:
    report = json.loads(path.read_text(encoding="utf-8"))
except (OSError, ValueError):
    print(json.dumps({"status": "missing_evidence", "integrationPassed": False}))
    sys.exit(1)
status = report.get("status")
passed = (build_status == 0
          and report.get("schemaVersion") == 1
          and report.get("syntheticOnly") is True
          and status == "passed"
          and report.get("accessibilityTrustedInActualTestProcess") is True
          and report.get("expectedCaseCount") == 18
          and report.get("completedCaseCount") == 18
          and report.get("passedCaseCount") == 18
          and report.get("failedCaseCount") == 0
          and len(report.get("cases", [])) == 18
          and all(case.get("status") == "passed" for case in report.get("cases", [])))
print(json.dumps({"status": status, "integrationPassed": passed,
                  "passedCases": report.get("passedCaseCount", 0),
                  "report": str(path)}, sort_keys=True))
sys.exit(0 if passed else 3 if status == "blocked_permission" else 1)
PY
verification_status=$?
set -e
# Only this shell accesses the repository archive. The native test process uses
# temporary paths, avoiding a Documents-folder TCC prompt during evidence IO.
ditto "$evidence_dir" "$archive_dir"
printf 'Evidence archived: %s\n' "$archive_dir"
exit "$verification_status"
