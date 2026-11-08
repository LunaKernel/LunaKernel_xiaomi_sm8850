#!/usr/bin/env bash
# 轻量检查不准备内核源码、不编译、不访问 Telegram。
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "${ROOT}"
export PYTHONDONTWRITEBYTECODE=1
. ./.env

git diff --check
git show --format= --check HEAD
for script in init.sh patch.sh patch_external.sh build.sh \
    tools/backport_manifest.sh tools/independent_backports.sh tools/ci/*.sh; do
    bash -n "${script}"
done
python3 - <<'PY'
from pathlib import Path
for path in (*Path('tools').glob('*.py'), *Path('tools/ci').glob('*.py')):
    compile(path.read_text(), str(path), 'exec')
PY
python3 -m unittest discover -s tools/ci -p 'test_*.py'
bash tools/ci/run_build.sh check-input

# actionlint 是固定摘要的宿主检查工具，留在可复用工具目录。
checker="work/tools/ci/actionlint-${CI_ACTIONLINT_VERSION}"
archive="${checker}/actionlint.tar.gz"
mkdir -p "${checker}"
if [[ ! -f "${archive}" ]]; then
    timeout --kill-after=10s 3m curl --fail --location --proto '=https' \
        --connect-timeout 15 --max-time 150 --retry 2 \
        "https://github.com/rhysd/actionlint/releases/download/v${CI_ACTIONLINT_VERSION}/actionlint_${CI_ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
        --output "${archive}.part"
    mv "${archive}.part" "${archive}"
fi
printf '%s  %s\n' "${CI_ACTIONLINT_ARCHIVE_SHA256}" "${archive}" | sha256sum --check --status
tar -xzf "${archive}" -C "${checker}" actionlint
"${checker}/actionlint" -shellcheck= .github/workflows/check.yml .github/workflows/build.yml
