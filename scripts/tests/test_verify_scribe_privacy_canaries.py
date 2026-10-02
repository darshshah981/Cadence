"""The privacy evidence gate must inspect every requested artifact."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "verify_scribe_privacy_canaries.sh"
CANARY = "SYNTHETIC_PRIVACY_CANARY_74A9"


class VerifyScribePrivacyCanariesTests(unittest.TestCase):
    def run_scan(self, *paths, env=None):
        environment = dict(os.environ, SCRIBE_PRIVACY_CANARIES=CANARY)
        if env:
            environment.update(env)
        return subprocess.run(
            ["bash", str(SCRIPT), *(str(path) for path in paths)],
            capture_output=True,
            text=True,
            env=environment,
            check=False,
        )

    def test_clean_artifact_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "runtime.log"
            artifact.write_text("No sensitive content here.\n")
            result = self.run_scan(artifact)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("passed", result.stdout)

    def test_one_missing_artifact_invalidates_entire_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "runtime.log"
            artifact.write_text("No sensitive content here.\n")
            missing = Path(directory) / "missing.log"
            result = self.run_scan(artifact, missing)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("passed", result.stdout)
        self.assertNotIn(str(missing), result.stderr)

    def test_canary_is_detected(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "runtime.log"
            artifact.write_text(CANARY)
            result = self.run_scan(artifact)
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAILED", result.stderr)
        self.assertNotIn(CANARY, result.stderr)

    def test_explicit_symlink_cannot_hide_artifact_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / "runtime.log"
            artifact.write_text("No sensitive content here.\n")
            link = root / "linked.log"
            link.symlink_to(artifact)
            result = self.run_scan(link)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn(str(link), result.stderr)

    def test_nested_symlink_cannot_hide_artifact_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / "evidence"
            evidence.mkdir()
            artifact = root / "runtime.log"
            artifact.write_text("No sensitive content here.\n")
            (evidence / "linked.log").symlink_to(artifact)
            result = self.run_scan(evidence)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn(str(artifact), result.stderr)

    def test_scanner_failure_does_not_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / "runtime.log"
            artifact.write_text("No sensitive content here.\n")
            shim = root / "rg"
            shim.write_text("#!/bin/sh\nexit 2\n")
            shim.chmod(0o755)
            result = self.run_scan(artifact, env={"PATH": f"{root}:{os.environ['PATH']}"})
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
