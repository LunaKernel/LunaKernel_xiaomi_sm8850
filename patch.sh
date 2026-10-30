#!/usr/bin/env bash
#
# patch.sh - project-owned direct kernel tuning/modification stage
#
set -euo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
export GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1 GIT_PAGER=cat

die() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }
log_info() { printf '[INFO] %s\n' "$1"; }
log_step() { printf '[STEP] %s\n' "$1"; }
log_success() { printf '[OK] %s\n' "$1"; }

reject_git_environment_overrides() {
    local name
    while IFS= read -r name; do
        case "${name}" in
            GIT_CONFIG_GLOBAL)
                [ "${!name}" = "/dev/null" ] || die "Git 全局配置隔离值异常"
                ;;
            GIT_CONFIG_COUNT)
                [ "${!name}" = "1" ] || die "Git 命令配置数量异常"
                ;;
            GIT_CONFIG_KEY_0)
                [ "${!name}" = "core.hooksPath" ] || die "Git 命令配置键异常"
                ;;
            GIT_CONFIG_VALUE_0)
                [ "${!name}" = "/dev/null" ] || die "Git hooks 隔离值异常"
                ;;
            GIT_CONFIG_NOSYSTEM|GIT_NO_LAZY_FETCH|GIT_NO_REPLACE_OBJECTS)
                [ "${!name}" = "1" ] || die "Git 隔离值异常: ${name}"
                ;;
            GIT_PAGER)
                [ "${!name}" = "cat" ] || die "Git pager 隔离值异常"
                ;;
            GIT_*) die "拒绝 Git 环境覆盖: ${name}" ;;
        esac
    done < <(compgen -e)
}
reject_git_environment_overrides

load_env_file() {
    local env_file="$1"
    local had_allexport=0
    [ -f "${env_file}" ] || return
    case "$-" in *a*) had_allexport=1 ;; esac
    set -a
    . "${env_file}"
    [ "${had_allexport}" = "1" ] || set +a
    reject_git_environment_overrides
}

sanitize_path_component() { printf '%s' "$1" | LC_ALL=C tr -cs 'A-Za-z0-9._-' '_'; }
resolve_workspace_path() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "${HOST_WORKSPACE_DIR}" "$1" ;; esac; }

reject_git_object_overrides() {
    local label="$1" repo_dir="$2" git_dir replace_refs unexpected_config
    local hooks_path is_bare top_level
    git_dir="$(git -C "${repo_dir}" rev-parse --absolute-git-dir 2>/dev/null)" || \
        die "${label} 不是 Git 仓库"
    replace_refs="$(git -C "${repo_dir}" for-each-ref --format='%(refname)' refs/replace/)"
    [ -z "${replace_refs}" ] || die "${label} 存在 refs/replace 对象替换:\n${replace_refs}"
    [ ! -s "${git_dir}/info/grafts" ] || die "${label} 存在 info/grafts 对象替换"
    [ ! -s "${git_dir}/info/attributes" ] || die "${label} 存在 info/attributes 工作树过滤覆盖"
    unexpected_config="$(git -C "${repo_dir}" config --name-only --list | LC_ALL=C sort -u | awk '
        /^core\.(repositoryformatversion|filemode|bare|logallrefupdates|hookspath|sparsecheckout|sparsecheckoutcone|ignorecase|precomposeunicode)$/ { next }
        /^extensions\.worktreeconfig$/ { next }
        /^remote\.origin\.(url|fetch|promisor|partialclonefilter|tagopt)$/ { next }
        /^branch\..+\.(remote|merge)$/ { next }
        /^(fetch|transfer)\.fsckobjects$/ { next }
        /^backport\.[a-z0-9.]+$/ { next }
        { print }
    ')"
    [ -z "${unexpected_config}" ] || \
        die "${label} 存在非白名单 Git 配置:\n${unexpected_config}"
    hooks_path="$(git -C "${repo_dir}" config --path --get core.hooksPath 2>/dev/null || true)"
    [ -z "${hooks_path}" ] || [ "${hooks_path}" = "/dev/null" ] || \
        die "${label} 存在非隔离 Git hooks 路径: ${hooks_path}"
    is_bare="$(git -C "${repo_dir}" rev-parse --is-bare-repository)"
    if [ "${is_bare}" = "false" ]; then
        top_level="$(git -C "${repo_dir}" rev-parse --show-toplevel)"
        [ "$(realpath -e "${repo_dir}")" = "$(realpath -e "${top_level}")" ] || \
            die "${label} Git worktree 与预期目录不一致: ${top_level}"
    fi
}

verify_no_hidden_index_flags() {
    local label="$1" repo_dir="$2" hidden
    hidden="$(git -C "${repo_dir}" ls-files -v | LC_ALL=C awk '
        substr($0, 1, 1) == "S" || substr($0, 1, 1) ~ /[a-z]/ { print }
    ')"
    [ -z "${hidden}" ] || \
        die "${label} 存在 skip-worktree/assume-unchanged 标记，无法证明源码状态:\n${hidden}"
}

