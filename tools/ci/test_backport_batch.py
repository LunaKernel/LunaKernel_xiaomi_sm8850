#!/usr/bin/env python3
"""用本地合成 Git 历史验证批量回移审计，不联网、不修改实际源码。"""

import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
BASH = os.environ.get("BACKPORT_TEST_BASH", "bash")
GIT = shutil.which("git")


class BackportBatchTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="luna-backport-batch-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "tools").mkdir()
        for name in ("independent_backports.sh", "backport_manifest.sh"):
            shutil.copyfile(ROOT / "tools" / name, self.root / "tools" / name)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("GIT_", "BACKPORT_", "BASH_FUNC_"))
                    and key not in ("BASH_ENV", "ENV")}
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                        GIT_TERMINAL_PROMPT="0", LC_ALL="C.UTF-8", TMPDIR=str(self.root))
        self.source = self.root / "history"
        self.source.mkdir()
        self.git(self.source, "init", "-q")
        for name in ("alpha", "beta"):
            (self.source / f"{name}.txt").write_text(f"{name} before\n")
        self.commit("base")
        self.base = self.git(self.source, "rev-parse", "HEAD")
        self.commits = {}
        for name in ("alpha", "beta"):
            (self.source / f"{name}.txt").write_text(f"{name} after\n")
            self.commit(name)
            self.commits[name] = self.git(self.source, "rev-parse", "HEAD")
        audits = self.root / "audits"
        audits.mkdir()
        for name in ("aosp", "stable", "mainline"):
            repo = audits / (name + ".git")
            if name == "mainline":
                self.git(self.root, "clone", "--quiet", "--bare", "--no-hardlinks", str(self.source), str(repo))
                self.git(repo, "remote", "set-url", "origin", f"https://example.invalid/{name}")
            else:
                self.git(self.root, "init", "--quiet", "--bare", str(repo))
                self.git(repo, "remote", "add", "origin", f"https://example.invalid/{name}")
        self.target = self.root / "target"
        self.git(self.root, "clone", "--quiet", "--no-hardlinks", str(self.source), str(self.target))
        self.git(self.target, "checkout", "--quiet", self.base)
        self.directory = self.root / "patches/backports/kmi6-2026-09-independent"
        self.directory.mkdir(parents=True)
        selected = self.root / "patches/backports/selected.tsv"
        shutil.copyfile(ROOT / "patches/backports/kmi6-2026-09-selected-backports.tsv", selected)
        rows = [line.split("\t") for line in selected.read_text().splitlines() if not line.startswith("#")]
        stable_ref = next(row[4] for row in rows if row[3] == "stable")
        snapshot = next(row[4].removeprefix("snapshot-") for row in rows if row[3] == "mainline")
        self.pins = {
            "LINUX_STABLE_STANDALONE_COMMITS": "03cb8cc2961f5f781d12e903782cb3815ed84b1c",
            "SELECTED_BACKPORT_MANIFEST": str(selected),
            "SELECTED_BACKPORT_MANIFEST_SHA256": hashlib.sha256(selected.read_bytes()).hexdigest(),
            "COMMON_REPO": "https://example.invalid/aosp",
            "AOSP_BACKPORT_AUDIT_SOURCE_DIR": "audits/aosp.git",
            "LINUX_STABLE_AUDIT_SOURCE_DIR": "audits/stable.git",
            "LINUX_STABLE_AUDIT_REPO": "https://example.invalid/stable",
            "LINUX_STABLE_AUDIT_REF": stable_ref,
            "LINUX_MAINLINE_AUDIT_SOURCE_DIR": "audits/mainline.git",
            "LINUX_MAINLINE_AUDIT_REPO": "https://example.invalid/mainline",
            "LINUX_MAINLINE_AUDIT_COMMIT": self.commits["beta"],
            "BACKPORT_AUDIT_SNAPSHOT": snapshot,
        }
        self.manifests = []
        for number, name in enumerate(("alpha", "beta"), 100):
            commit = self.commits[name]
            patch = self.git(self.source, "show", "--format=", commit)
            patch_id = self.git(self.source, "patch-id", "--stable", input=patch).split()[0]
            date = self.git(self.source, "show", "-s", "--format=%cs", commit)
            manifest = self.directory / f"{number}-{name}.tsv"
            manifest.write_text(selected.read_text().splitlines()[0] + "\n" + "\t".join((
                "001", name, "direct", "mainline", "snapshot-" + snapshot,
                commit, date, patch_id, name + ".txt", "-", "-", "-")) + "\n")
            self.manifests.append(manifest)
        self.write_pins()
        # 记录真实 Git 调用，以确认来源只验一次且完整 index 操作没有被删减。
        self.trace = self.root / "git-calls.jsonl"
        binary = self.root / "bin/git"
        binary.parent.mkdir()
        binary.write_text("#!" + sys.executable + "\nimport json, os, sys\n"
                          "with open(os.environ['MOCK_GIT_TRACE'], 'a') as stream:\n"
                          "    stream.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                          f"os.execv({GIT!r}, [{GIT!r}, *sys.argv[1:]])\n")
        binary.chmod(0o755)
        self.env["PATH"] = str(binary.parent) + os.pathsep + self.env.get("PATH", "/usr/bin:/bin")
        self.env["MOCK_GIT_TRACE"] = str(self.trace)
        # 脚本自行建立固定 Git 隔离环境；测试不能携带额外覆盖项。
        self.env.pop("GIT_TERMINAL_PROMPT")

    def git(self, repo, *arguments, input=None):
        result = subprocess.run([GIT, "-C", str(repo), *arguments], env=self.env,
                                input=input, capture_output=True, text=True, timeout=10, check=True)
        return result.stdout.strip()

    def commit(self, message):
        self.git(self.source, "add", ".")
        self.git(self.source, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "--no-gpg-sign", "-m", message)

    def write_pins(self):
        for manifest in self.manifests:
            key = "INDEPENDENT_" + manifest.stem.upper().replace("-", "_") + "_SHA256"
            self.pins[key] = hashlib.sha256(manifest.read_bytes()).hexdigest()
        (self.root / ".env").write_text("".join(f"{key}={shlex.quote(value)}\n" for key, value in self.pins.items()))

    def run_tool(self, command, *arguments, standalone=False):
        env = dict(self.env)
        if standalone:
            manifest = self.manifests[-1]
            env.update(BACKPORT_INDEPENDENT="1", BACKPORT_MANIFEST_OVERRIDE=str(manifest),
                       BACKPORT_MANIFEST_SHA256_OVERRIDE=hashlib.sha256(manifest.read_bytes()).hexdigest())
        name = "backport_manifest.sh" if standalone else "independent_backports.sh"
        return subprocess.run([BASH, str(self.root / "tools" / name), command, *map(str, arguments)],
                              env=env, capture_output=True, text=True, timeout=20)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def target_diff(self):
        return self.git(self.target, "diff", "--binary", "--full-index", "HEAD", "--", ".")

    def enable_bundle(self):
        self.pins["BACKPORT_BUNDLE_MANIFEST_SHA256"] = "a" * 64
        self.bundle = self.root / "work/cache/dependencies" / ("backports-" + "a" * 64)
        (self.bundle / "patches").mkdir(parents=True)
        for commit in self.commits.values():
            raw = subprocess.run([GIT, "-C", str(self.source), "show", "--format=", commit],
                                 env=self.env, capture_output=True, timeout=10, check=True).stdout
            (self.bundle / "patches" / (commit + ".patch")).write_bytes(raw)
        # helper 的真实完整性规则由其测试覆盖；这里只验证 shell 的信任边界与调用协议。
        self.bundle_trace = self.root / "bundle-calls.jsonl"
        (self.root / "tools/ci_dependencies.py").write_text(
            "import json, pathlib, sys\n"
            "assert sys.argv[1:] == ['backports-check', '--workspace', str(pathlib.Path(__file__).resolve().parents[1])]\n"
            f"trace = pathlib.Path({str(self.bundle_trace)!r})\n"
            "with trace.open('a') as stream: stream.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            f"print({str(self.bundle)!r})\n")
        self.write_pins()

    def test_bundle_combined_verification_reuses_helper_without_sources(self):
        self.enable_bundle()
        shutil.rmtree(self.root / "audits")
        self.assert_success(self.run_tool("apply", self.target))
        original = self.target_diff()
        self.bundle_trace.write_text("")
        self.trace.write_text("")
        self.assert_success(self.run_tool("verify-applied-base-diff", self.target,
                                          hashlib.sha256(b"").hexdigest()))
        self.assertEqual(len(self.bundle_trace.read_text().splitlines()), 1)
        calls = [json.loads(line) for line in self.trace.read_text().splitlines()]
        self.assertFalse(any("--is-ancestor" in call or "show" in call for call in calls))
        index_calls = [call for call in calls if "apply" in call and "--cached" in call]
        self.assertEqual(len(index_calls), 9)
        self.assertEqual(sum("--reverse" in call for call in index_calls), 4)
        self.assertTrue(any("apply" in call and "--reverse" in call and "--cached" not in call
                            for call in calls))
        self.assertEqual(self.target_diff(), original)

    def test_bundle_wrong_raw_patch_id_is_rejected_before_mutation(self):
        self.enable_bundle()
        commits = list(self.commits.values())
        shutil.copyfile(self.bundle / "patches" / (commits[0] + ".patch"),
                        self.bundle / "patches" / (commits[1] + ".patch"))
        result = self.run_tool("apply", self.target)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("patch-id 不匹配", result.stderr)
        self.assertEqual(self.target_diff(), "")

    def test_source_audit_flag_forces_original_source_checks(self):
        self.enable_bundle()
        self.env["BACKPORT_SOURCE_AUDIT"] = "1"
        self.git(self.root / "audits/mainline.git", "remote", "set-url", "origin", "https://example.invalid/other")
        result = self.run_tool("apply", self.target)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("remote 不匹配", result.stderr)
        self.assertFalse(self.bundle_trace.exists())
        self.assertEqual(self.target_diff(), "")

    def test_bundle_adapt_still_checks_project_patch_sha(self):
        self.enable_bundle()
        manifest = self.manifests[0]
        header, row = manifest.read_text().splitlines()
        fields = row.split("\t")
        patch = self.root / "patches/alpha.patch"
        shutil.copyfile(self.bundle / "patches" / (fields[5] + ".patch"), patch)
        fields[2] = "adapt"
        fields[9:12] = ["patches/alpha.patch", hashlib.sha256(patch.read_bytes()).hexdigest(), fields[7]]
        manifest.write_text(header + "\n" + "\t".join(fields) + "\n")
        self.write_pins()
        patch.write_bytes(patch.read_bytes() + b"# changed\n")
        result = self.run_tool("apply", self.target)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("项目适配补丁 SHA-256 不匹配", result.stderr)
        self.assertEqual(self.target_diff(), "")

    def run_legacy_build_checks(self):
        source = (ROOT / "build.sh").read_text()
        functions = source[source.index("verify_aosp_backport_source() {"):source.index("verify_first_batch_linux_backports() {")]
        commit = self.commits["alpha"]
        fields = self.manifests[0].read_text().splitlines()[1].split("\t")
        script = "\n".join((
            "set -euo pipefail", 'die() { printf "%s\\n" "$1" >&2; exit 1; }',
            "HOST_WORKSPACE_DIR=" + shlex.quote(str(self.root)),
            "COMMON_DIR=" + shlex.quote(str(self.target)),
            "BACKPORT_BUNDLE_MANIFEST_SHA256=" + "a" * 64,
            'BACKPORT_BUNDLE_LIBRARY=1 . "${HOST_WORKSPACE_DIR}/tools/backport_manifest.sh"',
            functions,
            *(f"{function} fixture {commit} {fields[7]} alpha.txt" for function in (
                "verify_aosp_backport_applied", "verify_linux_stable_backport_applied")),
            f"verify_linux_mainline_backport_applied fixture {commit} {fields[6]} {fields[7]} alpha.txt"))
        return subprocess.run([BASH, "-c", script], env=self.env, capture_output=True, text=True, timeout=20)

    def test_legacy_build_bundle_keeps_reverse_checks_without_audits(self):
        self.enable_bundle()
        shutil.rmtree(self.root / "audits")
        self.assert_success(self.run_tool("apply", self.target))
        self.bundle_trace.write_text("")
        self.assert_success(self.run_legacy_build_checks())
        self.assertEqual(len(self.bundle_trace.read_text().splitlines()), 1)
        self.git(self.target, "restore", "--", "alpha.txt")
        self.assertNotEqual(self.run_legacy_build_checks().returncode, 0)

    def test_audit_entry_requires_no_common_and_never_uses_bundle(self):
        self.enable_bundle()
        shutil.copyfile(ROOT / "patch.sh", self.root / "patch.sh")
        result = subprocess.run([BASH, str(self.root / "patch.sh"), "--audit-sources"],
                                env=self.env, capture_output=True, text=True, timeout=20)
        self.assert_success(result)
        self.assertIn("未修改 common", result.stdout)
        self.assertFalse(self.bundle_trace.exists())
        self.assertEqual(self.target_diff(), "")

    def test_bundle_helper_failure_is_rejected_before_mutation(self):
        self.enable_bundle()
        (self.root / "tools/ci_dependencies.py").write_text("raise SystemExit(1)\n")
        result = self.run_tool("apply", self.target)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("固定回移补丁包校验失败", result.stderr)
        self.assertEqual(self.target_diff(), "")

    def test_apply_idempotence_final_state_and_complete_replay(self):
        self.assert_success(self.run_tool("apply", self.target))
        original = self.target_diff()
        self.assert_success(self.run_tool("apply", self.target))
        self.assert_success(self.run_tool("verify-applied", self.target))
        self.trace.write_text("")
        self.assert_success(self.run_tool("verify-base-diff", self.target, hashlib.sha256(b"").hexdigest()))
        self.assertEqual(self.target_diff(), original)
        calls = [json.loads(line) for line in self.trace.read_text().splitlines()]
        for commit in self.commits.values():
            # patch-id 校验读取一次，实际补丁导出一次；不在每轮 index 操作重做。
            self.assertEqual(sum(call[-3:] == ["show", "--format=", commit] for call in calls), 2)
            self.assertEqual(sum("--is-ancestor" in call and
                                 call[call.index("--is-ancestor") + 1] == commit for call in calls), 1)
        index_calls = [call for call in calls if "apply" in call and "--cached" in call]
        self.assertEqual(len(index_calls), 9)  # 当前差异导入一次；两份补丁各四次。
        self.assertEqual(sum("--reverse" in call for call in index_calls), 4)

    def test_missing_layer_and_wrong_base_are_rejected(self):
        empty = hashlib.sha256(b"").hexdigest()
        self.assertNotEqual(self.run_tool("verify-base-diff", self.target, empty).returncode, 0)
        self.assert_success(self.run_tool("apply", self.target))
        result = self.run_tool("verify-base-diff", self.target, "0" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("基础差异不匹配", result.stderr)

    def test_partial_final_state_is_rejected(self):
        self.assert_success(self.run_tool("apply", self.target, standalone=True))
        original = self.target_diff()
        self.assertNotEqual(self.run_tool("verify-applied", self.target).returncode, 0)
        self.assertEqual(self.target_diff(), original)

    def test_tampered_manifest_is_rejected_before_mutation(self):
        self.manifests[1].write_text(self.manifests[1].read_text() + "# changed\n")
        result = self.run_tool("apply", self.target)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 不匹配", result.stderr)
        self.assertEqual(self.target_diff(), "")

    def test_wrong_source_patch_id_is_rejected_by_both_interfaces(self):
        manifest = self.manifests[-1]
        header, row = manifest.read_text().splitlines()
        fields = row.split("\t")
        fields[7] = "0" * 40
        manifest.write_text(header + "\n" + "\t".join(fields) + "\n")
        self.write_pins()
        for standalone in (False, True):
            with self.subTest(standalone=standalone):
                result = self.run_tool("apply", self.target, standalone=standalone)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("官方提交 patch-id 不匹配", result.stderr)
                self.assertEqual(self.target_diff(), "")

    def test_duplicate_commits_and_selected_overlap_are_rejected(self):
        manifest = self.manifests[-1]
        header, original = manifest.read_text().splitlines()
        independent = self.manifests[0].read_text().splitlines()[1]
        selected = next(line for line in Path(self.pins["SELECTED_BACKPORT_MANIFEST"]).read_text().splitlines()
                        if not line.startswith("#"))
        for source_row in (independent, selected):
            with self.subTest(row=source_row):
                fields = original.split("\t")
                fields[3:9] = source_row.split("\t")[3:9]
                manifest.write_text(header + "\n" + "\t".join(fields) + "\n")
                self.write_pins()
                result = self.run_tool("apply", self.target)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("重复", result.stderr)
                self.assertEqual(self.target_diff(), "")

    def test_wrong_origin_is_rejected_before_mutation(self):
        self.git(self.root / "audits/mainline.git", "remote", "set-url", "origin", "https://example.invalid/other")
        result = self.run_tool("apply", self.target)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("remote 不匹配", result.stderr)
        self.assertEqual(self.target_diff(), "")


if __name__ == "__main__":
    unittest.main()
