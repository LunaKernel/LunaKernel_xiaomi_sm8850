#!/usr/bin/env bash
#
# patch_external.sh - authorized external-project kernel patch stage
#
set -euo pipefail

die() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }
log_info() { printf '[INFO] %s\n' "$1"; }
log_step() { printf '[STEP] %s\n' "$1"; }
log_success() { printf '[OK] %s\n' "$1"; }

load_env_file() {
    local env_file="$1"
    local had_allexport=0
    [ -f "${env_file}" ] || return
    case "$-" in *a*) had_allexport=1 ;; esac
    set -a
    . "${env_file}"
    [ "${had_allexport}" = "1" ] || set +a
}

sanitize_path_component() { printf '%s' "$1" | LC_ALL=C tr -cs 'A-Za-z0-9._-' '_'; }
resolve_workspace_path() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "${HOST_WORKSPACE_DIR}" "$1" ;; esac; }
normalize_git_url() { printf '%s' "$1" | sed -e 's#/$##' -e 's#\.git$##'; }
orbctl_run() { local cmd=(orbctl run); [ -z "${ORB_MACHINE:-}" ] || cmd+=(-m "${ORB_MACHINE}"); "${cmd[@]}" "$@"; }
orbctl_run_host_path() { local cmd=(orbctl run -p); [ -z "${ORB_MACHINE:-}" ] || cmd+=(-m "${ORB_MACHINE}"); "${cmd[@]}" "$@"; }

sync_control_files_to_orb() {
    local items="init.sh patch.sh patch_external.sh build.sh"
    [ ! -f "${HOST_WORKSPACE_DIR}/.env" ] || items="${items} .env"
    [ ! -d "${HOST_WORKSPACE_DIR}/patches" ] || items="${items} patches"
    orbctl_run_host_path -w "${HOST_WORKSPACE_DIR}" sh -lc "set -e; target=\"\$HOME/${ORB_LINUX_WORKSPACE}\"; mkdir -p \"\$target\"; tar -cf - ${items} | tar -xf - -C \"\$target\""
}

run_in_orb_if_needed() {
    case "$(uname -s)" in
        Linux) return ;;
        Darwin)
            command -v orbctl >/dev/null 2>&1 || die "当前是 macOS，请启动 OrbStack。"
            sync_control_files_to_orb
            if orbctl_run sh -lc "cd \"\$HOME/${ORB_LINUX_WORKSPACE}\" && exec bash ./patch_external.sh \"\$@\"" sh "$@"; then exit 0; else exit $?; fi
            ;;
        *) die "不支持的操作系统" ;;
    esac
}

verify_repo_identity() {
    local label="$1" repo_dir="$2" expected_url="$3" expected_commit="$4"
    local actual_url actual_commit
    git -C "${repo_dir}" rev-parse --git-dir >/dev/null 2>&1 || die "${label} 未初始化，请先运行 ./init.sh"
    actual_url="$(git -C "${repo_dir}" remote get-url origin 2>/dev/null || true)"
    actual_commit="$(git -C "${repo_dir}" rev-parse HEAD)"
    [ "$(normalize_git_url "${actual_url}")" = "$(normalize_git_url "${expected_url}")" ] || die "${label} remote 不匹配: ${actual_url}"
    [ "${actual_commit}" = "${expected_commit}" ] || die "${label} commit 不匹配: ${actual_commit}"
}

apply_patch_once() {
    local label="$1" repo_dir="$2" patch_file="$3"
    shift 3
    if git -C "${repo_dir}" apply --check "$@" "${patch_file}" >/dev/null 2>&1; then
        git -C "${repo_dir}" apply "$@" "${patch_file}"
        log_success "已应用 ${label}"
    elif git -C "${repo_dir}" apply --reverse --check "$@" "${patch_file}" >/dev/null 2>&1; then
        log_info "${label} 已存在"
    else
        die "${label} 无法干净应用或识别为已应用状态"
    fi
}

verify_allowed_paths() {
    local label="$1" repo_dir="$2" allowed_file="$3"
    local status_line path
    while IFS= read -r status_line; do
        [ -n "${status_line}" ] || continue
        path="${status_line:3}"
        case "${path}" in *' -> '*) path="${path##* -> }" ;; esac
        grep -Fx -- "${path}" "${allowed_file}" >/dev/null || \
            die "${label} 存在未授权差异: ${status_line}"
    done < <(git -C "${repo_dir}" status --porcelain --untracked-files=all)
}

