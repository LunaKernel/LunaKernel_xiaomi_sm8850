#!/usr/bin/env bash
#
# patch_external.sh - authorized external-project kernel patch stage
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
normalize_git_url() { printf '%s' "$1" | sed -e 's#/$##' -e 's#\.git$##'; }
reject_git_object_overrides() {
    local label="$1" repo_dir="$2" git_dir replace_refs unexpected_config
    local hooks_path is_bare top_level
    git_dir="$(git -C "${repo_dir}" rev-parse --absolute-git-dir 2>/dev/null)" || die "${label} 不是 Git 仓库"
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
orbctl_run() { local cmd=(orbctl run); [ -z "${ORB_MACHINE:-}" ] || cmd+=(-m "${ORB_MACHINE}"); "${cmd[@]}" "$@"; }
orbctl_run_host_path() { local cmd=(orbctl run -p); [ -z "${ORB_MACHINE:-}" ] || cmd+=(-m "${ORB_MACHINE}"); "${cmd[@]}" "$@"; }

sync_control_files_to_orb() {
    local items="init.sh patch.sh patch_external.sh build.sh"
    [ ! -f "${HOST_WORKSPACE_DIR}/.env" ] || items="${items} .env"
    [ ! -d "${HOST_WORKSPACE_DIR}/patches" ] || items="${items} patches"
    [ ! -d "${HOST_WORKSPACE_DIR}/tools" ] || items="${items} tools"
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
    reject_git_object_overrides "${label}" "${repo_dir}"
    verify_no_hidden_index_flags "${label}" "${repo_dir}"
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

verify_project_patch() {
    local label="$1" patch_file="$2" expected_sha256="$3" expected_patch_id="$4"
    local actual_sha256 actual_patch_id
    [ -s "${patch_file}" ] || die "${label}缺失"
    actual_sha256="$(sha256sum "${patch_file}" | awk '{ print $1 }')"
    [ "${actual_sha256}" = "${expected_sha256}" ] || die "${label} SHA-256 不匹配"
    actual_patch_id="$(git patch-id --stable < "${patch_file}" | awk '{ print $1 }')"
    [ "${actual_patch_id}" = "${expected_patch_id}" ] || die "${label} patch-id 不匹配"
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

patch_paths_excluding() {
    local patch_file="$1" excluded path skip
    shift
    while IFS= read -r path; do
        skip=0
        for excluded in "$@"; do
            if [ "${path}" = "${excluded}" ]; then
                skip=1
                break
            fi
        done
        [ "${skip}" = "1" ] || printf '%s\n' "${path}"
    done < <(awk '$1 == "diff" && $2 == "--git" { sub(/^a\//, "", $3); print $3 }' "${patch_file}")
}

verify_rejected_susfs_fdinfo_hunk() {
    local official_patch="$1" repo_dir="$2" patch_file status
    local patch_header='diff --git a/fs/notify/fdinfo.c b/fs/notify/fdinfo.c'
    shift 2

    # The official hunk receives the inotify anon_inode file, not the watched
    # path.  Its d_path() lookup cannot identify the watched mount and its
    # three-argument callback also breaks a FANOTIFY-enabled configuration.
    [ "$(grep -Fxc "${patch_header}" "${official_patch}")" = "1" ] || \
        die "SUSFS 官方 fdinfo hunk 结构已变化，必须重新审计"
    for patch_file in "$@"; do
        ! grep -Fqx "${patch_header}" "${patch_file}" || \
            die "经审计拒绝的 SUSFS fdinfo hunk 被项目补丁重新引入"
    done
    status="$(git -C "${repo_dir}" status --porcelain --untracked-files=all -- fs/notify/fdinfo.c)"
    [ -z "${status}" ] || die "fs/notify/fdinfo.c 必须保持 AOSP 基线实现"
}

verify_no_trailing_whitespace() {
    local label="$1" source_file="$2" bad_lines
    bad_lines="$(LC_ALL=C grep -nE '[[:blank:]]+$' "${source_file}" || true)"
    [ -z "${bad_lines}" ] || die "${label} 存在行尾空白:\n${bad_lines}"
}

verify_no_hidden_index_flags() {
    local label="$1" repo_dir="$2" hidden
    hidden="$(git -C "${repo_dir}" ls-files -v | LC_ALL=C awk '
        substr($0, 1, 1) == "S" || substr($0, 1, 1) ~ /[a-z]/ { print }
    ')"
    [ -z "${hidden}" ] || \
        die "${label} 存在 skip-worktree/assume-unchanged 标记，无法证明源码差异:\n${hidden}"
}

tracked_diff_sha256() {
    local repo_dir="$1"
    env GIT_NO_LAZY_FETCH=1 LC_ALL=C git -c color.ui=false -C "${repo_dir}" diff \
        --binary --full-index --no-ext-diff --no-textconv --no-renames --no-color \
        --diff-algorithm=myers --src-prefix=a/ --dst-prefix=b/ \
        HEAD -- . | sha256sum | awk '{ print $1 }'
}

verify_final_source_deltas() {
    local ksu_sha256
    verify_no_hidden_index_flags "GKI common" "${COMMON_DIR}"
    verify_no_hidden_index_flags "KernelSU" "${KSU_DIR}"
    ksu_sha256="$(tracked_diff_sha256 "${KSU_DIR}")"
    [[ "${COMMON_BASE_TRACKED_DIFF_SHA256}" =~ ^[0-9a-f]{64}$ ]] || \
        die "GKI common 基础差异快照尚未固定"
    [[ "${KSU_TRACKED_DIFF_SHA256}" =~ ^[0-9a-f]{64}$ ]] || \
        die "KernelSU 精确差异快照尚未固定: ${ksu_sha256}"
    bash "${HOST_WORKSPACE_DIR}/tools/independent_backports.sh" \
        verify-base-diff "${COMMON_DIR}" "${COMMON_BASE_TRACKED_DIFF_SHA256}"
    [ "${ksu_sha256}" = "${KSU_TRACKED_DIFF_SHA256}" ] || \
        die "KernelSU 出现非预期补丁差异: ${ksu_sha256}"
    log_success "GKI common 基础差异、独立回移层与 KernelSU 精确差异指纹匹配"
}

verify_kernelsu_overlay() {
    local kconfig_line='source "drivers/kernelsu/Kconfig"'
    local makefile_line='obj-$(CONFIG_KSU) += kernelsu/'

    [ "$(grep -Fxc "${kconfig_line}" "${COMMON_DIR}/drivers/Kconfig")" = "1" ] || \
        die "KernelSU Kconfig 接入不是精确一处"
    [ "$(tail -n 2 "${COMMON_DIR}/drivers/Kconfig")" = "${kconfig_line}"$'\nendmenu' ] || \
        die "KernelSU Kconfig 接入位置异常"
    [ "$(grep -Fxc "${makefile_line}" "${COMMON_DIR}/drivers/Makefile")" = "1" ] || \
        die "KernelSU Kbuild 接入不是精确一处"
    [ -L "${COMMON_DIR}/drivers/kernelsu" ] || die "KernelSU drivers 链接缺失"
    [ "$(readlink -f "${COMMON_DIR}/drivers/kernelsu")" = "${KSU_DIR}/kernel" ] || \
        die "KernelSU drivers 链接目标错误"
}

verify_susfs_integration() {
    local allowed_common allowed_ksu
    local actual_sha256 source_file target_file
    grep -Fxq "static const __u32 KERNEL_SU_UAPI_VERSION = ${KSU_UAPI_VERSION};" \
        "${KSU_DIR}/uapi/supercall.h" || die "KernelSU 与固定 Manager 的 UAPI 版本不匹配"
    verify_rejected_susfs_fdinfo_hunk \
        "${COMMON_SUSFS_PATCH_FILE}" "${COMMON_DIR}" \
        "${SUSFS_CONTEXT_ADAPTATION}" "${SUSFS_COMMON_FIX_PATCH_FILE}"
    [ "$(env GIT_NO_LAZY_FETCH=1 git -C "${SUSFS_DIR}" rev-parse \
        refs/backport-audit/susfs-kernelsu-patch 2>/dev/null || true)" = \
        "${SUSFS_KSU_PATCH_COMMIT}" ] || \
        die "SUSFS KernelSU 兼容补丁固定引用缺失，请先运行 ./init.sh"
    git -C "${KSU_DIR}" apply --reverse --check \
        --exclude=kernel/Kconfig \
        --exclude=kernel/policy/app_profile.c \
        --exclude=kernel/runtime/boot_event.c \
        --exclude=kernel/runtime/ksud_integration.c \
        --exclude=kernel/selinux/selinux.c \
        --exclude=kernel/sulog/event.c \
        --exclude=kernel/supercall/dispatch.c \
        "${KSU_SUSFS_PATCH_FILE}" || die "KernelSU SUSFS 官方补丁状态异常"
    git -C "${COMMON_DIR}" apply --reverse --check \
        --exclude=fs/exec.c \
        --exclude=fs/namespace.c \
        --exclude=fs/proc/base.c \
        --exclude=fs/proc/task_mmu.c \
        --exclude=security/selinux/hooks.c \
        --exclude=fs/namei.c \
        --exclude=fs/notify/fdinfo.c \
        --exclude=fs/proc/fd.c \
        --exclude=fs/stat.c \
        --exclude=mm/memory.c \
        "${COMMON_SUSFS_PATCH_FILE}" || \
        die "SUSFS 官方 Android 16/6.12 common 主补丁剩余部分状态异常"
    git -C "${COMMON_DIR}" apply --reverse --check "${SUSFS_CONTEXT_ADAPTATION}" || \
        die "基于 SUSFS 官方实现的 AOSP 6.12.92 上下文补丁状态异常"
    git -C "${COMMON_DIR}" apply --reverse --check "${SUSFS_COMMON_FIX_PATCH_FILE}" || \
        die "基于 SUSFS 官方补丁的 common Luna 修正版状态异常"
    git -C "${KSU_DIR}" apply --reverse --check "${SUSFS_KSU_FIX_PATCH_FILE}" || \
        die "基于 SUSFS 官方补丁的 KernelSU Luna 修正版状态异常"

    for source_file in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
        target_file="${COMMON_DIR}/${source_file}"
        if [ "${source_file}" = "fs/susfs.c" ]; then
            actual_sha256="$(sha256sum "${target_file}" | awk '{ print $1 }')"
            [ "${actual_sha256}" = "${SUSFS_CORRECTED_SOURCE_SHA256}" ] || \
                die "SUSFS Luna 修正源码摘要不匹配: ${source_file}"
            verify_no_trailing_whitespace "SUSFS Luna 修正源码" "${target_file}"
            grep -Fqx 'DEFINE_STATIC_KEY_FALSE(susfs_is_log_enabled);' "${target_file}" || \
                die "SUSFS 日志必须默认关闭"
            [ "$(grep -Fc 'static_branch_unlikely(&susfs_is_log_enabled)' "${target_file}")" = "2" ] || \
                die "SUSFS 日志静态分支提示异常"
            continue
        fi
        cmp -s "${SUSFS_DIR}/kernel_patches/${source_file}" "${target_file}" || \
            die "SUSFS 源文件不是固定上游内容: ${source_file}"
    done

    allowed_ksu="$(mktemp)"
    allowed_common="$(mktemp)"
    {
        patch_paths_excluding "${KSU_SUSFS_PATCH_FILE}" \
            kernel/Kconfig \
            kernel/policy/app_profile.c \
            kernel/runtime/boot_event.c \
            kernel/selinux/selinux.c \
            kernel/sulog/event.c \
            kernel/supercall/dispatch.c
        patch_paths_excluding "${SUSFS_KSU_FIX_PATCH_FILE}"
        if [ "${ENABLE_BBG}" = "1" ]; then
            patch_paths_excluding "${BBG_KSU_CREDENTIAL_PATCH}"
        fi
    } | sort -u > "${allowed_ksu}"
    {
        printf '%s\n' drivers/Kconfig drivers/Makefile drivers/kernelsu
        patch_paths_excluding "${TEGRA_MC_KMI_PATCH_FILE}"
        patch_paths_excluding "${COMMON_SUSFS_PATCH_FILE}" \
            fs/exec.c \
            fs/namei.c \
            fs/notify/fdinfo.c \
            fs/proc/base.c \
            fs/proc/task_mmu.c \
            security/selinux/hooks.c
        patch_paths_excluding "${SUSFS_CONTEXT_ADAPTATION}"
        patch_paths_excluding "${SUSFS_COMMON_FIX_PATCH_FILE}"
        printf '%s\n' fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h
        if [ "${ENABLE_BBG}" = "1" ]; then
            printf '%s\n' security/Kconfig security/Makefile security/baseband-guard include/linux/lsm_count.h
            patch_paths_excluding "${BBG_COMMON_CREDENTIAL_PATCH}"
        fi
        if [ "${ENABLE_MEMCG_RSTAT_FAST_PATH:-0}" = "1" ]; then
            printf '%s\n' mm/memcontrol.c
        fi
        if [ "${ENABLE_TCP_RECV_MSTAMP_FAST_PATH:-0}" = "1" ]; then
            printf '%s\n' net/ipv4/tcp.c net/ipv4/tcp_input.c
        fi
        if [ "${ENABLE_F2FS_ACL_ENTRY_BOUNDS_FIX:-0}" = "1" ]; then
            printf '%s\n' fs/f2fs/acl.c
        fi
        if [ "${ENABLE_F2FS_LISTXATTR_BOUNDS_FIX:-0}" = "1" ]; then
            printf '%s\n' fs/f2fs/xattr.c
        fi
        if [ "${ENABLE_BLKCG_RSTAT_RELEASE_FIX:-0}" = "1" ]; then
            printf '%s\n' block/blk-cgroup.c
        fi
        if [ "${ENABLE_F2FS_FOREGROUND_GC_DEADLOCK_FIX:-0}" = "1" ]; then
            printf '%s\n' fs/f2fs/data.c fs/f2fs/f2fs.h fs/f2fs/segment.c
        fi
        if [ "${ENABLE_TIMER_BASE_FAST_PATH:-0}" = "1" ]; then
            printf '%s\n' kernel/time/timer.c
        fi
        if [ "${ENABLE_F2FS_DIO_OVERWRITE_FAST_PATH:-0}" = "1" ]; then
            printf '%s\n' fs/f2fs/data.c
        fi
        if [ "${ENABLE_EAS_CPUMASK_FAST_PATH:-0}" = "1" ]; then
            printf '%s\n' kernel/sched/fair.c
        fi
        if [ "${ENABLE_BLK_WBT_DONE_FAST_PATH:-0}" = "1" ]; then
            printf '%s\n' block/blk-wbt.c
        fi
        if [ "${ENABLE_IPV6_MLD_UAF_FIX:-0}" = "1" ]; then
            printf '%s\n' net/ipv6/mcast.c
        fi
        if [ "${ENABLE_IPV6_MLD_DELAYED_WORK_UAF_FIX:-0}" = "1" ]; then
            printf '%s\n' include/net/addrconf.h net/ipv6/mcast.c
        fi
        if [ "${ENABLE_SELECTED_BACKPORTS:-0}" = "1" ]; then
            bash "${HOST_WORKSPACE_DIR}/tools/backport_manifest.sh" list-paths
        fi
        bash "${HOST_WORKSPACE_DIR}/tools/independent_backports.sh" list-paths
    } | sort -u > "${allowed_common}"
    verify_allowed_paths "KernelSU" "${KSU_DIR}" "${allowed_ksu}"
    verify_allowed_paths "GKI common" "${COMMON_DIR}" "${allowed_common}"
    rm -f "${allowed_ksu}" "${allowed_common}"
    git -C "${COMMON_DIR}" diff --check
    git -C "${KSU_DIR}" diff --check
    verify_kernelsu_overlay
    log_success "SUSFS v2.3.0 官方补丁、经审计拒绝项与 Luna 修正版状态校验通过"
}

verify_bbg_integration() {
    local kconfig_line='source "security/baseband-guard/Kconfig"'
    local makefile_line='obj-$(CONFIG_BBG) += baseband-guard/'
    [ "$(grep -Fxc "${kconfig_line}" "${COMMON_DIR}/security/Kconfig")" = "1" ] || die "Baseband Guard Kconfig 接入不是精确一处"
    [ "$(grep -Fxc "${makefile_line}" "${COMMON_DIR}/security/Makefile")" = "1" ] || die "Baseband Guard Kbuild 接入不是精确一处"
    [ -L "${COMMON_DIR}/security/baseband-guard" ] || die "Baseband Guard security 链接缺失"
    [ "$(readlink -f "${COMMON_DIR}/security/baseband-guard")" = "${BBG_DIR}" ] || die "Baseband Guard security 链接目标错误"
    git -C "${COMMON_DIR}" apply --reverse --check "${BBG_LSM_COUNT_PATCH}" || die "Baseband Guard LSM 计数适配状态异常"
    git -C "${COMMON_DIR}" apply --reverse --check "${BBG_COMMON_CREDENTIAL_PATCH}" || \
        die "Baseband Guard 内部凭据接口状态异常"
    git -C "${KSU_DIR}" apply --reverse --check "${BBG_KSU_CREDENTIAL_PATCH}" || \
        die "KernelSU Baseband Guard 凭据标记状态异常"
    [ "$(grep -Ec '^#define BASEBAND_GUARD_ENABLED( |$)' "${COMMON_DIR}/include/linux/lsm_count.h")" = "2" ] || die "Baseband Guard LSM 计数宏异常"
    [ "$(grep -Ec '^[[:space:]]*BASEBAND_GUARD_ENABLED\)?[[:space:]]*\\?$' "${COMMON_DIR}/include/linux/lsm_count.h")" = "1" ] || die "Baseband Guard LSM 计数入口异常"
    verify_bbg_source_fix
    log_success "Baseband Guard overlay 与 AOSP 6.12.69 LSM 计数适配检查通过"
}

verify_bbg_source_fix() {
    local allowed actual_sha256 marker_count token

    verify_project_patch "Baseband Guard 保护边界修复" \
        "${BBG_LUNA_FIX_PATCH}" "${BBG_LUNA_FIX_PATCH_SHA256}" \
        "${BBG_LUNA_FIX_PATCH_ID}"
    git -C "${BBG_DIR}" apply --reverse --check "${BBG_LUNA_FIX_PATCH}" || \
        die "Baseband Guard 保护边界修复状态异常"
    allowed="$(mktemp)"
    printf '%s\n' \
        baseband_guard.c \
        blkdev_helper.c \
        blkdev_helper.h \
        tracing/tracing.c > "${allowed}"
    verify_allowed_paths "Baseband Guard" "${BBG_DIR}" "${allowed}"
    rm -f "${allowed}"
    actual_sha256="$(tracked_diff_sha256 "${BBG_DIR}")"
    [ "${actual_sha256}" = "${BBG_TRACKED_DIFF_SHA256}" ] || \
        die "Baseband Guard 出现非预期源码差异: ${actual_sha256}"
    ! grep -Eq 'allowed_devs|allow_add|allow_has|security_secctx_to_secid|get_cmdline|argv=|path=%s' \
        "${BBG_DIR}/baseband_guard.c" \
        "${BBG_DIR}/blkdev_helper.c" \
        "${BBG_DIR}/tracing/tracing.c" || \
        die "Baseband Guard 仍含失效缓存、SID 推断或敏感拒绝日志"
    grep -Fq 'IS_ERR_OR_NULL(bdev)' "${BBG_DIR}/blkdev_helper.c" || \
        die "Baseband Guard block_device 获取未同时处理 NULL 与 ERR_PTR"
    ! grep -Fq 'slot_suffix_from_cmdline' "${BBG_DIR}/blkdev_helper.c" || \
        die "Baseband Guard 仍依赖不必要的活动槽解析"
    grep -Fq 'partition_name_matches(name, name_len,' "${BBG_DIR}/blkdev_helper.c" || \
        die "Baseband Guard A/B 分区名匹配缺失"
    for hook in file_ioctl_compat uring_cmd mmap_file file_mprotect; do
        grep -Fq "LSM_HOOK_INIT(${hook}," "${BBG_DIR}/baseband_guard.c" || \
            die "Baseband Guard 缺少 ${hook} 写入口保护"
    done
    grep -Fq 'static inline bool is_destructive_ioctl(unsigned int cmd)' \
        "${BBG_DIR}/baseband_guard.c" || die "Baseband Guard 缺少明确破坏性 ioctl 判定"
    grep -Fq 'if (!inode || !is_destructive_ioctl(cmd))' \
        "${BBG_DIR}/baseband_guard.c" || \
        die "Baseband Guard 未默认放行非破坏性 block ioctl"
    grep -Fq 'return deny("destructive ioctl on protected partition", inode, cmd);' \
        "${BBG_DIR}/baseband_guard.c" || \
        die "Baseband Guard 缺少受保护分区破坏性 ioctl 拒绝路径"
    grep -Fq 'return bb_file_ioctl(file, cmd, arg);' \
        "${BBG_DIR}/baseband_guard.c" || die "Baseband Guard compat ioctl 未复用同一策略"
    ! grep -Eq 'is_read_only_block_ioctl|is_partition_scoped_block_ioctl|normalize_compat_block_ioctl|case (LOOP_SET_FD|BLKFLSBUF|BLKROSET):' \
        "${BBG_DIR}/baseband_guard.c" || \
        die "Baseband Guard 仍含默认拒绝或非破坏性 ioctl 特判"
    for token in 'case BLKDISCARD:' 'case BLKSECDISCARD:' 'case BLKZEROOUT:' \
        'case BLKRRPART:' 'cmd == SG_IO' 'cmd == SCSI_IOCTL_SEND_COMMAND' \
        'S_ISCHR(inode->i_mode)'; do
        grep -Fq "${token}" "${BBG_DIR}/baseband_guard.c" || \
            die "Baseband Guard ioctl 或原始存储入口保护缺失: ${token}"
    done
    grep -Fq 'if (!inode || ioucmd->cmd_op != BLOCK_URING_CMD_DISCARD)' \
        "${BBG_DIR}/baseband_guard.c" || \
        die "Baseband Guard 未将 io_uring 拒绝边界收敛到 discard"
    marker_count="$(grep -RhcF 'bbg_mark_untrusted_cred(cred);' \
        "${KSU_DIR}/kernel/policy/app_profile.c" \
        "${KSU_DIR}/kernel/selinux/selinux.c" | awk '{ total += $1 } END { print total + 0 }')"
    [ "${marker_count}" = "3" ] || die "KernelSU root 凭据标记数量异常: ${marker_count}"
    grep -Fq 'void bbg_mark_untrusted_cred(struct cred *cred)' \
        "${COMMON_DIR}/include/linux/baseband_guard.h" || \
        die "Baseband Guard 内部凭据接口缺失"
    grep -Fq '#include <linux/baseband_guard.h>' \
        "${BBG_DIR}/tracing/tracing.c" || \
        die "Baseband Guard 未通过公共内部头文件声明凭据接口"
    [ "$(grep -Fxc 'void bbg_mark_untrusted_cred(struct cred *cred);' \
        "${BBG_DIR}/tracing/tracing.c")" = "0" ] || \
        die "Baseband Guard 仍含重复的本地凭据接口声明"
    ! grep -Eq 'EXPORT_SYMBOL.*bbg_mark_untrusted_cred' \
        "${COMMON_DIR}/include/linux/baseband_guard.h" \
        "${BBG_DIR}/tracing/tracing.c" || \
        die "Baseband Guard 内部凭据接口不得导出"
    log_success "Baseband Guard 无缓存设备判定、最小 ioctl 拒绝、写入口与 KernelSU 凭据标记状态正确"
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
    apply_patch_once "AOSP 6.12.69 Baseband Guard LSM 计数适配" \
        "${COMMON_DIR}" "${BBG_LSM_COUNT_PATCH}"
    apply_patch_once "AOSP 6.12.69 Baseband Guard 内部凭据接口" \
        "${COMMON_DIR}" "${BBG_COMMON_CREDENTIAL_PATCH}"
}

apply_susfs_integration() {
    local actual_sha256 source_file

    if git -C "${KSU_DIR}" apply --reverse --check \
        "${SUSFS_KSU_FIX_PATCH_FILE}" >/dev/null 2>&1; then
        log_info "SUSFS 对 KernelSU ${KSU_REF} 的官方兼容补丁与 Luna fixup 已存在"
    else
        apply_patch_once "SUSFS 对 KernelSU ${KSU_REF} 的官方兼容补丁" \
            "${KSU_DIR}" "${KSU_SUSFS_PATCH_FILE}"
        apply_patch_once "基于 SUSFS v2.3.0 官方补丁的 KernelSU Luna fixup" \
            "${KSU_DIR}" "${SUSFS_KSU_FIX_PATCH_FILE}"
    fi

    if git -C "${COMMON_DIR}" apply --reverse --check \
        "${SUSFS_CONTEXT_ADAPTATION}" >/dev/null 2>&1 && \
       git -C "${COMMON_DIR}" apply --reverse --check \
        "${SUSFS_COMMON_FIX_PATCH_FILE}" >/dev/null 2>&1; then
        log_info "SUSFS common 官方补丁与 Luna 最小修正已存在"
        return
    fi

    # fdinfo hunk is deliberately excluded; verify_susfs_integration() proves
    # both its official presence and the untouched AOSP target afterwards.
    apply_patch_once "SUSFS Android 16/6.12 官方主补丁（排除替代与拒绝项）" \
        "${COMMON_DIR}" "${COMMON_SUSFS_PATCH_FILE}" \
        --exclude=fs/exec.c \
        --exclude=fs/namei.c \
        --exclude=fs/notify/fdinfo.c \
        --exclude=fs/proc/base.c \
        --exclude=fs/proc/task_mmu.c \
        --exclude=security/selinux/hooks.c
    apply_patch_once "基于 SUSFS 官方实现的 AOSP 6.12.92 上下文补丁" \
        "${COMMON_DIR}" "${SUSFS_CONTEXT_ADAPTATION}"

    for source_file in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
        if [ ! -e "${COMMON_DIR}/${source_file}" ]; then
            cp "${SUSFS_DIR}/kernel_patches/${source_file}" "${COMMON_DIR}/${source_file}"
            continue
        fi
        if cmp -s "${SUSFS_DIR}/kernel_patches/${source_file}" "${COMMON_DIR}/${source_file}"; then
            continue
        fi
        [ "${source_file}" = "fs/susfs.c" ] || \
            die "目标已存在不同的 SUSFS 源文件: ${source_file}"
        actual_sha256="$(sha256sum "${COMMON_DIR}/${source_file}" | awk '{ print $1 }')"
        [ "${actual_sha256}" = "${SUSFS_CORRECTED_SOURCE_SHA256}" ] || \
            die "目标已存在未授权的 SUSFS 修正源码: ${source_file}"
    done

    apply_patch_once "基于 SUSFS v2.3.0 官方补丁的 common Luna 修正版" \
        "${COMMON_DIR}" "${SUSFS_COMMON_FIX_PATCH_FILE}"
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
[ -f "${HOST_WORKSPACE_DIR}/.env" ] || die "缺少受版本控制的 .env"
load_env_file "${HOST_WORKSPACE_DIR}/.env"
[ "${ENABLE_KERNELSU:-0}" = "1" ] || \
    die "Luna 固定构建只支持 ENABLE_KERNELSU=1；拒绝未审计的第二套产品矩阵"
[ "${ENABLE_SUSFS:-0}" = "1" ] || \
    die "Luna 固定构建只支持 ENABLE_SUSFS=1；拒绝未审计的第二套产品矩阵"
WORKSPACE_NAME="$(sanitize_path_component "$(basename "${HOST_WORKSPACE_DIR}")")"
ORB_LINUX_ROOT="${ORB_LINUX_ROOT:-.cache/xiaomi_kernel_build}"
ORB_LINUX_WORKSPACE="${ORB_LINUX_ROOT%/}/${WORKSPACE_NAME:-workspace}/workspace"
run_in_orb_if_needed "$@"

ENABLE_KERNELSU="${ENABLE_KERNELSU:-0}"

COMMON_REPO="${COMMON_REPO:-https://android.googlesource.com/kernel/common}"
COMMON_COMMIT="${COMMON_COMMIT:-0316e9866fdf55601aae97b14ee08d1b38a3916c}"
COMMON_DIR="$(resolve_workspace_path "${COMMON_SOURCE_DIR:-sources/aosp_common_6.12.92_kmi6_2026-09}")"
TEGRA_MC_KMI_PATCH_FILE="${HOST_WORKSPACE_DIR}/${TEGRA_MC_KMI_PATCH:-patches/kmi/tegra-mc-opaque-pointer-kmi-r21.patch}"
TEGRA_MC_KMI_PATCH_SHA256="${TEGRA_MC_KMI_PATCH_SHA256:-ed862fd9b766ba5ee47baef59b4f6485c9ee8545c5a3270f2f58258082a9a792}"
TEGRA_MC_KMI_PATCH_ID="${TEGRA_MC_KMI_PATCH_ID:-120d76a884b594c227377b034f0eecf1071b5b91}"
KSU_REPO="${KSU_REPO:-https://github.com/tiann/KernelSU.git}"
KSU_REF="${KSU_REF:-main}"
KSU_COMMIT="${KSU_COMMIT:-623eba3e092b911a3a7389b7d87622a5835d2f3a}"
KSU_DIR="$(resolve_workspace_path "${KSU_SOURCE_DIR:-sources/kernelsu}")"
KSU_INTEGRATION_MODE="${KSU_INTEGRATION_MODE:-builtin}"
[ "${KSU_INTEGRATION_MODE}" = "builtin" ] || die "本阶段只允许经批准的 KernelSU built-in 模式"
ENABLE_SUSFS="${ENABLE_SUSFS:-0}"
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_REF="${SUSFS_REF:-gki-android16-6.12}"
SUSFS_COMMIT="${SUSFS_COMMIT:-b213c54126fb243595ce7876e91d84d6e0861fec}"
SUSFS_DIR="$(resolve_workspace_path "${SUSFS_SOURCE_DIR:-sources/susfs4ksu}")"
SUSFS_KSU_PATCH_COMMIT="${SUSFS_KSU_PATCH_COMMIT:-b213c54126fb243595ce7876e91d84d6e0861fec}"
SUSFS_CONTEXT_ADAPTATION="${HOST_WORKSPACE_DIR}/${SUSFS_CONTEXT_PATCH}"
SUSFS_COMMON_FIX_PATCH_FILE="${HOST_WORKSPACE_DIR}/${SUSFS_COMMON_FIX_PATCH}"
SUSFS_KSU_FIX_PATCH_FILE="${HOST_WORKSPACE_DIR}/${SUSFS_KSU_FIX_PATCH}"
ENABLE_BBG="${ENABLE_BBG:-0}"
BBG_REPO="${BBG_REPO:-https://github.com/vc-teahouse/Baseband-guard.git}"
BBG_REF="${BBG_REF:-main}"
BBG_COMMIT="${BBG_COMMIT:-a54e0dc6cf0aff4dd87fec49644a02d2eb612905}"
BBG_DIR="$(resolve_workspace_path "${BBG_SOURCE_DIR:-sources/baseband_guard}")"
BBG_LSM_COUNT_PATCH="${HOST_WORKSPACE_DIR}/${BBG_LSM_COUNT_PATCH:-patches/bbg/aosp-6.12.69-lsm-count.patch}"
BBG_LSM_COUNT_PATCH_SHA256="${BBG_LSM_COUNT_PATCH_SHA256:-f3792ead7a5dfd1b813e3260a2840e16a2eba548ca6a7c7e72f9bf144c9b30a1}"
BBG_LSM_COUNT_PATCH_ID="${BBG_LSM_COUNT_PATCH_ID:-d52557f81ce48d80782f0419c437de33f16c07c1}"
BBG_LUNA_FIX_PATCH="${HOST_WORKSPACE_DIR}/${BBG_LUNA_FIX_PATCH:-patches/bbg/baseband-guard-a54e0dc-luna-fixes.patch}"
BBG_LUNA_FIX_PATCH_SHA256="${BBG_LUNA_FIX_PATCH_SHA256:-344ed44657982ea780b946b11165255dc52be18dc1de2ac15f86d520d79a6bc4}"
BBG_LUNA_FIX_PATCH_ID="${BBG_LUNA_FIX_PATCH_ID:-3b5c92af344640f6ea4d508709f3f491005acf90}"
BBG_COMMON_CREDENTIAL_PATCH="${HOST_WORKSPACE_DIR}/${BBG_COMMON_CREDENTIAL_PATCH:-patches/bbg/aosp-6.12.69-credential-api.patch}"
BBG_COMMON_CREDENTIAL_PATCH_SHA256="${BBG_COMMON_CREDENTIAL_PATCH_SHA256:-2898be21ea20f4b80cacb12459f0e3cab25faff25921a9b81bae0d9226ab42be}"
BBG_COMMON_CREDENTIAL_PATCH_ID="${BBG_COMMON_CREDENTIAL_PATCH_ID:-a770f38f4f9c7a1a14e7cf46b81bfa1f6a7db897}"
BBG_KSU_CREDENTIAL_PATCH="${HOST_WORKSPACE_DIR}/${BBG_KSU_CREDENTIAL_PATCH:-patches/bbg/kernelsu-623eba3e-credential-marking.patch}"
BBG_KSU_CREDENTIAL_PATCH_SHA256="${BBG_KSU_CREDENTIAL_PATCH_SHA256:-e1308a48dde630014aff4cc594705842f66539fb7fa97bf9c516dea9f9fe33bb}"
BBG_KSU_CREDENTIAL_PATCH_ID="${BBG_KSU_CREDENTIAL_PATCH_ID:-2eec8ddd3b3257dd38e7ed342eb83a17191f972b}"
BBG_TRACKED_DIFF_SHA256="${BBG_TRACKED_DIFF_SHA256:-}"
COMMON_BASE_TRACKED_DIFF_SHA256="${COMMON_BASE_TRACKED_DIFF_SHA256:-}"
KSU_TRACKED_DIFF_SHA256="${KSU_TRACKED_DIFF_SHA256:-}"

verify_repo_identity "Android 16 GKI common 九月 KMI6" "${COMMON_DIR}" "${COMMON_REPO}" "${COMMON_COMMIT}"
verify_project_patch "Tegra MC opaque-pointer KMI compatibility" \
    "${TEGRA_MC_KMI_PATCH_FILE}" "${TEGRA_MC_KMI_PATCH_SHA256}" \
    "${TEGRA_MC_KMI_PATCH_ID}"
git -C "${COMMON_DIR}" apply --reverse --check "${TEGRA_MC_KMI_PATCH_FILE}" || \
    die "Tegra MC opaque-pointer KMI compatibility patch status is invalid"
verify_repo_identity "KernelSU ${KSU_REF}" "${KSU_DIR}" "${KSU_REPO}" "${KSU_COMMIT}"
verify_repo_identity "SUSFS ${SUSFS_REF}" "${SUSFS_DIR}" "${SUSFS_REPO}" "${SUSFS_COMMIT}"
[ -z "$(git -C "${SUSFS_DIR}" status --porcelain)" ] || die "SUSFS 上游工作树不干净"
[ "$(env GIT_NO_LAZY_FETCH=1 git -C "${SUSFS_DIR}" rev-parse \
    refs/backport-audit/susfs-kernelsu-patch 2>/dev/null || true)" = \
    "${SUSFS_KSU_PATCH_COMMIT}" ] || \
    die "SUSFS KernelSU 兼容补丁固定引用缺失，请先运行 ./init.sh"
verify_project_patch "基于 SUSFS 官方实现的 AOSP 6.12.92 上下文补丁" \
    "${SUSFS_CONTEXT_ADAPTATION}" "${SUSFS_CONTEXT_PATCH_SHA256}" \
    "${SUSFS_CONTEXT_PATCH_ID}"
verify_project_patch "基于 SUSFS v2.3.0 官方补丁的 common Luna 修正版" \
    "${SUSFS_COMMON_FIX_PATCH_FILE}" "${SUSFS_COMMON_FIX_PATCH_SHA256}" \
    "${SUSFS_COMMON_FIX_PATCH_ID}"
verify_project_patch "基于 SUSFS v2.3.0 官方补丁的 KernelSU Luna 修正版" \
    "${SUSFS_KSU_FIX_PATCH_FILE}" "${SUSFS_KSU_FIX_PATCH_SHA256}" \
    "${SUSFS_KSU_FIX_PATCH_ID}"

log_step "应用 KernelSU ${KSU_REF} built-in 外部补丁"
apply_kernelsu_integration
KSU_SUSFS_PATCH_FILE="$(mktemp)"
COMMON_SUSFS_PATCH_FILE="$(mktemp)"
trap 'rm -f "${KSU_SUSFS_PATCH_FILE:-}" "${COMMON_SUSFS_PATCH_FILE:-}"' EXIT
git -C "${SUSFS_DIR}" show "${SUSFS_KSU_PATCH_COMMIT}:kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" > "${KSU_SUSFS_PATCH_FILE}"
cp "${SUSFS_DIR}/kernel_patches/50_add_susfs_in_gki-android16-6.12.patch" "${COMMON_SUSFS_PATCH_FILE}"
log_step "应用 SUSFS v2.3.0 官方 Android 16/6.12 补丁"
apply_susfs_integration
verify_susfs_integration
if [ "${ENABLE_BBG}" = "1" ]; then
    verify_repo_identity "Baseband Guard ${BBG_REF}" "${BBG_DIR}" "${BBG_REPO}" "${BBG_COMMIT}"
    verify_project_patch "Baseband Guard 保护边界修复" \
        "${BBG_LUNA_FIX_PATCH}" "${BBG_LUNA_FIX_PATCH_SHA256}" \
        "${BBG_LUNA_FIX_PATCH_ID}"
    apply_patch_once "Baseband Guard 保护边界修复" \
        "${BBG_DIR}" "${BBG_LUNA_FIX_PATCH}"
    verify_project_patch "KernelSU Baseband Guard 凭据标记补丁" \
        "${BBG_KSU_CREDENTIAL_PATCH}" "${BBG_KSU_CREDENTIAL_PATCH_SHA256}" \
        "${BBG_KSU_CREDENTIAL_PATCH_ID}"
    apply_patch_once "KernelSU Baseband Guard 凭据标记" \
        "${KSU_DIR}" "${BBG_KSU_CREDENTIAL_PATCH}"
    verify_project_patch "AOSP 6.12.69 Baseband Guard LSM 计数适配补丁" \
        "${BBG_LSM_COUNT_PATCH}" "${BBG_LSM_COUNT_PATCH_SHA256}" \
        "${BBG_LSM_COUNT_PATCH_ID}"
    verify_project_patch "AOSP 6.12.69 Baseband Guard 内部凭据接口补丁" \
        "${BBG_COMMON_CREDENTIAL_PATCH}" "${BBG_COMMON_CREDENTIAL_PATCH_SHA256}" \
        "${BBG_COMMON_CREDENTIAL_PATCH_ID}"
    log_step "应用 Baseband Guard ${BBG_COMMIT:0:12} overlay"
    apply_bbg_integration
    verify_bbg_integration
fi
verify_final_source_deltas
log_success "KernelSU ${KSU_REF} built-in 接入完成"
