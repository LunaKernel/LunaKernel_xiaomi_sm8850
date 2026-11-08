#!/usr/bin/env python3
"""用临时 Git 仓库验证 CI 编排；阶段入口均为桩，不下载或编译。"""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import time
import unittest


PROJECT = Path(__file__).resolve().parents[2]
COMMON_SOURCE = "sources/aosp_common_6.12.92_kmi6_2026-09"
PHASES = ("init", "patch", "patch_external", "build")
FIXED_PINS = {
    "BACKPORT_BUNDLE_MANIFEST_SHA256": "1" * 64,
    "BACKPORT_BUNDLE_SHA256": "2" * 64,
    "BACKPORT_BUNDLE_URL": "https://example.invalid/backports.tar.gz",
    "CI_TOOLCHAIN_BUNDLE_SHA256": "3" * 64,
    "CI_TOOLCHAIN_BUNDLE_URL": "https://example.invalid/toolchain.tar.zst",
}
TOOLCHAIN_PATH = "work/tools/toolchain/ci-sm8850-r596125-rust1.97.0-bc39cdb1dc"
SOURCE_CACHES = ("aosp", "stable", "mainline", "kbuild", "clang", "rust", "build_tools")


class RunBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="luna-ci-run-test-")
        self.addCleanup(temporary.cleanup)
        self.temp = Path(temporary.name)
        self.root = self.temp / "repo"
        (self.root / "tools/ci").mkdir(parents=True)
        shutil.copyfile(PROJECT / "tools/ci/run_build.sh", self.root / "tools/ci/run_build.sh")
        shutil.copyfile(PROJECT / "tools/ci/notify_telegram.py", self.root / "tools/ci/notify_telegram.py")
        shutil.copyfile(PROJECT / "tools/release_artifacts.py", self.root / "tools/release_artifacts.py")
        for name in ('ci_dependencies.py', 'tree_sha256.py'):
            shutil.copyfile(PROJECT / 'tools' / name, self.root / 'tools' / name)
        image = self.root / "work/cache/downloads/ota/system_dlkm-os4.0.6.0.img"
        image.parent.mkdir(parents=True)
        image.write_bytes(b"public CI input fixture\n")
        # 只生成公开测试 pin，不读取项目真实 .env 或实际镜像。
        keys = """
CI_TOOLCHAIN_TREE_SHA256 ANDROID_NDK_TREE_SHA256 SM8850_C_ARCH SM8850_TUNE_CPU
AOSP_AUTOFDO_PROFILE_SHA256 CI_CLANG_REVISION AOSP_BUILD_TOOLS_REPO STOCK_AUDIT_TOOLS_COMMIT
STOCK_FSCK_EROFS_SHA256 STOCK_KMOD_SHA256 STOCK_LIBCXX_SHA256 ANDROID_NDK_URL
ANDROID_NDK_SHA256 IPSET_URL IPSET_SHA512 LIBMNL_URL LIBMNL_SHA256 KSU_MANAGER_APK_SHA256
COMMON_REPO
""".split()
        pins = dict.fromkeys(keys, "fixture")
        pins.update({
            "AK3_TEMPLATE_URL": "https://example.invalid/ak3-template.tar.gz",
            "AK3_TEMPLATE_SHA256": "8" * 64,
            "AK3_TEMPLATE_TREE_SHA256": "9" * 64,
            "ANDROID17_STOCK_SYSTEM_DLKM_URL": "https://example.invalid/system_dlkm.img",
            "ANDROID17_STOCK_SYSTEM_DLKM_IMAGE": image.relative_to(self.root).as_posix(),
            "ANDROID17_STOCK_SYSTEM_DLKM_SIZE": str(image.stat().st_size),
            "ANDROID17_STOCK_SYSTEM_DLKM_SHA256": hashlib.sha256(image.read_bytes()).hexdigest(),
            "BUILD_DIR": "work/cache/kernel",
            "BUILD_ENVIRONMENT_DIR": "work/tools",
            "CI_TOOLCHAIN_NAME": Path(TOOLCHAIN_PATH).name,
            "CI_TOOLCHAIN_TREE_SHA256": "e" * 64,
            "COMMON_SOURCE_DIR": COMMON_SOURCE,
            "COMMON_COMMIT": "d" * 40,
        })
        (self.root / ".env").write_text("".join(f"{key}={value}\n" for key, value in pins.items()))
        (self.root / ".gitignore").write_text("work/\nsources/\nkernel_out/\n")
        (self.root / "patches").mkdir()
        for phase in PHASES:
            (self.root / "patches" / f"{phase}.sh").write_text(
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
            f"{COMMON_SOURCE}/scripts/kallsyms.c": "token_syms\n",
            f"{COMMON_SOURCE}/.gitignore": "ignored/\n",
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
            **FIXED_PINS,
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
        backports = "work/cache/dependencies/backports-" + FIXED_PINS["BACKPORT_BUNDLE_MANIFEST_SHA256"]
        for path in (backports, TOOLCHAIN_PATH):
            directory = self.root / path
            directory.mkdir(parents=True)
            (directory / "fixture.txt").write_text("verified by init stub\n")
        self.git("-C", COMMON_SOURCE, "init", "-q")
        self.git("-C", COMMON_SOURCE, "add", ".")
        self.git("-C", COMMON_SOURCE, "-c", "user.name=CI Test", "-c", "user.email=ci@example.invalid",
                 "-c", "core.hooksPath=/dev/null", "commit", "-qm", "source fixture", "--no-gpg-sign")

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

    def commit_fixture_change(self, path, text):
        with (self.root / path).open("a") as stream:
            stream.write(text)
        self.git("add", path)
        self.git("-c", "user.name=CI Test", "-c", "user.email=ci@example.invalid",
                 "-c", "core.hooksPath=/dev/null", "commit", "-qm", "update fixture", "--no-gpg-sign")
        self.env["GITHUB_SHA"] = self.git("rev-parse", "HEAD").stdout.strip()

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
        self.assertNotIn("dependencies_mode", output)
        self.assertEqual(output["project_commit"], self.env["GITHUB_SHA"])
        self.assertEqual(env["LUNA_PROJECT_COMMIT"], self.env["GITHUB_SHA"])
        self.assertRegex(output["build_id"], "^luna-xiaomi17-g" + self.env["GITHUB_SHA"][:8] + r"-\d{8}-\d{4}$")
        self.assertEqual(env["LUNA_BUILD_ID"], output["build_id"])
        self.assertEqual(env["CI_RUN_DIR"], self.env["CI_RUN_DIR"])
        self.assertGreater(int(env["CI_BUILD_DEADLINE"]), time.time())
        self.assertNotIn("bundle_name", output)
        self.assertEqual(output["manager_key"], "luna-manager-v1-fixture")
        self.assertIn("ccache_prefix", output)
        self.assertIn("downloads_key", output)
        config = self.git("config", "--local", "--list").stdout
        self.assertNotIn("gc.auto=", config)
        self.assertIn("core.filemode=false", config)

    def test_input_checks_do_not_require_image_until_after_init(self):
        image = self.root / 'work/cache/downloads/ota/system_dlkm-os4.0.6.0.img'
        original = image.read_bytes()
        for content, message in ((None, '固定镜像缺失'), (b'short', '固定镜像大小'),
                                 (b'x' * len(original), '固定镜像 SHA-256')):
            with self.subTest(content=content):
                if content is None:
                    image.unlink()
                else:
                    image.write_bytes(content)
                self.assert_success(self.run_step('check-input'))
                self.assert_success(self.run_step('metadata'))
                self.reset_phase_records()
                result = self.run_step('init')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assert_calls(['init'])
                self.assertNotIn('[CACHE]', result.stdout)
        image.write_bytes(original)
        self.assert_success(self.run_step('init'))

    def test_input_pins_fail_before_init_and_download_keys_bind_content(self):
        self.assert_success(self.run_step('metadata'))
        original = self.read_assignments('github.output')['downloads_key']
        for key in ('AK3_TEMPLATE_URL', 'AK3_TEMPLATE_SHA256', 'AK3_TEMPLATE_TREE_SHA256',
                    'ANDROID17_STOCK_SYSTEM_DLKM_URL', 'ANDROID17_STOCK_SYSTEM_DLKM_SIZE'):
            with self.subTest(missing=key):
                text = (self.root / '.env').read_text()
                value = next(line.split('=', 1)[1] for line in text.splitlines() if line.startswith(key + '='))
                self.commit_fixture_change('.env', f'\n{key}=\n')
                for command in ('metadata', 'check-input'):
                    self.assertNotEqual(self.run_step(command).returncode, 0)
                self.assert_calls([])
                self.commit_fixture_change('.env', f'\n{key}={value}\n')
        for key in ('AK3_TEMPLATE_URL', 'ANDROID17_STOCK_SYSTEM_DLKM_URL'):
            self.commit_fixture_change('.env', f'\n{key}=https://example.invalid/relocated\n')
        self.assert_success(self.run_step('metadata'))
        self.assertEqual(original, self.read_assignments('github.output')['downloads_key'])
        for key in ('AK3_TEMPLATE_SHA256', 'ANDROID17_STOCK_SYSTEM_DLKM_SHA256'):
            self.commit_fixture_change('.env', f'\n{key}=' + 'a' * 64 + '\n')
            self.assert_success(self.run_step('metadata'))
            current = self.read_assignments('github.output')['downloads_key']
            self.assertNotEqual(original, current)
            original = current

    def test_fixed_cache_paths_and_sizes_do_not_require_source_caches(self):
        # fixture 不创建来源目录；fixed 缓存不能依赖它们。
        backports = "work/cache/dependencies/backports-" + FIXED_PINS["BACKPORT_BUNDLE_MANIFEST_SHA256"]
        self.assert_success(self.run_step("metadata"))
        output = self.read_assignments("github.output")
        self.assertEqual({key: value for key, value in output.items() if key.endswith("_path")}, {
            "common_path": COMMON_SOURCE, "backports_path": backports, "toolchain_path": TOOLCHAIN_PATH,
        })
        self.assertEqual(output["backports_key"], "luna-backports-v1-ubuntu24-x64-" + "1" * 64)
        self.assertEqual(output["toolchain_key"], "luna-toolchain-v1-ubuntu24-x64-" + "e" * 64)
        for name in SOURCE_CACHES:
            self.assertNotIn(name + "_key", output)
        result = self.run_step("init", **FIXED_PINS)
        self.assert_success(result)
        output = self.read_assignments("github.output")
        self.assertEqual(result.stdout.count("[CACHE]"), 3)
        for name in ("common", "backports", "toolchain"):
            self.assertEqual(output[name + "_save"], "true")
        for name in SOURCE_CACHES:
            self.assertNotIn(name + "_save", output)
        self.assert_calls(["init"])

    def test_fixed_keys_bind_content_without_binding_scheduling_or_urls(self):
        self.assert_success(self.run_step("metadata", **FIXED_PINS))
        original = self.read_assignments("github.output")
        self.commit_fixture_change("patches/init.sh", "# scheduling changed\n")
        relocated = {**FIXED_PINS, "BACKPORT_BUNDLE_URL": "https://example.invalid/moved.tar.gz",
                     "CI_TOOLCHAIN_BUNDLE_URL": "https://example.invalid/moved.tar.zst"}
        self.assert_success(self.run_step("metadata", **relocated, GITHUB_RUN_ID="456"))
        changed = self.read_assignments("github.output")
        for key in ("backports_key", "toolchain_key", "common_key", "downloads_key", "ccache_prefix"):
            self.assertEqual(original[key], changed[key])
        # 压缩归档改变只影响下载缓存，不改变已解包内容的身份。
        repacked = {**FIXED_PINS, "BACKPORT_BUNDLE_SHA256": "4" * 64,
                    "CI_TOOLCHAIN_BUNDLE_SHA256": "5" * 64}
        self.assert_success(self.run_step("metadata", **repacked))
        changed = self.read_assignments("github.output")
        self.assertNotEqual(original["downloads_key"], changed["downloads_key"])
        for key in ("backports_key", "toolchain_key", "common_key"):
            self.assertEqual(original[key], changed[key])
        replacement = {**FIXED_PINS, "BACKPORT_BUNDLE_MANIFEST_SHA256": "6" * 64}
        self.assert_success(self.run_step("metadata", **replacement))
        changed = self.read_assignments("github.output")
        self.assertNotEqual(original["backports_key"], changed["backports_key"])
        self.assertTrue(changed["backports_path"].endswith("6" * 64))
        self.assertEqual(original["toolchain_key"], changed["toolchain_key"])
        self.commit_fixture_change(".env", "\nCI_TOOLCHAIN_TREE_SHA256=" + "7" * 64 + "\n")
        self.assert_success(self.run_step("metadata", **FIXED_PINS))
        changed = self.read_assignments("github.output")
        self.assertNotEqual(original["toolchain_key"], changed["toolchain_key"])
        self.assertEqual(original["backports_key"], changed["backports_key"])
        self.assertEqual(original["common_key"], changed["common_key"])

    def test_missing_or_partial_fixed_pins_fail_before_init_without_falling_back(self):
        empty = dict.fromkeys(FIXED_PINS, "")
        cases = [empty]
        cases += [{**FIXED_PINS, missing: ""} for missing in FIXED_PINS]
        cases += [{**empty, key: value} for key, value in FIXED_PINS.items()]
        # 未设置与显式空值都必须失败。
        for key in FIXED_PINS:
            self.env.pop(key)
        cases.append({})
        for pins in cases:
            for command in ("metadata", "init"):
                with self.subTest(pins=tuple(pins), command=command):
                    result = self.run_step(command, **pins)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("固定依赖 pin 不完整", result.stderr)
                    self.assert_calls([])
                    self.assertFalse((self.temp / "github.output").exists())

    def test_fixed_pins_reject_invalid_digests_and_unsafe_toolchain_paths(self):
        for key in ("BACKPORT_BUNDLE_MANIFEST_SHA256", "BACKPORT_BUNDLE_SHA256",
                    "CI_TOOLCHAIN_BUNDLE_SHA256"):
            with self.subTest(key=key):
                result = self.run_step("metadata", **{**FIXED_PINS, key: "invalid"})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("固定依赖摘要无效", result.stderr)
        for assignment in ("CI_TOOLCHAIN_TREE_SHA256=invalid", "CI_TOOLCHAIN_NAME=../escape",
                           "BUILD_ENVIRONMENT_DIR=work/../sources", "BUILD_ENVIRONMENT_DIR=work"):
            with self.subTest(assignment=assignment):
                self.commit_fixture_change(".env", "\n" + assignment + "\n")
                result = self.run_step("metadata", **FIXED_PINS)
                self.assertNotEqual(result.returncode, 0)
                # 恢复本轮字段，确保每个路径检查独立触达。
                key = assignment.split("=", 1)[0]
                value = {"CI_TOOLCHAIN_TREE_SHA256": "e" * 64,
                         "CI_TOOLCHAIN_NAME": Path(TOOLCHAIN_PATH).name,
                         "BUILD_ENVIRONMENT_DIR": "work/tools"}[key]
                self.commit_fixture_change(".env", f"\n{key}={value}\n")

    def test_common_cache_binds_fixed_source_without_invalidating_other_caches(self):
        self.assert_success(self.run_step("metadata"))
        original = self.read_assignments("github.output")
        self.assertEqual(original["common_path"], COMMON_SOURCE)
        self.commit_fixture_change(".env", "\nCOMMON_COMMIT=" + "e" * 40 + "\n")
        self.assert_success(self.run_step("metadata"))
        changed = self.read_assignments("github.output")
        self.assertNotEqual(original["common_key"], changed["common_key"])
        for key in original:
            if key.endswith("_key") and key != "common_key":
                self.assertEqual(original[key], changed[key])
        self.commit_fixture_change(".env", "\nCOMMON_SOURCE_DIR=sources\n")
        result = self.run_step("metadata")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("common 缓存路径不在固定范围", result.stderr)

    def test_common_cache_excludes_patched_staged_untracked_and_ignored_files(self):
        for relative, staged in (("scripts/kallsyms.c", False), ("scripts/kallsyms.c", True),
                                 ("unexpected.txt", False), ("ignored/build.o", False)):
            with self.subTest(path=relative, staged=staged):
                path = self.root / COMMON_SOURCE / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                original = path.read_bytes() if path.exists() else None
                path.write_bytes((original or b"") + b"changed\n")
                if staged:
                    self.git("-C", COMMON_SOURCE, "add", relative)
                try:
                    result = self.run_step("init")
                    self.assert_success(result)
                    self.assertEqual(self.read_assignments("github.output")["common_save"], "false")
                finally:
                    if original is None:
                        path.unlink()
                        if path.parent.name == "ignored":
                            path.parent.rmdir()
                    else:
                        path.write_bytes(original)
                    if staged:
                        self.git("-C", COMMON_SOURCE, "add", relative)
        self.assert_success(self.run_step("init"))
        self.assertEqual(self.read_assignments("github.output")["common_save"], "true")

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
        for name in ("patches/patch.sh", "unexpected.txt"):
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

    def prepare_release(self):
        manager = "KernelSU_v3.3.1-29-gab05a062_32709-release.apk"
        self.commit_fixture_change(".env", "\nKSU_MANAGER_APK_NAME=" + manager +
                                   "\nKSU_MANAGER_APK_SHA256=" + hashlib.sha256(b"apk fixture").hexdigest() +
                                   "\nIPSET_VERSION=7.24\nANDROID17_STOCK_SYSTEM_DLKM_FINGERPRINT="
                                   "Xiaomi/pudding/pudding:16/build/OS4.0.6.0.XPCCN:user/release-keys\n")
        commit = self.env["GITHUB_SHA"]
        stem = f"luna-xiaomi17-g{commit[:8]}-20261108"
        build_id = stem + "-1200"
        self.env.update(LUNA_BUILD_ID=build_id, LUNA_PROJECT_COMMIT=commit)
        kernel, audit, component = (prefix + build_id for prefix in
                                    ("kernel_out/", "work/audit/", "work/components/"))
        files = {
            kernel + "/Image-" + stem: b"kernel fixture",
            kernel + "/" + stem + ".zip": b"zip fixture",
            kernel + "/" + manager: b"apk fixture",
            audit + "/" + stem + "-audit.zip": b"audit fixture",
            component + "/ipset-arm64-v7.24": b"ipset fixture",
            component + "/ipset-v7.24-android-arm64-kernelsu-module.zip": b"module fixture",
        }
        files[audit + "/.build-artifacts"] = "".join(
            hashlib.sha256(data).hexdigest() + "  " + name + "\n" for name, data in files.items()).encode()
        files[audit + "/release.tsv"] = (
            "field\tvalue\nbuild_id\t" + build_id + "\nproject_commit\t" + commit +
            "\nvalidation_status\tawaiting-device\nksu_manager_apk\t" + manager + "\n").encode()
        for name, data in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        return files

    def test_export_contains_only_complete_verified_delivery_and_preserves_sources(self):
        files = self.prepare_release()
        audit = self.root / "work/audit" / self.env["LUNA_BUILD_ID"]
        (audit / "unlisted.log").write_text("not a release artifact\n")
        self.assert_success(self.run_step("export"))
        bundle = self.root / self.read_assignments("github.output")["bundle_path"]
        with tarfile.open(bundle) as archive:
            members = archive.getmembers()
            self.assertCountEqual([member.name for member in members], files)
            self.assertTrue(all(member.isfile() for member in members))
            for member in members:
                self.assertEqual(archive.extractfile(member).read(), files[member.name])
        restored = self.temp / "restored"
        restored.mkdir()
        result = subprocess.run([
            "python3", "-c",
            "import sys; from pathlib import Path; from release_artifacts import import_archive; "
            "import_archive(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])",
            str(bundle), str(restored), self.env["LUNA_BUILD_ID"],
        ], cwd=self.root / "tools", env=self.env, capture_output=True, text=True, timeout=10)
        self.assert_success(result)
        for name, data in files.items():
            self.assertEqual((self.root / name).read_bytes(), data)
            self.assertEqual((restored / name).read_bytes(), data)
        self.assertFalse((self.root / self.env["CI_RUN_DIR"] / "export").exists())
        digest = hashlib.sha256(bundle.read_bytes()).hexdigest()
        result = self.run_step("export")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("拒绝覆盖", result.stderr)
        self.assertEqual(hashlib.sha256(bundle.read_bytes()).hexdigest(), digest)

    def test_export_rejects_corrupt_artifacts_and_missing_component_record(self):
        files = self.prepare_release()
        for name, data in files.items():
            if name.endswith(("/.build-artifacts", "/release.tsv")):
                continue
            with self.subTest(path=name):
                path = self.root / name
                path.write_bytes(data + b"corrupt")
                result = self.run_step("export")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("产物缺失或摘要不匹配", result.stderr)
                path.write_bytes(data)
        manifest = self.root / "work/audit" / self.env["LUNA_BUILD_ID"] / ".build-artifacts"
        manifest.write_text("".join(line for line in manifest.read_text().splitlines(keepends=True)
                                    if not line.rstrip().endswith("/ipset-arm64-v7.24")))
        result = self.run_step("export")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("完整六文件集合", result.stderr)
        self.assertFalse(list((self.root / self.env["CI_RUN_DIR"]).glob("*.tar.gz")))
        self.assertFalse((self.temp / "github.output").exists())

    def test_summary_without_destination_is_optional(self):
        self.assert_success(self.run_step("summary", GITHUB_STEP_SUMMARY=""))


if __name__ == "__main__":
    unittest.main()
