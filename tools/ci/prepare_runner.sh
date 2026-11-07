#!/usr/bin/env bash
# 仅配置 GitHub 托管的临时构建机，不用于开发者本机。
set -euo pipefail

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] || \
    fail '宿主准备只允许在 GitHub 托管 runner 执行'
[[ "$(uname -m)" == x86_64 ]] || fail '需要 x86_64 runner'
. /etc/os-release
[[ "${ID}" == ubuntu && "${VERSION_ID}" == 24.04 ]] || fail '需要 Ubuntu 24.04'

# 只删除明确无关的预装 SDK；不跟随目录或祖先路径的符号链接。
timeout --kill-after=15s 5m sudo -n python3 - <<'PY'
from pathlib import Path
import shutil

for name in (
    '/usr/local/lib/android', '/usr/share/dotnet', '/opt/ghc',
    '/usr/local/.ghcup', '/usr/share/swift', '/usr/local/share/powershell',
    '/opt/hostedtoolcache/CodeQL', '/usr/share/miniconda',
):
    path = Path(name)
    if any(parent.is_symlink() for parent in (path, *path.parents)):
        raise SystemExit('拒绝清理经过符号链接的 SDK: ' + name)
    if path.exists():
        if not path.is_dir():
            raise SystemExit('预装 SDK 路径不是目录: ' + name)
        shutil.rmtree(path)
        print('[CLEAN] ' + name, flush=True)
PY

timeout --kill-after=15s 5m sudo -n env DEBIAN_FRONTEND=noninteractive apt-get update -q
timeout --kill-after=15s 10m sudo -n env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends \
    build-essential flex bison libdw-dev libelf-dev zlib1g-dev libssl-dev \
    pkg-config ccache python3 git curl ca-certificates patch file \
    bzip2 xz-utils zip unzip p7zip-full zstd

for tool in bash git curl make gcc cc ld flex bison python3 pkg-config ccache \
    tar gzip bzip2 xz unzip zip 7z patch sha256sum timeout nm; do
    command -v "${tool}" >/dev/null || fail "缺少宿主工具: ${tool}"
done
[[ -x /usr/bin/x86_64-linux-gnu-gcc ]] || fail '缺少固定宿主 gcc 入口'
pkg-config --exists libdw libelf zlib openssl || fail '缺少宿主开发库'

python3 - <<'PY'
import os
import shutil

free = shutil.disk_usage('.').free
print(f'[INFO] CPU={os.cpu_count()} 可用磁盘={free / 2**30:.1f} GiB')
if free < 50 * 2**30:
    raise SystemExit('可用空间不足 50 GiB，停止下载和编译')
PY
df -h .