verify_kernelsu_integration() {
    local kconfig_line='source "drivers/kernelsu/Kconfig"'
    local makefile_line='obj-$(CONFIG_KSU) += kernelsu/'
    local unexpected
    [ "$(grep -Fxc "${kconfig_line}" "${COMMON_DIR}/drivers/Kconfig")" = "1" ] || die "KernelSU Kconfig 接入不是精确一处"
    [ "$(tail -n 2 "${COMMON_DIR}/drivers/Kconfig" | head -n 1)" = "${kconfig_line}" ] || die "KernelSU Kconfig 接入位置异常"
    [ "$(grep -Fxc "${makefile_line}" "${COMMON_DIR}/drivers/Makefile")" = "1" ] || die "KernelSU Kbuild 接入不是精确一处"
    [ -L "${COMMON_DIR}/drivers/kernelsu" ] || die "KernelSU drivers 链接缺失"
    [ "$(readlink -f "${COMMON_DIR}/drivers/kernelsu")" = "${KSU_DIR}/kernel" ] || die "KernelSU drivers 链接目标错误"
    unexpected="$(git -C "${COMMON_DIR}" status --porcelain --untracked-files=all | grep -Ev '^( M drivers/(Kconfig|Makefile)|\?\? drivers/kernelsu)$' || true)"
    [ -z "${unexpected}" ] || die "GKI common 存在未授权差异:\n${unexpected}"
    git -C "${COMMON_DIR}" diff --check
    log_success "KernelSU 外部补丁状态校验通过"
}

