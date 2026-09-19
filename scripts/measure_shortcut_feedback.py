#!/usr/bin/env python3
"""Measure production HUD clock behavior; never opens a mic or loads a model."""
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
output = root / "Build" / "ShortcutResponsiveness"
output.mkdir(parents=True, exist_ok=True)
log = output / "measurement.log"
with log.open("w") as stream:
    result = subprocess.run([
        "xcodebuild", "test", "-project", "Cadence.xcodeproj", "-scheme", "Cadence",
        "-configuration", "Debug", "-destination", "platform=macOS",
        "-derivedDataPath", ".derived-data-contracts",
        "-only-testing:CadenceTests/ShortcutFeedbackLatencyTests",
        "CODE_SIGNING_ALLOWED=NO",
    ], cwd=root, stdout=stream, stderr=subprocess.STDOUT)
if result.returncode:
    raise SystemExit("Measurement failed; inspect " + str(log))
marker = "SHORTCUT_FEEDBACK_METRICS "
samples = [json.loads(line.split(marker, 1)[1])
           for line in log.read_text().splitlines() if marker in line]
if len(samples) != 1:
    raise SystemExit("Expected exactly one measurement result")
print(json.dumps(samples[0], sort_keys=True))