orbctl_run() { local cmd=(orbctl run); [ -z "${ORB_MACHINE:-}" ] || cmd+=(-m "${ORB_MACHINE}"); "${cmd[@]}" "$@"; }
orbctl_run_host_path() { local cmd=(orbctl run -p); [ -z "${ORB_MACHINE:-}" ] || cmd+=(-m "${ORB_MACHINE}"); "${cmd[@]}" "$@"; }

sync_control_files_to_orb() {
    local items="init.sh patch.sh patch_external.sh build.sh patches tools"
    [ ! -f "${HOST_WORKSPACE_DIR}/.env" ] || items="${items} .env"
    orbctl_run_host_path -w "${HOST_WORKSPACE_DIR}" sh -lc "set -e; target=\"\$HOME/${ORB_LINUX_WORKSPACE}\"; mkdir -p \"\$target\"; tar -cf - ${items} | tar -xf - -C \"\$target\""
}

run_in_orb_if_needed() {
    case "$(uname -s)" in
        Linux) return ;;
        Darwin)
            command -v orbctl >/dev/null 2>&1 || die "当前是 macOS，请启动 OrbStack。"
            sync_control_files_to_orb
            if orbctl_run sh -lc "cd \"\$HOME/${ORB_LINUX_WORKSPACE}\" && exec bash ./patch.sh \"\$@\"" sh "$@"; then exit 0; else exit $?; fi
            ;;
        *) die "不支持的操作系统" ;;
    esac
}

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
HOST_WORKSPACE_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")" && pwd -P)"
[ -f "${HOST_WORKSPACE_DIR}/.env" ] || die "缺少受版本控制的 .env"
load_env_file "${HOST_WORKSPACE_DIR}/.env"
WORKSPACE_NAME="$(sanitize_path_component "$(basename "${HOST_WORKSPACE_DIR}")")"
ORB_LINUX_ROOT="${ORB_LINUX_ROOT:-.cache/xiaomi_kernel_build}"
ORB_LINUX_WORKSPACE="${ORB_LINUX_ROOT%/}/${WORKSPACE_NAME:-workspace}/workspace"
run_in_orb_if_needed "$@"

COMMON_DIR="$(resolve_workspace_path "${COMMON_SOURCE_DIR:-sources/aosp_common_6.12.92_kmi6_2026-09}")"
[ -d "${COMMON_DIR}/.git" ] || die "GKI common 未初始化，请先运行 ./init.sh"
[ "$(git -C "${COMMON_DIR}" rev-parse HEAD)" = "${COMMON_COMMIT:-aa556307b679df7ced0cc644068a529280dbc412}" ] || die "GKI common pin 不匹配"