verify_susfs_integration() {
    local allowed_common allowed_ksu
    local source_file target_file
    git -C "${KSU_DIR}" apply --reverse --check "${KSU_SUSFS_PATCH_FILE}" || die "KernelSU SUSFS 补丁状态异常"
    git -C "${COMMON_DIR}" apply --reverse --check --exclude=security/selinux/hooks.c "${COMMON_SUSFS_PATCH_FILE}" || \
        die "AOSP SUSFS 主补丁状态异常"
    git -C "${COMMON_DIR}" apply --reverse --check "${SUSFS_HOOKS_ADAPTATION}" || \
        die "AOSP r57 SELinux 适配补丁状态异常"

    for source_file in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
        target_file="${COMMON_DIR}/${source_file}"
        cmp -s "${SUSFS_DIR}/kernel_patches/${source_file}" "${target_file}" || \
            die "SUSFS 源文件不是固定上游内容: ${source_file}"
    done

    allowed_ksu="$(mktemp)"
    allowed_common="$(mktemp)"
    awk '$1 == "diff" && $2 == "--git" { sub(/^a\//, "", $3); print $3 }' "${KSU_SUSFS_PATCH_FILE}" | sort -u > "${allowed_ksu}"
    {
        printf '%s\n' drivers/Kconfig drivers/Makefile drivers/kernelsu
        awk '$1 == "diff" && $2 == "--git" { sub(/^a\//, "", $3); print $3 }' "${COMMON_SUSFS_PATCH_FILE}"
        printf '%s\n' fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h
        if [ "${ENABLE_BBG}" = "1" ]; then
            printf '%s\n' security/Kconfig security/Makefile security/baseband-guard include/linux/lsm_count.h
        fi
        if [ "${ENABLE_STAGE5_RTMUTEX_FIX:-0}" = "1" ]; then
            printf '%s\n' kernel/locking/rtmutex.c
        fi
        if [ "${ENABLE_F2FS_MERGE_PAGE_BIO_UAF_FIX:-0}" = "1" ]; then
            printf '%s\n' fs/f2fs/data.c
        fi
        if [ "${ENABLE_F2FS_OPEN_FAST_PATH:-0}" = "1" ]; then
            printf '%s\n' fs/f2fs/file.c
        fi
        if [ "${ENABLE_MEMCG_RSTAT_FAST_PATH:-0}" = "1" ]; then
            printf '%s\n' mm/memcontrol.c
        fi
        if [ "${ENABLE_TCP_RECV_MSTAMP_FAST_PATH:-0}" = "1" ]; then
            printf '%s\n' net/ipv4/tcp.c net/ipv4/tcp_input.c
        fi
        if [ "${ENABLE_GUNYAH_CLEAN_RESOURCES_UAF_FIX:-0}" = "1" ]; then
            printf '%s\n' drivers/virt/gunyah/vm_mgr.c
        fi
        if [ "${ENABLE_IDLETIMER_DESTROY_UAF_FIX:-0}" = "1" ]; then
            printf '%s\n' net/netfilter/xt_IDLETIMER.c
        fi
        if [ "${ENABLE_EVENTPOLL_RCU_UAF_FIX:-0}" = "1" ]; then
            printf '%s\n' fs/eventpoll.c
        fi
        if [ "${ENABLE_CGROUP_KERNFS_UAF_FIX:-0}" = "1" ]; then
            printf '%s\n' kernel/cgroup/cgroup.c
        fi
        if [ "${ENABLE_F2FS_SYNC_INODE_META_UAF_FIX:-0}" = "1" ]; then
            printf '%s\n' fs/f2fs/inode.c
        fi
        if [ "${ENABLE_TIMER_SHUTDOWN_SYNC_RACE_FIX:-0}" = "1" ]; then
            printf '%s\n' kernel/time/timer.c
        fi
        if [ "${ENABLE_FUTEX_REQUEUE_PI_UAF_FIX:-0}" = "1" ]; then
            printf '%s\n' kernel/futex/requeue.c
        fi
        if [ "${ENABLE_PAGE_POOL_DESTROY_RACE_FIX:-0}" = "1" ]; then
            printf '%s\n' net/core/page_pool.c
        fi
        if [ "${ENABLE_CONNTRACK_UNCONFIRMED_RACE_FIX:-0}" = "1" ]; then
            printf '%s\n' include/net/netfilter/nf_conntrack.h net/netfilter/nf_conntrack_core.c
        fi
        if [ "${ENABLE_EROFS_DIR_TAIL_OOB_FIX:-0}" = "1" ]; then
            printf '%s\n' fs/erofs/dir.c
        fi
        if [ "${ENABLE_EXT4_XATTR_OOB_FIX:-0}" = "1" ]; then
            printf '%s\n' fs/ext4/xattr.c
        fi
        if [ "${ENABLE_IPV6_MLD_UAF_FIX:-0}" = "1" ]; then
            printf '%s\n' net/ipv6/mcast.c
        fi
        if [ "${ENABLE_RTMUTEX_WAITER_ENQUEUE_FIX:-0}" = "1" ]; then
            printf '%s\n' kernel/locking/rtmutex.c kernel/locking/rtmutex_api.c
        fi
        if [ "${ENABLE_UNICODE_IGNORABLE_FIX:-0}" = "1" ]; then
            printf '%s\n' fs/ext4/namei.c fs/f2fs/super.c fs/unicode/mkutf8data.c fs/unicode/utf8-norm.c \
                fs/unicode/utf8-selftest.c fs/unicode/utf8n.h include/linux/unicode.h
        fi
        if [ "${ENABLE_ADIOS:-0}" = "1" ]; then
            printf '%s\n' block/Kconfig.iosched block/Makefile block/adios.c block/elevator.c
        fi
        if [ "${ENABLE_TCP_BRUTAL:-0}" = "1" ]; then
            printf '%s\n' net/ipv4/Kconfig net/ipv4/Makefile net/ipv4/tcp_brutal.c
        fi
    } | sort -u > "${allowed_common}"
    verify_allowed_paths "KernelSU" "${KSU_DIR}" "${allowed_ksu}"
    verify_allowed_paths "GKI common" "${COMMON_DIR}" "${allowed_common}"
    rm -f "${allowed_ksu}" "${allowed_common}"
    # The pinned official patches contain a handful of upstream whitespace
    # defects. Reverse-apply checks above prove the tracked diff byte-for-byte;
    # do not rewrite upstream code merely to silence git diff --check.
    log_success "SUSFS v2.2.0 官方补丁与 r57 最小适配状态校验通过"
}

