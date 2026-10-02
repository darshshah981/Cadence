#!/usr/bin/env python3
"""Control only ComposeTestHost's private synthetic-fixture protocol.

This utility does not launch, activate, type into, or inspect any other app.
The explicit `focus` command asks the host to activate its own test window.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import time
import uuid


FIXTURES = {
    "short": "SYNTHETIC alpha 314.",
    "unicode": "SYNTHETIC café 🌿 東京.",
    "multiline": "SYNTHETIC first line.\nSYNTHETIC second line.",
    "partial-prefix": "S",
}
FIELDS = ("native-field", "native-editor", "native-secure", "web-textarea",
          "web-contenteditable", "web-cursor-button")
TARGETS = FIELDS + ("native-button", "web-button")


class ProtocolError(Exception):
    pass


def private_directory(path):
    path = Path(path)
    attributes = path.lstat()
    if (not path.is_absolute() or not stat.S_ISDIR(attributes.st_mode)
            or attributes.st_uid != os.getuid()
            or stat.S_IMODE(attributes.st_mode) != 0o700):
        raise ProtocolError("Expected an absolute private directory owned by this user, mode 0700.")
    return path


def read_state(directory):
    path = directory / "state.json"
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > 1_048_576:
        raise ProtocolError("Invalid state file.")
    result = json.loads(path.read_text(encoding="utf-8"))
    if result.get("schemaVersion") != 1 or result.get("syntheticOnly") is not True:
        raise ProtocolError("Unsupported host state.")
    return result


def send_command(directory, action, target=None, timeout=5.0, instance_id=None):
    """One caller at a time. UUID acknowledgement prevents accepting stale state."""
    directory = private_directory(directory)
    command_id = str(uuid.uuid4()).upper()
    command = {"schemaVersion": 1, "id": command_id, "action": action}
    if target is not None:
        command["target"] = target
    fd, temporary = tempfile.mkstemp(prefix=".command-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(command, stream)
        os.replace(temporary, directory / "command.json")
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            state = read_state(directory)
        except FileNotFoundError:
            state = {}
        if instance_id is not None and state.get("instanceID") not in (None, instance_id):
            raise ProtocolError("Host process instance changed.")
        if state.get("commandID") == command_id:
            if state.get("status") not in ("ok", "ready", "loading"):
                raise ProtocolError("Host rejected the command: " + str(state.get("status")))
            return state
        time.sleep(0.025)
    raise ProtocolError("Timed out waiting for this command's acknowledgement.")


def verify_value(state, target, fixture=None, copies=1, no_return=False):
    """Compare complete synthetic values, not substrings or claimed key events."""
    observed = state.get("fields", {}).get(target)
    if observed is None:
        raise ProtocolError("Target field was not included in the snapshot.")
    expected = "" if fixture is None else FIXTURES[fixture] * copies
    if target == "native-secure":
        if expected:
            raise ProtocolError("Secure-field verification permits only an empty result.")
        matches = observed.get("isEmpty") is True and observed.get("utf16Length") == 0
    else:
        expected_hash = hashlib.sha256(expected.encode("utf-8")).hexdigest()
        matches = (observed.get("sha256") == expected_hash
                   and observed.get("containsOnlySyntheticFixtures") is True
                   and observed.get("redacted") is False)
    if no_return:
        count_key = {"native-field": "nativeFieldReturnCount",
                     "native-editor": "nativeEditorReturnCount",
                     "native-secure": "secureFieldReturnCount"}.get(target)
        count = state.get(count_key) if count_key else state.get("webReturnCounts", {}).get(target)
        matches = matches and count == 0
    return {"passed": matches, "target": target, "expectedFixture": fixture,
            "expectedCopies": 0 if fixture is None else copies,
            "checkedNoReturn": no_return, "instanceID": state.get("instanceID"),
            "sequence": state.get("sequence"), "observation": observed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--instance-id", help="Fail if the host has restarted.")
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("init", help="Create a new empty mode-0700 run directory.")
    commands.add_parser("fixtures", help="Print the public synthetic input fixtures.")
    for action in ("reset", "snapshot", "close-window", "reopen-window", "quit", "wait-ready"):
        commands.add_parser(action)
    focus = commands.add_parser("focus")
    focus.add_argument("target", choices=TARGETS)
    expect = commands.add_parser("expect")
    expect.add_argument("target", choices=FIELDS)
    expect.add_argument("--fixture", choices=FIXTURES, help="Omit to verify an empty field.")
    expect.add_argument("--copies", type=int, default=1)
    expect.add_argument("--no-return", action="store_true")
    args = parser.parse_args()
    try:
        if not 0 < args.timeout <= 60:
            raise ProtocolError("Timeout must be between zero and 60 seconds.")
        if args.action == "init":
            if not args.directory.is_absolute():
                raise ProtocolError("Use an absolute run-directory path.")
            args.directory.mkdir(mode=0o700, parents=False, exist_ok=False)
            print(json.dumps({"directory": str(args.directory), "status": "created"}))
            return 0
        if args.action == "fixtures":
            print(json.dumps(FIXTURES, ensure_ascii=False, indent=2))
            return 0
        if args.action == "expect" and args.copies < 1:
            raise ProtocolError("Expected copies must be positive.")
        action = "snapshot" if args.action in ("expect", "wait-ready") else args.action
        state = send_command(args.directory, action, getattr(args, "target", None),
                             args.timeout, args.instance_id)
        if args.action == "wait-ready":
            deadline = time.monotonic() + args.timeout
            while not state.get("webReady"):
                if time.monotonic() >= deadline:
                    raise ProtocolError("WebKit did not become ready.")
                time.sleep(0.05)
                state = send_command(args.directory, "snapshot", timeout=args.timeout,
                                     instance_id=args.instance_id)
        result = state
        if args.action == "expect":
            result = verify_value(state, args.target, args.fixture, args.copies, args.no_return)
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
        return 0 if result.get("passed", True) else 1
    except (OSError, ValueError, ProtocolError):
        # Do not reflect arbitrary file contents or raw platform error strings.
        print(json.dumps({"status": "error", "reason": "Host protocol or verification request failed."}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
