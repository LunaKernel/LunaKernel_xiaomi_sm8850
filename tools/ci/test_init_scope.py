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


def function(name):
    match = re.search(rf"^{name}\(\) \{{\n.*?^\}}$", SOURCE, re.M | re.S)
    if match is None:
        raise AssertionError(f"missing init function: {name}")
    return match.group()


AUDIT_BODY = re.search(
    r'^if \[ "\$\{ENABLE_BACKPORT_AUDIT\}" = "1" \]; then\n.*?^fi$',
    SOURCE, re.M | re.S,
).group()
FUNCTIONS = "\n".join(function(name) for name in (
    "parse_init_args", "required_aosp_refs", "prepare_aosp_audit_sources",
))
PREAMBLE = r'''
set -euo pipefail
die() { printf '%s\n' "$1" >&2; exit 1; }
log_step() { :; }
log_success() { printf 'success|%s\n' "$1"; }
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