verify_bbg_integration() {
    local kconfig_line='source "security/baseband-guard/Kconfig"'
    local makefile_line='obj-$(CONFIG_BBG) += baseband-guard/'
    [ "$(grep -Fxc "${kconfig_line}" "${COMMON_DIR}/security/Kconfig")" = "1" ] || die "Baseband Guard Kconfig 接入不是精确一处"
    [ "$(grep -Fxc "${makefile_line}" "${COMMON_DIR}/security/Makefile")" = "1" ] || die "Baseband Guard Kbuild 接入不是精确一处"
    [ -L "${COMMON_DIR}/security/baseband-guard" ] || die "Baseband Guard security 链接缺失"
    [ "$(readlink -f "${COMMON_DIR}/security/baseband-guard")" = "${BBG_DIR}" ] || die "Baseband Guard security 链接目标错误"
    git -C "${COMMON_DIR}" apply --reverse --check "${BBG_LSM_COUNT_PATCH}" || die "Baseband Guard LSM 计数适配状态异常"
    [ "$(grep -Ec '^#define BASEBAND_GUARD_ENABLED( |$)' "${COMMON_DIR}/include/linux/lsm_count.h")" = "2" ] || die "Baseband Guard LSM 计数宏异常"
    [ "$(grep -Ec '^[[:space:]]*BASEBAND_GUARD_ENABLED\)?[[:space:]]*\\?$' "${COMMON_DIR}/include/linux/lsm_count.h")" = "1" ] || die "Baseband Guard LSM 计数入口异常"
    log_success "Baseband Guard overlay 与 AOSP r57 LSM 计数适配检查通过"
}

verify_adios_integration() {
    git -C "${COMMON_DIR}" apply --reverse --check --exclude=block/Makefile --exclude=block/Kconfig.iosched "${ADIOS_STABLE_PATCH_FILE}" || \
        die "ADIOS 3.2.0 官方 6.12 补丁状态异常"
    git -C "${COMMON_DIR}" apply --reverse --check "${ADIOS_KBUILD_ADAPTATION}" || \
        die "ADIOS AOSP 6.12.23 Kbuild 适配状态异常"
    git -C "${COMMON_DIR}" apply --check "${ADIOS_FORCE_DEFAULT_PATCH_FILE}" || \
        die "ADIOS 强制默认补丁不得存在"
    grep -Fq '#define ADIOS_VERSION "3.2.0"' "${COMMON_DIR}/block/adios.c" || \
        die "ADIOS 源码版本不是 3.2.0"
    [ "$(grep -Fxc 'config MQ_IOSCHED_ADIOS' "${COMMON_DIR}/block/Kconfig.iosched")" = "1" ] || \
        die "ADIOS Kconfig 主选项不是精确一处"
    [ "$(grep -Fxc 'config MQ_IOSCHED_DEFAULT_ADIOS' "${COMMON_DIR}/block/Kconfig.iosched")" = "1" ] || \
        die "ADIOS Kconfig 默认选项不是精确一处"
    grep -A3 -F 'config MQ_IOSCHED_DEFAULT_ADIOS' "${COMMON_DIR}/block/Kconfig.iosched" | \
        grep -Fqx $'\tdefault n' || die "ADIOS 默认选项没有保持关闭"
    [ "$(grep -Ec '^obj-\$\(CONFIG_MQ_IOSCHED_ADIOS\)[[:space:]]*\+= adios\.o$' "${COMMON_DIR}/block/Makefile")" = "1" ] || \
        die "ADIOS Kbuild 接入不是精确一处"
    ! grep -Eq '^all:|^clean:|/lib/modules/' "${COMMON_DIR}/block/Makefile" || \
        die "ADIOS 外置模块 Makefile 规则不得进入完整内核树"
    log_success "ADIOS 3.2.0 官方补丁与 AOSP 6.12.23 适配检查通过"
}

verify_tcp_brutal_integration() {
    cmp -s "${TCP_BRUTAL_DIR}/brutal.c" "${COMMON_DIR}/net/ipv4/tcp_brutal.c" || \
        die "TCP Brutal 源文件不是固定官方内容"
    git -C "${COMMON_DIR}" apply --reverse --check "${TCP_BRUTAL_INTEGRATION_PATCH}" || \
        die "TCP Brutal AOSP 6.12.23 接入补丁状态异常"
    [ "$(grep -Fxc 'obj-$(CONFIG_TCP_CONG_BRUTAL) += tcp_brutal.o' "${COMMON_DIR}/net/ipv4/Makefile")" = "1" ] || \
        die "TCP Brutal Kbuild 接入不是精确一处"
    log_success "TCP Brutal ${TCP_BRUTAL_COMMIT:0:12} 官方源码接入检查通过"
}

