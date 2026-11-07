#!/usr/bin/env python3
"""用临时 Git 仓库验证 CI 编排；阶段入口均为桩，不下载或编译。"""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


PROJECT = Path(__file__).resolve().parents[2]
PHASES = ("init", "patch", "patch_external", "build")


class RunBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="luna-ci-run-test-")
        self.addCleanup(temporary.cleanup)
        self.temp = Path(temporary.name)
        self.root = self.temp / "repo"
        (self.root / "tools/ci").mkdir(parents=True)
        shutil.copyfile(PROJECT / "tools/ci/run_build.sh", self.root / "tools/ci/run_build.sh")
        shutil.copyfile(PROJECT / "tools/release_artifacts.py", self.root / "tools/release_artifacts.py")
        image = self.root / "ci/inputs/os4.0.6.0/system_dlkm.img"
        image.parent.mkdir(parents=True)
        image.write_bytes(b"public CI input fixture\n")
        # 只生成公开测试 pin，不读取项目真实 .env 或实际镜像。
        keys = """
CI_TOOLCHAIN_TREE_SHA256 ANDROID_NDK_TREE_SHA256 SM8850_C_ARCH SM8850_TUNE_CPU
AOSP_AUTOFDO_PROFILE_SHA256 CI_CLANG_REVISION CI_BINDGEN_URL CI_BINDGEN_SHA256
CI_HOST_BC_URL CI_HOST_BC_SHA256 AOSP_BUILD_TOOLS_REPO STOCK_AUDIT_TOOLS_COMMIT
STOCK_FSCK_EROFS_SHA256 STOCK_KMOD_SHA256 STOCK_LIBCXX_SHA256 ANDROID_NDK_URL
ANDROID_NDK_SHA256 IPSET_URL IPSET_SHA512 LIBMNL_URL LIBMNL_SHA256 MAGISK_APK_URL
MAGISK_APK_SHA256 AK3_BUSYBOX_URL AK3_BUSYBOX_SHA256 KSU_MANAGER_APK_SHA256
""".split()
        pins = dict.fromkeys(keys, "fixture")
        pins.update({
            "ANDROID17_STOCK_SYSTEM_DLKM_IMAGE": image.relative_to(self.root).as_posix(),
            "ANDROID17_STOCK_SYSTEM_DLKM_SIZE": str(image.stat().st_size),
            "ANDROID17_STOCK_SYSTEM_DLKM_SHA256": hashlib.sha256(image.read_bytes()).hexdigest(),
            "BUILD_DIR": "work/cache/kernel",
            "COMMON_SOURCE_DIR": "work/source",
        })
        (self.root / ".env").write_text("".join(f"{key}={value}\n" for key, value in pins.items()))
        (self.root / ".gitignore").write_text("work/\n")
        for phase in PHASES:
            (self.root / f"{phase}.sh").write_text(
                "set -euo pipefail\n"
                f"printf '%s\\n' {phase} >> \"$MOCK_CALLS\"\n"
                f"if [[ ${{MOCK_FAIL_PHASE:-}} == {phase} ]]; then exit 7; fi\n"
                f"if [[ ${{MOCK_TIMEOUT_PHASE:-}} == {phase} ]]; then exec sleep 10; fi\n"
            )
        binary = self.temp / "bin/ccache"
        binary.parent.mkdir()
        binary.write_text(
            "#!/usr/bin/env bash\n"
            "if [[ $1 == --show-stats && ${MOCK_CCACHE_FAIL:-} == 1 ]]; then exit 9; fi\n"
            "printf 'fixture ccache %s\\n' \"$1\"\n"
        )
        binary.chmod(0o755)
        # 成功编排所需的最小证据桩；此处不重复测试 Kbuild 规则。
        files = {
            "work/cache/kernel/scripts/kallsyms": "#!/bin/sh\nexit 0\n",
            "work/cache/kernel/scripts/.kallsyms.cmd": "cc scripts/kallsyms.c\n",
            "work/source/scripts/kallsyms.c": "token_syms\n",
            "work/cache/kernel/.config": "CONFIG_CC_OPT_NO_ADDRSIG=y\nCONFIG_CC_OPT_STRICT_FLEX_ARRAYS=y\n",
            "work/cache/kernel/arch/arm64/kernel/pi/.map_range.o.cmd": "cc -fno-addrsig -mstrict-align\n",
        }
        for name, content in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        (self.root / "work/cache/kernel/scripts/kallsyms").chmod(0o755)
        # 不继承宿主 Git 配置、凭据入口或 shell 启动脚本。
        self.env = {
            "PATH": str(binary.parent) + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"),
            "LC_ALL": "C.UTF-8",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "PYTHONDONTWRITEBYTECODE": "1",
            "GITHUB_ACTIONS": "true",
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_RUN_ID": "123",
            "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_ENV": str(self.temp / "github.env"),
            "GITHUB_OUTPUT": str(self.temp / "github.output"),
            "GITHUB_STEP_SUMMARY": str(self.temp / "summary.md"),
            "CI_RUN_DIR": "work/tmp/ci-123-1",
            "MOCK_CALLS": str(self.root / "work/calls"),
        }
        self.git("init", "-q", "--initial-branch=main")
        self.git("add", ".")
        self.git("-c", "user.name=CI Test", "-c", "user.email=ci@example.invalid",
                 "-c", "core.hooksPath=/dev/null", "commit", "-qm", "test fixture", "--no-gpg-sign")
        self.env["GITHUB_SHA"] = self.git("rev-parse", "HEAD").stdout.strip()

    def git(self, *arguments):
        return subprocess.run(["git", *arguments], cwd=self.root, env=self.env,
                              capture_output=True, text=True, timeout=10, check=True)

    def run_step(self, command, **environment):
        env = {**self.env, "CI_BUILD_DEADLINE": str(int(time.time()) + 30), **environment}
        return subprocess.run(["bash", "tools/ci/run_build.sh", command], cwd=self.root,
                              env=env, capture_output=True, text=True, timeout=10)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def read_assignments(self, name):
        return dict(line.split("=", 1) for line in (self.temp / name).read_text().splitlines())

    def reset_phase_records(self):
        calls = Path(self.env["MOCK_CALLS"])
        calls.unlink(missing_ok=True)
        logs = self.root / self.env["CI_RUN_DIR"] / "logs"
        if logs.is_dir():
            for path in logs.iterdir():
                path.unlink()

    def assert_calls(self, expected):
        calls = Path(self.env["MOCK_CALLS"])
        self.assertEqual(calls.read_text().splitlines() if calls.exists() else [], expected)

    def test_metadata_fixes_identity_and_removes_only_checkout_gc(self):
        self.git("config", "--local", "gc.auto", "0")
        self.git("config", "--local", "core.filemode", "false")
        self.assert_success(self.run_step("metadata"))
        output = self.read_assignments("github.output")
        env = self.read_assignments("github.env")
        self.assertEqual(output["project_commit"], self.env["GITHUB_SHA"])
        self.assertEqual(env["LUNA_PROJECT_COMMIT"], self.env["GITHUB_SHA"])
        self.assertRegex(output["build_id"], "^luna-xiaomi17-g" + self.env["GITHUB_SHA"][:8] + r"-\d{8}-\d{4}$")
        self.assertEqual(env["LUNA_BUILD_ID"], output["build_id"])
        self.assertEqual(env["CI_RUN_DIR"], self.env["CI_RUN_DIR"])
        self.assertGreater(int(env["CI_BUILD_DEADLINE"]), time.time())
        self.assertEqual(output["bundle_name"], f"luna-{self.env['GITHUB_SHA'][:8]}-123-1.tar.gz")
        self.assertEqual(output["manager_key"], "luna-manager-v1-fixture")
        self.assertIn("ccache_prefix", output)
        self.assertIn("downloads_key", output)
        config = self.git("config", "--local", "--list").stdout
        self.assertNotIn("gc.auto=", config)
        self.assertIn("core.filemode=false", config)

    def test_metadata_accepts_no_gc_override_and_rejects_unknown_value(self):
        self.assert_success(self.run_step("metadata"))
        self.git("config", "--local", "gc.auto", "1")
        result = self.run_step("metadata")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("gc.auto", result.stderr)
        self.assertEqual(self.git("config", "--local", "gc.auto").stdout.strip(), "1")

    def test_metadata_rejects_wrong_run_or_commit_before_any_phase(self):
        cases = {"GITHUB_ACTIONS": "false", "GITHUB_REF": "refs/heads/topic",
                 "GITHUB_EVENT_NAME": "push", "GITHUB_RUN_ID": "bad",
                 "GITHUB_RUN_ATTEMPT": "", "GITHUB_SHA": "0" * 40}
        for key, value in cases.items():
            with self.subTest(key=key):
                self.assertNotEqual(self.run_step("metadata", **{key: value}).returncode, 0)
                self.assertFalse((self.temp / "github.output").exists())
                self.assert_calls([])

    def test_metadata_rejects_dirty_tracked_and_untracked_files(self):
        for name in ("patch.sh", "unexpected.txt"):
            with self.subTest(path=name):
                path = self.root / name
                original = path.read_bytes() if path.exists() else None
                path.write_bytes((original or b"") + b"# dirty\n")
                try:
                    result = self.run_step("metadata")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("工作区不干净", result.stderr)
                finally:
                    if original is None:
                        path.unlink()
                    else:
                        path.write_bytes(original)

    def check_phase_stop(self, phase, *, timeout=False):
        self.reset_phase_records()
        command = "init" if phase == "init" else "compile"
        environment = {"MOCK_TIMEOUT_PHASE" if timeout else "MOCK_FAIL_PHASE": phase}
        if timeout:
            environment["CI_BUILD_DEADLINE"] = str(int(time.time()) + 2)
        result = self.run_step(command, **environment)
        expected_code = 124 if timeout else 7
        self.assertEqual(result.returncode, expected_code, result.stdout + result.stderr)
        expected = ["init"] if phase == "init" else list(PHASES[1:PHASES.index(phase) + 1])
        self.assert_calls(expected)
        records = (self.root / self.env["CI_RUN_DIR"] / "logs/stages.tsv").read_text().splitlines()
        self.assertEqual([line.split("\t")[0] for line in records], expected)
        self.assertEqual(records[-1].split("\t")[1], str(expected_code))

    def test_nonzero_stops_at_each_phase(self):
        for phase in PHASES:
            with self.subTest(phase=phase):
                self.check_phase_stop(phase)

    def test_timeout_stops_at_each_phase(self):
        for phase in PHASES:
            with self.subTest(phase=phase):
                self.check_phase_stop(phase, timeout=True)

    def test_expired_deadline_does_not_start_phase(self):
        result = self.run_step("compile", CI_BUILD_DEADLINE=str(int(time.time()) - 1))
        self.assertNotEqual(result.returncode, 0)
        self.assert_calls([])

    def test_success_then_summary_survives_missing_ccache_stats(self):
        self.assert_success(self.run_step("init"))
        self.assert_success(self.run_step("compile"))
        self.assert_calls(list(PHASES))
        result = self.run_step(
            "summary", MOCK_CCACHE_FAIL="1", CI_COMPILE_RESULT="success", CI_UPLOAD_RESULT="success",
            CI_ARTIFACT_URL="https://github.com/example/luna/actions/runs/123/artifacts/456")
        self.assert_success(result)
        summary = (self.temp / "summary.md").read_text()
        # 这些以 '-' 起始的 printf 必须传入 '--'，否则摘要会把成功任务变成失败。
        self.assertIn("- 构建检查：`success`；产物上传：`success`", summary)
        self.assertIn("- ccache 恢复键：", summary)
        self.assertIn("- [完整交付集合]", summary)
        self.assertIn("待实机验收", summary)
        self.assertIn("| build | 0 |", summary)
        self.assertNotIn("invalid option", result.stderr)

    def test_summary_without_destination_is_optional(self):
        self.assert_success(self.run_step("summary", GITHUB_STEP_SUMMARY=""))


if __name__ == "__main__":
    unittest.main()
