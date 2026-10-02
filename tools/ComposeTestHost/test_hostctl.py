import hashlib
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest

import hostctl


class HostProtocolTests(unittest.TestCase):
    def state(self, value, return_count=0):
        return {"schemaVersion": 1, "syntheticOnly": True, "instanceID": "instance-a",
                "sequence": 2, "nativeFieldReturnCount": return_count,
                "fields": {"native-field": {
                    "sha256": hashlib.sha256(value.encode("utf-8")).hexdigest(),
                    "containsOnlySyntheticFixtures": True, "redacted": False}}}

    def test_exact_value_detects_duplicate_insertion(self):
        fixture = hostctl.FIXTURES["short"]
        self.assertTrue(hostctl.verify_value(self.state(fixture), "native-field", "short")["passed"])
        self.assertFalse(hostctl.verify_value(self.state(fixture * 2), "native-field", "short")["passed"])
        self.assertTrue(hostctl.verify_value(self.state(fixture * 2), "native-field", "short", copies=2)["passed"])

    def test_unicode_comparison_is_exact(self):
        text = hostctl.FIXTURES["unicode"]
        self.assertTrue(hostctl.verify_value(self.state(text), "native-field", "unicode")["passed"])
        changed = text.replace("é", "e")
        self.assertFalse(hostctl.verify_value(self.state(changed), "native-field", "unicode")["passed"])

    def test_no_return_checks_observed_events(self):
        state = self.state(hostctl.FIXTURES["short"], return_count=1)
        self.assertFalse(hostctl.verify_value(state, "native-field", "short", no_return=True)["passed"])

    def test_secure_target_requires_empty_observation(self):
        state = {"fields": {"native-secure": {"isEmpty": True, "utf16Length": 0}}, "secureFieldReturnCount": 0}
        self.assertTrue(hostctl.verify_value(state, "native-secure", no_return=True)["passed"])
        with self.assertRaises(hostctl.ProtocolError):
            hostctl.verify_value(state, "native-secure", "short")
        state["fields"]["native-secure"]["utf16Length"] = 1
        self.assertFalse(hostctl.verify_value(state, "native-secure")["passed"])

    def test_redacted_or_missing_observation_never_passes(self):
        state = self.state(hostctl.FIXTURES["short"])
        state["fields"]["native-field"]["redacted"] = True
        self.assertFalse(hostctl.verify_value(state, "native-field", "short")["passed"])
        with self.assertRaises(hostctl.ProtocolError):
            hostctl.verify_value(state, "web-textarea", "short")

    def test_command_waits_for_matching_acknowledgement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stale = {"schemaVersion": 1, "syntheticOnly": True, "commandID": "stale", "status": "ok"}
            (root / "state.json").write_text(json.dumps(stale), encoding="utf-8")
            def acknowledge():
                deadline = time.monotonic() + 1
                while not (root / "command.json").exists() and time.monotonic() < deadline:
                    time.sleep(0.005)
                command = json.loads((root / "command.json").read_text(encoding="utf-8"))
                response = dict(stale, commandID=command["id"], instanceID="instance-a")
                temporary = root / ".state.json"
                temporary.write_text(json.dumps(response), encoding="utf-8")
                temporary.replace(root / "state.json")
            thread = threading.Thread(target=acknowledge)
            thread.start()
            result = hostctl.send_command(root, "snapshot", timeout=1, instance_id="instance-a")
            thread.join(timeout=1)
            self.assertNotEqual(result["commandID"], "stale")
            self.assertFalse(thread.is_alive())

    def test_stale_state_times_out_and_restart_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = {"schemaVersion": 1, "syntheticOnly": True, "commandID": "stale", "status": "ok", "instanceID": "restarted"}
            (root / "state.json").write_text(json.dumps(state), encoding="utf-8")
            with self.assertRaises(hostctl.ProtocolError):
                hostctl.send_command(root, "snapshot", timeout=0.06)
            with self.assertRaises(hostctl.ProtocolError):
                hostctl.send_command(root, "snapshot", timeout=0.06, instance_id="old")

    def test_insecure_or_symlink_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            public = root / "public"
            public.mkdir(mode=0o755)
            link = root / "link"
            link.symlink_to(root, target_is_directory=True)
            for path in (public, link):
                with self.assertRaises(hostctl.ProtocolError):
                    hostctl.private_directory(path)


if __name__ == "__main__":
    unittest.main()