apply_bbg_integration() {
    local kconfig_line='source "security/baseband-guard/Kconfig"'
    local makefile_line='obj-$(CONFIG_BBG) += baseband-guard/'
    if ! grep -Fqx "${kconfig_line}" "${COMMON_DIR}/security/Kconfig"; then
        awk -v line="${kconfig_line}" '
            { lines[NR] = $0; if ($0 ~ /^endmenu[[:space:]]*$/) last = NR }
            END {
                if (!last) exit 2
                for (i = 1; i <= NR; i++) {
                    if (i == last) print line
                    print lines[i]
                }
            }
        ' "${COMMON_DIR}/security/Kconfig" > "${COMMON_DIR}/security/Kconfig.bbg.tmp" || \
            die "security/Kconfig 没有可用的末尾 endmenu"
        mv "${COMMON_DIR}/security/Kconfig.bbg.tmp" "${COMMON_DIR}/security/Kconfig"
    fi
    if ! grep -Fqx "${makefile_line}" "${COMMON_DIR}/security/Makefile"; then
        printf '\n%s\n' "${makefile_line}" >> "${COMMON_DIR}/security/Makefile"
    fi
    if [ -e "${COMMON_DIR}/security/baseband-guard" ] && [ ! -L "${COMMON_DIR}/security/baseband-guard" ]; then
        die "security/baseband-guard 已存在且不是符号链接"
    fi
    if [ ! -L "${COMMON_DIR}/security/baseband-guard" ]; then
        ln -s "$(realpath --relative-to="${COMMON_DIR}/security" "${BBG_DIR}")" "${COMMON_DIR}/security/baseband-guard"
    fi
    apply_patch_once "AOSP r57 Baseband Guard LSM 计数适配" \
        "${COMMON_DIR}" "${BBG_LSM_COUNT_PATCH}"
}

apply_adios_integration() {
    if git -C "${COMMON_DIR}" apply --check --exclude=block/Makefile "${ADIOS_STABLE_PATCH_FILE}" >/dev/null 2>&1; then
        git -C "${COMMON_DIR}" apply --exclude=block/Makefile "${ADIOS_STABLE_PATCH_FILE}"
        log_success "已应用 ADIOS 3.2.0 官方 Linux 6.12 补丁"
    elif git -C "${COMMON_DIR}" apply --reverse --check --exclude=block/Makefile --exclude=block/Kconfig.iosched "${ADIOS_STABLE_PATCH_FILE}" >/dev/null 2>&1; then
        log_info "ADIOS 3.2.0 官方 Linux 6.12 补丁 已存在"
    else
        die "ADIOS 3.2.0 官方 Linux 6.12 补丁无法干净应用或识别为已应用状态"
    fi
    apply_patch_once "ADIOS AOSP 6.12.23 Kbuild 最小适配" \
        "${COMMON_DIR}" "${ADIOS_KBUILD_ADAPTATION}"
    if git -C "${COMMON_DIR}" apply --reverse --check "${ADIOS_FORCE_DEFAULT_PATCH_FILE}" >/dev/null 2>&1; then
        git -C "${COMMON_DIR}" apply --reverse "${ADIOS_FORCE_DEFAULT_PATCH_FILE}"
        log_success "已撤销 ADIOS 强制默认补丁，恢复小米多队列 none 默认策略"
    elif git -C "${COMMON_DIR}" apply --check "${ADIOS_FORCE_DEFAULT_PATCH_FILE}" >/dev/null 2>&1; then
        log_info "ADIOS 强制默认补丁未应用"
    else
        die "ADIOS 强制默认补丁无法精确识别为已应用或未应用状态"
    fi
}

apply_tcp_brutal_integration() {
    if [ -e "${COMMON_DIR}/net/ipv4/tcp_brutal.c" ]; then
        cmp -s "${TCP_BRUTAL_DIR}/brutal.c" "${COMMON_DIR}/net/ipv4/tcp_brutal.c" || \
            die "目标已存在不同的 TCP Brutal 源文件"
    else
        cp "${TCP_BRUTAL_DIR}/brutal.c" "${COMMON_DIR}/net/ipv4/tcp_brutal.c"
    fi
    apply_patch_once "TCP Brutal AOSP 6.12.23 最小接入" \
        "${COMMON_DIR}" "${TCP_BRUTAL_INTEGRATION_PATCH}"
}

