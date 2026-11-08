#!/usr/bin/env python3
"""只执行宿主空间准备的 Python 段，所有磁盘查询和删除均使用桩。"""

import contextlib
import io
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import call, patch


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


if __name__ == "__main__":
    unittest.main()