AOSP_BACKPORT_AUDIT_DIR="$(resolve_workspace_path "${AOSP_BACKPORT_AUDIT_SOURCE_DIR:-sources/aosp_common_backport_audit}")"
LINUX_STABLE_AUDIT_DIR="$(resolve_workspace_path "${LINUX_STABLE_AUDIT_SOURCE_DIR:-sources/linux_stable_6.12_audit}")"
LINUX_STABLE_AUDIT_COMMIT="${LINUX_STABLE_AUDIT_COMMIT:-}"
LINUX_MAINLINE_AUDIT_DIR="$(resolve_workspace_path "${LINUX_MAINLINE_AUDIT_SOURCE_DIR:-sources/linux_mainline_audit}")"
LINUX_MAINLINE_AUDIT_COMMIT="${LINUX_MAINLINE_AUDIT_COMMIT:-}"
reject_git_object_overrides "GKI common" "${COMMON_DIR}"
verify_no_hidden_index_flags "GKI common" "${COMMON_DIR}"
reject_git_object_overrides "AOSP common 审计仓库" "${AOSP_BACKPORT_AUDIT_DIR}"
reject_git_object_overrides "Linux stable 审计仓库" "${LINUX_STABLE_AUDIT_DIR}"
reject_git_object_overrides "Linux mainline 审计仓库" "${LINUX_MAINLINE_AUDIT_DIR}"
TEGRA_MC_KMI_PATCH_FILE="${HOST_WORKSPACE_DIR}/${TEGRA_MC_KMI_PATCH:-patches/kmi/tegra-mc-opaque-pointer-kmi-r21.patch}"
TEGRA_MC_KMI_PATCH_SHA256="${TEGRA_MC_KMI_PATCH_SHA256:-ed862fd9b766ba5ee47baef59b4f6485c9ee8545c5a3270f2f58258082a9a792}"
TEGRA_MC_KMI_PATCH_ID="${TEGRA_MC_KMI_PATCH_ID:-120d76a884b594c227377b034f0eecf1071b5b91}"
ENABLE_F2FS_ACL_ENTRY_BOUNDS_FIX="${ENABLE_F2FS_ACL_ENTRY_BOUNDS_FIX:-0}"
F2FS_ACL_ENTRY_BOUNDS_STABLE_COMMIT="${F2FS_ACL_ENTRY_BOUNDS_STABLE_COMMIT:-aba4f94ac1832c7299c33e1b4fe5f87eef6dc8f1}"
F2FS_ACL_ENTRY_BOUNDS_PATCH_ID="${F2FS_ACL_ENTRY_BOUNDS_PATCH_ID:-3021795cf81293828302c01bb7d52bb4d52a7259}"
ENABLE_F2FS_LISTXATTR_BOUNDS_FIX="${ENABLE_F2FS_LISTXATTR_BOUNDS_FIX:-0}"
F2FS_LISTXATTR_BOUNDS_STABLE_COMMIT="${F2FS_LISTXATTR_BOUNDS_STABLE_COMMIT:-7dd01f7d0291583e3e5420c95c7d584e114899bd}"
F2FS_LISTXATTR_BOUNDS_PATCH_ID="${F2FS_LISTXATTR_BOUNDS_PATCH_ID:-daaf1f38e2ef4939e6981e7a563c1a488225a11c}"
ENABLE_BLKCG_RSTAT_RELEASE_FIX="${ENABLE_BLKCG_RSTAT_RELEASE_FIX:-0}"
BLKCG_RSTAT_RELEASE_STABLE_COMMIT="${BLKCG_RSTAT_RELEASE_STABLE_COMMIT:-bbebd9425cad3573d1527441753899b926525a0f}"
BLKCG_RSTAT_RELEASE_PATCH_ID="${BLKCG_RSTAT_RELEASE_PATCH_ID:-5149120b23c377e425b11bfdcb1933e39245a1c7}"
ENABLE_F2FS_FOREGROUND_GC_DEADLOCK_FIX="${ENABLE_F2FS_FOREGROUND_GC_DEADLOCK_FIX:-0}"
F2FS_FOREGROUND_GC_DEADLOCK_STABLE_COMMIT="${F2FS_FOREGROUND_GC_DEADLOCK_STABLE_COMMIT:-44480f7e3f8369671452c0d262831c51aa5a9c20}"
F2FS_FOREGROUND_GC_DEADLOCK_PATCH_ID="${F2FS_FOREGROUND_GC_DEADLOCK_PATCH_ID:-8d86d1f0ff47ad109628af8462bd4506c81dd4f6}"
F2FS_GC_MERGE_DEADLOCK_STABLE_COMMIT="${F2FS_GC_MERGE_DEADLOCK_STABLE_COMMIT:-b885c7783c19c36c7bf899492a0bffcd68afa8c7}"
F2FS_GC_MERGE_DEADLOCK_PATCH_ID="${F2FS_GC_MERGE_DEADLOCK_PATCH_ID:-f1e7da7bf78fadbfd5f41ae8f1d1b196ee96b98d}"
F2FS_FOREGROUND_GC_PATCH="${HOST_WORKSPACE_DIR}/${F2FS_FOREGROUND_GC_PATCH:-patches/backports/f2fs-foreground-gc-deadlock-r21.patch}"
F2FS_FOREGROUND_GC_PATCH_ID="${F2FS_FOREGROUND_GC_PATCH_ID:-70442d9fb39ac24622e33231473817e5dc60249b}"
ENABLE_TIMER_BASE_FAST_PATH="${ENABLE_TIMER_BASE_FAST_PATH:-0}"
TIMER_BASE_FAST_PATH_COMMIT="${TIMER_BASE_FAST_PATH_COMMIT:-3ec955713d9617059d2fc8f2816d0b95ace72256}"
TIMER_BASE_FAST_PATH_COMMIT_DATE="${TIMER_BASE_FAST_PATH_COMMIT_DATE:-2025-01-16}"
TIMER_BASE_FAST_PATH_PATCH_ID="${TIMER_BASE_FAST_PATH_PATCH_ID:-68dca003ed5b13fb40d3b777155c6568438563ef}"
ENABLE_F2FS_DIO_OVERWRITE_FAST_PATH="${ENABLE_F2FS_DIO_OVERWRITE_FAST_PATH:-0}"
F2FS_DIO_OVERWRITE_FAST_PATH_COMMIT="${F2FS_DIO_OVERWRITE_FAST_PATH_COMMIT:-d860974a7e38d35e9e2c4dc8a9f4223b38b6ad99}"
F2FS_DIO_OVERWRITE_FAST_PATH_PATCH_ID="${F2FS_DIO_OVERWRITE_FAST_PATH_PATCH_ID:-fec231f96375f0622cf9bd9427ef2baf5614ac03}"
ENABLE_BLK_WBT_DONE_FAST_PATH="${ENABLE_BLK_WBT_DONE_FAST_PATH:-0}"
BLK_WBT_DONE_FAST_PATH_COMMIT="${BLK_WBT_DONE_FAST_PATH_COMMIT:-d8b96a79622e03813c221450498ca9742704ebf2}"
BLK_WBT_DONE_FAST_PATH_PATCH_ID="${BLK_WBT_DONE_FAST_PATH_PATCH_ID:-097d27325d53feb894b26bb0c7e152fca314e7b9}"
ENABLE_MEMCG_RSTAT_FAST_PATH="${ENABLE_MEMCG_RSTAT_FAST_PATH:-0}"
MEMCG_RSTAT_FAST_PATH_COMMIT="${MEMCG_RSTAT_FAST_PATH_COMMIT:-60cada258dfe3694e15c4539259173c37bd5f1fe}"
MEMCG_RSTAT_FAST_PATH_PATCH_ID="${MEMCG_RSTAT_FAST_PATH_PATCH_ID:-5b12701394b4f6a128f5456e3bd8fed4f8740c27}"
ENABLE_TCP_RECV_MSTAMP_FAST_PATH="${ENABLE_TCP_RECV_MSTAMP_FAST_PATH:-0}"
TCP_RECV_MSTAMP_FAST_PATH_COMMIT="${TCP_RECV_MSTAMP_FAST_PATH_COMMIT:-0ae1ac7335ca2328c42fbbe2b71bc9c3fc8e65d9}"
TCP_RECV_MSTAMP_FAST_PATH_PATCH_ID="${TCP_RECV_MSTAMP_FAST_PATH_PATCH_ID:-66387ee17b01507a8f2a2b6537c9f7e22c86b509}"
ENABLE_IPV6_MLD_UAF_FIX="${ENABLE_IPV6_MLD_UAF_FIX:-0}"
IPV6_MLD_UAF_FIX_COMMIT="${IPV6_MLD_UAF_FIX_COMMIT:-791c91dc7a9dfb2457d5e29b8216a6484b9c4b40}"
IPV6_MLD_UAF_FIX_PATCH_ID="${IPV6_MLD_UAF_FIX_PATCH_ID:-1358ebc3d619657f50c2f0f50f5408f60ea5b732}"
ENABLE_IPV6_MLD_DELAYED_WORK_UAF_FIX="${ENABLE_IPV6_MLD_DELAYED_WORK_UAF_FIX:-0}"
IPV6_MLD_DELAYED_WORK_STABLE_COMMIT="${IPV6_MLD_DELAYED_WORK_STABLE_COMMIT:-ebbebf6cee950d7f1c81990256c0eae9e62572ae}"
IPV6_MLD_DELAYED_WORK_UPSTREAM_COMMIT="${IPV6_MLD_DELAYED_WORK_UPSTREAM_COMMIT:-9b26518b6896a16b809b1e42986f4ebac7bccc1e}"
IPV6_MLD_DELAYED_WORK_COMMIT_DATE="${IPV6_MLD_DELAYED_WORK_COMMIT_DATE:-2026-07-24}"
IPV6_MLD_DELAYED_WORK_OFFICIAL_PATCH_ID="${IPV6_MLD_DELAYED_WORK_OFFICIAL_PATCH_ID:-4fcf3ce5ec83da4c8203e344d896802035700c78}"
IPV6_MLD_DELAYED_WORK_PATCH="${IPV6_MLD_DELAYED_WORK_PATCH:-patches/backports/ipv6-mld-delayed-work-uaf-r21.patch}"
IPV6_MLD_DELAYED_WORK_PATCH_SHA256="${IPV6_MLD_DELAYED_WORK_PATCH_SHA256:-7bd3339c3a5db6b1aa034585a5bb5eb53d90a0ac98775e5bdfc941547d5c1c5b}"
IPV6_MLD_DELAYED_WORK_PATCH_ID="${IPV6_MLD_DELAYED_WORK_PATCH_ID:-8d28904741b04eefe83489706946e55a0682fe08}"
IPV6_MLD_DELAYED_WORK_PATCH_FILE="${HOST_WORKSPACE_DIR}/${IPV6_MLD_DELAYED_WORK_PATCH}"
apply_official_backport_once() {
    local label="$1" repo_mode="$2" repo_dir="$3" commit="$4" expected_patch_id="$5"
    local patch_file patch_id
    local git_cmd
    case "${repo_mode}" in
        worktree) git_cmd=(git -C "${repo_dir}") ;;
        bare) git_cmd=(git --git-dir="${repo_dir}") ;;
        *) die "${label}审计仓库模式无效" ;;
    esac
    patch_file="$(mktemp)"
    env GIT_NO_LAZY_FETCH=1 "${git_cmd[@]}" \
        cat-file -e "${commit}^{commit}" 2>/dev/null || \
        die "${label}对象缺失，请先运行 ./init.sh"
    env GIT_NO_LAZY_FETCH=1 "${git_cmd[@]}" -c log.mailmap=false \
        show --format= "${commit}" > "${patch_file}"
    patch_id="$(git patch-id --stable < "${patch_file}" | awk '{ print $1 }')"
    [ "${patch_id}" = "${expected_patch_id}" ] || die "${label} patch-id 不匹配"
    if git -C "${COMMON_DIR}" apply --check "${patch_file}" >/dev/null 2>&1; then
        log_step "应用 ${label}"
        git -C "${COMMON_DIR}" apply "${patch_file}"
    elif git -C "${COMMON_DIR}" apply --reverse --check "${patch_file}" >/dev/null 2>&1; then
        log_info "${label}已存在"
    else
        die "${label}无法干净应用或识别"
    fi
    git -C "${COMMON_DIR}" apply --reverse --check "${patch_file}" || \
        die "${label}状态不完整"
    rm -f "${patch_file}"
}