apply_susfs_integration() {
    local source_file
    apply_patch_once "SUSFS 对 KernelSU ${KSU_REF} 的官方兼容补丁" \
        "${KSU_DIR}" "${KSU_SUSFS_PATCH_FILE}"
    apply_patch_once "SUSFS Android 16/6.12 主补丁" \
        "${COMMON_DIR}" "${COMMON_SUSFS_PATCH_FILE}" --exclude=security/selinux/hooks.c
    apply_patch_once "AOSP r57 SELinux hooks 最小上下文适配" \
        "${COMMON_DIR}" "${SUSFS_HOOKS_ADAPTATION}"
    for source_file in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
        if [ -e "${COMMON_DIR}/${source_file}" ]; then
            cmp -s "${SUSFS_DIR}/kernel_patches/${source_file}" "${COMMON_DIR}/${source_file}" || \
                die "目标已存在不同的 SUSFS 源文件: ${source_file}"
        else
            cp "${SUSFS_DIR}/kernel_patches/${source_file}" "${COMMON_DIR}/${source_file}"
        fi
    done
}

apply_kernelsu_integration() {
    local kconfig_line='source "drivers/kernelsu/Kconfig"'
    local makefile_line='obj-$(CONFIG_KSU) += kernelsu/'
    if ! grep -Fqx "${kconfig_line}" "${COMMON_DIR}/drivers/Kconfig"; then
        [ "$(tail -n 1 "${COMMON_DIR}/drivers/Kconfig")" = "endmenu" ] || die "drivers/Kconfig 末尾结构变化，不能安全插入 KernelSU"
        sed -i '$i source "drivers/kernelsu/Kconfig"' "${COMMON_DIR}/drivers/Kconfig"
    fi
    if ! grep -Fqx "${makefile_line}" "${COMMON_DIR}/drivers/Makefile"; then
        printf '\n%s\n' "${makefile_line}" >> "${COMMON_DIR}/drivers/Makefile"
    fi
    if [ -e "${COMMON_DIR}/drivers/kernelsu" ] && [ ! -L "${COMMON_DIR}/drivers/kernelsu" ]; then
        die "drivers/kernelsu 已存在且不是符号链接"
    fi
    if [ ! -L "${COMMON_DIR}/drivers/kernelsu" ]; then
        ln -s "$(realpath --relative-to="${COMMON_DIR}/drivers" "${KSU_DIR}/kernel")" "${COMMON_DIR}/drivers/kernelsu"
    fi
}

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
HOST_WORKSPACE_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")" && pwd -P)"
load_env_file "${HOST_WORKSPACE_DIR}/.env"
WORKSPACE_NAME="$(sanitize_path_component "$(basename "${HOST_WORKSPACE_DIR}")")"
ORB_LINUX_ROOT="${ORB_LINUX_ROOT:-.cache/xiaomi_kernel_build}"
ORB_LINUX_WORKSPACE="${ORB_LINUX_ROOT%/}/${WORKSPACE_NAME:-workspace}/workspace"
run_in_orb_if_needed "$@"

ENABLE_KERNELSU="${ENABLE_KERNELSU:-0}"
if [ "${ENABLE_KERNELSU}" != "1" ]; then
    log_info "当前阶段未启用外部项目补丁"
    log_success "外部 patch 阶段完成 (no-op)"
    exit 0
fi

