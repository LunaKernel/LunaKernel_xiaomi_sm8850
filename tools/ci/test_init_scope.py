#!/usr/bin/env python3
"""离线验证审计资料的准备范围，不执行完整初始化或访问网络。"""

import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "init.sh").read_text()
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


AUDIT_BODY = re.search(
    r'^if \[ "\$\{ENABLE_BACKPORT_AUDIT\}" = "1" \] && backport_bundle_enabled; then\n.*?^fi$',
    SOURCE, re.M | re.S,
).group()
FUNCTIONS = "\n".join(function(name) for name in (
    "parse_init_args", "backport_bundle_enabled", "required_aosp_refs",
    "prepare_aosp_audit_sources",
))
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
BACKPORT_BUNDLE_MANIFEST_SHA256=
resolve_workspace_path() { printf '%s/%s\n' "$HOST_WORKSPACE_DIR" "$1"; }
ensure_audit_repo() { printf 'repo|%s\n' "$2"; }
fetch_audit_ref() { printf 'fetch|%s|%s\n' "$3" "$4"; }
hydrate_audit_history() { printf 'history|%s\n' "$*"; }
hydrate_audit_commit_history() { printf 'history|%s\n' "$*"; }
hydrate_audit_blob() { printf 'blob|%s|%s\n' "$3" "$4"; }
hydrate_audit_patches() { printf 'patches|%s\n' "$*"; }
prepare_kbuild_audit() { printf 'kbuild\n'; }
git() { printf '%s\n' "$ANDROID17_ABI_CLASSIFICATION_COMMIT"; }
env() { shift; "$@"; }
bash() {
    if [ "$2" = list ]; then
        case "$3" in
            stable|mainline) printf '%s-%s\n' "$1" "$3" ;;
        esac
    else
        printf 'verify|%s|%s\n' "$1" "$2"
        [ "$1:$2" != "${FAIL_VERIFY:-}" ] || return 7
    fi
}
ENABLE_BACKPORT_AUDIT=1 ENABLE_SELECTED_BACKPORTS=1
BACKPORT_TOOL=selected INDEPENDENT_BACKPORT_TOOL=independent
BACKPORT_AUDIT_SNAPSHOT=2026-08-28
AOSP_BACKPORT_AUDIT_DIR=aosp COMMON_REPO=official-aosp
AOSP_BACKPORT_AUDIT_BASE_COMMIT=old-aosp-base
AOSP_BACKPORT_AUDIT_SHALLOW_SINCE=2023-10-04
COMMON_COMMIT=common COMMON_ABI_STG_SHA256=common-stg
ABI_BASELINE_COMMIT=old-abi ABI_BASELINE_STG_SHA256=old-stg
ANDROID17_ABI_CLASSIFICATION_REF=old-classification
ANDROID17_ABI_CLASSIFICATION_COMMIT=3333333333333333333333333333333333333333
ANDROID17_ABI_CLASSIFICATION_QCOM_SHA256=qcom-sha
ANDROID17_ABI_CLASSIFICATION_XIAOMI_SHA256=xiaomi-sha
AOSP_BACKPORT_AUDIT_REFS='android-mainline:1111111111111111111111111111111111111111 candidate:2222222222222222222222222222222222222222 old-classification:3333333333333333333333333333333333333333'
LINUX_STABLE_AUDIT_DIR=stable LINUX_STABLE_AUDIT_REPO=official-stable
LINUX_STABLE_AUDIT_BASE_COMMIT=stable-base LINUX_STABLE_AUDIT_COMMIT=stable-tip
LINUX_STABLE_AUDIT_REF=linux-6.12.y
LINUX_MAINLINE_AUDIT_DIR=mainline LINUX_MAINLINE_AUDIT_REPO=official-mainline
LINUX_MAINLINE_AUDIT_BASE_COMMIT=mainline-base LINUX_MAINLINE_AUDIT_COMMIT=mainline-tip
ENABLE_F2FS_DIO_OVERWRITE_FAST_PATH=1
F2FS_DIO_OVERWRITE_FAST_PATH_AOSP_REF=android-mainline
F2FS_DIO_OVERWRITE_FAST_PATH_COMMIT=direct-aosp
ENABLE_IPV6_MLD_DELAYED_WORK_UAF_FIX=1
IPV6_MLD_DELAYED_WORK_STABLE_COMMIT=direct-stable
IPV6_MLD_DELAYED_WORK_UPSTREAM_COMMIT=direct-mainline-origin
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
                               + extra + "\n" + AUDIT_BODY, args)

    def validate_pins(self, pins, args=()):
        keys = (*FIXED_PINS, "CI_TOOLCHAIN_TREE_SHA256")
        # 只读取测试生成的公开 pin，执行真实启动段中的校验调用。
        (self.root / ".env").write_text("".join(f"{key}={value}\n" for key, value in pins.items()))
        definitions = "\n".join(function(name) for name in (
            "parse_init_args", "validate_dependency_pins", "backport_bundle_enabled",
            "toolchain_bundle_enabled",
        ))
        startup = SOURCE[SOURCE.index('parse_init_args "$@"\n'):
                         SOURCE.index('[ "${ENABLE_KERNELSU:-0}"')]
        return self.run_script(
            PREAMBLE + "\nunset " + " ".join(keys) + "\n" + definitions + r'''
validate_init_fetch_jobs() { :; }
load_env_file() { . "$1"; }
''' + startup + r'''
if backport_bundle_enabled; then printf 'backports-fixed\n'; fi
if toolchain_bundle_enabled; then printf 'toolchain-fixed\n'; fi
printf 'preparation\n'
''', args)

    def test_dependency_pins_allow_source_or_complete_fixed_mode(self):
        result = self.validate_pins({})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "preparation\n")
        result = self.validate_pins({**FIXED_PINS, "CI_TOOLCHAIN_TREE_SHA256": "e" * 64})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "backports-fixed\ntoolchain-fixed\npreparation\n")

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

    def test_maintenance_ignores_partial_or_invalid_producer_pins(self):
        cases = ({"BACKPORT_BUNDLE_MANIFEST_SHA256": "producer-pin"},
                 {**FIXED_PINS, "CI_TOOLCHAIN_BUNDLE_URL": "http://producer.invalid/package"})
        for args in (("--prepare-dependencies",), ("--audit-history",)):
            for pins in cases:
                with self.subTest(args=args, pins=tuple(pins)):
                    result = self.validate_pins(pins, args)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, "preparation\n")

    def test_default_prepares_only_selected_sources(self):
        result = self.scope()
        self.assertEqual(result.returncode, 0, result.stderr)
        fetched = [line.split("|")[1] for line in result.stdout.splitlines()
                   if line.startswith("fetch|")]
        self.assertEqual(fetched, ["aosp/android-mainline", "linux-stable/linux-6.12.y",
                                   "linux-mainline/snapshot-2026-08-28"])
        self.assertNotIn("blob|", result.stdout)
        for required in ("direct-aosp", "direct-stable", "direct-mainline-origin",
                         "selected-stable", "independent-stable", "selected-mainline",
                         "independent-mainline", "kbuild", "verify|selected|verify-sources",
                         "verify|independent|verify-sources"):
            self.assertIn(required, result.stdout)
        self.assertNotIn("stable-base", result.stdout)
        self.assertNotIn("mainline-base", result.stdout)

    def test_bundle_skips_official_audit_preparation(self):
        result = self.scope(extra="BACKPORT_BUNDLE_MANIFEST_SHA256=fixed-pin")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("prepare-backports --workspace", result.stderr)
        for forbidden in ("repo|", "fetch|", "verify|", "patches|", "kbuild"):
            self.assertNotIn(forbidden, result.stdout)

    def test_bundle_helper_failure_stops_initialization(self):
        result = self.scope(extra="BACKPORT_BUNDLE_MANIFEST_SHA256=fixed-pin FAIL_HELPER=1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("success|", result.stdout)
        self.assertNotIn("repo|", result.stdout)

    def test_dependency_maintenance_uses_official_sources_with_bundle_pin(self):
        result = self.scope(("--prepare-dependencies",),
                            extra="BACKPORT_BUNDLE_MANIFEST_SHA256=fixed-pin")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("repo|", result.stdout)
        self.assertIn("verify|independent|verify-sources", result.stdout)
        self.assertNotIn("prepare-backports", result.stderr)
        self.assertNotIn("blob|", result.stdout)

    def test_maintenance_exports_source_audit_mode(self):
        for args in (("--prepare-dependencies",), ("--audit-history",)):
            with self.subTest(args=args):
                result = self.run_script(PREAMBLE + FUNCTIONS + r'''
parse_init_args "$@"
export -p | command grep 'declare -x BACKPORT_SOURCE_AUDIT="1"'
''', args)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_bundle_skips_legacy_direct_source_verification(self):
        body = SOURCE[SOURCE.index("if ! backport_bundle_enabled &&"):
                      SOURCE.index("\nverify_source_baseline\n")]
        setup = PREAMBLE + FUNCTIONS + r'''
parse_init_args "$@"
verify_aosp_backport_source() { printf 'legacy-source\n'; }
for feature in F2FS_DIO_OVERWRITE_FAST_PATH BLK_WBT_DONE_FAST_PATH \
        MEMCG_RSTAT_FAST_PATH TCP_RECV_MSTAMP_FAST_PATH IPV6_MLD_UAF_FIX; do
    printf -v "ENABLE_${feature}" 1
    for field in AOSP_REF COMMIT COMMIT_DATE PATCH_ID; do
        printf -v "${feature}_${field}" fixture
    done
done
'''
        result = self.run_script(setup + '\nBACKPORT_BUNDLE_MANIFEST_SHA256=fixed-pin\n' + body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("legacy-source", result.stdout)
        result = self.run_script(setup + '\n' + body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("legacy-source"), 5)

    def test_maintenance_keeps_history_and_classification(self):
        result = self.scope(("--audit-history",))
        self.assertEqual(result.returncode, 0, result.stderr)
        for required in ("fetch|aosp/candidate|", "fetch|aosp/old-classification|",
                         "fetch|aosp/build-base-kmi6-2026-09|",
                         "fetch|aosp/abi-generation-6-base|", "old-aosp-base",
                         "fetch|linux-stable/base-v6.12.69|",
                         "fetch|linux-mainline/base-v6.12|"):
            self.assertIn(required, result.stdout)
        self.assertEqual(result.stdout.count("blob|"), 4)

    def test_manifest_aosp_refs_are_included(self):
        self.selected.write_text("1\tfix\tapply\taosp\tcandidate\n")
        (self.manifests / "kmi6-2026-09-independent/010-fixture.tsv").write_text(
            "1\tfix\tapply\taosp\told-classification\n")
        result = self.scope(extra="ENABLE_F2FS_DIO_OVERWRITE_FAST_PATH=0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("fetch|aosp/android-mainline|", result.stdout)
        self.assertIn("fetch|aosp/candidate|", result.stdout)
        self.assertIn("fetch|aosp/old-classification|", result.stdout)
        self.assertNotIn("blob|", result.stdout)

    def test_unpinned_and_duplicate_refs_fail(self):
        for extra in ("F2FS_DIO_OVERWRITE_FAST_PATH_AOSP_REF=unknown",
                      'AOSP_BACKPORT_AUDIT_REFS="$AOSP_BACKPORT_AUDIT_REFS android-mainline:4444444444444444444444444444444444444444"'):
            with self.subTest(extra=extra):
                result = self.scope(extra=extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("fetch|", result.stdout)

    def test_invalid_arguments_fail_before_preparation(self):
        for args in (("--unknown",), ("--audit-history", "--audit-history")):
            with self.subTest(args=args):
                result = self.scope(args)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("repo|", result.stdout)

    def test_source_proof_failure_is_not_ignored(self):
        result = self.scope(extra="FAIL_VERIFY=independent:verify-sources")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("success|", result.stdout)

    def toolchain_script(self, extra=""):
        definitions = "\n".join(function(name) for name in (
            "parse_init_args", "toolchain_bundle_enabled", "verify_installed_toolchain",
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
prepare_toolchain_source_trees() { printf 'official-sources\n'; exit 71; }
prepare_toolchain_assets() { die 'unexpected legacy assets'; }
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

    def test_unpinned_toolchain_and_maintenance_keep_official_path(self):
        result = self.run_script(self.toolchain_script())
        self.assertEqual(result.returncode, 71, result.stderr)
        self.assertIn("official-sources", result.stdout)
        self.assertNotIn("helper|", result.stderr)
        (self.root / "toolchain").mkdir()
        result = self.run_script(self.toolchain_script("CI_TOOLCHAIN_BUNDLE_URL=https://fixture"),
                                 ("--prepare-dependencies",))
        self.assertEqual(result.returncode, 71, result.stderr)
        self.assertIn("official-sources", result.stdout)
        self.assertNotIn("identity", result.stdout)
        self.assertNotIn("helper|", result.stderr)

    def test_daily_bundle_uses_shared_scheduler_without_nesting(self):
        definitions = "\n".join(function(name) for name in (
            "toolchain_bundle_enabled", "prepare_build_dependencies",
        ))
        script = PREAMBLE + definitions + r'''
INIT_PREPARE_DEPENDENCIES=0 INIT_AUDIT_HISTORY=0 CI_TOOLCHAIN_BUNDLE_SHA256=fixed-pin
run_init_tasks() { printf 'shared|%s\n' "$*"; }
prepare_userspace_sources() { printf 'userspace\n'; }
setup_toolchain() { printf 'toolchain\n'; }
prepare_build_dependencies
CI_TOOLCHAIN_BUNDLE_SHA256=
prepare_build_dependencies
'''
        result = self.run_script(script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "shared|setup_toolchain prepare_userspace_sources", "userspace", "toolchain",
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

    def test_maintenance_marker_survives_default_initialization(self):
        # Use a real, tiny bare repository; no remote operation is performed.
        repo = self.root / "audit.git"
        subprocess.run(["git", "init", "--bare", str(repo)], check=True,
                       capture_output=True, timeout=5)
        subprocess.run(["git", "-C", str(repo), "remote", "add", "origin", "fixture"],
                       check=True, capture_output=True, timeout=5)
        script = 'set -euo pipefail\ndie() { exit 1; }\n' + function("ensure_audit_repo") + r'''
reject_git_object_overrides() { :; }
normalize_git_url() { printf '%s' "$1"; }
INIT_AUDIT_HISTORY=1
ensure_audit_repo fixture "$HOST_WORKSPACE_DIR/audit.git" fixture
INIT_AUDIT_HISTORY=0
ensure_audit_repo fixture "$HOST_WORKSPACE_DIR/audit.git" fixture
git -C "$HOST_WORKSPACE_DIR/audit.git" config --get backport.auditHistoryExpanded
'''
        result = self.run_script(script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "true")

    def test_hydration_reuses_objects_and_checks_downloaded_content(self):
        origin = self.root / "origin"
        target = self.root / "target.git"
        git_env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}

        def git(*args):
            return subprocess.run(["git", "-c", "core.hooksPath=/dev/null", *args],
                                  env=git_env, check=True, capture_output=True,
                                  text=True, timeout=5).stdout.strip()

        git("init", str(origin))
        (origin / "fixture").write_text("fixture\n")
        git("-C", str(origin), "add", "fixture")
        git("-C", str(origin), "-c", "user.name=Fixture", "-c",
            "user.email=fixture@example.invalid", "commit", "-m", "fixture")
        commit = git("-C", str(origin), "rev-parse", "HEAD")
        git("init", "--bare", str(target))
        digest = hashlib.sha256(b"fixture\n").hexdigest()
        setup = r'''
set -euo pipefail
die() { printf '%s\n' "$1" >&2; exit 1; }
log_step() { :; }
log_success() { :; }
git_network() {
    printf 'network\n' >> "$HOST_WORKSPACE_DIR/network-calls"
    command git -C "$HOST_WORKSPACE_DIR/target.git" fetch --no-tags --depth=1 \
        "$HOST_WORKSPACE_DIR/origin" "$COMMIT" >/dev/null 2>&1
    command git "$@"
}
'''
        setup += function("hydrate_audit_patches") + "\n" + function("hydrate_audit_blob")
        setup += f"\nCOMMIT={commit}\nDIGEST={digest}\n"
        result = self.run_script(setup + r'''
hydrate_audit_patches fixture "$HOST_WORKSPACE_DIR/target.git" "$COMMIT"
hydrate_audit_patches fixture "$HOST_WORKSPACE_DIR/target.git" "$COMMIT"
hydrate_audit_blob fixture "$HOST_WORKSPACE_DIR/target.git" "$COMMIT" fixture "$DIGEST"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.root / "network-calls"
        self.assertEqual(calls.read_text(), "network\n")
        result = self.run_script(setup + r'''
hydrate_audit_blob fixture "$HOST_WORKSPACE_DIR/target.git" "$COMMIT" fixture incorrect
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls.read_text(), "network\n")

        # A failed fetch must not be hidden by the hashing pipeline.
        result = self.run_script(setup + r'''
git_network() { return 9; }
hydrate_audit_blob fixture "$HOST_WORKSPACE_DIR/target.git" missing fixture "$DIGEST"
''')
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