apply_aosp_backport_once() {
    apply_official_backport_once "$1" worktree "${AOSP_BACKPORT_AUDIT_DIR}" "$2" "$3"
}

apply_linux_stable_backport_once() {
    apply_official_backport_once "$1" bare "${LINUX_STABLE_AUDIT_DIR}" "$2" "$3"
}

apply_linux_mainline_backport_once() {
    apply_official_backport_once "$1" bare "${LINUX_MAINLINE_AUDIT_DIR}" "$2" "$3"
}

verify_linux_mainline_source_exact() {
    local label="$1" commit="$2" commit_date="$3" expected_patch_id="$4"
    local expected_paths="$5" actual_date actual_paths patch_id

    [ -n "${LINUX_MAINLINE_AUDIT_COMMIT}" ] || die "缺少 Linux mainline 固定审计终点"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        cat-file -e "${commit}^{commit}" 2>/dev/null || \
        die "${label}对象缺失，请先运行 ./init.sh"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        merge-base --is-ancestor "${commit}" "${LINUX_MAINLINE_AUDIT_COMMIT}" || \
        die "${label}不属于固定 Linux mainline 审计快照"
    actual_date="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        -c log.mailmap=false show -s --format=%cs "${commit}")"
    [ "${actual_date}" = "${commit_date}" ] || die "${label}提交日期不匹配: ${actual_date}"
    actual_paths="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        diff-tree --no-commit-id --name-only -r "${commit}" | LC_ALL=C sort | paste -sd ' ' -)"
    [ "${actual_paths}" = "${expected_paths}" ] || die "${label}触及非预期路径: ${actual_paths}"
    patch_id="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        -c log.mailmap=false show --format= "${commit}" | git patch-id --stable | awk '{ print $1 }')"
    [ "${patch_id}" = "${expected_patch_id}" ] || die "${label}patch-id 不匹配"
}