COMMON_REPO="${COMMON_REPO:-https://android.googlesource.com/kernel/common}"
COMMON_COMMIT="${COMMON_COMMIT:-a82fc641d6d2c687802606190c0a8c33a4242201}"
COMMON_DIR="$(resolve_workspace_path "${COMMON_SOURCE_DIR:-sources/aosp_common_6.12.23_r57}")"
KSU_REPO="${KSU_REPO:-https://github.com/tiann/KernelSU.git}"
KSU_REF="${KSU_REF:-v3.2.5}"
KSU_COMMIT="${KSU_COMMIT:-b0bc817b4e966aa6aa830834eaf6ef765d821d40}"
KSU_DIR="$(resolve_workspace_path "${KSU_SOURCE_DIR:-sources/kernelsu}")"
KSU_INTEGRATION_MODE="${KSU_INTEGRATION_MODE:-builtin}"
[ "${KSU_INTEGRATION_MODE}" = "builtin" ] || die "本阶段只允许经批准的 KernelSU built-in 模式"
ENABLE_SUSFS="${ENABLE_SUSFS:-0}"
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_REF="${SUSFS_REF:-gki-android16-6.12}"
SUSFS_COMMIT="${SUSFS_COMMIT:-d9a486dc7197800149c31fe35a77997ea0ddaa83}"
SUSFS_DIR="$(resolve_workspace_path "${SUSFS_SOURCE_DIR:-sources/susfs4ksu}")"
SUSFS_KSU_PATCH_COMMIT="${SUSFS_KSU_PATCH_COMMIT:-ef69c8322232340f43c78c7fc491b32cb9f7da86}"
SUSFS_HOOKS_ADAPTATION="${HOST_WORKSPACE_DIR}/patches/susfs/aosp-r57-selinux-hooks.patch"
ENABLE_BBG="${ENABLE_BBG:-0}"
BBG_REPO="${BBG_REPO:-https://github.com/vc-teahouse/Baseband-guard.git}"
BBG_REF="${BBG_REF:-main}"
BBG_COMMIT="${BBG_COMMIT:-1c664957da7539de860503940ee73c7447f1dfaf}"
BBG_DIR="$(resolve_workspace_path "${BBG_SOURCE_DIR:-sources/baseband_guard}")"
BBG_LSM_COUNT_PATCH="${HOST_WORKSPACE_DIR}/patches/bbg/aosp-r57-lsm-count.patch"
ENABLE_ADIOS="${ENABLE_ADIOS:-0}"
ADIOS_REPO="${ADIOS_REPO:-https://github.com/firelzrd/adios.git}"
ADIOS_REF="${ADIOS_REF:-main}"
ADIOS_COMMIT="${ADIOS_COMMIT:-08bf078aac99075a0bef73c2b2497574a82e4c41}"
ADIOS_DIR="$(resolve_workspace_path "${ADIOS_SOURCE_DIR:-sources/adios}")"
ADIOS_STABLE_PATCH_FILE="${ADIOS_DIR}/${ADIOS_STABLE_PATCH:-patches/stable/0001-linux6.12.44-ADIOS-3.2.0.patch}"
ADIOS_FORCE_DEFAULT_PATCH_FILE="${ADIOS_DIR}/${ADIOS_FORCE_DEFAULT_PATCH:-patches/0002-Make-ADIOS-the-Default-I-O-scheduler.patch}"
ADIOS_KBUILD_ADAPTATION="${HOST_WORKSPACE_DIR}/patches/adios/aosp-6.12.23-kbuild.patch"
ENABLE_TCP_BRUTAL="${ENABLE_TCP_BRUTAL:-0}"
TCP_BRUTAL_REPO="${TCP_BRUTAL_REPO:-https://github.com/apernet/tcp-brutal.git}"
TCP_BRUTAL_REF="${TCP_BRUTAL_REF:-master}"
TCP_BRUTAL_COMMIT="${TCP_BRUTAL_COMMIT:-f11e52d88c7ad2285896de018c2d96d4687f0ab6}"
TCP_BRUTAL_DIR="$(resolve_workspace_path "${TCP_BRUTAL_SOURCE_DIR:-sources/tcp_brutal}")"
TCP_BRUTAL_SOURCE_SHA256="${TCP_BRUTAL_SOURCE_SHA256:-171d775cc494f9378c89772ef68ad8001e093f701a35d1566ec9c7e459cb81c0}"
TCP_BRUTAL_INTEGRATION_PATCH="${HOST_WORKSPACE_DIR}/patches/tcp_brutal/aosp-6.12.23-integration.patch"

verify_repo_identity "Android 16 GKI common" "${COMMON_DIR}" "${COMMON_REPO}" "${COMMON_COMMIT}"
verify_repo_identity "KernelSU ${KSU_REF}" "${KSU_DIR}" "${KSU_REPO}" "${KSU_COMMIT}"
[ "${ENABLE_SUSFS}" = "1" ] || [ -z "$(git -C "${KSU_DIR}" status --porcelain)" ] || die "KernelSU 工作树不干净"

