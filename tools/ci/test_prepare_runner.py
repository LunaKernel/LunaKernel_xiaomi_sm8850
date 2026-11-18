#!/usr/bin/env python3
"""离线检查宿主准备策略；磁盘操作和 apt 命令均使用桩。"""

import contextlib
import hashlib
import io
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import call, patch

from tools.ci.apt_archives import copy_verified, package_plan


SCRIPT = Path(__file__).with_name("prepare_runner.sh").read_text()
SPACE_CHECK = compile(SCRIPT.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0],
                      "prepare_runner.sh:space", "exec")


class PrepareRunnerTests(unittest.TestCase):
    def run_space_check(self, free, *, symlink=False, directory=True):
        with patch("shutil.disk_usage", side_effect=[SimpleNamespace(free=n * 2**30) for n in free]), \
                patch("pathlib.Path.is_symlink", return_value=symlink), \
                patch("pathlib.Path.exists", return_value=True), \
                patch("pathlib.Path.is_dir", return_value=directory), \
                patch("shutil.rmtree") as remove, contextlib.redirect_stdout(io.StringIO()):
            try:
                exec(SPACE_CHECK, {})
            except SystemExit as error:
                return remove.call_args_list, str(error)
            return remove.call_args_list, None

    def test_enough_space_does_not_delete_or_inspect_sdk_paths(self):
        removed, error = self.run_space_check([50], symlink=True, directory=False)
        self.assertIsNone(error)
        self.assertEqual(removed, [])

    def test_cleanup_stops_as_soon_as_space_is_sufficient(self):
        removed, error = self.run_space_check([40, 45, 51])
        self.assertIsNone(error)
        self.assertEqual(removed, [call(Path("/usr/local/lib/android")),
                                   call(Path("/usr/share/dotnet"))])

    def test_insufficient_space_still_fails(self):
        removed, error = self.run_space_check([40] * 9)
        self.assertEqual(len(removed), 8)
        self.assertIn("不足 50 GiB", error)

    def test_symlink_and_non_directory_are_rejected_before_deletion(self):
        for options in ({"symlink": True}, {"directory": False}):
            with self.subTest(options=options):
                removed, error = self.run_space_check([40], **options)
                self.assertEqual(removed, [])
                self.assertIsNotNone(error)


class RunnerPackagesTests(unittest.TestCase):
    def test_cached_indices_and_refresh_fallback(self):
        function = SCRIPT[SCRIPT.index('install_runner_packages() {'):
                          SCRIPT.index('packages_started=')]
        stub = r'''
set -eu
timeout() { shift 2; "$@"; }
sudo() {
    shift 4
    printf '%s\n' "$1" >&2
    case "$1" in
        update) return "$UPDATE_STATUS" ;;
        install)
            if [[ " $* " == *" Acquire::Retries=0 "* ]]; then
                return "$FIRST_STATUS"
            fi
            return "$SECOND_STATUS"
            ;;
    esac
}
FIRST_STATUS=$1 UPDATE_STATUS=$2 SECOND_STATUS=$3
LUNA_APT_STAGE=
apt=(sudo -n env DEBIAN_FRONTEND=noninteractive apt-get)
packages=(test)
'''
        for statuses, calls, code in (
            ((0, 9, 9), ['install'], 0),
            ((7, 0, 0), ['install', 'update', 'install'], 0),
            ((7, 9, 0), ['install', 'update'], 9),
            ((7, 0, 9), ['install', 'update', 'install'], 9),
        ):
            with self.subTest(statuses=statuses):
                result = subprocess.run(['bash', '-c', stub + function + '\ninstall_runner_packages\n',
                                         'test', *map(str, statuses)], capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(result.stderr.splitlines(), calls)


class AptArchivesTests(unittest.TestCase):
    def test_plan_requires_unique_names_and_sha256(self):
        digest = hashlib.sha256(b'pkg').hexdigest()
        line = f"'http://archive.ubuntu.com/ubuntu/pkg.deb' pkg_1%3a2_amd64.deb 3 SHA256:{digest}\n"
        self.assertEqual(package_plan(['Reading package lists...\n', line]),
                         {'pkg_1%3a2_amd64.deb': (3, digest)})
        for lines in ([line, line], [line.replace('SHA256:', 'MD5Sum:')],
                      [line.replace(' pkg_', ' ../pkg_')]):
            with self.subTest(lines=lines), self.assertRaises(ValueError):
                package_plan(lines)

    def test_copy_verifies_bytes_and_rejects_symlinks_and_extras(self):
        with tempfile.TemporaryDirectory() as directory:
            source, target = (Path(directory) / name for name in ('restore', 'archives'))
            source.mkdir()
            target.mkdir()
            (source / 'valid.deb').write_bytes(b'pkg')
            (source / 'wrong.deb').write_bytes(b'bad')
            (source / 'link.deb').symlink_to('valid.deb')
            (source / 'extra.deb').write_bytes(b'pkg')
            plan = dict.fromkeys(('valid.deb', 'wrong.deb', 'link.deb', 'missing.deb'),
                                 (3, hashlib.sha256(b'pkg').hexdigest()))
            self.assertEqual(copy_verified(plan, source, target), 1)
            self.assertEqual([path.name for path in target.iterdir()], ['valid.deb'])
            self.assertEqual((target / 'valid.deb').read_bytes(), b'pkg')


if __name__ == "__main__":
    unittest.main()
