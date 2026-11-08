#!/usr/bin/env python3
"""Exercise init's process coordination without sourcing init or using the network."""

import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "patches/init.sh").read_text()
BASH = os.environ.get("INIT_TEST_BASH", "bash")


def function(name):
    match = re.search(rf"^{name}\(\) \{{\n.*?^\}}$", SOURCE, re.M | re.S)
    if match is None:
        raise AssertionError(f"missing init function: {name}")
    return match.group()


FUNCTIONS = "\n".join(function(name) for name in (
    "validate_init_fetch_jobs", "stop_toolchain_fetches", "run_init_tasks"
))
MOCK = r'''
import json, os, pathlib, subprocess, sys, time
root = pathlib.Path(os.environ["MOCK_ROOT"])
name = sys.argv[1]
child = None
if os.environ.get("MOCK_MODE") == "cancel":
    child = subprocess.Popen([sys.executable, "-c",
        "import pathlib,sys,time; time.sleep(30); pathlib.Path(sys.argv[1]).touch()",
        str(root / (name + ".leaked"))])
(root / (name + ".start")).write_text(json.dumps({
    "time": time.monotonic(), "pid": os.getpid(),
    "child": child.pid if child else None}))
if os.environ.get("MOCK_FAIL") == name:
    time.sleep(0.05)
    sys.exit(int(os.environ.get("MOCK_EXIT", "7")))
delay = 0.8 if os.environ.get("MOCK_LONG") == name else 0.15
time.sleep(30 if child or os.environ.get("MOCK_SLOW") == name else delay)
(root / (name + ".end")).write_text(str(time.monotonic()))
'''
SCRIPT = r'''
set -euo pipefail
die() { printf '%s\n' "$1" >&2; exit 1; }
''' + FUNCTIONS + r'''
validate_init_fetch_jobs
prepare_toolchain() {
    python3 "$MOCK_ROOT/mock.py" toolchain
    touch "$MOCK_ROOT/toolchain.continued"
}
prepare_userspace() {
    python3 "$MOCK_ROOT/mock.py" userspace
    touch "$MOCK_ROOT/userspace.continued"
}
prepare_backports() {
    python3 "$MOCK_ROOT/mock.py" backports
    touch "$MOCK_ROOT/backports.continued"
}
wait() {
    # Deterministically exercise statuses Bash already collected before wait.
    if [ "${MOCK_WAIT_COMPLETED:-0}" = 1 ]; then
        for arg in "$@"; do
            case "${arg}" in
                [0-9]*) while kill -0 "${arg}" 2>/dev/null; do sleep 0.01; done ;;
            esac
        done
    fi
    builtin wait "$@"
}
run_init_tasks prepare_toolchain prepare_userspace prepare_backports
touch "$MOCK_ROOT/installed"
'''


class InitParallelTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="luna-init-test-")
        self.root = Path(self.temporary.name)
        (self.root / "mock.py").write_text(MOCK)
        self.processes = []

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate(timeout=3)
        # Only test-owned mock descendants; also clean up after failed assertions.
        for entry in self.root.glob("*.start"):
            state = json.loads(entry.read_text())
            for pid in (state["pid"], state["child"]):
                if pid and self.running(pid):
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
        self.temporary.cleanup()

    @staticmethod
    def running(pid):
        try:
            return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] != "Z"
        except FileNotFoundError:
            return False

    def start(self, jobs=None, **extra):
        env = dict(os.environ, MOCK_ROOT=str(self.root), **extra)
        env.pop("INIT_FETCH_JOBS", None)
        if jobs is not None:
            env["INIT_FETCH_JOBS"] = jobs
        process = subprocess.Popen([BASH, "-c", SCRIPT], env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)
        self.processes.append(process)
        return process

    def finish(self, process):
        stdout, stderr = process.communicate(timeout=5)
        return process.returncode, stdout + stderr

    def check_success(self, jobs, limit, **extra):
        code, output = self.finish(self.start(jobs, **extra))
        self.assertEqual(code, 0, output)
        self.assertTrue((self.root / "installed").exists())
        events = []
        for name in ("toolchain", "userspace", "backports"):
            events.append((json.loads((self.root / (name + ".start")).read_text())["time"], 1))
            events.append((float((self.root / (name + ".end")).read_text()), -1))
        active = peak = 0
        for _, change in sorted(events):
            active += change
            peak = max(peak, active)
        self.assertEqual(peak, limit)

    def test_default_is_serial(self):
        self.check_success(None, 1)

    def test_parallel_limit_is_two(self):
        self.check_success("2", 2)

    def test_completed_slot_is_refilled_before_slow_worker_finishes(self):
        self.check_success("2", 2, MOCK_LONG="toolchain")
        started = json.loads((self.root / "backports.start").read_text())["time"]
        self.assertLess(started, float((self.root / "toolchain.end").read_text()))

    def test_completed_tasks_are_reaped_successfully(self):
        self.check_success("2", 2, MOCK_WAIT_COMPLETED="1")

    def test_completed_failure_status_is_not_ignored(self):
        for status in ("7", "127"):
            with self.subTest(status=status):
                code, _ = self.finish(self.start("2", MOCK_FAIL="userspace", MOCK_EXIT=status,
                                                 MOCK_WAIT_COMPLETED="1"))
                self.assertNotEqual(code, 0)
                self.assertFalse((self.root / "backports.start").exists())
                self.assertFalse((self.root / "installed").exists())
                self.assertFalse((self.root / "userspace.continued").exists())
                for entry in self.root.iterdir():
                    if entry.name != "mock.py":
                        entry.unlink()

    def test_invalid_limits_fail_before_preparation(self):
        for jobs in ("", "0", "3", "two"):
            with self.subTest(jobs=jobs):
                code, _ = self.finish(self.start(jobs))
                self.assertNotEqual(code, 0)
                self.assertFalse(list(self.root.glob("*.start")))
                self.assertFalse((self.root / "installed").exists())

    def test_each_failure_blocks_later_tasks_and_install(self):
        for failed in ("toolchain", "userspace", "backports"):
            with self.subTest(failed=failed):
                slow = {"toolchain": "userspace", "userspace": "toolchain", "backports": ""}[failed]
                started = time.monotonic()
                code, _ = self.finish(self.start("2", MOCK_FAIL=failed, MOCK_SLOW=slow))
                self.assertNotEqual(code, 0)
                self.assertLess(time.monotonic() - started, 2)
                self.assertEqual((self.root / "backports.start").exists(), failed == "backports")
                self.assertFalse((self.root / "installed").exists())
                self.assertFalse((self.root / (failed + ".continued")).exists())
                for entry in self.root.glob("*.start"):
                    self.assertFalse(self.running(json.loads(entry.read_text())["pid"]))
                for entry in self.root.iterdir():
                    if entry.name != "mock.py":
                        entry.unlink()

    def test_signals_reap_workers_and_stop_descendants(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=sig):
                process = self.start("2", MOCK_MODE="cancel")
                deadline = time.monotonic() + 3
                while len(list(self.root.glob("*.start"))) < 2 and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertEqual(len(list(self.root.glob("*.start"))), 2)
                process.send_signal(sig)
                code, output = self.finish(process)
                self.assertEqual(code, 128 + sig, output)
                self.assertFalse((self.root / "installed").exists())
                self.assertFalse((self.root / "backports.start").exists())
                for entry in self.root.glob("*.start"):
                    state = json.loads(entry.read_text())
                    self.assertFalse(self.running(state["pid"]))
                    self.assertFalse(self.running(state["child"]))
                    entry.unlink()


if __name__ == "__main__":
    unittest.main()