verify_linux_stable_source() {
    local label="$1" commit="$2" expected_patch_id="$3"
    local patch_file patch_id
    patch_file="$(mktemp)"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        cat-file -e "${commit}^{commit}" 2>/dev/null || \
        die "${label}对象缺失，请先运行 ./init.sh"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        merge-base --is-ancestor "${commit}" "${LINUX_STABLE_AUDIT_COMMIT}" || \
        die "${label} 不属于固定 Linux 6.12.y 审计快照"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        -c log.mailmap=false show --format= "${commit}" > "${patch_file}"
    patch_id="$(git patch-id --stable < "${patch_file}" | awk '{ print $1 }')"
    rm -f "${patch_file}"
    [ "${patch_id}" = "${expected_patch_id}" ] || die "${label} patch-id 不匹配"
}

verify_linux_stable_source_exact() {
    local label="$1" commit="$2" commit_date="$3" expected_patch_id="$4"
    local expected_paths="$5" upstream_commit="$6"
    local actual_date actual_paths commit_message upstream_patch_id upstream_paths

    [ -n "${LINUX_STABLE_AUDIT_COMMIT}" ] || die "缺少 Linux stable 固定审计终点"
    verify_linux_stable_source "${label}" "${commit}" "${expected_patch_id}"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        merge-base --is-ancestor "${commit}" "${LINUX_STABLE_AUDIT_COMMIT}" || \
        die "${label} 不属于固定 Linux 6.12.y 审计快照"
    actual_date="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        -c log.mailmap=false show -s --format=%cs "${commit}")"
    [ "${actual_date}" = "${commit_date}" ] || die "${label} 提交日期不匹配: ${actual_date}"
    actual_paths="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        diff-tree --no-commit-id --name-only -r "${commit}" | LC_ALL=C sort | paste -sd ' ' -)"
    [ "${actual_paths}" = "${expected_paths}" ] || die "${label} 触及非预期路径: ${actual_paths}"
    commit_message="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        -c log.mailmap=false show -s --format=%B "${commit}")"
    grep -Fx "[ Upstream commit ${upstream_commit} ]" <<<"${commit_message}" >/dev/null || \
        die "${label} 未绑定固定 Linux mainline 上游提交"
    [ -n "${LINUX_MAINLINE_AUDIT_COMMIT}" ] || die "缺少 Linux mainline 固定审计终点"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        cat-file -e "${upstream_commit}^{commit}" 2>/dev/null || \
        die "${label} Linux mainline 上游对象缺失，请先运行 ./init.sh"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        merge-base --is-ancestor "${upstream_commit}" "${LINUX_MAINLINE_AUDIT_COMMIT}" || \
        die "${label} 上游提交不属于固定 Linux mainline 快照"
    upstream_paths="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        diff-tree --no-commit-id --name-only -r "${upstream_commit}" | LC_ALL=C sort | paste -sd ' ' -)"
    [ "${upstream_paths}" = "${expected_paths}" ] || \
        die "${label} Linux mainline 上游触及非预期路径: ${upstream_paths}"
    upstream_patch_id="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        -c log.mailmap=false show --format= "${upstream_commit}" | \
        git patch-id --stable | awk '{ print $1 }')"
    [ "${upstream_patch_id}" = "${expected_patch_id}" ] || \
        die "${label} Linux mainline 上游 patch-id 不匹配"
}

