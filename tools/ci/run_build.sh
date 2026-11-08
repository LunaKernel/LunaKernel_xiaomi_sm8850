#!/usr/bin/env bash
# CI 只编排已有构建入口，pin 与目标参数仍由项目脚本解释。
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "${ROOT}"
export PYTHONDONTWRITEBYTECODE=1
set -a
. "${ROOT}/.env"
set +a

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

validate_fixed_dependencies() {
    local key
    local pins=(BACKPORT_BUNDLE_MANIFEST_SHA256 BACKPORT_BUNDLE_SHA256 BACKPORT_BUNDLE_URL
        CI_TOOLCHAIN_BUNDLE_SHA256 CI_TOOLCHAIN_BUNDLE_URL)
    for key in "${pins[@]}"; do
        [[ -n "${!key:-}" ]] || fail "固定依赖 pin 不完整: ${key}"
    done
    for key in BACKPORT_BUNDLE_MANIFEST_SHA256 BACKPORT_BUNDLE_SHA256 \
        CI_TOOLCHAIN_BUNDLE_SHA256 CI_TOOLCHAIN_TREE_SHA256; do
        [[ "${!key:-}" =~ ^[0-9a-f]{64}$ ]] || fail "固定依赖摘要无效: ${key}"
    done
}

cache_paths() {
    local path
    validate_fixed_dependencies
    [[ "${COMMON_SOURCE_DIR}" == sources/aosp_common_6.12.92_kmi6_2026-09 ]] || \
        fail "common 缓存路径不在固定范围: ${COMMON_SOURCE_DIR}"
    [[ "${COMMON_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || fail 'common 缓存缺少固定提交'
    printf '%s\t%s\n' common "${COMMON_SOURCE_DIR}"
    [[ "${CI_TOOLCHAIN_NAME:-}" =~ ^ci-sm8850-[A-Za-z0-9._-]+$ ]] || fail '工具链缓存目录名无效'
    path="${BUILD_ENVIRONMENT_DIR:?缺少工具链安装根目录 pin}"
    [[ "${path}" =~ ^work/([A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+$ ]] || fail '工具链缓存路径必须位于 work 内'
    case "/${path}/" in
        */./*|*/../*) fail '工具链缓存路径不允许相对跳转' ;;
    esac
    printf '%s\t%s\n' \
        backports "work/cache/dependencies/backports-${BACKPORT_BUNDLE_MANIFEST_SHA256}" \
        toolchain "${path}/toolchain/${CI_TOOLCHAIN_NAME}"
}

check_input() {
    python3 "${ROOT}/tools/ci_dependencies.py" check-input-pins --workspace "${ROOT}"
}

require_run() {
    [[ "${GITHUB_ACTIONS:-}" == true && "${GITHUB_REF:-}" == refs/heads/main ]] || \
        fail '完整构建只接受 main 的 GitHub Actions 手动任务'
    [[ "${GITHUB_EVENT_NAME:-}" == workflow_dispatch ]] || fail '完整构建必须手动触发'
    [[ "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ && "${GITHUB_RUN_ATTEMPT:-}" =~ ^[0-9]+$ ]] || fail '缺少运行身份'
    [[ "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || fail '项目提交格式错误'
    [[ "$(git rev-parse HEAD)" == "${GITHUB_SHA}" ]] || fail '检出提交与触发提交不一致'
    [[ -z "$(git status --porcelain --untracked-files=normal)" ]] || fail '项目工作区不干净'
}

metadata() {
    require_run
    check_input
    local build_id checkout_gc paths name path
    paths="$(cache_paths)"
    # checkout 关闭自动 gc；只移除已知附加项，不扩大项目 Git 配置白名单。
    checkout_gc="$(git config --local --get-all gc.auto || true)"
    if [[ -n "${checkout_gc}" ]]; then
        [[ "${checkout_gc}" == 0 ]] || fail 'checkout gc.auto 配置不符合预期'
        git config --local --unset-all gc.auto
    fi
    build_id="luna-xiaomi17-g${GITHUB_SHA:0:8}-$(TZ=Asia/Shanghai date +%Y%m%d-%H%M)"
    {
        printf 'LUNA_PROJECT_COMMIT=%s\nLUNA_BUILD_ID=%s\n' "${GITHUB_SHA}" "${build_id}"
        printf 'CI_BUILD_DEADLINE=%s\n' "$(( $(date +%s) + 330 * 60 ))"
        printf 'CI_RUN_DIR=work/tmp/ci-%s-%s\n' "${GITHUB_RUN_ID}" "${GITHUB_RUN_ATTEMPT}"
    } >> "${GITHUB_ENV:?}"
    printf 'project_commit=%s\nbuild_id=%s\n' "${GITHUB_SHA}" "${build_id}" >> "${GITHUB_OUTPUT:?}"
    python3 - <<'PY' >> "${GITHUB_OUTPUT}"
import hashlib
import os

def identity(keys):
    return hashlib.sha256('\0'.join(key + '=' + os.environ[key] for key in keys).encode()).hexdigest()

compiler = identity(('CI_TOOLCHAIN_TREE_SHA256', 'ANDROID_NDK_TREE_SHA256',
                     'SM8850_C_ARCH', 'SM8850_TUNE_CPU', 'AOSP_AUTOFDO_PROFILE_SHA256'))
download_keys = ('CI_CLANG_REVISION', 'AOSP_BUILD_TOOLS_REPO',
                 'STOCK_AUDIT_TOOLS_COMMIT', 'STOCK_FSCK_EROFS_SHA256',
                 'STOCK_KMOD_SHA256', 'STOCK_LIBCXX_SHA256',
                 'ANDROID_NDK_URL', 'ANDROID_NDK_SHA256', 'IPSET_URL', 'IPSET_SHA512',
                 'LIBMNL_URL', 'LIBMNL_SHA256',
                 'BACKPORT_BUNDLE_SHA256', 'CI_TOOLCHAIN_BUNDLE_SHA256',
                 'AK3_TEMPLATE_SHA256', 'ANDROID17_STOCK_SYSTEM_DLKM_SHA256')
print('ccache_prefix=luna-ccache-v1-ubuntu24-x64-' + compiler)
print('downloads_key=luna-downloads-v1-' + identity(download_keys))
print('manager_key=luna-manager-v1-' + os.environ['KSU_MANAGER_APK_SHA256'])

# common 的缓存格式与内容身份独立于 init 调度，恢复后仍由 init 验证干净树。
print('common_key=luna-common-v2-ubuntu24-x64-' + identity(('COMMON_REPO', 'COMMON_COMMIT')))
# 只使用精确 key；归档下载缓存与解包内容/安装树缓存分别按内容标识。
print('backports_key=luna-backports-v1-ubuntu24-x64-' + os.environ['BACKPORT_BUNDLE_MANIFEST_SHA256'])
print('toolchain_key=luna-toolchain-v1-ubuntu24-x64-' + os.environ['CI_TOOLCHAIN_TREE_SHA256'])
PY
    while IFS=$'\t' read -r name path; do
        printf '%s_path=%s\n' "${name}" "${path}" >> "${GITHUB_OUTPUT}"
    done <<< "${paths}"
}

cache_sizes() {
    local name path bytes save paths status
    paths="$(cache_paths)"
    while IFS=$'\t' read -r name path; do
        python3 - "${path}" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, 'tools')
from release_artifacts import checked_path
path = checked_path(Path.cwd(), sys.argv[1])
if not path.is_dir():
    raise SystemExit('已验证来源缓存目录缺失: ' + str(path))
PY
        bytes="$(du -sb -- "${path}" | cut -f1)"
        save=true
        if [[ "${name}" == common ]]; then
            # init 允许后续补丁脚本复核已有差异，common 缓存只接受干净树。
            status="$(git -C "${path}" status --porcelain=v1 --untracked-files=all --ignored=matching)"
            [[ -z "${status}" ]] || save=false
        fi
        printf '[CACHE] %s bytes=%s save=%s path=%s\n' "${name}" "${bytes}" "${save}" "${path}"
        printf '%s_save=%s\n' "${name}" "${save}" >> "${GITHUB_OUTPUT:?}"
    done <<< "${paths}"
}

prepare_run_directory() {
    [[ "${CI_RUN_DIR:-}" == "work/tmp/ci-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}" ]] || fail 'CI 临时目录身份错误'
    python3 - "${CI_RUN_DIR}" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, 'tools')
from release_artifacts import checked_path
checked_path(Path.cwd(), sys.argv[1] + '/logs').mkdir(parents=True, exist_ok=True)
PY
}

phase() {
    local script="$1" path="$2" remaining started status
    remaining="$(( ${CI_BUILD_DEADLINE:?} - $(date +%s) ))"
    (( remaining > 0 )) || fail '构建主体已达到 330 分钟软时限'
    started="$(date +%s)"
    printf '::group::%s\n' "${script}"
    if timeout --signal=TERM --kill-after=30s "${remaining}s" bash "${path}" \
        2>&1 | tee "${CI_RUN_DIR}/logs/${script}.log"; then
        status=0
    else
        status=$?
    fi
    printf '::endgroup::\n'
    printf '%s\t%s\t%s\n' "${script}" "${status}" "$(( $(date +%s) - started ))" >> "${CI_RUN_DIR}/logs/stages.tsv"
    printf '[TIME] %s status=%s seconds=%s\n' "${script}" "${status}" "$(( $(date +%s) - started ))"
    df -h . | tee -a "${CI_RUN_DIR}/logs/space.log"
    return "${status}"
}

compile() {
    phase patch patches/patch.sh
    phase patch_external patches/patch_external.sh
    export CCACHE_DIR="${ROOT}/work/cache/ccache" CCACHE_COMPILERCHECK=content
    ccache --zero-stats
    printf 'CI_CCACHE_USED=true\n' >> "${GITHUB_ENV:?}"
    phase build patches/build.sh
    # 复用已构建证据核对两项宿主加速；它们不属于设备启动条件。
    [[ -x "${BUILD_DIR}/scripts/kallsyms" && -s "${BUILD_DIR}/scripts/.kallsyms.cmd" ]]
    grep -F 'scripts/kallsyms.c' "${BUILD_DIR}/scripts/.kallsyms.cmd" >/dev/null
    grep -F 'token_syms' "${COMMON_SOURCE_DIR}/scripts/kallsyms.c" >/dev/null
    grep -F 'CONFIG_CC_OPT_NO_ADDRSIG=' "${BUILD_DIR}/.config" >/dev/null
    grep -F 'CONFIG_CC_OPT_STRICT_FLEX_ARRAYS=' "${BUILD_DIR}/.config" >/dev/null
    grep -F -- '-fno-addrsig' "${BUILD_DIR}/arch/arm64/kernel/pi/.map_range.o.cmd" >/dev/null
    grep -F -- '-mstrict-align' "${BUILD_DIR}/arch/arm64/kernel/pi/.map_range.o.cmd" >/dev/null
    printf '[OK] Kbuild 670/680 的源码、宿主工具和实际参数证据通过\n'
}

export_bundle() {
    python3 tools/ci/notify_telegram.py --check-only --workspace "${ROOT}" \
        --build-id "${LUNA_BUILD_ID:?}" --project-commit "${LUNA_PROJECT_COMMIT:?}"
    local bundle
    bundle="${CI_RUN_DIR}/luna-${LUNA_PROJECT_COMMIT:0:8}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}.tar.gz"
    [[ ! -e "${bundle}" && ! -L "${bundle}" ]] || fail '拒绝覆盖已有 CI 传输归档'
    python3 - "${ROOT}" "${LUNA_BUILD_ID}" "${bundle}" <<'PY'
import gzip
import sys
import tarfile
from pathlib import Path
sys.path.insert(0, 'tools')
from release_artifacts import verify

root, build_id, target = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
names = verify(root, build_id)
with target.open('xb') as raw, gzip.GzipFile(fileobj=raw, mode='wb', compresslevel=1) as zipped:
    with tarfile.open(fileobj=zipped, mode='w') as archive:
        for name in names:
            archive.add(root / name, arcname=name, recursive=False)
PY
    printf 'bundle_path=%s\n' "${bundle}" >> "${GITHUB_OUTPUT:?}"
}

summary() {
    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
    {
        printf '### Luna CI 构建\n\n- 提交：`%s`\n- 构建：`%s`\n' "${GITHUB_SHA:-unknown}" "${LUNA_BUILD_ID:-未生成}"
        printf -- '- 构建检查：`%s`；产物上传：`%s`\n' "${CI_COMPILE_RESULT:-未运行}" "${CI_UPLOAD_RESULT:-未运行}"
        printf -- '- ccache 恢复键：`%s`；下载精确命中=%s；Manager 精确命中=%s\n' \
            "${CI_CCACHE_HIT:-未恢复}" "${CI_DOWNLOADS_HIT:-false}" "${CI_MANAGER_HIT:-false}"
        if [[ -n "${CI_ARTIFACT_URL:-}" ]]; then
            printf -- '- [完整交付集合](%s)，保留 30 天；待实机验收。\n' "${CI_ARTIFACT_URL}"
        fi
        if [[ -n "${CI_RUN_DIR:-}" && -f "${CI_RUN_DIR}/logs/stages.tsv" ]]; then
            printf '\n| 阶段 | 退出码 | 秒 |\n|---|---:|---:|\n'
            awk -F '\t' '{ printf "| %s | %s | %s |\n", $1, $2, $3 }' "${CI_RUN_DIR}/logs/stages.tsv"
        fi
        printf '\n```text\n'
        CCACHE_DIR="${ROOT}/work/cache/ccache" ccache --show-stats 2>/dev/null || true
        df -h .
        printf '```\n'
    } >> "${GITHUB_STEP_SUMMARY}"
}

case "${1:-}" in
    check-input) check_input ;;
    metadata) metadata ;;
    init|compile|export)
        require_run
        prepare_run_directory
        case "$1" in
            init)
                validate_fixed_dependencies
                phase init patches/init.sh
                python3 "${ROOT}/tools/ci_dependencies.py" check-stock-image --workspace "${ROOT}"
                cache_sizes
                ;;
            compile) compile ;;
            export) export_bundle ;;
        esac
        ;;
    summary) summary ;;
    *) fail '用法: run_build.sh {check-input|metadata|init|compile|export|summary}' ;;
esac
