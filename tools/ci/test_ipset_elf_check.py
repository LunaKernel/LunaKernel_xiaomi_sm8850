#!/usr/bin/env python3
"""直接执行构建脚本的 IPSet 检查，复现 readelf 被提前关闭管道的情况。"""

import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "build.sh").read_text()
MATCH = re.search(
    r'^    "\$\{ndk_bin\}/llvm-readelf" -l "\$\{binary\}" \| .*\\\n'
    r'        die "ipset Android linker ABI 不匹配"$', SOURCE, re.M)
if MATCH is None:
    raise AssertionError("未找到 build.sh 的 IPSet interpreter 检查")
CHECK = MATCH.group()

MOCK = r'''
import os, pathlib, sys, time
mode = os.environ["MOCK_MODE"]
line = {
    "wrong": "Requesting program interpreter: /lib/ld-linux-aarch64.so.1\n",
    "missing": "Program Headers:\n",
}.get(mode, "Requesting program interpreter: /system/bin/linker64\n")
status = 0
try:
    os.write(1, line.encode())
    time.sleep(0.05)
    # 超过管道容量；旧 grep -q 在首行匹配后退出，生产者确定收到 EPIPE。
    for _ in range(1024):
        os.write(1, b"x" * 4095 + b"\n")
    if mode == "error":
        status = 74
except BrokenPipeError:
    status = 74
pathlib.Path(os.environ["MOCK_STATUS"]).write_text(str(status))
sys.exit(status)
'''


class IPSetElfCheckTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="luna-ipset-elf-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        readelf = self.root / "llvm-readelf"
        readelf.write_text("#!" + sys.executable + "\n" + MOCK)
        readelf.chmod(0o755)

    def run_check(self, mode="valid", check=CHECK):
        script = r'''
set -euo pipefail
die() { printf '%s\n' "$1" >&2; exit 1; }
ndk_bin="$MOCK_ROOT"
binary="$MOCK_ROOT/ipset"
''' + check + "\nprintf 'CHECK_PASSED\\n'\n"
        result = subprocess.run(
            ["bash", "-c", script], capture_output=True, text=True, timeout=5,
            env={**os.environ, "MOCK_ROOT": str(self.root), "MOCK_MODE": mode,
                 "MOCK_STATUS": str(self.root / "producer-status")})
        status = int((self.root / "producer-status").read_text())
        return result, status

    def assert_rejected(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ipset Android linker ABI 不匹配", result.stderr)
        self.assertNotIn("CHECK_PASSED", result.stdout)

    def test_valid_interpreter_consumes_complete_output(self):
        result, producer_status = self.run_check()
        self.assertEqual(producer_status, 0)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CHECK_PASSED", result.stdout)

    def test_quiet_grep_reproduces_broken_pipe(self):
        # 仅修改临时执行段用于反证，磁盘上的实际构建脚本保持不变。
        self.assertIn("grep -F ", CHECK)
        result, producer_status = self.run_check(check=CHECK.replace("grep -F ", "grep -Fq ", 1))
        self.assertEqual(producer_status, 74)
        self.assert_rejected(result)

    def test_wrong_or_missing_interpreter_is_rejected(self):
        for mode in ("wrong", "missing"):
            with self.subTest(mode=mode):
                result, producer_status = self.run_check(mode)
                self.assertEqual(producer_status, 0)
                self.assert_rejected(result)

    def test_readelf_failure_is_rejected_even_after_match(self):
        result, producer_status = self.run_check("error")
        self.assertEqual(producer_status, 74)
        self.assert_rejected(result)


if __name__ == "__main__":
    unittest.main()
