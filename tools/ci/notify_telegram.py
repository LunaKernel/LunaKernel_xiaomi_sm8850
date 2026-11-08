#!/usr/bin/env python3
"""校验 CI 完整交付集合，并向 Telegram 发送刷机包和官方 Manager。"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_artifacts


MAX_UPLOAD_BYTES = 50_000_000
MAX_RESPONSE_BYTES = 65536
MAX_ATTEMPTS = 3
MAX_RETRY_AFTER = 60


class NetworkError(RuntimeError):
    """只携带可公开的网络错误，不保留 curl 原始响应。"""


def require(condition, message):
    if not condition:
        raise ValueError(message)


def checked_documents(workspace, build_id, project_commit):
    require(re.fullmatch(r"[0-9a-f]{40}", project_commit), "项目提交必须是完整 SHA")
    manager = os.environ.get("KSU_MANAGER_APK_NAME", "")
    manager_sha = os.environ.get("KSU_MANAGER_APK_SHA256", "")
    ipset = os.environ.get("IPSET_VERSION", "")
    fingerprint = os.environ.get("ANDROID17_STOCK_SYSTEM_DLKM_FINGERPRINT", "")
    require(re.fullmatch(r"KernelSU_[A-Za-z0-9.+-]+_[0-9]+-release\.apk", manager), "Manager 文件名 pin 无效")
    require(re.fullmatch(r"[0-9a-f]{64}", manager_sha), "Manager SHA-256 pin 无效")
    require(re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", ipset), "IPSet 版本 pin 无效")
    require(fingerprint.startswith("Xiaomi/pudding/pudding:") and
            fingerprint.endswith("/OS4.0.6.0.XPCCN:user/release-keys"), "OTA 与固定 system_dlkm 身份不一致")

    # 先复用原发布检查，再施加当前 CI 六文件要求；历史发布规则不变。
    names = release_artifacts.verify(workspace, build_id)
    kernel_dir, audit_dir, component_dir = release_artifacts.release_directories(build_id)
    match = release_artifacts.BUILD_ID.fullmatch(build_id)
    stem = "luna-xiaomi17-g" + match[1] + "-" + match[2]
    kernel_zip = kernel_dir + "/" + stem + ".zip"
    manager_path = kernel_dir + "/" + manager
    expected = {
        kernel_dir + "/Image-" + stem,
        kernel_zip,
        manager_path,
        audit_dir + "/" + stem + "-audit.zip",
        component_dir + "/ipset-arm64-v" + ipset,
        component_dir + "/ipset-v" + ipset + "-android-arm64-kernelsu-module.zip",
    }
    state_path = audit_dir + "/release.tsv"
    manifest_path = audit_dir + "/.build-artifacts"
    require(set(names) == expected | {state_path, manifest_path}, "CI 交付必须包含固定的完整六文件集合")
    state = dict(line.split("\t", 1) for line in
                 release_artifacts.checked_path(workspace, state_path).read_text().splitlines()[1:])
    require(state["project_commit"] == project_commit, "发布完整项目提交与本次 CI 不符")
    require(state["validation_status"] == "awaiting-device", "本次 CI 产物必须标记 awaiting-device")
    require(state.get("ksu_manager_apk") == manager, "发布 Manager 文件名与 pin 不符")
    records = {}
    for line in release_artifacts.checked_path(workspace, manifest_path).read_text().splitlines():
        digest, relative = release_artifacts.RECORD.fullmatch(line).groups()
        records[relative] = digest
    require(records[manager_path] == manager_sha, "发布 Manager SHA-256 与官方 pin 不符")

    documents = []
    for relative in (kernel_zip, manager_path):
        path = release_artifacts.checked_path(workspace, relative)
        require(0 < path.stat().st_size <= MAX_UPLOAD_BYTES, "Telegram 文件为空或超过 50 MB: " + path.name)
        caption = f"SHA256: {records[relative]}\nBuild: {build_id}"
        require(len(caption) <= 1024, "Telegram caption 超过长度限制")
        documents.append((path, caption))
    return documents


def curl_quote(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('\r', '\\r').replace('\n', '\\n') + '"'


def telegram_request(token, chat_id, path, caption):
    # secret 通过 stdin 传入，不进入进程参数；不打印 stderr 或远端响应正文。
    quoted_path = str(path).replace('\\', '\\\\').replace('"', '\\"')
    options = {
        "url": f"https://api.telegram.org/bot{token}/sendDocument",
        "proto": "=https",
        "connect-timeout": "15",
        "max-time": "120",
        "max-filesize": str(MAX_RESPONSE_BYTES),
        "write-out": "\n%{http_code}",
    }
    config = "silent\nshow-error\n" + "".join(
        key + " = " + curl_quote(value) + "\n" for key, value in options.items())
    config += "form-string = " + curl_quote("chat_id=" + chat_id) + "\n"
    config += "form-string = " + curl_quote("caption=" + caption) + "\n"
    config += "form = " + curl_quote(f'document=@"{quoted_path}";type=application/octet-stream') + "\n"
    try:
        result = subprocess.run(["curl", "-q", "--config", "-"], input=config.encode(),
                                capture_output=True, timeout=135)
    except subprocess.TimeoutExpired:
        raise NetworkError("Telegram 请求超时") from None
    except OSError:
        raise ValueError("无法启动 curl") from None
    if result.returncode in (5, 6, 7, 18, 28, 35, 52, 55, 56, 92, 95, 96):
        raise NetworkError(f"Telegram 网络请求失败（curl {result.returncode}）")
    require(result.returncode == 0, f"Telegram 请求失败（curl {result.returncode}）")
    body, separator, status = result.stdout.rpartition(b"\n")
    require(separator and re.fullmatch(rb"[0-9]{3}", status) and len(body) <= MAX_RESPONSE_BYTES,
            "Telegram HTTP 响应格式错误")
    status = int(status)
    try:
        payload = json.loads(body)
    except (ValueError, UnicodeError):
        payload = None
    # 代理的 5xx 可能不是 JSON，仍按暂时错误有限重试。
    if not isinstance(payload, dict) and 500 <= status <= 599:
        payload = {}
    require(isinstance(payload, dict), "Telegram 响应不是有效 JSON 对象")
    return status, payload


def send_document(token, chat_id, path, caption):
    for attempt in range(1, MAX_ATTEMPTS + 1):
        delay = 2 ** (attempt - 1)
        try:
            status, payload = telegram_request(token, chat_id, path, caption)
        except NetworkError:
            reason = "网络错误或超时"
        else:
            if 200 <= status <= 299 and payload.get("ok") is True:
                result = payload.get("result")
                message_id = result.get("message_id") if isinstance(result, dict) else None
                require(type(message_id) is int and message_id > 0, "Telegram 未返回有效 message_id")
                return message_id
            code = status if not 200 <= status <= 299 else payload.get("error_code")
            require(type(code) is int, "Telegram 错误响应缺少有效 error_code")
            if code == 429:
                parameters = payload.get("parameters", {})
                require(isinstance(parameters, dict), "Telegram retry_after 响应格式错误")
                delay = parameters.get("retry_after", delay)
                require(type(delay) is int and 0 <= delay <= MAX_RETRY_AFTER,
                        "Telegram retry_after 无效或超过 60 秒，请稍后重跑通知")
            else:
                require(500 <= code <= 599, f"Telegram 拒绝发送（HTTP/API {code}），停止重试")
            reason = f"HTTP/API {code}"
        if attempt == MAX_ATTEMPTS:
            raise ValueError(f"Telegram 发送失败，已尝试 {MAX_ATTEMPTS} 次；仅需重跑通知任务")
        print(f"Telegram 暂时失败（{reason}），{delay} 秒后重试 {attempt + 1}/{MAX_ATTEMPTS}", file=sys.stderr)
        time.sleep(delay)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", required=True, type=Path)
    parser.add_argument("--build-id", required=True)
    parser.add_argument("--project-commit", required=True)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args(argv)
    documents = checked_documents(args.workspace.resolve(strict=True), args.build_id,
                                  args.project_commit)
    if args.check_only:
        print("[OK] CI 六文件、项目身份、官方 Manager 与 TG 文件大小检查通过")
        return
    # 两个文件全部通过本地检查后，才访问 secret 并开始发送。
    token = os.environ.get("TG_BOT_TOKEN", "")
    chat_id = os.environ.get("CHAT_ID", "")
    require(re.fullmatch(r"[0-9]+:[A-Za-z0-9_-]+", token), "TG_BOT_TOKEN 缺失或格式错误")
    require(re.fullmatch(r"-?[0-9]+|@[A-Za-z][A-Za-z0-9_]{4,31}", chat_id), "CHAT_ID 缺失或格式错误")
    for path, caption in documents:
        message_id = send_document(token, chat_id, path, caption)
        print(f"[OK] 已发送 {path.name}，message_id={message_id}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print("[FAIL] " + str(error), file=sys.stderr)
        sys.exit(1)
