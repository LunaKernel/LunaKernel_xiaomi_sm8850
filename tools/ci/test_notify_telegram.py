#!/usr/bin/env python3
"""通知脚本的离线发布校验及网络失败测试，不调用真实 Telegram。"""

import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import notify_telegram as notify


class NotifyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="luna-notify-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.commit = "a" * 40
        self.build_id = "luna-xiaomi17-gaaaaaaaa-20261108-1200"
        self.stem = "luna-xiaomi17-gaaaaaaaa-20261108"
        self.manager = "KernelSU_v3.3.1-29-gab05a062_32709-release.apk"
        kernel, audit, component = notify.release_artifacts.release_directories(self.build_id)
        self.zip = kernel + "/" + self.stem + ".zip"
        self.apk = kernel + "/" + self.manager
        self.ipset = component + "/ipset-arm64-v7.24"
        self.files = {
            kernel + "/Image-" + self.stem: b"kernel fixture",
            self.zip: b"zip fixture",
            self.apk: b"apk fixture",
            audit + "/" + self.stem + "-audit.zip": b"audit fixture",
            self.ipset: b"ipset fixture",
            component + "/ipset-v7.24-android-arm64-kernelsu-module.zip": b"module fixture",
        }
        for name, content in self.files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        self.manifest = self.root / audit / ".build-artifacts"
        self.state = self.root / audit / "release.tsv"
        self.write_manifest()
        self.state.write_text("field\tvalue\nbuild_id\t" + self.build_id +
                              "\nproject_commit\t" + self.commit +
                              "\nvalidation_status\tawaiting-device\nksu_manager_apk\t" + self.manager + "\n")
        self.env = {
            "KSU_MANAGER_APK_NAME": self.manager,
            "KSU_MANAGER_APK_SHA256": notify.release_artifacts.sha256(self.root / self.apk),
            "IPSET_VERSION": "7.24",
            "ANDROID17_STOCK_SYSTEM_DLKM_FINGERPRINT":
                "Xiaomi/pudding/pudding:16/build/OS4.0.6.0.XPCCN:user/release-keys",
            "TG_BOT_TOKEN": "123456:test_token_never_used_on_network",
            "CHAT_ID": "-1001234567890",
        }
        self.environment = mock.patch.dict(os.environ, self.env, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.request = mock.patch.object(notify, "telegram_request", return_value=(200, {"ok": True, "result": {"message_id": 1}}))
        self.network = self.request.start()
        self.addCleanup(self.request.stop)
        self.sleep_patch = mock.patch.object(notify.time, "sleep")
        self.sleep = self.sleep_patch.start()
        self.addCleanup(self.sleep_patch.stop)

    def write_manifest(self):
        self.manifest.write_text("".join(notify.release_artifacts.sha256(self.root / name) +
                                         "  " + name + "\n" for name in self.files))

    def arguments(self):
        return ["--workspace", str(self.root), "--build-id", self.build_id,
                "--project-commit", self.commit, "--run-url",
                "https://github.com/example/luna/actions/runs/123"]

    def run_main(self, *extra):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            notify.main(self.arguments() + list(extra))

    def assert_local_failure(self):
        with self.assertRaises(ValueError):
            self.run_main()
        self.network.assert_not_called()

    def test_check_only_reads_no_secrets_or_network(self):
        class PinsOnly(dict):
            def get(self, key, default=None):
                if key in ("TG_BOT_TOKEN", "CHAT_ID"):
                    raise AssertionError("check-only accessed a secret")
                return super().get(key, default)
        with mock.patch.object(notify.os, "environ", PinsOnly(self.env)):
            self.run_main("--check-only")
        self.network.assert_not_called()

    def test_send_only_zip_and_pinned_apk_with_hashes(self):
        self.run_main()
        self.assertEqual(self.network.call_count, 2)
        for call, relative in zip(self.network.call_args_list, (self.zip, self.apk)):
            path, caption = call.args[2:]
            self.assertEqual(path, self.root / relative)
            self.assertIn(notify.release_artifacts.sha256(path), caption)
            self.assertIn(self.build_id, caption)
            self.assertIn("awaiting-device", caption)
            self.assertIn(notify.OTA, caption)

    def test_corrupt_second_file_stops_before_first_send(self):
        (self.root / self.apk).write_bytes(b"corrupt")
        self.assert_local_failure()

    def test_official_apk_pin_is_checked(self):
        os.environ["KSU_MANAGER_APK_SHA256"] = "0" * 64
        self.assert_local_failure()

    def test_full_commit_is_checked_beyond_short_prefix(self):
        self.state.write_text(self.state.read_text().replace(self.commit, "a" * 8 + "b" * 32))
        self.assert_local_failure()

    def test_new_ci_output_cannot_claim_device_acceptance(self):
        self.state.write_text(self.state.read_text().replace("awaiting-device", "accepted"))
        self.assert_local_failure()

    def test_optional_legacy_ipset_is_required_by_ci(self):
        self.files.pop(self.ipset)
        (self.root / self.ipset).unlink()
        self.write_manifest()
        notify.release_artifacts.verify(self.root, self.build_id)
        self.assert_local_failure()

    def test_extra_component_in_manifest_is_rejected(self):
        name = self.ipset + "-extra"
        self.files[name] = b"extra"
        (self.root / name).write_bytes(b"extra")
        self.write_manifest()
        self.assert_local_failure()

    def test_unsafe_manifest_path_is_rejected(self):
        self.manifest.write_text(self.manifest.read_text() + "0" * 64 + "  ../outside\n")
        self.assert_local_failure()

    def test_symlink_is_rejected(self):
        path = self.root / self.apk
        path.unlink()
        target = self.root / "apk-copy"
        target.write_bytes(self.files[self.apk])
        path.symlink_to(target)
        self.assert_local_failure()

    def test_both_sizes_are_checked_before_sending(self):
        (self.root / self.apk).write_bytes(b"x" * 101)
        self.write_manifest()
        os.environ["KSU_MANAGER_APK_SHA256"] = notify.release_artifacts.sha256(self.root / self.apk)
        with mock.patch.object(notify, "MAX_UPLOAD_BYTES", 100):
            self.assert_local_failure()

    def test_invalid_run_url_is_rejected(self):
        for url in ("http://github.com/a/b/actions/runs/1", "https://evil.invalid/a",
                    "https://github.com@evil.invalid/a", "https://github.com/a/b/actions/runs/1?token=x"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                notify.checked_documents(self.root, self.build_id, self.commit, url)
        self.network.assert_not_called()

    def send(self):
        with contextlib.redirect_stderr(io.StringIO()):
            return notify.send_document(self.env["TG_BOT_TOKEN"], self.env["CHAT_ID"],
                                        self.root / self.zip, "caption")

    def test_rate_limit_waits_then_succeeds(self):
        for status in (429, 200):
            self.sleep.reset_mock()
            self.network.side_effect = [(status, {"ok": False, "error_code": 429,
                                                 "parameters": {"retry_after": 4}}),
                                       (200, {"ok": True, "result": {"message_id": 42}})]
            with self.subTest(status=status):
                self.assertEqual(self.send(), 42)
            self.sleep.assert_called_once_with(4)

    def test_rate_limit_wait_is_bounded_and_typed(self):
        for value in (61, "4", True, -1):
            self.network.reset_mock()
            self.network.return_value = (429, {"ok": False, "parameters": {"retry_after": value}})
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.send()
            self.assertEqual(self.network.call_count, 1)
        self.sleep.assert_not_called()

    def test_server_failure_is_limited_to_three_attempts(self):
        self.network.return_value = (503, {"ok": False})
        with self.assertRaisesRegex(ValueError, "仅需重跑通知"):
            self.send()
        self.assertEqual(self.network.call_count, 3)
        self.assertEqual(self.sleep.call_args_list, [mock.call(1), mock.call(2)])

    def test_network_failure_retries_without_running_build(self):
        self.network.side_effect = [notify.NetworkError("fixture timeout"),
                                   (200, {"ok": True, "result": {"message_id": 7}})]
        with mock.patch.object(notify.subprocess, "run") as process:
            self.assertEqual(self.send(), 7)
            process.assert_not_called()
        self.assertEqual(self.network.call_count, 2)

    def test_bad_request_is_not_retried(self):
        self.network.return_value = (400, {"ok": False, "description": self.env["TG_BOT_TOKEN"]})
        with self.assertRaisesRegex(ValueError, "停止重试") as caught:
            self.send()
        self.assertNotIn(self.env["TG_BOT_TOKEN"], str(caught.exception))
        self.assertEqual(self.network.call_count, 1)

    def test_api_failure_with_http_success_is_not_accepted(self):
        self.network.return_value = (200, {"ok": False, "error_code": 403})
        with self.assertRaises(ValueError):
            self.send()
        self.assertEqual(self.network.call_count, 1)

    def test_error_fields_require_expected_json_types(self):
        for status, payload in ((200, {"ok": False, "error_code": "429"}),
                                (200, {"ok": False, "error_code": True}),
                                (429, {"ok": False, "parameters": []})):
            self.network.reset_mock()
            self.network.return_value = status, payload
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                self.send()
            self.assertEqual(self.network.call_count, 1)
        self.sleep.assert_not_called()

    def test_success_requires_a_valid_message_id(self):
        for result in ({}, {"message_id": True}, {"message_id": "1"}):
            self.network.return_value = (200, {"ok": True, "result": result})
            with self.subTest(result=result), self.assertRaises(ValueError):
                self.send()

    def test_curl_secrets_only_enter_stdin(self):
        self.request.stop()
        response = subprocess.CompletedProcess([], 0, json.dumps({"ok": True, "result": {"message_id": 1}}).encode() + b"\n200", b"")
        with mock.patch.object(notify.subprocess, "run", return_value=response) as process:
            status, payload = notify.telegram_request(self.env["TG_BOT_TOKEN"], self.env["CHAT_ID"],
                                                       self.root / self.zip, "two\nlines")
        self.assertEqual(status, 200)
        self.assertTrue(payload["ok"])
        args = process.call_args.args[0]
        self.assertNotIn(self.env["TG_BOT_TOKEN"], " ".join(args))
        self.assertNotIn(self.env["CHAT_ID"], " ".join(args))
        self.assertIn(self.env["TG_BOT_TOKEN"].encode(), process.call_args.kwargs["input"])

    def test_curl_error_does_not_expose_stderr(self):
        self.request.stop()
        response = subprocess.CompletedProcess([], 60, b"\n000", self.env["TG_BOT_TOKEN"].encode())
        with mock.patch.object(notify.subprocess, "run", return_value=response), self.assertRaises(ValueError) as caught:
            notify.telegram_request(self.env["TG_BOT_TOKEN"], self.env["CHAT_ID"], self.root / self.zip, "caption")
        self.assertNotIn(self.env["TG_BOT_TOKEN"], str(caught.exception))

    def test_json_and_proxy_errors_are_handled(self):
        self.request.stop()
        for body, status in ((b"[]", 200), (b"bad json", 200), (b"null", 429)):
            response = subprocess.CompletedProcess([], 0, body + b"\n" + str(status).encode(), b"")
            with self.subTest(body=body), mock.patch.object(notify.subprocess, "run", return_value=response), self.assertRaises(ValueError):
                notify.telegram_request(self.env["TG_BOT_TOKEN"], self.env["CHAT_ID"], self.root / self.zip, "caption")
        for body in (b"upstream error", b"[]"):
            response = subprocess.CompletedProcess([], 0, body + b"\n502", b"")
            with self.subTest(body=body), mock.patch.object(notify.subprocess, "run", return_value=response):
                self.assertEqual(notify.telegram_request(self.env["TG_BOT_TOKEN"], self.env["CHAT_ID"],
                                                          self.root / self.zip, "caption"), (502, {}))


if __name__ == "__main__":
    unittest.main()