apply_project_patch_once() {
    local label="$1" patch_file="$2" expected_sha256="$3" expected_patch_id="$4"
    local actual_sha256 patch_id
    [ -f "${patch_file}" ] || die "${label}补丁缺失"
    actual_sha256="$(sha256sum "${patch_file}" | awk '{ print $1 }')"
    [ "${actual_sha256}" = "${expected_sha256}" ] || die "${label} SHA-256 不匹配"
    patch_id="$(git patch-id --stable < "${patch_file}" | awk '{ print $1 }')"
    [ "${patch_id}" = "${expected_patch_id}" ] || die "${label} patch-id 不匹配"
    if git -C "${COMMON_DIR}" apply --check "${patch_file}" >/dev/null 2>&1; then
        log_step "应用 ${label}"
        git -C "${COMMON_DIR}" apply "${patch_file}"
    elif git -C "${COMMON_DIR}" apply --reverse --check "${patch_file}" >/dev/null 2>&1; then
        log_info "${label}已存在"
    else
        die "${label}无法干净应用或识别"
    fi
    git -C "${COMMON_DIR}" apply --reverse --check "${patch_file}" || \
        die "${label}状态不完整"
}

apply_project_patch_once "AOSP r21 Tegra 不透明指针 KMI 兼容标注" \
    "${TEGRA_MC_KMI_PATCH_FILE}" \
    "${TEGRA_MC_KMI_PATCH_SHA256}" \
    "${TEGRA_MC_KMI_PATCH_ID}"

if [ "${ENABLE_TIMER_BASE_FAST_PATH}" = "1" ]; then
    verify_linux_mainline_source_exact "Linux mainline timer base 指针获取快路径优化" \
        "${TIMER_BASE_FAST_PATH_COMMIT}" \
        "${TIMER_BASE_FAST_PATH_COMMIT_DATE}" \
        "${TIMER_BASE_FAST_PATH_PATCH_ID}" \
        "kernel/time/timer.c"
    apply_linux_mainline_backport_once "Linux mainline timer base 指针获取快路径优化" \
        "${TIMER_BASE_FAST_PATH_COMMIT}" "${TIMER_BASE_FAST_PATH_PATCH_ID}"
    grep -Fq 'return per_cpu_ptr(&timer_bases[index], cpu);' \
        "${COMMON_DIR}/kernel/time/timer.c" || \
        die "timer CPU base 快路径未使用单次 per_cpu_ptr"
    grep -Fq 'return this_cpu_ptr(&timer_bases[index]);' \
        "${COMMON_DIR}/kernel/time/timer.c" || \
        die "timer this CPU base 快路径未使用单次 this_cpu_ptr"
    log_success "Linux mainline timer base 指针获取快路径优化状态正确"
fi

if [ "${ENABLE_F2FS_DIO_OVERWRITE_FAST_PATH}" = "1" ]; then
    apply_aosp_backport_once "AOSP F2FS DIO overwrite 映射检查优化" \
        "${F2FS_DIO_OVERWRITE_FAST_PATH_COMMIT}" \
        "${F2FS_DIO_OVERWRITE_FAST_PATH_PATCH_ID}"
    grep -Fq 'static bool __f2fs_overwrite_io(struct inode *inode, loff_t pos, size_t len,' \
        "${COMMON_DIR}/fs/f2fs/data.c" || \
        die "F2FS DIO overwrite 优化缺少内部 helper"
    grep -Fq '!__f2fs_overwrite_io(inode, offset, length, true)' \
        "${COMMON_DIR}/fs/f2fs/data.c" || \
        die "F2FS iomap 未启用首映射检查"
    grep -Fq 'return __f2fs_overwrite_io(inode, pos, len, false);' \
        "${COMMON_DIR}/fs/f2fs/data.c" || \
        die "F2FS 原有完整 overwrite 检查语义被破坏"
    log_success "AOSP F2FS DIO overwrite 映射检查优化状态正确"
