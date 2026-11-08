#!/usr/bin/env python3
"""离线验证 fixed 初始化的 pin、安装树与准备边界。"""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "patches/init.sh").read_text()
FIXED_PINS = {
    "BACKPORT_BUNDLE_MANIFEST_SHA256": "1" * 64,
    "BACKPORT_BUNDLE_SHA256": "2" * 64,
    "BACKPORT_BUNDLE_URL": "https://example.invalid/backports.tar.gz",
    "CI_TOOLCHAIN_BUNDLE_SHA256": "3" * 64,
    "CI_TOOLCHAIN_BUNDLE_URL": "https://example.invalid/toolchain.tar.zst",
}


def function(name):
    match = re.search(rf"^{name}\(\) \{{\n.*?^\}}$", SOURCE, re.M | re.S)
    if match is None:
        raise AssertionError(f"missing init function: {name}")
    return match.group()


BUNDLE_BODY = SOURCE[SOURCE.index('BACKPORT_BUNDLE_DIR="$(python3'):
                     SOURCE.index('\nverify_source_baseline\n')]
FUNCTIONS = function("parse_init_args")
PREAMBLE = r'''
set -euo pipefail
die() { printf '%s\n' "$1" >&2; exit 1; }
log_step() { :; }
log_success() { printf 'success|%s\n' "$1"; }
python3() {
    printf 'helper|%s\n' "$*" >&2
    [ "${FAIL_HELPER:-0}" = 0 ] || return 7
    printf '%s\n' "$HOST_WORKSPACE_DIR"
}
'''


class InitScopeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="luna-init-scope-")
        self.root = Path(self.temporary.name)
        self.manifests = self.root / "patches/backports"
        (self.manifests / "kmi6-2026-09-independent").mkdir(parents=True)
        self.selected = self.manifests / "kmi6-2026-09-selected-backports.tsv"
        self.selected.write_text("# fixture\n")

    def tearDown(self):
        self.temporary.cleanup()

    def run_script(self, script, args=()):
        return subprocess.run(
            [os.environ.get("INIT_TEST_BASH", "bash"), "-c", script, "test", *args],
            env={**os.environ, "HOST_WORKSPACE_DIR": str(self.root)},
            text=True, capture_output=True, timeout=10,
        )

    def scope(self, args=(), extra=""):
        return self.run_script(PREAMBLE + FUNCTIONS + '\nparse_init_args "$@"\n'
                               + extra + "\n" + BUNDLE_BODY, args)

    def validate_pins(self, pins, args=()):
        keys = (*FIXED_PINS, "CI_TOOLCHAIN_TREE_SHA256")
        # 只读取测试生成的公开 pin，执行真实启动段中的校验调用。
        (self.root / ".env").write_text("".join(f"{key}={value}\n" for key, value in pins.items()))
        definitions = "\n".join(function(name) for name in (
            "parse_init_args", "validate_dependency_pins",
        ))
        startup = SOURCE[SOURCE.index('parse_init_args "$@"\n'):
                         SOURCE.index('[ "${ENABLE_KERNELSU:-0}"')]
        return self.run_script(
            PREAMBLE + "\nunset " + " ".join(keys) + "\n" + definitions + r'''
validate_init_fetch_jobs() { :; }
load_env_file() { . "$1"; }
''' + startup + r'''
printf 'preparation\n'
''', args)

    def test_dependency_pins_require_complete_fixed_mode(self):
        result = self.validate_pins({})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("固定依赖 pin 不完整", result.stderr)
        self.assertEqual(result.stdout, "")
        result = self.validate_pins({**FIXED_PINS, "CI_TOOLCHAIN_TREE_SHA256": "e" * 64})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "preparation\n")

    def test_partial_dependency_pins_fail_before_preparation_or_cache_reuse(self):
        cases = [{key: value} for key, value in FIXED_PINS.items()]
        cases += [{key: value for key, value in FIXED_PINS.items() if key != missing}
                  for missing in FIXED_PINS]
        for pins in cases:
            with self.subTest(pins=tuple(pins)):
                result = self.validate_pins({**pins, "CI_TOOLCHAIN_TREE_SHA256": "e" * 64})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("固定依赖 pin 不完整", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_dependency_pins_reject_invalid_digests_before_preparation(self):
        pins = {**FIXED_PINS, "CI_TOOLCHAIN_TREE_SHA256": "e" * 64}
        for key in ("BACKPORT_BUNDLE_MANIFEST_SHA256", "BACKPORT_BUNDLE_SHA256",
                    "CI_TOOLCHAIN_BUNDLE_SHA256", "CI_TOOLCHAIN_TREE_SHA256"):
            for value in ("a" * 63, "g" * 64, "A" * 64):
                with self.subTest(key=key, value=value):
                    result = self.validate_pins({**pins, key: value})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("固定依赖摘要无效: " + key, result.stderr)
                    self.assertEqual(result.stdout, "")
        result = self.validate_pins(FIXED_PINS)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("固定依赖摘要无效: CI_TOOLCHAIN_TREE_SHA256", result.stderr)

    def test_dependency_pins_require_https_even_with_installed_tree(self):
        pins = {**FIXED_PINS, "CI_TOOLCHAIN_TREE_SHA256": "e" * 64}
        (self.root / "toolchain").mkdir()
        for key in ("BACKPORT_BUNDLE_URL", "CI_TOOLCHAIN_BUNDLE_URL"):
            for url in ("http://example.invalid/package", "file:///package", "https://"):
                with self.subTest(key=key, url=url):
                    result = self.validate_pins({**pins, key: url})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("必须使用 HTTPS: " + key, result.stderr)
                    self.assertEqual(result.stdout, "")

    def test_bundle_preparation_uses_consumer_helper(self):
        result = self.scope()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("prepare-backports --workspace", result.stderr)
        self.assertIn("success|", result.stdout)

    def test_bundle_helper_failure_stops_initialization(self):
        result = self.scope(extra="BACKPORT_BUNDLE_MANIFEST_SHA256=fixed-pin FAIL_HELPER=1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("success|", result.stdout)
        self.assertNotIn("repo|", result.stdout)

    def test_invalid_arguments_fail_before_preparation(self):
        for args in (("--unknown",), ("--audit-history",), ("--prepare-dependencies",)):
            with self.subTest(args=args):
                result = self.scope(args)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("repo|", result.stdout)

    def toolchain_script(self, extra=""):
        definitions = "\n".join(function(name) for name in (
            "parse_init_args", "verify_installed_toolchain",
            "setup_toolchain",
        ))
        return PREAMBLE + definitions + r'''
parse_init_args "$@"
CI_TOOLCHAIN_DIR="$HOST_WORKSPACE_DIR/toolchain"
CI_TOOLCHAIN_TREE_SHA256=expected-tree
DL_DIR="$HOST_WORKSPACE_DIR/downloads"
TREE_RESULT=expected-tree CI_TOOLCHAIN_BUNDLE_SHA256= CI_TOOLCHAIN_BUNDLE_URL=
tree_sha256() { printf 'tree|%s\n' "$1" >&2; printf '%s\n' "$TREE_RESULT"; }
verify_toolchain_identity() {
    printf 'identity\n'
    [ "${FAIL_IDENTITY:-0}" = 0 ] || die 'identity mismatch'
}
prepare_stock_tools() { printf 'stock\n'; }
python3() {
    printf 'helper|%s\n' "$*" >&2
    [ "${FAIL_HELPER:-0}" = 0 ] || return 7
    mkdir -p "$CI_TOOLCHAIN_DIR"
    printf '%s\n' "${HELPER_PATH:-$CI_TOOLCHAIN_DIR}"
}
''' + extra + '\nsetup_toolchain\n'

    def test_installed_toolchain_precedes_sources_assets_and_bundle(self):
        (self.root / "toolchain").mkdir()
        result = self.run_script(self.toolchain_script("CI_TOOLCHAIN_BUNDLE_SHA256=fixed-pin"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("stock\n"), 1)
        self.assertIn("identity", result.stdout)
        self.assertNotIn("helper|", result.stderr)
        self.assertNotIn("official-sources", result.stdout)

    def test_toolchain_cache_requires_tree_and_compiler_identity(self):
        (self.root / "toolchain").mkdir()
        (self.root / "toolchain.project-tree-sha256").write_text("expected-tree\n")
        for extra in ("TREE_RESULT=changed-tree", "FAIL_IDENTITY=1",
                      "tree_sha256() { return 7; }"):
            with self.subTest(extra=extra):
                result = self.run_script(self.toolchain_script(extra))
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("official-sources", result.stdout)

    def test_toolchain_bundle_is_verified_after_install(self):
        result = self.run_script(self.toolchain_script("CI_TOOLCHAIN_BUNDLE_SHA256=fixed-pin"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("prepare-toolchain --workspace", result.stderr)
        self.assertIn("tree|", result.stderr)
        self.assertIn("identity", result.stdout)
        self.assertIn("stock", result.stdout)
        self.assertNotIn("official-sources", result.stdout)

    def test_toolchain_bundle_failure_wrong_path_or_tree_stops_install(self):
        for extra in ("FAIL_HELPER=1", "HELPER_PATH=/wrong", "TREE_RESULT=changed-tree"):
            with self.subTest(extra=extra):
                # Each invocation starts with no installed tree.
                installed = self.root / "toolchain"
                if installed.exists():
                    installed.rmdir()
                result = self.run_script(self.toolchain_script(
                    "CI_TOOLCHAIN_BUNDLE_SHA256=fixed-pin\n" + extra))
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("identity", result.stdout)
                self.assertNotIn("official-sources", result.stdout)

    def test_daily_bundle_uses_shared_scheduler_without_nesting(self):
        definitions = "\n".join(function(name) for name in (
            "prepare_build_dependencies",
        ))
        script = PREAMBLE + definitions + r'''
run_init_tasks() { printf 'shared|%s\n' "$*"; }
prepare_userspace_sources() { printf 'userspace\n'; }
setup_toolchain() { printf 'toolchain\n'; }
prepare_build_dependencies
'''
        result = self.run_script(script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "shared|setup_toolchain prepare_userspace_sources",
        ])

    def ndk_script(self, extra=""):
        return PREAMBLE + function("prepare_android_ndk") + r'''
ENVIRONMENT_DIR="$HOST_WORKSPACE_DIR/env"
ANDROID_NDK_VERSION=fixture ANDROID_NDK_API=35
ANDROID_NDK_DIR="$ENVIRONMENT_DIR/toolchain/android-ndk-fixture"
SOURCE_DOWNLOAD_DIR="$HOST_WORKSPACE_DIR/downloads"
ANDROID_NDK_URL=https://fixture ANDROID_NDK_SHA1=sha1 ANDROID_NDK_SHA256=sha256
ANDROID_NDK_TREE_SHA256=expected-tree
TREE_RESULT=expected-tree
tree_sha256() { printf 'tree|%s\n' "$1" >&2; printf '%s\n' "$TREE_RESULT"; }
sha1sum() { printf 'sha1\n' >&2; printf 'sha1  fixture\n'; }
sha256sum() { printf 'sha256\n' >&2; printf 'sha256  fixture\n'; }
curl() {
    local destination
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -o ]; then shift; destination="$1"; fi
        shift
    done
    printf 'download\n' >&2
    : > "$destination"
}
unzip() {
    printf 'extract\n' >&2
    local compiler="$4/android-ndk-fixture/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android35-clang"
    mkdir -p "$(dirname "$compiler")"
    touch "$compiler"
    chmod 0755 "$compiler"
}
''' + extra + '\nprepare_android_ndk\n'

    def test_installed_ndk_does_not_need_archive_or_download(self):
        installed = self.root / "env/toolchain/android-ndk-fixture"
        installed.mkdir(parents=True)
        result = self.run_script(self.ndk_script())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("tree|", result.stderr)
        for forbidden in ("download", "sha1\n", "sha256\n", "extract"):
            self.assertNotIn(forbidden, result.stderr)

    def test_new_ndk_archive_is_hashed_once_before_extraction(self):
        result = self.run_script(self.ndk_script())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.splitlines().count("sha1"), 1)
        self.assertEqual(result.stderr.splitlines().count("sha256"), 1)
        self.assertLess(result.stderr.index("sha256\n"), result.stderr.index("extract\n"))

    def test_modified_ndk_fails_before_archive_access(self):
        installed = self.root / "env/toolchain/android-ndk-fixture"
        installed.mkdir(parents=True)
        installed.with_name(installed.name + ".project-tree-sha256").write_text("expected-tree\n")
        result = self.run_script(self.ndk_script("TREE_RESULT=changed-tree"))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("download", result.stderr)
        self.assertNotIn("extract", result.stderr)


if __name__ == "__main__":
    unittest.main()
