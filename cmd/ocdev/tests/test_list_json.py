#!/usr/bin/env python3
"""Fake-Incus CLI tests: python3 cmd/ocdev/tests/test_list_json.py ./bin/ocdev.

Build the repository binary first. No real Incus executable is reachable.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BINARY = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else None


class ListJsonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.bin),
                        FAKE_ROOT=str(self.root))
        self.script("groups", "print('incus-admin')\n")
        self.script("incus", '''import json, os, pathlib, sys
root = pathlib.Path(os.environ["FAKE_ROOT"])
with (root / "calls").open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1:] not in (["list", "--format=json", "ocdev-"],
                        ["list", "--format=csv", "-c", "n,s", "ocdev-"]):
    print("Unexpected Incus command", file=sys.stderr)
    sys.exit(99)
sys.stdout.write((root / "response").read_text())
sys.stderr.write((root / "stderr").read_text())
sys.exit(int((root / "exit").read_text()))
''')
        self.response([])

    def script(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n" + body)
        path.chmod(0o755)

    def response(self, data, code=0, stderr="", raw=False):
        (self.root / "response").write_text(data if raw else json.dumps(data))
        (self.root / "exit").write_text(str(code))
        (self.root / "stderr").write_text(stderr)

    def run_list(self, *args):
        return subprocess.run([str(BINARY), "list", *args], env=self.env,
                              text=True, capture_output=True, timeout=10)

    def assert_failure(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertTrue(result.stderr)
        self.assertNotIn("private-sentinel", result.stderr)

    def test_projection_and_prefix_and_ports(self):
        state = self.home / ".ocdev"
        state.mkdir()
        ports = state / "ports"
        ports.write_text("demo-ocdev-copy:2210\nstopped:2220\n")
        before = ports.read_bytes()
        self.response([
            {"name": "ocdev-demo-ocdev-copy", "status": "Running",
             "config": {"volatile.uuid": "dummy-uuid", "user.private": "private-sentinel"},
             "expanded_config": {"user.private": "private-sentinel"}},
            {"name": "ocdev-stopped", "status": "Stopped", "config": {}},
            {"name": "other-ocdev-demo", "status": "Running"},
        ])
        result = self.run_list("--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(json.loads(result.stdout), [
            dict(name="demo-ocdev-copy", instance="ocdev-demo-ocdev-copy",
                 status="Running", uuid="dummy-uuid", ssh_port=2210),
            dict(name="stopped", instance="ocdev-stopped", status="Stopped",
                 uuid=None, ssh_port=2220),
        ])
        self.assertEqual(ports.read_bytes(), before)
        self.assertEqual(sorted(p.name for p in state.iterdir()), ["ports"])
        self.assertEqual((self.root / "calls").read_text(),
                         '["list", "--format=json", "ocdev-"]\n')

    def test_missing_uuid_and_allocation_no_state_created(self):
        for config in (None, {}, {"volatile.uuid": ""}, {"volatile.uuid": None}):
            with self.subTest(config=config):
                self.response([dict(name="ocdev-demo", status="Frozen", config=config)])
                result = self.run_list("--json")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), [dict(
                    name="demo", instance="ocdev-demo", status="Frozen",
                    uuid=None, ssh_port=None)])
                self.assertFalse((self.home / ".ocdev").exists())
        self.response([dict(name="ocdev-demo", status="Running")])
        self.assertIsNone(json.loads(self.run_list("--json").stdout)[0]["uuid"])

    def test_unavailable_allocations_are_null(self):
        state = self.home / ".ocdev"
        state.mkdir()
        self.response([dict(name="ocdev-demo", status="Running")])
        for allocation in ("other:2200\n", "demo:invalid\n", "demo:0\n", "demo:-1\n"):
            with self.subTest(allocation=allocation):
                (state / "ports").write_text(allocation)
                result = self.run_list("--json")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIsNone(json.loads(result.stdout)[0]["ssh_port"])

    def test_empty_success(self):
        result = self.run_list("--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "[]\n")
        self.assertEqual(result.stderr, "")
        self.assertFalse((self.home / ".ocdev").exists())

    def test_nonmatching_instances_are_empty(self):
        self.response([dict(name="unrelated", status="Running")])
        self.assertEqual(self.run_list("--json").stdout, "[]\n")

    def test_query_failure_is_not_empty_success(self):
        for output in ("[]", "No container found"):
            self.response(output, code=1, stderr="query failed private-sentinel\n", raw=True)
            self.assert_failure(self.run_list("--json"))

    def test_warning_does_not_corrupt_json(self):
        self.response([], stderr="warning from Incus\n")
        result = self.run_list("--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "[]\n")
        self.assertEqual(result.stderr, "")

    def test_malformed_metadata_never_emits_partial_json(self):
        valid = dict(name="ocdev-good", status="Running")
        for bad in ("", "not json private-sentinel", "{}", "null", '[42]',
                    json.dumps([valid, dict(name="ocdev-bad", status=12)]),
                    json.dumps([dict(status="Running")]),
                    json.dumps([dict(name="ocdev-demo", status="Running", config=[])]),
                    json.dumps([dict(name="ocdev-demo", status="Running",
                                     config={"volatile.uuid": 12})])):
            with self.subTest(data=bad):
                self.response(bad, raw=True)
                self.assert_failure(self.run_list("--json"))

    def test_prerequisite_failures(self):
        self.script("groups", "print('users')\n")
        self.assert_failure(self.run_list("--json"))
        self.assertFalse((self.root / "calls").exists())
        (self.bin / "incus").unlink()
        self.assert_failure(self.run_list("--json"))
        self.assertFalse((self.home / ".ocdev").exists())

    def test_default_table_unchanged(self):
        self.response("ocdev-demo,RUNNING\n", raw=True)
        result = self.run_list()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout,
                         f"{'NAME':<20} {'STATUS':<10} SSH PORT\n"
                         f"{'demo':<20} {'RUNNING':<10} N/A\n")
        self.assertEqual((self.root / "calls").read_text(),
                         '["list", "--format=csv", "-c", "n,s", "ocdev-"]\n')


if __name__ == "__main__":
    if BINARY is None or not BINARY.is_file():
        sys.exit("Pass a freshly built repository binary; no installed binary is used.")
    unittest.main()