log_step "应用 KernelSU ${KSU_REF} built-in 外部补丁"
apply_kernelsu_integration
if [ "${ENABLE_SUSFS}" = "1" ]; then
    verify_repo_identity "SUSFS ${SUSFS_REF}" "${SUSFS_DIR}" "${SUSFS_REPO}" "${SUSFS_COMMIT}"
    [ -z "$(git -C "${SUSFS_DIR}" status --porcelain)" ] || die "SUSFS 上游工作树不干净"
    [ -s "${SUSFS_HOOKS_ADAPTATION}" ] || die "缺少 AOSP r57 SUSFS SELinux 适配补丁"
    KSU_SUSFS_PATCH_FILE="$(mktemp)"
    COMMON_SUSFS_PATCH_FILE="$(mktemp)"
    trap 'rm -f "${KSU_SUSFS_PATCH_FILE:-}" "${COMMON_SUSFS_PATCH_FILE:-}"' EXIT
    git -C "${SUSFS_DIR}" show "${SUSFS_KSU_PATCH_COMMIT}:kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" > "${KSU_SUSFS_PATCH_FILE}"
    cp "${SUSFS_DIR}/kernel_patches/50_add_susfs_in_gki-android16-6.12.patch" "${COMMON_SUSFS_PATCH_FILE}"
    log_step "应用 SUSFS v2.2.0 官方 Android 16/6.12 补丁"
    apply_susfs_integration
    verify_susfs_integration
else
    verify_kernelsu_integration
fi
if [ "${ENABLE_BBG}" = "1" ]; then
    verify_repo_identity "Baseband Guard ${BBG_REF}" "${BBG_DIR}" "${BBG_REPO}" "${BBG_COMMIT}"
    [ -z "$(git -C "${BBG_DIR}" status --porcelain)" ] || die "Baseband Guard 上游工作树不干净"
    [ -s "${BBG_LSM_COUNT_PATCH}" ] || die "缺少 AOSP r57 Baseband Guard LSM 计数适配"
    log_step "应用 Baseband Guard ${BBG_COMMIT:0:12} overlay"
    apply_bbg_integration
    verify_bbg_integration
fi
if [ "${ENABLE_ADIOS}" = "1" ]; then
    verify_repo_identity "ADIOS ${ADIOS_REF}" "${ADIOS_DIR}" "${ADIOS_REPO}" "${ADIOS_COMMIT}"
    [ -z "$(git -C "${ADIOS_DIR}" status --porcelain)" ] || die "ADIOS 上游工作树不干净"
    [ -s "${ADIOS_STABLE_PATCH_FILE}" ] || die "缺少 ADIOS 6.12 stable 补丁"
    [ -s "${ADIOS_FORCE_DEFAULT_PATCH_FILE}" ] || die "缺少 ADIOS 强制默认补丁审计输入"
    [ -s "${ADIOS_KBUILD_ADAPTATION}" ] || die "缺少 ADIOS AOSP 6.12.23 Kbuild 适配"
    log_step "应用 ADIOS 3.2.0 官方补丁"
    apply_adios_integration
    verify_adios_integration
fi
if [ "${ENABLE_TCP_BRUTAL}" = "1" ]; then
    verify_repo_identity "TCP Brutal ${TCP_BRUTAL_REF}" "${TCP_BRUTAL_DIR}" "${TCP_BRUTAL_REPO}" "${TCP_BRUTAL_COMMIT}"
    [ -z "$(git -C "${TCP_BRUTAL_DIR}" status --porcelain)" ] || die "TCP Brutal 上游工作树不干净"
    [ "$(sha256sum "${TCP_BRUTAL_DIR}/brutal.c" | awk '{ print $1 }')" = "${TCP_BRUTAL_SOURCE_SHA256}" ] || \
        die "TCP Brutal 官方源码 SHA-256 不匹配"
    [ -s "${TCP_BRUTAL_INTEGRATION_PATCH}" ] || die "缺少 TCP Brutal AOSP 6.12.23 接入补丁"
    log_step "应用 TCP Brutal ${TCP_BRUTAL_COMMIT:0:12} 官方源码"
    apply_tcp_brutal_integration
    verify_tcp_brutal_integration
fi
log_success "KernelSU ${KSU_REF} built-in 接入完成"