fi

if [ "${ENABLE_BLK_WBT_DONE_FAST_PATH}" = "1" ]; then
    apply_aosp_backport_once "AOSP blk-wbt 非节流写完成快路径优化" \
        "${BLK_WBT_DONE_FAST_PATH_COMMIT}" \
        "${BLK_WBT_DONE_FAST_PATH_PATCH_ID}"
    wbt_done_function="$(sed -n '/^static void wbt_done(/,/^}/p' \
        "${COMMON_DIR}/block/blk-wbt.c")"
    printf '%s\n' "${wbt_done_function}" | \
        grep -Fq 'if (wbt_is_read(rq)) {' || \
        die "blk-wbt 未将 read-only 状态更新置于读请求分支"
    log_success "AOSP blk-wbt 非节流写完成快路径优化状态正确"
fi

if [ "${ENABLE_MEMCG_RSTAT_FAST_PATH}" = "1" ]; then
    apply_aosp_backport_once "Linux memcg rstat 快路径优化" \
        "${MEMCG_RSTAT_FAST_PATH_COMMIT}" \
        "${MEMCG_RSTAT_FAST_PATH_PATCH_ID}"
    grep -Fq 'if (memcg_vmstats_needs_flush(statc->vmstats))' \
        "${COMMON_DIR}/mm/memcontrol.c" || \
        die "memcg rstat 快路径未在祖先遍历前检查刷新状态"
    log_success "Linux memcg rstat 快路径优化状态正确"
fi

if [ "${ENABLE_TCP_RECV_MSTAMP_FAST_PATH}" = "1" ]; then
    apply_aosp_backport_once "Linux TCP recv 时间戳快路径优化" \
        "${TCP_RECV_MSTAMP_FAST_PATH_COMMIT}" \
        "${TCP_RECV_MSTAMP_FAST_PATH_PATCH_ID}"
    grep -Fq 'if (unlikely(!tp->rcv_rtt_est.rtt_us))' \
        "${COMMON_DIR}/net/ipv4/tcp_input.c" || \
        die "TCP recv 快路径未保留无 RTT 样本保护"
    log_success "Linux TCP recv 时间戳快路径优化状态正确"
fi

if [ "${ENABLE_IPV6_MLD_UAF_FIX}" = "1" ]; then
    apply_aosp_backport_once "AOSP IPv6 MLD 查询释放后访问修复" \
        "${IPV6_MLD_UAF_FIX_COMMIT}" \
        "${IPV6_MLD_UAF_FIX_PATCH_ID}"
    grep -Fq 'group = mld->mld_mca;' "${COMMON_DIR}/net/ipv6/mcast.c" || \
        die "IPv6 MLD 查询仍可能在 skb 重分配后使用旧 group 指针"
    log_success "AOSP IPv6 MLD 查询释放后访问修复状态正确"
fi

if [ "${ENABLE_IPV6_MLD_DELAYED_WORK_UAF_FIX}" = "1" ]; then
    verify_linux_stable_source_exact "Linux IPv6 MLD delayed-work 生命周期修复" \
        "${IPV6_MLD_DELAYED_WORK_STABLE_COMMIT}" \
        "${IPV6_MLD_DELAYED_WORK_COMMIT_DATE}" \
        "${IPV6_MLD_DELAYED_WORK_OFFICIAL_PATCH_ID}" \
        "include/net/addrconf.h net/ipv6/mcast.c" \
        "${IPV6_MLD_DELAYED_WORK_UPSTREAM_COMMIT}"
    apply_project_patch_once "Linux IPv6 MLD delayed-work UAF 修复（r21 上下文适配）" \
        "${IPV6_MLD_DELAYED_WORK_PATCH_FILE}" \
        "${IPV6_MLD_DELAYED_WORK_PATCH_SHA256}" \
        "${IPV6_MLD_DELAYED_WORK_PATCH_ID}"
    [ "$(grep -Fc 'in6_dev_hold_safe(idev)' "${COMMON_DIR}/net/ipv6/mcast.c")" = "5" ] || \
        die "IPv6 MLD delayed-work 安全引用覆盖点异常"
    grep -Fq 'return refcount_inc_not_zero(&idev->refcnt);' \
        "${COMMON_DIR}/include/net/addrconf.h" || \
        die "IPv6 MLD delayed-work 仍可能复活零引用 inet6_dev"
    log_success "Linux IPv6 MLD delayed-work 生命周期修复状态正确"
