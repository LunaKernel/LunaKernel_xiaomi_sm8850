#!/usr/bin/env bash
# 从官方固定来源制作可复核依赖；不发布、不修改主仓库 pin。
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${ROOT}"
export PYTHONDONTWRITEBYTECODE=1
set -a
. "${ROOT}/.env"
set +a
mkdir -p work/ci-dependencies
output="$(mktemp -d "${ROOT}/work/ci-dependencies/prepared.XXXXXX")"
printf '[INFO] 依赖制作目录: %s\n' "${output}"

python3 tools/ci_dependencies.py export-toolchain --workspace "${ROOT}" \
    --output "${output}/toolchain.tar.zst"
python3 tools/ci_dependencies.py export-backports --workspace "${ROOT}" \
    --output "${output}/backports"
export BACKPORT_BUNDLE_MANIFEST_SHA256
BACKPORT_BUNDLE_MANIFEST_SHA256="$(sha256sum "${output}/backports/manifest.json" | cut -d ' ' -f1)"
python3 tools/ci_dependencies.py pack-backports --workspace "${ROOT}" \
    --input "${output}/backports" --output "${output}/backports.tar.gz"
{
    printf 'BACKPORT_BUNDLE_MANIFEST_SHA256=%s\n' "${BACKPORT_BUNDLE_MANIFEST_SHA256}"
    printf 'BACKPORT_BUNDLE_SHA256=%s\n' "$(sha256sum "${output}/backports.tar.gz" | cut -d ' ' -f1)"
    printf 'CI_TOOLCHAIN_BUNDLE_SHA256=%s\n' "$(sha256sum "${output}/toolchain.tar.zst" | cut -d ' ' -f1)"
} > "${output}/pins.env"
printf '[OK] 固定依赖制作完成: %s\n' "${output}"