fi

if [ "${ENABLE_F2FS_ACL_ENTRY_BOUNDS_FIX}" = "1" ]; then
    apply_linux_stable_backport_once "Linux F2FS ACL 条目边界修复" \
        "${F2FS_ACL_ENTRY_BOUNDS_STABLE_COMMIT}" \
        "${F2FS_ACL_ENTRY_BOUNDS_PATCH_ID}"
    grep -Fq 'sizeof(struct f2fs_acl_entry_short) > end' \
        "${COMMON_DIR}/fs/f2fs/acl.c" || \
        die "F2FS ACL 短条目读取前未验证边界"
    grep -Fq 'err = -EFSCORRUPTED;' "${COMMON_DIR}/fs/f2fs/acl.c" || \
        die "F2FS ACL 损坏条目未返回 EFSCORRUPTED"
    log_success "Linux F2FS ACL 条目边界修复状态正确"
fi

if [ "${ENABLE_F2FS_LISTXATTR_BOUNDS_FIX}" = "1" ]; then
    apply_linux_stable_backport_once "Linux F2FS listxattr 条目边界修复" \
        "${F2FS_LISTXATTR_BOUNDS_STABLE_COMMIT}" \
        "${F2FS_LISTXATTR_BOUNDS_PATCH_ID}"
    grep -A9 -F 'sizeof(__u32) > last_base_addr' \
        "${COMMON_DIR}/fs/f2fs/xattr.c" |
        grep -Fq 'error = -EFSCORRUPTED;' || \
        die "F2FS listxattr 损坏条目仍返回部分成功结果"
    log_success "Linux F2FS listxattr 条目边界修复状态正确"
fi

if [ "${ENABLE_BLKCG_RSTAT_RELEASE_FIX}" = "1" ]; then
    apply_linux_stable_backport_once "Linux blk-cgroup rstat 释放竞态修复" \
        "${BLKCG_RSTAT_RELEASE_STABLE_COMMIT}" \
        "${BLKCG_RSTAT_RELEASE_PATCH_ID}"
    grep -A15 -F 'static void blkg_release(struct percpu_ref *ref)' \
        "${COMMON_DIR}/block/blk-cgroup.c" |
        grep -Fq '__blkcg_rstat_flush(blkcg, cpu);' || \
        die "blk-cgroup rstat 未在 call_rcu 前刷新"
    log_success "Linux blk-cgroup rstat 释放竞态修复状态正确"
fi

f2fs_gc_deadlock_fix_complete() {
    grep -Fq 'void f2fs_submit_all_merged_ipu_writes(struct f2fs_sb_info *sbi)' \
        "${COMMON_DIR}/fs/f2fs/data.c" &&
    awk '
        /^void f2fs_balance_fs\(/ { body = 1 }
        body && /f2fs_submit_all_merged_ipu_writes\(sbi\);/ { flushed = NR }
        body && /test_opt\(sbi, GC_MERGE\)/ {
            if (!flushed || flushed >= NR)
                exit 1
            checked = 1
        }
        body && /^}/ { exit !checked }
        END { if (!checked) exit 1 }
    ' "${COMMON_DIR}/fs/f2fs/segment.c"
}

if [ "${ENABLE_F2FS_FOREGROUND_GC_DEADLOCK_FIX}" = "1" ]; then
    verify_linux_stable_source "Linux F2FS 前台 GC 写回死锁修复" \
        "${F2FS_FOREGROUND_GC_DEADLOCK_STABLE_COMMIT}" \
        "${F2FS_FOREGROUND_GC_DEADLOCK_PATCH_ID}"
    verify_linux_stable_source "Linux F2FS GC_MERGE 写回死锁补充修复" \
        "${F2FS_GC_MERGE_DEADLOCK_STABLE_COMMIT}" \
        "${F2FS_GC_MERGE_DEADLOCK_PATCH_ID}"
    apply_project_patch_once "Linux F2FS 前台 GC 写回死锁组合修复（r21 上下文适配）" \
        "${F2FS_FOREGROUND_GC_PATCH}" \
        "${F2FS_FOREGROUND_GC_PATCH_SHA256}" \
        "${F2FS_FOREGROUND_GC_PATCH_ID}"
    f2fs_gc_deadlock_fix_complete || \
        die "F2FS 缓存 bio 未在 GC_MERGE 分支前统一提交"
    log_success "Linux F2FS 前台 GC 写回死锁修复状态正确"
fi

if [ "${ENABLE_SELECTED_BACKPORTS:-0}" = "1" ]; then
    bash "${HOST_WORKSPACE_DIR}/tools/backport_manifest.sh" apply "${COMMON_DIR}"
fi

bash "${HOST_WORKSPACE_DIR}/tools/independent_backports.sh" \
    apply "${COMMON_DIR}"

log_success "内部 patch 阶段完成"
