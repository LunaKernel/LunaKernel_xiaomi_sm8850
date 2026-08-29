#!/usr/bin/env bash
#
# build.sh - Luna Kernel build, verification and release packaging
#
set -euo pipefail

die() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

log_info() { printf '[INFO] %s\n' "$1"; }
log_step() { printf '[STEP] %s\n' "$1"; }
log_success() { printf '[OK] %s\n' "$1"; }

clean_previous_release_artifacts() {
    local output_dir="$1"
    local manifest_name="$2"
    local manifest="${output_dir}/${manifest_name}"
    local name path

    [ -d "${output_dir}" ] || return
    if [ -f "${manifest}" ]; then
        while IFS= read -r name; do
            case "${name}" in
                ''|*/*|.|..) die "已有产物清单含非法条目: ${name}" ;;
            esac
            rm -f -- "${output_dir}/${name}"
        done < "${manifest}"
    fi

    while IFS= read -r -d '' path; do
        rm -f -- "${path}"
    done < <(
        find "${output_dir}" -maxdepth 1 -type f \
            \( -name 'Image-luna-xiaomi17-g????????-????????' \
            -o -name 'luna-xiaomi17-g????????-????????.zip' \) -print0
    )
    rm -f -- "${manifest}" "${output_dir}/Image"
}

append_orbenv_var() {
    local name="$1"
    case ":${ORBENV:-}:" in
        *:"${name}":*) ;;
        *) ORBENV="${ORBENV:+${ORBENV}:}${name}" ;;
    esac
}

prepare_orb_passthrough_env() {
    local var
    for var in NO_COLOR USE_CCACHE CCACHE_MAXSIZE CCACHE_COMPRESS CCACHE_COMPILERCHECK CCACHE_NOHASHDIR http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy; do
        if [ -n "${!var:-}" ]; then
            append_orbenv_var "${var}"
        fi
    done
    export ORBENV
}

load_env_file() {
    local env_file="$1"
    local had_allexport=0
    [ -f "${env_file}" ] || return

    case "$-" in
        *a*) had_allexport=1 ;;
    esac

    set -a
    . "${env_file}"
    if [ "${had_allexport}" = "0" ]; then
        set +a
    fi
}

sanitize_path_component() {
    printf '%s' "$1" | LC_ALL=C tr -cs 'A-Za-z0-9._-' '_'
}

resolve_workspace_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "${HOST_WORKSPACE_DIR}" "$1" ;;
    esac
}

normalize_git_url() {
    printf '%s' "$1" | sed -e 's#/$##' -e 's#\.git$##'
}

tree_sha256() {
    local root="$1" special path digest
    [ -d "${root}" ] || die "完整性校验目录不存在: ${root}"
    special="$(find "${root}" -mindepth 1 ! -type d ! -type f ! -type l -print -quit)"
    [ -z "${special}" ] || die "完整性校验目录含特殊文件: ${special}"
    (
        cd "${root}"
        find . -mindepth 1 \( -type f -o -type l \) -print0 | LC_ALL=C sort -z |
            while IFS= read -r -d '' path; do
                if [ -L "${path}" ]; then
                    printf 'l\0%s\0%s\0' "${path#./}" "$(readlink "${path}")"
                else
                    digest="$(sha256sum "${path}")"
                    digest="${digest%% *}"
                    printf 'f\0%s\0%s\0%s\0' \
                        "${path#./}" "$(stat -c %a "${path}")" "${digest}"
                fi
            done
    ) | sha256sum | awk '{ print $1 }'
}

resolve_project_identity() {
    local actual_commit

    if git -C "${HOST_WORKSPACE_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
        actual_commit="$(git -C "${HOST_WORKSPACE_DIR}" rev-parse HEAD)"
        [[ "${actual_commit}" =~ ^[0-9a-f]{40}$ ]] || die "项目提交格式异常: ${actual_commit}"
        [ -z "$(git -C "${HOST_WORKSPACE_DIR}" status --porcelain --untracked-files=no)" ] || \
            die "项目受跟踪文件存在未提交修改，拒绝生成发布产物"
        if [ -n "${LUNA_PROJECT_COMMIT:-}" ]; then
            [ "${LUNA_PROJECT_COMMIT}" = "${actual_commit}" ] || \
                die "宿主与构建环境的项目提交不一致"
        else
            LUNA_PROJECT_COMMIT="${actual_commit}"
        fi
    else
        [[ "${LUNA_PROJECT_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] || \
            die "构建环境缺少宿主项目提交，无法生成可追溯版本"
    fi
    export LUNA_PROJECT_COMMIT
    append_orbenv_var LUNA_PROJECT_COMMIT
}

orbctl_run() {
    local cmd=(orbctl run)
    if [ -n "${ORB_MACHINE:-}" ]; then
        cmd+=(-m "${ORB_MACHINE}")
    fi
    "${cmd[@]}" "$@"
}

orbctl_run_host_path() {
    local cmd=(orbctl run -p)
    if [ -n "${ORB_MACHINE:-}" ]; then
        cmd+=(-m "${ORB_MACHINE}")
    fi
    "${cmd[@]}" "$@"
}

sync_control_files_to_orb() {
    local items="init.sh patch.sh patch_external.sh build.sh"
    if [ -f "${HOST_WORKSPACE_DIR}/.env" ]; then items="${items} .env"; fi
    if [ -d "${HOST_WORKSPACE_DIR}/ak3_template" ]; then items="${items} ak3_template"; fi
    if [ -d "${HOST_WORKSPACE_DIR}/patches" ]; then items="${items} patches"; fi

    orbctl_run_host_path -w "${HOST_WORKSPACE_DIR}" sh -lc "set -e; target=\"\$HOME/${ORB_LINUX_WORKSPACE}\"; outbox=\"\$HOME/${ORB_LINUX_OUTBOX}\"; mkdir -p \"\$target\" \"\$outbox\"; rm -rf \"\$target/init.sh\" \"\$target/patch.sh\" \"\$target/patch_external.sh\" \"\$target/build.sh\" \"\$target/.env\" \"\$target/ak3_template\" \"\$target/patches\"; tar -cf - --exclude='.DS_Store' --exclude='.idea' --exclude='kernel_out' --exclude='toolchain' ${items} | tar --warning=no-unknown-keyword -xf - -C \"\$target\""
}

export_orb_results() {
    orbctl_run sh -lc "set -e; workspace=\"\$HOME/${ORB_LINUX_WORKSPACE}\"; output_dir='${BUILD_OUTPUT_DIR}'; case \"\$output_dir\" in /*) ;; *) output_dir=\"\$workspace/\$output_dir\" ;; esac; manifest=\"\$output_dir/${ARTIFACT_MANIFEST_NAME}\"; [ -s \"\$manifest\" ] || { printf '[FAIL] 当前构建产物清单缺失: %s\n' \"\$manifest\" >&2; exit 1; }; rm -rf \"\$workspace/../artifact_out\"; mkdir -p \"\$workspace/../artifact_out/kernel_out\" \"\$workspace/../outbox\"; count=0; while IFS= read -r name; do case \"\$name\" in ''|*/*|.|..) printf '[FAIL] 非法产物清单项: %s\n' \"\$name\" >&2; exit 1 ;; esac; path=\"\$output_dir/\$name\"; [ -f \"\$path\" ] || { printf '[FAIL] 当前构建产物缺失: %s\n' \"\$path\" >&2; exit 1; }; cp -f \"\$path\" \"\$workspace/../artifact_out/kernel_out/\$name\"; count=\$((count + 1)); done < \"\$manifest\"; [ \"\$count\" -gt 0 ] || { printf '[FAIL] 当前构建产物清单为空\n' >&2; exit 1; }; cp -f \"\$manifest\" \"\$workspace/../artifact_out/kernel_out/${ARTIFACT_MANIFEST_NAME}\"; tar -cf \"\$workspace/../outbox/${ORB_RESULT_ARCHIVE}\" -C \"\$workspace/../artifact_out\" kernel_out"
}

pull_orb_results() {
    local temp_dir manifest name count=0
    temp_dir="$(mktemp -d "${HOST_WORKSPACE_DIR}/.${SCRIPT_NAME%.sh}.pull.XXXXXX")"
    orbctl_run_host_path -w "${HOST_WORKSPACE_DIR}" sh -lc "set -e; src=\"\$HOME/${ORB_LINUX_OUTBOX}/${ORB_RESULT_ARCHIVE}\"; dst='${temp_dir}/${ORB_RESULT_ARCHIVE}'; [ -f \"\$src\" ] || { printf '[FAIL] Orb 结果归档不存在: %s\n' \"\$src\" >&2; exit 1; }; cp -f \"\$src\" \"\$dst\""
    mkdir -p "${temp_dir}/extracted"
    tar -xf "${temp_dir}/${ORB_RESULT_ARCHIVE}" -C "${temp_dir}/extracted"
    [ -d "${temp_dir}/extracted/kernel_out" ] || die "Orb 结果缺少 kernel_out"
    manifest="${temp_dir}/extracted/kernel_out/${ARTIFACT_MANIFEST_NAME}"
    [ -s "${manifest}" ] || die "Orb 结果缺少当前构建产物清单"
    mkdir -p "${PRODUCT_DIR}"
    clean_previous_release_artifacts "${PRODUCT_DIR}" "${ARTIFACT_MANIFEST_NAME}"
    while IFS= read -r name; do
        case "${name}" in
            ''|*/*|.|..) die "Orb 结果含非法产物清单项: ${name}" ;;
        esac
        [ -f "${temp_dir}/extracted/kernel_out/${name}" ] || die "Orb 结果缺少清单产物: ${name}"
        cp -f "${temp_dir}/extracted/kernel_out/${name}" "${PRODUCT_DIR}/${name}"
        count=$((count + 1))
    done < "${manifest}"
    [ "${count}" -gt 0 ] || die "Orb 结果产物清单为空"
    cp -f "${manifest}" "${PRODUCT_DIR}/${ARTIFACT_MANIFEST_NAME}"
    rm -rf "${temp_dir}"
    log_success "macOS 当前构建的 ${count} 个产物已同步到: ${PRODUCT_DIR}"
}

run_in_orb_if_needed() {
    local host_os
    host_os="$(uname -s)"
    case "${host_os}" in
        Linux) return ;;
        Darwin)
            command -v orbctl >/dev/null 2>&1 || die "当前是 macOS，请启动 OrbStack。"
            prepare_orb_passthrough_env
            sync_control_files_to_orb
            printf '[INFO] macOS 环境，进入 Orb Linux 工作区 %s 执行 %s\n' "${ORB_LINUX_WORKSPACE}" "${SCRIPT_NAME}" >&2
            if orbctl_run sh -lc "cd \"\$HOME/${ORB_LINUX_WORKSPACE}\" && exec bash \"./${SCRIPT_NAME}\" \"\$@\"" sh "$@"; then
                export_orb_results
                pull_orb_results
                exit 0
            else
                exit $?
            fi
            ;;
        *) die "不支持的系统: ${host_os}" ;;
    esac
}

detect_cpu_count() {
    local cpu_count=""
    if command -v nproc >/dev/null 2>&1; then cpu_count="$(nproc 2>/dev/null || true)"; fi
    if [ -z "${cpu_count}" ] && command -v sysctl >/dev/null 2>&1; then cpu_count="$(sysctl -n hw.logicalcpu 2>/dev/null || true)"; fi
    if [[ "${cpu_count}" =~ ^[0-9]+$ ]] && [ "${cpu_count}" -gt 0 ]; then
        printf '%s\n' "${cpu_count}"
    else
        printf '8\n'
    fi
}

verify_repo_identity() {
    local label="$1"
    local repo_dir="$2"
    local expected_url="$3"
    local expected_commit="$4"
    local require_clean="${5:-1}"
    local actual_url
    local actual_commit

    git -C "${repo_dir}" rev-parse --git-dir >/dev/null 2>&1 || die "${label} 不是 Git 仓库: ${repo_dir}"
    actual_url="$(git -C "${repo_dir}" remote get-url origin 2>/dev/null || true)"
    actual_commit="$(git -C "${repo_dir}" rev-parse HEAD)"
    [ "$(normalize_git_url "${actual_url}")" = "$(normalize_git_url "${expected_url}")" ] || die "${label} remote 不匹配: ${actual_url}"
    [ "${actual_commit}" = "${expected_commit}" ] || die "${label} commit 不匹配: ${actual_commit}"
    if [ "${require_clean}" = "1" ]; then
        [ -z "$(git -C "${repo_dir}" status --porcelain)" ] || die "${label} 工作树不干净"
    fi
}

verify_kernelsu_source_state() {
    local kconfig_line='source "drivers/kernelsu/Kconfig"'
    local makefile_line='obj-$(CONFIG_KSU) += kernelsu/'
    local official_selinux_hide unexpected
    [ "${KSU_INTEGRATION_MODE}" = "builtin" ] || die "KernelSU 集成模式不是 builtin"
    if [ "${ENABLE_SUSFS}" = "1" ]; then
        verify_repo_identity "KernelSU ${KSU_REF}" "${KSU_DIR}" "${KSU_REPO}" "${KSU_COMMIT}" "0"
    else
        verify_repo_identity "KernelSU ${KSU_REF}" "${KSU_DIR}" "${KSU_REPO}" "${KSU_COMMIT}"
    fi
    [ "$(git -C "${KSU_DIR}" rev-list --count HEAD)" = "${KSU_GIT_VERSION_COUNT}" ] || die "KernelSU Git 历史计数不匹配"
    [ "$(grep -Fxc "${kconfig_line}" "${COMMON_DIR}/drivers/Kconfig")" = "1" ] || die "KernelSU Kconfig 接入状态异常"
    [ "$(tail -n 2 "${COMMON_DIR}/drivers/Kconfig" | head -n 1)" = "${kconfig_line}" ] || die "KernelSU Kconfig 接入位置异常"
    [ "$(grep -Fxc "${makefile_line}" "${COMMON_DIR}/drivers/Makefile")" = "1" ] || die "KernelSU Kbuild 接入状态异常"
    [ -L "${COMMON_DIR}/drivers/kernelsu" ] || die "KernelSU drivers 链接缺失"
    [ "$(readlink -f "${COMMON_DIR}/drivers/kernelsu")" = "${KSU_DIR}/kernel" ] || die "KernelSU drivers 链接目标错误"
    git -C "${KSU_DIR}" merge-base --is-ancestor "${KSU_SELINUX_HIDE_FIX_COMMIT}" "${KSU_COMMIT}" || \
        die "固定 KernelSU 版本不包含官方 DirtySepolicy attr/current 修复"
    git -C "${KSU_DIR}" merge-base --is-ancestor "${KSU_ENHANCED_SECURITY_REMOVAL_COMMIT}" "${KSU_COMMIT}" || \
        die "固定 KernelSU 版本未包含官方不可靠增强安全功能移除提交"
    ! git -C "${KSU_DIR}" grep -q 'KSU_FEATURE_ENHANCED_SECURITY' "${KSU_COMMIT}" -- kernel manager userspace || \
        die "固定 KernelSU 版本意外恢复了不可靠的增强安全开关"
    official_selinux_hide="$(git -C "${KSU_DIR}" show "${KSU_COMMIT}:kernel/feature/selinux_hide.c")"
    for token in my_write_context my_write_access my_setprocattr; do
        grep -Fq -- "${token}" <<<"${official_selinux_hide}" || \
            die "KernelSU 固定提交的官方 SELinux 隐藏实现缺少 ${token}"
    done
    grep -Fq 'static ssize_t my_write_context' "${COMMON_DIR}/security/selinux/selinuxfs.c" || \
        die "SUSFS 接入后缺少 SELinux context 查询代理"
    grep -Fq 'static ssize_t my_write_access' "${COMMON_DIR}/security/selinux/selinuxfs.c" || \
        die "SUSFS 接入后缺少 SELinux access 查询代理"
    grep -Fq 'static int my_setprocattr' "${COMMON_DIR}/security/selinux/hooks.c" || \
        die "SUSFS 接入后缺少 SELinux attr/current 代理"
    ! grep -Rqs --exclude='lsm_hook.h' 'security_add_hooks[[:space:]]*(' "${KSU_DIR}/kernel" || \
        die "KernelSU 意外注册了额外 LSM，必须重新审计 MAX_LSM_COUNT"
    if [ "${ENABLE_SUSFS}" != "1" ]; then
        unexpected="$(git -C "${COMMON_DIR}" status --porcelain --untracked-files=all | grep -Ev '^( M drivers/(Kconfig|Makefile)|\?\? drivers/kernelsu)$' || true)"
        [ -z "${unexpected}" ] || die "GKI common 存在未授权差异:\n${unexpected}"
        git -C "${COMMON_DIR}" diff --check
    fi
    log_success "KernelSU ${KSU_REF} 源码、官方 DirtySepolicy 修复与接入状态检查通过"
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

verify_susfs_source_state() {
    local ksu_patch common_patch allowed_ksu allowed_common source_file
    verify_repo_identity "SUSFS ${SUSFS_REF}" "${SUSFS_DIR}" "${SUSFS_REPO}" "${SUSFS_COMMIT}"
    [ -s "${SUSFS_HOOKS_ADAPTATION}" ] || die "缺少 AOSP r57 SUSFS SELinux 适配补丁"
    ksu_patch="$(mktemp)"
    common_patch="$(mktemp)"
    allowed_ksu="$(mktemp)"
    allowed_common="$(mktemp)"
    git -C "${SUSFS_DIR}" show "${SUSFS_KSU_PATCH_COMMIT}:kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" > "${ksu_patch}"
    cp "${SUSFS_DIR}/kernel_patches/50_add_susfs_in_gki-android16-6.12.patch" "${common_patch}"
    git -C "${KSU_DIR}" apply --reverse --check "${ksu_patch}" || die "KernelSU SUSFS 补丁状态异常"
    git -C "${COMMON_DIR}" apply --reverse --check --exclude=security/selinux/hooks.c "${common_patch}" || die "AOSP SUSFS 主补丁状态异常"
    git -C "${COMMON_DIR}" apply --reverse --check "${SUSFS_HOOKS_ADAPTATION}" || die "AOSP r57 SELinux 适配状态异常"
    for source_file in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
        cmp -s "${SUSFS_DIR}/kernel_patches/${source_file}" "${COMMON_DIR}/${source_file}" || \
            die "SUSFS 源文件不是固定上游内容: ${source_file}"
    done
    awk '$1 == "diff" && $2 == "--git" { sub(/^a\//, "", $3); print $3 }' "${ksu_patch}" | sort -u > "${allowed_ksu}"
    {
        printf '%s\n' drivers/Kconfig drivers/Makefile drivers/kernelsu
        awk '$1 == "diff" && $2 == "--git" { sub(/^a\//, "", $3); print $3 }' "${common_patch}"
        printf '%s\n' fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h
        if [ "${ENABLE_BBG}" = "1" ]; then
            printf '%s\n' security/Kconfig security/Makefile security/baseband-guard include/linux/lsm_count.h
        fi
        if [ "${ENABLE_STAGE5_RTMUTEX_FIX}" = "1" ]; then
            printf '%s\n' kernel/locking/rtmutex.c
        fi
        if [ "${ENABLE_F2FS_MERGE_PAGE_BIO_UAF_FIX}" = "1" ]; then
            printf '%s\n' fs/f2fs/data.c
        fi
        if [ "${ENABLE_F2FS_OPEN_FAST_PATH}" = "1" ]; then
            printf '%s\n' fs/f2fs/file.c
        fi
        if [ "${ENABLE_MEMCG_RSTAT_FAST_PATH}" = "1" ]; then
            printf '%s\n' mm/memcontrol.c
        fi
        if [ "${ENABLE_TCP_RECV_MSTAMP_FAST_PATH}" = "1" ]; then
            printf '%s\n' net/ipv4/tcp.c net/ipv4/tcp_input.c
        fi
        if [ "${ENABLE_GUNYAH_CLEAN_RESOURCES_UAF_FIX}" = "1" ]; then
            printf '%s\n' drivers/virt/gunyah/vm_mgr.c
        fi
        if [ "${ENABLE_IDLETIMER_DESTROY_UAF_FIX}" = "1" ]; then
            printf '%s\n' net/netfilter/xt_IDLETIMER.c
        fi
        if [ "${ENABLE_EVENTPOLL_RCU_UAF_FIX}" = "1" ]; then
            printf '%s\n' fs/eventpoll.c
        fi
        if [ "${ENABLE_CGROUP_KERNFS_UAF_FIX}" = "1" ]; then
            printf '%s\n' kernel/cgroup/cgroup.c
        fi
        if [ "${ENABLE_F2FS_SYNC_INODE_META_UAF_FIX}" = "1" ]; then
            printf '%s\n' fs/f2fs/inode.c
        fi
        if [ "${ENABLE_TIMER_SHUTDOWN_SYNC_RACE_FIX}" = "1" ]; then
            printf '%s\n' kernel/time/timer.c
        fi
        if [ "${ENABLE_FUTEX_REQUEUE_PI_UAF_FIX}" = "1" ]; then
            printf '%s\n' kernel/futex/requeue.c
        fi
        if [ "${ENABLE_PAGE_POOL_DESTROY_RACE_FIX}" = "1" ]; then
            printf '%s\n' net/core/page_pool.c
        fi
        if [ "${ENABLE_CONNTRACK_UNCONFIRMED_RACE_FIX}" = "1" ]; then
            printf '%s\n' include/net/netfilter/nf_conntrack.h net/netfilter/nf_conntrack_core.c
        fi
        if [ "${ENABLE_EROFS_DIR_TAIL_OOB_FIX}" = "1" ]; then
            printf '%s\n' fs/erofs/dir.c
        fi
        if [ "${ENABLE_EXT4_XATTR_OOB_FIX}" = "1" ]; then
            printf '%s\n' fs/ext4/xattr.c
        fi
        if [ "${ENABLE_IPV6_MLD_UAF_FIX}" = "1" ]; then
            printf '%s\n' net/ipv6/mcast.c
        fi
        if [ "${ENABLE_RTMUTEX_WAITER_ENQUEUE_FIX}" = "1" ]; then
            printf '%s\n' kernel/locking/rtmutex.c kernel/locking/rtmutex_api.c
        fi
        if [ "${ENABLE_FUTEX_EXITING_POINTER_FIX:-0}" = "1" ]; then
            printf '%s\n' kernel/futex/pi.c
        fi
        if [ "${ENABLE_FUTEX_REQUEUE_PI_LOCKUP_FIX:-0}" = "1" ]; then
            printf '%s\n' kernel/futex/requeue.c
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
        if [ "${ENABLE_BINDER_TRANSACTION_LIFETIME_FIX:-0}" = "1" ]; then
            printf '%s\n' drivers/android/binder.c
        fi
        if [ "${ENABLE_F2FS_FOREGROUND_GC_DEADLOCK_FIX:-0}" = "1" ]; then
            printf '%s\n' fs/f2fs/data.c fs/f2fs/f2fs.h fs/f2fs/segment.c
        fi
        if [ "${ENABLE_F2FS_ATOMIC_INODE_UAF_FIX:-0}" = "1" ]; then
            printf '%s\n' fs/f2fs/gc.c fs/f2fs/inode.c
        fi
        if [ "${ENABLE_UFS_RUNTIME_PM_ERROR_RECOVERY_FIX:-0}" = "1" ]; then
            printf '%s\n' drivers/ufs/core/ufshcd.c
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
        if [ "${ENABLE_UNICODE_IGNORABLE_FIX}" = "1" ]; then
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
    rm -f "${ksu_patch}" "${common_patch}" "${allowed_ksu}" "${allowed_common}"
    log_success "SUSFS v2.2.0 源码、补丁与 r57 适配状态检查通过"
}

verify_bbg_source_state() {
    local kconfig_line='source "security/baseband-guard/Kconfig"'
    local makefile_line='obj-$(CONFIG_BBG) += baseband-guard/'
    verify_repo_identity "Baseband Guard ${BBG_REF}" "${BBG_DIR}" "${BBG_REPO}" "${BBG_COMMIT}"
    [ "$(grep -Fxc "${kconfig_line}" "${COMMON_DIR}/security/Kconfig")" = "1" ] || die "Baseband Guard Kconfig 接入状态异常"
    [ "$(grep -Fxc "${makefile_line}" "${COMMON_DIR}/security/Makefile")" = "1" ] || die "Baseband Guard Kbuild 接入状态异常"
    [ -L "${COMMON_DIR}/security/baseband-guard" ] || die "Baseband Guard security 链接缺失"
    [ "$(readlink -f "${COMMON_DIR}/security/baseband-guard")" = "${BBG_DIR}" ] || die "Baseband Guard security 链接目标错误"
    git -C "${COMMON_DIR}" apply --reverse --check "${BBG_LSM_COUNT_PATCH}" || die "Baseband Guard LSM 计数适配状态异常"
    [ "$(grep -Ec '^#define BASEBAND_GUARD_ENABLED( |$)' "${COMMON_DIR}/include/linux/lsm_count.h")" = "2" ] || die "Baseband Guard LSM 计数宏异常"
    [ "$(grep -Ec '^[[:space:]]*BASEBAND_GUARD_ENABLED\)?[[:space:]]*\\?$' "${COMMON_DIR}/include/linux/lsm_count.h")" = "1" ] || die "Baseband Guard LSM 计数入口异常"
    log_success "Baseband Guard ${BBG_COMMIT:0:12} 源码与 overlay 状态检查通过"
}

verify_f2fs_merge_page_bio_uaf_fix() {
    local changed_paths patch_file patch_id
    [ "${ENABLE_F2FS_MERGE_PAGE_BIO_UAF_FIX}" = "1" ] || return
    env GIT_NO_LAZY_FETCH=1 git -C "${AOSP_BACKPORT_AUDIT_DIR}" \
        cat-file -e "${F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT}^{commit}" 2>/dev/null || \
        die "F2FS merge_page_bio UAF 修复对象缺失"
    changed_paths="$(env GIT_NO_LAZY_FETCH=1 git -C "${AOSP_BACKPORT_AUDIT_DIR}" \
        diff-tree --no-commit-id --name-only -r "${F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT}")"
    [ "${changed_paths}" = "fs/f2fs/data.c" ] || \
        die "F2FS merge_page_bio UAF 修复路径集合异常"
    patch_file="$(mktemp)"
    env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${AOSP_BACKPORT_AUDIT_DIR}" \
        show --format= "${F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT}" > "${patch_file}"
    patch_id="$(git patch-id --stable < "${patch_file}" | awk '{ print $1 }')"
    [ "${patch_id}" = "${F2FS_MERGE_PAGE_BIO_UAF_FIX_PATCH_ID}" ] || \
        die "F2FS merge_page_bio UAF 修复 patch-id 不匹配"
    git -C "${COMMON_DIR}" apply --reverse --check "${patch_file}" || \
        die "F2FS merge_page_bio UAF 修复未完整应用"
    rm -f "${patch_file}"
    grep -Fq 'inc_page_count(fio->sbi, WB_DATA_TYPE(fio->page, false));' \
        "${COMMON_DIR}/fs/f2fs/data.c" || \
        die "F2FS merge_page_bio UAF 修复语义检查失败"
    log_success "F2FS merge_page_bio 加密写回 UAF 修复检查通过"
}

verify_aosp_backport_source() {
    local label="$1" commit="$2" expected_patch_id="$3" expected_paths="$4"
    local actual_paths patch_file patch_id
    env GIT_NO_LAZY_FETCH=1 git -C "${AOSP_BACKPORT_AUDIT_DIR}" \
        cat-file -e "${commit}^{commit}" 2>/dev/null || die "${label}对象缺失"
    actual_paths="$(env GIT_NO_LAZY_FETCH=1 git -C "${AOSP_BACKPORT_AUDIT_DIR}" \
        diff-tree --no-commit-id --name-only -r "${commit}" | LC_ALL=C sort | paste -sd ' ' -)"
    [ "${actual_paths}" = "${expected_paths}" ] || die "${label}路径集合异常: ${actual_paths}"
    patch_file="$(mktemp)"
    env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${AOSP_BACKPORT_AUDIT_DIR}" \
        show --format= "${commit}" > "${patch_file}"
    patch_id="$(git patch-id --stable < "${patch_file}" | awk '{ print $1 }')"
    [ "${patch_id}" = "${expected_patch_id}" ] || die "${label} patch-id 不匹配"
    rm -f "${patch_file}"
}

verify_aosp_backport_applied() {
    local label="$1" commit="$2" expected_patch_id="$3" expected_paths="$4"
    local patch_file
    verify_aosp_backport_source "${label}" "${commit}" "${expected_patch_id}" "${expected_paths}"
    patch_file="$(mktemp)"
    env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${AOSP_BACKPORT_AUDIT_DIR}" \
        show --format= "${commit}" > "${patch_file}"
    git -C "${COMMON_DIR}" apply --reverse --check "${patch_file}" || die "${label}未完整应用"
    rm -f "${patch_file}"
}

verify_linux_stable_source() {
    local label="$1" commit="$2" expected_patch_id="$3" expected_paths="$4"
    local actual_paths patch_file patch_id
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        cat-file -e "${commit}^{commit}" 2>/dev/null || die "${label}对象缺失"
    actual_paths="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        diff-tree --no-commit-id --name-only -r "${commit}" | LC_ALL=C sort | paste -sd ' ' -)"
    [ "${actual_paths}" = "${expected_paths}" ] || die "${label}路径集合异常: ${actual_paths}"
    patch_file="$(mktemp)"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        -c log.mailmap=false show --format= "${commit}" > "${patch_file}"
    patch_id="$(git patch-id --stable < "${patch_file}" | awk '{ print $1 }')"
    rm -f "${patch_file}"
    [ "${patch_id}" = "${expected_patch_id}" ] || die "${label} patch-id 不匹配"
}

verify_linux_stable_backport_applied() {
    local label="$1" commit="$2" expected_patch_id="$3" expected_paths="$4"
    local patch_file
    verify_linux_stable_source "${label}" "${commit}" "${expected_patch_id}" "${expected_paths}"
    patch_file="$(mktemp)"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        -c log.mailmap=false show --format= "${commit}" > "${patch_file}"
    git -C "${COMMON_DIR}" apply --reverse --check "${patch_file}" || die "${label}未完整应用"
    rm -f "${patch_file}"
}

verify_first_batch_linux_backports() {
    local actual_sha256 patch_id composite_patch binder_function

    if [ "${ENABLE_FUTEX_EXITING_POINTER_FIX}" = "1" ]; then
        verify_linux_stable_backport_applied "futex PI stale exiting 指针修复" \
            "${FUTEX_EXITING_POINTER_STABLE_COMMIT}" \
            "${FUTEX_EXITING_POINTER_PATCH_ID}" \
            "kernel/futex/pi.c"
    fi
    if [ "${ENABLE_FUTEX_REQUEUE_PI_LOCKUP_FIX}" = "1" ]; then
        verify_linux_stable_backport_applied "futex requeue-PI 超时竞态活锁修复" \
            "${FUTEX_REQUEUE_PI_LOCKUP_STABLE_COMMIT}" \
            "${FUTEX_REQUEUE_PI_LOCKUP_PATCH_ID}" \
            "kernel/futex/requeue.c"
    fi
    if [ "${ENABLE_F2FS_ACL_ENTRY_BOUNDS_FIX}" = "1" ]; then
        verify_linux_stable_backport_applied "F2FS ACL 条目边界修复" \
            "${F2FS_ACL_ENTRY_BOUNDS_STABLE_COMMIT}" \
            "${F2FS_ACL_ENTRY_BOUNDS_PATCH_ID}" \
            "fs/f2fs/acl.c"
    fi
    if [ "${ENABLE_F2FS_LISTXATTR_BOUNDS_FIX}" = "1" ]; then
        verify_linux_stable_backport_applied "F2FS listxattr 条目边界修复" \
            "${F2FS_LISTXATTR_BOUNDS_STABLE_COMMIT}" \
            "${F2FS_LISTXATTR_BOUNDS_PATCH_ID}" \
            "fs/f2fs/xattr.c"
    fi
    if [ "${ENABLE_BLKCG_RSTAT_RELEASE_FIX}" = "1" ]; then
        verify_linux_stable_backport_applied "blk-cgroup rstat 释放竞态修复" \
            "${BLKCG_RSTAT_RELEASE_STABLE_COMMIT}" \
            "${BLKCG_RSTAT_RELEASE_PATCH_ID}" \
            "block/blk-cgroup.c"
    fi
    if [ "${ENABLE_BINDER_TRANSACTION_LIFETIME_FIX}" = "1" ]; then
        verify_linux_stable_source "Binder thread release 生命周期修复" \
            "${BINDER_THREAD_RELEASE_STABLE_COMMIT}" \
            "${BINDER_THREAD_RELEASE_PATCH_ID}" \
            "drivers/android/binder.c"
        verify_linux_stable_source "Binder transaction free 生命周期修复" \
            "${BINDER_FREE_TRANSACTION_STABLE_COMMIT}" \
            "${BINDER_FREE_TRANSACTION_PATCH_ID}" \
            "drivers/android/binder.c"
        actual_sha256="$(sha256sum "${BINDER_TRANSACTION_LIFETIME_PATCH}" | awk '{ print $1 }')"
        [ "${actual_sha256}" = "${BINDER_TRANSACTION_LIFETIME_PATCH_SHA256}" ] || \
            die "Binder Android 适配补丁 SHA-256 不匹配"
        patch_id="$(git patch-id --stable < "${BINDER_TRANSACTION_LIFETIME_PATCH}" | awk '{ print $1 }')"
        [ "${patch_id}" = "${BINDER_TRANSACTION_LIFETIME_PATCH_ID}" ] || \
            die "Binder Android 适配补丁 patch-id 不匹配"
        git -C "${COMMON_DIR}" apply --reverse --check \
            "${BINDER_TRANSACTION_LIFETIME_PATCH}" || \
            die "Binder Android 适配补丁未完整应用"
        binder_function="$(sed -n '/^static void binder_free_transaction(/,/^}/p' \
            "${COMMON_DIR}/drivers/android/binder.c")"
        printf '%s\n' "${binder_function}" | \
            grep -Fq 'atomic_inc(&target_thread->tmp_ref);' || \
            die "Binder 修复未固定目标线程生命周期"
        printf '%s\n' "${binder_function}" | \
            grep -Fq 'binder_thread_dec_tmpref(target_thread);' || \
            die "Binder 修复未释放目标线程临时引用"
    fi
    if [ "${ENABLE_F2FS_FOREGROUND_GC_DEADLOCK_FIX}" = "1" ]; then
        verify_linux_stable_source "F2FS 前台 GC 写回死锁修复" \
            "${F2FS_FOREGROUND_GC_DEADLOCK_STABLE_COMMIT}" \
            "${F2FS_FOREGROUND_GC_DEADLOCK_PATCH_ID}" \
            "fs/f2fs/data.c fs/f2fs/f2fs.h fs/f2fs/segment.c"
        verify_linux_stable_source "F2FS GC_MERGE 写回死锁补充修复" \
            "${F2FS_GC_MERGE_DEADLOCK_STABLE_COMMIT}" \
            "${F2FS_GC_MERGE_DEADLOCK_PATCH_ID}" \
            "fs/f2fs/segment.c"
        [ "$(git --git-dir="${LINUX_STABLE_AUDIT_DIR}" rev-parse \
            "${F2FS_GC_MERGE_DEADLOCK_STABLE_COMMIT}^")" = \
            "${F2FS_FOREGROUND_GC_DEADLOCK_STABLE_COMMIT}" ] || \
            die "F2FS GC 死锁组合提交顺序异常"
        composite_patch="$(mktemp)"
        git --git-dir="${LINUX_STABLE_AUDIT_DIR}" diff \
            "${F2FS_FOREGROUND_GC_DEADLOCK_STABLE_COMMIT}^" \
            "${F2FS_GC_MERGE_DEADLOCK_STABLE_COMMIT}" -- fs/f2fs > "${composite_patch}"
        git -C "${COMMON_DIR}" apply --reverse --check "${composite_patch}" || \
            die "F2FS GC 死锁组合修复未完整应用"
        rm -f "${composite_patch}"
    fi
    log_success "第一批 Linux 稳定修复来源、路径与应用状态检查通过"
}

verify_second_batch_backports() {
    local actual_sha256 patch_id ufs_error_handler

    if [ "${ENABLE_F2FS_ATOMIC_INODE_UAF_FIX}" = "1" ]; then
        verify_linux_stable_backport_applied "F2FS atomic inode 生命周期修复" \
            "${F2FS_ATOMIC_INODE_UAF_STABLE_COMMIT}" \
            "${F2FS_ATOMIC_INODE_UAF_PATCH_ID}" \
            "fs/f2fs/gc.c fs/f2fs/inode.c"
    fi
    if [ "${ENABLE_UFS_RUNTIME_PM_ERROR_RECOVERY_FIX}" = "1" ]; then
        verify_aosp_backport_source "UFS runtime suspend 错误恢复死锁修复" \
            "${UFS_RUNTIME_SUSPEND_DEADLOCK_AOSP_COMMIT}" \
            "${UFS_RUNTIME_SUSPEND_DEADLOCK_PATCH_ID}" \
            "drivers/ufs/core/ufshcd.c"
        verify_aosp_backport_source "UFS error handler host_sem 补充修复" \
            "${UFS_ERROR_HANDLER_HOST_SEM_AOSP_COMMIT}" \
            "${UFS_ERROR_HANDLER_HOST_SEM_PATCH_ID}" \
            "drivers/ufs/core/ufshcd.c"
        verify_aosp_backport_source "UFS error handler WLUN 空指针补充修复" \
            "${UFS_ERROR_HANDLER_WLUN_AOSP_COMMIT}" \
            "${UFS_ERROR_HANDLER_WLUN_PATCH_ID}" \
            "drivers/ufs/core/ufshcd.c"
        actual_sha256="$(sha256sum "${UFS_RUNTIME_PM_ERROR_RECOVERY_PATCH}" | awk '{ print $1 }')"
        [ "${actual_sha256}" = "${UFS_RUNTIME_PM_ERROR_RECOVERY_PATCH_SHA256}" ] || \
            die "UFS r57 适配补丁 SHA-256 不匹配"
        patch_id="$(git patch-id --stable < "${UFS_RUNTIME_PM_ERROR_RECOVERY_PATCH}" | awk '{ print $1 }')"
        [ "${patch_id}" = "${UFS_RUNTIME_PM_ERROR_RECOVERY_PATCH_ID}" ] || \
            die "UFS r57 适配补丁 patch-id 不匹配"
        git -C "${COMMON_DIR}" apply --reverse --check \
            "${UFS_RUNTIME_PM_ERROR_RECOVERY_PATCH}" || \
            die "UFS r57 适配补丁未完整应用"
        ufs_error_handler="$(sed -n '/^static void ufshcd_err_handler(/,/^}/p' \
            "${COMMON_DIR}/drivers/ufs/core/ufshcd.c")"
        printf '%s\n' "${ufs_error_handler}" | \
            grep -Fq 'if (hba->ufs_device_wlun) {' || \
            die "UFS error handler 未保护未初始化 WLUN"
        [ "$(printf '%s\n' "${ufs_error_handler}" | \
            grep -Fc 'ufshcd_rpm_put(hba);')" = "2" ] || \
            die "UFS error handler runtime PM 引用不平衡"
        printf '%s\n' "${ufs_error_handler}" | awk '
            /ufshcd_rpm_get_noresume\(hba\);/ { rpm = NR }
            /down\(&hba->host_sem\);/ {
                if (!rpm || rpm >= NR)
                    exit 1
                checked = 1
                exit 0
            }
            END { if (!checked) exit 1 }
        ' || die "UFS runtime PM 检查未置于 host_sem 获取之前"
    fi
    if [ "${ENABLE_TIMER_BASE_FAST_PATH}" = "1" ]; then
        verify_aosp_backport_applied "timer base 指针获取快路径优化" \
            "${TIMER_BASE_FAST_PATH_COMMIT}" \
            "${TIMER_BASE_FAST_PATH_PATCH_ID}" \
            "kernel/time/timer.c"
    fi
    if [ "${ENABLE_F2FS_DIO_OVERWRITE_FAST_PATH}" = "1" ]; then
        verify_aosp_backport_applied "F2FS DIO overwrite 映射检查优化" \
            "${F2FS_DIO_OVERWRITE_FAST_PATH_COMMIT}" \
            "${F2FS_DIO_OVERWRITE_FAST_PATH_PATCH_ID}" \
            "fs/f2fs/data.c"
    fi
    if [ "${ENABLE_EAS_CPUMASK_FAST_PATH}" = "1" ]; then
        verify_aosp_backport_applied "EAS cpumask 空集判断优化" \
            "${EAS_CPUMASK_FAST_PATH_COMMIT}" \
            "${EAS_CPUMASK_FAST_PATH_PATCH_ID}" \
            "kernel/sched/fair.c"
    fi
    if [ "${ENABLE_BLK_WBT_DONE_FAST_PATH}" = "1" ]; then
        verify_aosp_backport_applied "blk-wbt 非节流写完成快路径优化" \
            "${BLK_WBT_DONE_FAST_PATH_COMMIT}" \
            "${BLK_WBT_DONE_FAST_PATH_PATCH_ID}" \
            "block/blk-wbt.c"
    fi
    log_success "第二批修复/优化来源、路径与应用状态检查通过"
}

verify_f2fs_open_fast_path() {
    [ "${ENABLE_F2FS_OPEN_FAST_PATH}" = "1" ] || return
    verify_aosp_backport_applied "F2FS open 快路径优化" \
        "${F2FS_OPEN_FAST_PATH_COMMIT}" \
        "${F2FS_OPEN_FAST_PATH_PATCH_ID}" \
        "fs/f2fs/file.c"
    grep -Fq 'opened = is_inode_flag_set(inode, FI_OPENED_FILE);' \
        "${COMMON_DIR}/fs/f2fs/file.c" || \
        die "F2FS open 快路径语义检查失败"
    log_success "F2FS open 快路径优化检查通过"
}

verify_memcg_rstat_fast_path() {
    [ "${ENABLE_MEMCG_RSTAT_FAST_PATH}" = "1" ] || return
    verify_aosp_backport_applied "memcg rstat 快路径优化" \
        "${MEMCG_RSTAT_FAST_PATH_COMMIT}" \
        "${MEMCG_RSTAT_FAST_PATH_PATCH_ID}" \
        "mm/memcontrol.c"
    grep -Fq 'if (memcg_vmstats_needs_flush(statc->vmstats))' \
        "${COMMON_DIR}/mm/memcontrol.c" || \
        die "memcg rstat 快路径语义检查失败"
    log_success "memcg rstat 快路径优化检查通过"
}

verify_tcp_recv_mstamp_fast_path() {
    [ "${ENABLE_TCP_RECV_MSTAMP_FAST_PATH}" = "1" ] || return
    verify_aosp_backport_applied "TCP recv 时间戳快路径优化" \
        "${TCP_RECV_MSTAMP_FAST_PATH_COMMIT}" \
        "${TCP_RECV_MSTAMP_FAST_PATH_PATCH_ID}" \
        "net/ipv4/tcp.c net/ipv4/tcp_input.c"
    grep -Fq 'if (unlikely(!tp->rcv_rtt_est.rtt_us))' \
        "${COMMON_DIR}/net/ipv4/tcp_input.c" || \
        die "TCP recv 时间戳快路径语义检查失败"
    log_success "TCP recv 时间戳快路径优化检查通过"
}

verify_gunyah_clean_resources_uaf_fix() {
    [ "${ENABLE_GUNYAH_CLEAN_RESOURCES_UAF_FIX}" = "1" ] || return
    verify_aosp_backport_applied "Gunyah clean_resources UAF 修复" \
        "${GUNYAH_CLEAN_RESOURCES_UAF_FIX_COMMIT}" \
        "${GUNYAH_CLEAN_RESOURCES_UAF_FIX_PATCH_ID}" \
        "drivers/virt/gunyah/vm_mgr.c"
    grep -Fq 'list_del(&ghrsc->list);' "${COMMON_DIR}/drivers/virt/gunyah/vm_mgr.c" || \
        die "Gunyah clean_resources UAF 修复语义检查失败"
    log_success "Gunyah clean_resources UAF 修复检查通过"
}

verify_idletimer_destroy_uaf_fix() {
    [ "${ENABLE_IDLETIMER_DESTROY_UAF_FIX}" = "1" ] || return
    verify_aosp_backport_applied "IDLETIMER destroy UAF 修复" \
        "${IDLETIMER_DESTROY_UAF_FIX_COMMIT}" \
        "${IDLETIMER_DESTROY_UAF_FIX_PATCH_ID}" \
        "net/netfilter/xt_IDLETIMER.c"
    log_success "IDLETIMER destroy UAF 修复检查通过"
}

verify_eventpoll_rcu_uaf_fix() {
    [ "${ENABLE_EVENTPOLL_RCU_UAF_FIX}" = "1" ] || return
    verify_aosp_backport_applied "eventpoll RCU UAF 修复" \
        "${EVENTPOLL_RCU_UAF_FIX_COMMIT}" \
        "${EVENTPOLL_RCU_UAF_FIX_PATCH_ID}" \
        "fs/eventpoll.c"
    grep -Fq 'kfree_rcu(ep, rcu);' "${COMMON_DIR}/fs/eventpoll.c" || \
        die "eventpoll RCU UAF 修复语义检查失败"
    log_success "eventpoll RCU UAF 修复检查通过"
}

verify_cgroup_kernfs_uaf_fix() {
    [ "${ENABLE_CGROUP_KERNFS_UAF_FIX}" = "1" ] || return
    verify_aosp_backport_applied "cgroup kernfs UAF 修复" \
        "${CGROUP_KERNFS_UAF_FIX_COMMIT}" \
        "${CGROUP_KERNFS_UAF_FIX_PATCH_ID}" \
        "kernel/cgroup/cgroup.c"
    log_success "cgroup kernfs UAF 修复检查通过"
}

verify_f2fs_sync_inode_meta_uaf_fix() {
    [ "${ENABLE_F2FS_SYNC_INODE_META_UAF_FIX}" = "1" ] || return
    verify_aosp_backport_applied "F2FS sync_inode_meta UAF 修复" \
        "${F2FS_SYNC_INODE_META_UAF_FIX_COMMIT}" \
        "${F2FS_SYNC_INODE_META_UAF_FIX_PATCH_ID}" \
        "fs/f2fs/inode.c"
    log_success "F2FS sync_inode_meta UAF 修复检查通过"
}

verify_timer_shutdown_sync_race_fix() {
    [ "${ENABLE_TIMER_SHUTDOWN_SYNC_RACE_FIX}" = "1" ] || return
    verify_aosp_backport_applied "timer shutdown_sync 竞态修复" \
        "${TIMER_SHUTDOWN_SYNC_RACE_FIX_COMMIT}" \
        "${TIMER_SHUTDOWN_SYNC_RACE_FIX_PATCH_ID}" \
        "kernel/time/timer.c"
    log_success "timer shutdown_sync 竞态修复检查通过"
}

verify_futex_requeue_pi_uaf_fix() {
    [ "${ENABLE_FUTEX_REQUEUE_PI_UAF_FIX}" = "1" ] || return
    verify_aosp_backport_applied "futex requeue-PI UAF 修复" \
        "${FUTEX_REQUEUE_PI_UAF_FIX_COMMIT}" \
        "${FUTEX_REQUEUE_PI_UAF_FIX_PATCH_ID}" \
        "kernel/futex/requeue.c"
    log_success "futex requeue-PI UAF 修复检查通过"
}

verify_page_pool_destroy_race_fix() {
    [ "${ENABLE_PAGE_POOL_DESTROY_RACE_FIX}" = "1" ] || return
    verify_aosp_backport_applied "page_pool 销毁竞态修复" \
        "${PAGE_POOL_DESTROY_RACE_FIX_COMMIT}" \
        "${PAGE_POOL_DESTROY_RACE_FIX_PATCH_ID}" \
        "net/core/page_pool.c"
    log_success "page_pool 销毁竞态修复检查通过"
}

verify_conntrack_unconfirmed_race_fix() {
    [ "${ENABLE_CONNTRACK_UNCONFIRMED_RACE_FIX}" = "1" ] || return
    verify_aosp_backport_applied "conntrack 未确认项并发删除修复" \
        "${CONNTRACK_UNCONFIRMED_RACE_FIX_COMMIT}" \
        "${CONNTRACK_UNCONFIRMED_RACE_FIX_PATCH_ID}" \
        "include/net/netfilter/nf_conntrack.h net/netfilter/nf_conntrack_core.c"
    log_success "conntrack 未确认项并发删除修复检查通过"
}

verify_erofs_dir_tail_oob_fix() {
    [ "${ENABLE_EROFS_DIR_TAIL_OOB_FIX}" = "1" ] || return
    verify_aosp_backport_applied "EROFS 目录尾项越界读取修复" \
        "${EROFS_DIR_TAIL_OOB_FIX_COMMIT}" \
        "${EROFS_DIR_TAIL_OOB_FIX_PATCH_ID}" \
        "fs/erofs/dir.c"
    log_success "EROFS 目录尾项越界读取修复检查通过"
}

verify_ext4_xattr_oob_fix() {
    [ "${ENABLE_EXT4_XATTR_OOB_FIX}" = "1" ] || return
    verify_aosp_backport_applied "ext4 扩展属性边界越界读取修复" \
        "${EXT4_XATTR_OOB_FIX_COMMIT}" \
        "${EXT4_XATTR_OOB_FIX_PATCH_ID}" \
        "fs/ext4/xattr.c"
    log_success "ext4 扩展属性边界越界读取修复检查通过"
}

verify_ipv6_mld_uaf_fix() {
    [ "${ENABLE_IPV6_MLD_UAF_FIX}" = "1" ] || return
    verify_aosp_backport_applied "IPv6 MLD 查询释放后访问修复" \
        "${IPV6_MLD_UAF_FIX_COMMIT}" \
        "${IPV6_MLD_UAF_FIX_PATCH_ID}" \
        "net/ipv6/mcast.c"
    grep -Fq 'group = mld->mld_mca;' "${COMMON_DIR}/net/ipv6/mcast.c" || \
        die "IPv6 MLD 查询释放后访问修复语义检查失败"
    log_success "IPv6 MLD 查询释放后访问修复检查通过"
}

verify_rtmutex_waiter_enqueue_fix() {
    [ "${ENABLE_RTMUTEX_WAITER_ENQUEUE_FIX}" = "1" ] || return
    verify_aosp_backport_applied "rtmutex 未入队 waiter 错误路径修复" \
        "${RTMUTEX_WAITER_ENQUEUE_FIX_COMMIT}" \
        "${RTMUTEX_WAITER_ENQUEUE_FIX_PATCH_ID}" \
        "kernel/locking/rtmutex.c kernel/locking/rtmutex_api.c"
    grep -Fq 'if (!waiter_task) /* never enqueued */' \
        "${COMMON_DIR}/kernel/locking/rtmutex.c" || \
        die "rtmutex 未入队 waiter 错误路径修复语义检查失败"
    grep -Fq 'if (unlikely(ret < 0))' \
        "${COMMON_DIR}/kernel/locking/rtmutex_api.c" || \
        die "rtmutex proxy lock 返回值检查语义失败"
    log_success "rtmutex 未入队 waiter 错误路径修复检查通过"
}

verify_stage5_rtmutex_fix() {
    local patch_file patch_id stack_patch_id
    [ "${ENABLE_STAGE5_RTMUTEX_FIX}" = "1" ] || return
    git -C "${COMMON_DIR}" cat-file -e "${STAGE5_RTMUTEX_FIX_COMMIT}^{commit}" 2>/dev/null || \
        die "阶段 5 AOSP rtmutex 修复对象缺失"
    patch_file="$(mktemp)"
    git -C "${COMMON_DIR}" show --format= "${STAGE5_RTMUTEX_FIX_COMMIT}" > "${patch_file}"
    patch_id="$(git patch-id --stable < "${patch_file}" | awk '{ print $1 }')"
    [ "${patch_id}" = "${STAGE5_RTMUTEX_FIX_PATCH_ID}" ] || die "阶段 5 rtmutex patch-id 不匹配"
    if [ "${ENABLE_RTMUTEX_WAITER_ENQUEUE_FIX}" = "1" ]; then
        stack_patch_id="$(
            git -C "${COMMON_DIR}" diff HEAD -- \
                kernel/locking/rtmutex.c kernel/locking/rtmutex_api.c |
                git patch-id --stable | awk '{ print $1 }'
        )"
        [ "${stack_patch_id}" = "${RTMUTEX_FIX_STACK_PATCH_ID}" ] || \
            die "rtmutex 固定修复栈 patch-id 不匹配"
    else
        git -C "${COMMON_DIR}" apply --reverse --check "${patch_file}" || \
            die "阶段 5 rtmutex 修复未应用"
    fi
    rm -f "${patch_file}"
    grep -Fq 'struct task_struct *waiter_task = waiter->task;' "${COMMON_DIR}/kernel/locking/rtmutex.c" || \
        die "阶段 5 rtmutex waiter_task 守卫失败"
    log_success "阶段 5 AOSP rtmutex 安全修复检查通过"
}

verify_unicode_ignorable_fix() {
    local patch_id changed_paths official_ext4_patch_id project_ext4_patch_id
    [ "${ENABLE_UNICODE_IGNORABLE_FIX}" = "1" ] || return
    git -C "${COMMON_DIR}" cat-file -e "${UNICODE_FIX_COMMIT}^" 2>/dev/null || die "AOSP Unicode 修复对象不完整"
    patch_id="$(git -C "${COMMON_DIR}" show --format= "${UNICODE_FIX_COMMIT}" | git patch-id --stable | awk '{ print $1 }')"
    [ "${patch_id}" = "${UNICODE_FIX_PATCH_ID}" ] || die "Unicode 官方修复 patch-id 不匹配"
    changed_paths="$(git -C "${COMMON_DIR}" diff-tree --no-commit-id --name-only -r "${UNICODE_FIX_COMMIT}" | LC_ALL=C sort | paste -sd ' ' -)"
    [ "${changed_paths}" = "fs/unicode/mkutf8data.c fs/unicode/utf8data.h_shipped" ] || die "Unicode 官方修复路径集合异常"
    [ -s "${UNICODE_FIX_PATCH}" ] || die "Unicode 6.12.23 兼容补丁缺失"
    [ "$(sha256sum "${UNICODE_FIX_PATCH}" | awk '{ print $1 }')" = "${UNICODE_FIX_PATCH_SHA256}" ] || die "Unicode 兼容补丁校验失败"
    git -C "${COMMON_DIR}" apply --recount --reverse --check "${UNICODE_FIX_PATCH}" || die "Unicode 兼容修复未完整应用"
    [ -s "${UNICODE_SELFTEST_PATCH}" ] || die "Unicode 12.1 全码点自测补丁缺失"
    [ "$(sha256sum "${UNICODE_SELFTEST_PATCH}" | awk '{ print $1 }')" = "${UNICODE_SELFTEST_PATCH_SHA256}" ] || \
        die "Unicode 全码点自测补丁校验失败"
    git -C "${COMMON_DIR}" apply --recount --reverse --check "${UNICODE_SELFTEST_PATCH}" || \
        die "Unicode 12.1 全码点自测未完整应用"
    ! grep -Fq 'ignore_init();' "${COMMON_DIR}/fs/unicode/mkutf8data.c" || die "Unicode 生成器仍调用旧的 default-ignorable 删除逻辑"
    grep -Fq 'ZERO WIDTH SPACE must no longer normalize to an empty name' "${COMMON_DIR}/fs/unicode/utf8-selftest.c" || \
        die "Unicode 零宽 NFDI 自测缺失"
    grep -Fq 'Casefold surrounding text but preserve ZERO WIDTH SPACE' "${COMMON_DIR}/fs/unicode/utf8-selftest.c" || \
        die "Unicode 零宽 NFDICF 自测缺失"
    grep -Fq 'checked == 4173' "${COMMON_DIR}/fs/unicode/utf8-selftest.c" || \
        die "Unicode 12.1 Default-Ignorable 全码点覆盖缺失"
    grep -Fq 'sb_no_casefold_compat_fallback(dir->i_sb)' "${COMMON_DIR}/fs/ext4/namei.c" || \
        die "ext4 旧 casefold 哈希线性回退缺失"
    git -C "${COMMON_DIR}" cat-file -e "${UNICODE_EXT4_COMPAT_COMMIT}^" 2>/dev/null || \
        die "AOSP ext4 casefold 兼容提交对象不完整"
    official_ext4_patch_id="$(git -C "${COMMON_DIR}" show --format= "${UNICODE_EXT4_COMPAT_COMMIT}" -- fs/ext4/namei.c | \
        git patch-id --stable | awk '{ print $1 }')"
    project_ext4_patch_id="$(git -C "${COMMON_DIR}" diff HEAD -- fs/ext4/namei.c | git patch-id --stable | awk '{ print $1 }')"
    [ "${official_ext4_patch_id}" = "${UNICODE_EXT4_COMPAT_PATCH_ID}" ] || \
        die "AOSP ext4 casefold 兼容 patch-id 不匹配"
    [ "${project_ext4_patch_id}" = "${official_ext4_patch_id}" ] || \
        die "项目 ext4 casefold 兼容增量与 AOSP 官方实现不一致"
    grep -Fq 'f2fs_should_fallback_to_linear' "${COMMON_DIR}/fs/f2fs/dir.c" || \
        die "f2fs 旧 casefold 哈希线性回退缺失"
    grep -Fq 'f2fs_set_lookup_mode(sbi, LOOKUP_AUTO);' "${COMMON_DIR}/fs/f2fs/super.c" || \
        die "f2fs 默认 lookup_mode 未启用安全的自动兼容回退"
    log_success "Unicode 零宽语义、全码点自测及 ext4/f2fs 旧目录兼容检查通过"
}

run_unicode_uml_selftest() {
    local uml_out uml_log uml_rc
    [ "${ENABLE_UNICODE_IGNORABLE_FIX}" = "1" ] || return
    command -v gcc >/dev/null 2>&1 || die "Unicode UML selftest 缺少主机 gcc"
    command -v timeout >/dev/null 2>&1 || die "Unicode UML selftest 缺少 timeout"

    uml_out="${BUILD_DIR}_unicode_uml"
    uml_log="${uml_out}/unicode-selftest.log"
    mkdir -p "${uml_out}"
    log_step "构建并运行 Unicode 12.1 UML 全码点 selftest"
    make -C "${COMMON_DIR}" O="${uml_out}" ARCH=um SUBARCH=x86_64 CROSS_COMPILE= CC=gcc HOSTCC=gcc LD=ld defconfig >/dev/null
    bash "${COMMON_DIR}/scripts/config" --file "${uml_out}/.config" \
        --enable UNICODE \
        --enable UNICODE_NORMALIZATION_SELFTEST \
        --disable MODULES \
        --disable BLK_DEV_UBD \
        --disable UML_NET \
        --disable KSU \
        --disable KSU_SUSFS \
        --disable BBG \
        --disable MQ_IOSCHED_ADIOS \
        --disable TCP_CONG_BRUTAL \
        --disable IP_SET
    make -C "${COMMON_DIR}" O="${uml_out}" ARCH=um SUBARCH=x86_64 CROSS_COMPILE= CC=gcc HOSTCC=gcc LD=ld olddefconfig >/dev/null
    make -C "${COMMON_DIR}" O="${uml_out}" ARCH=um SUBARCH=x86_64 CROSS_COMPILE= CC=gcc HOSTCC=gcc LD=ld -j"${BUILD_JOBS}" linux >/dev/null

    set +e
    {
        timeout 30s "${uml_out}/linux" mem=256M ssl=null con0=fd:0,fd:1 >"${uml_log}" 2>&1
        uml_rc=$?
    } 2>/dev/null
    set -e
    grep -Fq "utf8_selftest: All ${UNICODE_SELFTEST_EXPECTED_TESTS} tests passed" "${uml_log}" || \
        die "Unicode UML selftest 未通过（UML rc=${uml_rc}）"
    ! grep -Eq 'utf8_selftest: [0-9]+ out of [0-9]+ tests failed' "${uml_log}" || \
        die "Unicode UML selftest 报告失败"
    log_success "Unicode UML 运行时 selftest 通过 (${UNICODE_SELFTEST_EXPECTED_TESTS} 项)"
}

verify_lsm_slot_capacity() {
    local expected=0 expanded preprocess_file symbol
    # CAPABILITIES is represented by CONFIG_SECURITY; each remaining macro in
    # lsm_count.h must correspond to one enabled configuration exactly once.
    expected=1
    for symbol in SECURITY_SELINUX SECURITY_SMACK SECURITY_APPARMOR SECURITY_TOMOYO \
                  SECURITY_YAMA SECURITY_LOADPIN SECURITY_LOCKDOWN_LSM SECURITY_SAFESETID \
                  BPF_LSM SECURITY_LANDLOCK IMA EVM SECURITY_IPE BBG; do
        grep -qx "CONFIG_${symbol}=y" "${BUILD_DIR}/.config" && expected=$((expected + 1))
    done
    [ "$(grep -Ec '^#define BASEBAND_GUARD_ENABLED( |$)' "${COMMON_DIR}/include/linux/lsm_count.h")" = "2" ] || \
        die "BBG LSM 启用/禁用宏必须各有且仅有一处"
    [ "$(grep -Ec '^[[:space:]]*BASEBAND_GUARD_ENABLED\)?[[:space:]]*\\?$' "${COMMON_DIR}/include/linux/lsm_count.h")" = "1" ] || \
        die "BBG 在 MAX_LSM_COUNT 中必须恰好计数一次"
    ! grep -Rqs --exclude='lsm_hook.h' 'security_add_hooks[[:space:]]*(' "${KSU_DIR}/kernel" || \
        die "KernelSU 注册额外 LSM 但 lsm_count.h 未获授权增加槽位"
    make -C "${COMMON_DIR}" "${MAKE_ARGS[@]}" security/security.i -j"${BUILD_JOBS}" >/dev/null
    preprocess_file="${BUILD_DIR}/security/security.i"
    [ -s "${preprocess_file}" ] || die "无法生成 LSM 计数预处理证明"
    expanded="$(sed -n 's/.*lsm_idlist\[\([0-9][0-9]*\)\].*/\1/p' "${preprocess_file}" | head -n 1)"
    [ -n "${expanded}" ] || die "无法从 security.i 解析 MAX_LSM_COUNT"
    [ "${expanded}" = "${expected}" ] || die "LSM 槽位展开值异常: ${expanded} != ${expected}"
    log_success "LSM 槽位计数已由目标配置预处理证明: ${expanded}（BBG 1 槽，KernelSU 0 槽）"
}

verify_adios_source_state() {
    [ "${ENABLE_ADIOS}" = "1" ] || return
    verify_repo_identity "ADIOS ${ADIOS_REF}" "${ADIOS_DIR}" "${ADIOS_REPO}" "${ADIOS_COMMIT}"
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
    ! grep -Eq '^all:|^clean:|/lib/modules/' "${COMMON_DIR}/block/Makefile" || \
        die "ADIOS 外置模块 Makefile 规则不得进入完整内核树"
    log_success "ADIOS 3.2.0 官方来源与适配状态检查通过"
}

verify_tcp_brutal_source_state() {
    [ "${ENABLE_TCP_BRUTAL}" = "1" ] || return
    verify_repo_identity "TCP Brutal ${TCP_BRUTAL_REF}" "${TCP_BRUTAL_DIR}" "${TCP_BRUTAL_REPO}" "${TCP_BRUTAL_COMMIT}"
    [ "$(sha256sum "${TCP_BRUTAL_DIR}/brutal.c" | awk '{ print $1 }')" = "${TCP_BRUTAL_SOURCE_SHA256}" ] || \
        die "TCP Brutal 官方源码 SHA-256 不匹配"
    cmp -s "${TCP_BRUTAL_DIR}/brutal.c" "${COMMON_DIR}/net/ipv4/tcp_brutal.c" || \
        die "TCP Brutal 源文件不是固定官方内容"
    git -C "${COMMON_DIR}" apply --reverse --check "${TCP_BRUTAL_INTEGRATION_PATCH}" || \
        die "TCP Brutal AOSP 6.12.23 接入补丁状态异常"
    log_success "TCP Brutal ${TCP_BRUTAL_COMMIT:0:12} 官方来源与接入状态检查通过"
}

verify_kernelsu_build() {
    local cmd_file="${BUILD_DIR}/drivers/kernelsu/core/.init.o.cmd"
    [ -s "${BUILD_DIR}/drivers/kernelsu/built-in.a" ] || die "KernelSU built-in archive 缺失"
    [ -s "${cmd_file}" ] || die "KernelSU init 编译命令记录缺失"
    grep -F -- "-DKSU_VERSION=${KSU_VERSION_CODE}" "${cmd_file}" >/dev/null || die "KernelSU version code 未固定为 ${KSU_VERSION_CODE}"
    "${CI_TOOLCHAIN_DIR}/bin/llvm-nm" "${BUILD_DIR}/vmlinux" | grep -E '[[:space:]]T[[:space:]]+kernelsu_init$' >/dev/null || die "vmlinux 未链接 kernelsu_init"
    [ -s "${BUILD_DIR}/kernel/seccomp.o" ] || die "内核 seccomp 对象缺失"
    [ -s "${BUILD_DIR}/drivers/kernelsu/infra/seccomp_cache.o" ] || die "KernelSU seccomp cache 对象缺失"
    for symbol in disable_seccomp ksu_seccomp_allow_cache ksu_seccomp_clear_cache seccomp_filter_release; do
        "${CI_TOOLCHAIN_DIR}/bin/llvm-nm" "${BUILD_DIR}/vmlinux" | \
            grep -E "[[:space:]][Tt][[:space:]]+${symbol}$" >/dev/null || die "vmlinux 未链接 seccomp 支持符号: ${symbol}"
    done
    log_success "KernelSU built-in、version code ${KSU_VERSION_CODE} 与标准 seccomp 支持检查通过"
}

verify_bbg_build() {
    [ -s "${BUILD_DIR}/security/baseband-guard/built-in.a" ] || die "Baseband Guard built-in archive 缺失"
    "${CI_TOOLCHAIN_DIR}/bin/llvm-nm" "${BUILD_DIR}/vmlinux" | \
        grep -E '[[:space:]][Tt][[:space:]]+bbg_init$' >/dev/null || die "vmlinux 未链接 bbg_init"
    strings "${BUILD_DIR}/arch/arm64/boot/Image" | grep -F "${BBG_COMMIT:0:8}" >/dev/null || \
        die "Image 未包含固定 Baseband Guard 版本"
    log_success "Baseband Guard built-in 与版本 ${BBG_COMMIT:0:8} 检查通过"
}

verify_stage5_selected_build() {
    if [ "${ENABLE_ADIOS}" = "1" ]; then
        [ -s "${BUILD_DIR}/block/built-in.a" ] || die "block built-in archive 缺失"
        "${CI_TOOLCHAIN_DIR}/bin/llvm-nm" "${BUILD_DIR}/vmlinux" | \
            grep -E '[[:space:]][Tt][[:space:]]+adios_init$' >/dev/null || die "vmlinux 未链接 adios_init"
        strings "${BUILD_DIR}/arch/arm64/boot/Image" | grep -F '3.2.0' >/dev/null || \
            die "Image 未包含 ADIOS 3.2.0"
    fi
    if [ "${ENABLE_STAGE5_NETWORK}" = "1" ]; then
        "${CI_TOOLCHAIN_DIR}/bin/llvm-nm" "${BUILD_DIR}/vmlinux" | \
            grep -E '[[:space:]][Tt][[:space:]]+bbr_register$' >/dev/null || die "vmlinux 未链接 BBR v1"
        "${CI_TOOLCHAIN_DIR}/bin/llvm-nm" "${BUILD_DIR}/vmlinux" | \
            grep -E '[[:space:]][Tt][[:space:]]+brutal_register$' >/dev/null || die "vmlinux 未链接 TCP Brutal"
    fi
    log_success "阶段 5 已选调度、网络与 namespace 功能链接检查通过"
}

require_config_enabled() {
    local symbol="$1"
    grep -qx "CONFIG_${symbol}=y" "${BUILD_DIR}/.config" || die "KMI 配置缺失: CONFIG_${symbol}=y"
}

require_config_disabled() {
    local symbol="$1"
    grep -qx "# CONFIG_${symbol} is not set" "${BUILD_DIR}/.config" || die "KMI 配置必须关闭: CONFIG_${symbol}"
}

require_config_not_enabled() {
    local symbol="$1"
    ! grep -Eq "^CONFIG_${symbol}=[ym]$" "${BUILD_DIR}/.config" || \
        die "KMI 配置必须不启用: CONFIG_${symbol}"
}

verify_kmi_config() {
    local config_lines config_sha256
    config_lines="$(wc -l < "${BUILD_DIR}/.config" | tr -d ' ')"
    config_sha256="$(sha256sum "${BUILD_DIR}/.config" | awk '{ print $1 }')"
    [ "${config_lines}" -ge "${KMI_CONFIG_MIN_LINES}" ] || die "配置项数量异常: ${config_lines} < ${KMI_CONFIG_MIN_LINES}"

    local symbol
    for symbol in \
        ARM64_4K_PAGES PAGE_SIZE_4KB SMP PREEMPT NET \
        MODULES MODULE_UNLOAD MODVERSIONS GENDWARFKSYMS \
        ANDROID_VENDOR_HOOKS GKI_HACKS_TO_FIX \
        IKCONFIG IKCONFIG_PROC CFI_CLANG RUST \
        BPF BPF_JIT BPF_JIT_ALWAYS_ON BPF_UNPRIV_DEFAULT_OFF \
        HAVE_ARCH_SECCOMP HAVE_ARCH_SECCOMP_FILTER SECCOMP SECCOMP_FILTER \
        DEBUG_INFO_BTF DEBUG_INFO_BTF_MODULES \
        FUSE_BPF LTO_NONE \
        TMPFS TMPFS_XATTR TMPFS_POSIX_ACL \
        EROFS_FS_ZIP EROFS_FS_ZIP_LZMA EROFS_FS_ZIP_DEFLATE EROFS_FS_ZIP_ZSTD \
        XZ_DEC_MICROLZMA WQ_POWER_EFFICIENT_DEFAULT; do
        require_config_enabled "${symbol}"
    done
    for symbol in \
        ARM64_16K_PAGES ARM64_64K_PAGES \
        LOCALVERSION_AUTO TRIM_UNUSED_KSYMS MODULE_SIG_FORCE SECCOMP_CACHE_DEBUG \
        LTO_CLANG_FULL LTO_CLANG_THIN; do
        require_config_disabled "${symbol}"
    done
    if [ "${ENABLE_KERNELSU}" = "1" ]; then
        for symbol in KSU KPROBES EXT4_FS; do require_config_enabled "${symbol}"; done
        require_config_disabled KSU_DEBUG
        if [ "${ENABLE_SUSFS}" = "1" ]; then
            for symbol in \
                KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT \
                KSU_SUSFS_SUS_KSTAT KSU_SUSFS_SPOOF_UNAME \
                KSU_SUSFS_ENABLE_LOG KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
                KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
                KSU_SUSFS_OPEN_REDIRECT KSU_SUSFS_SUS_MAP; do
                require_config_enabled "${symbol}"
            done
        fi
        if [ "${ENABLE_BBG}" = "1" ]; then
            require_config_enabled BBG
            require_config_disabled BBG_BLOCK_BOOT
            require_config_disabled BBG_BLOCK_RECOVERY
            grep -qx 'CONFIG_LSM="landlock,lockdown,yama,loadpin,safesetid,selinux,smack,tomoyo,apparmor,ipe,bpf,baseband_guard"' "${BUILD_DIR}/.config" || \
                die "CONFIG_LSM 未精确启用 baseband_guard"
        fi
        if [ "${ENABLE_STAGE4_FS}" = "1" ]; then
            for symbol in \
                BLK_DEV_LOOP EROFS_FS EROFS_FS_XATTR EROFS_FS_POSIX_ACL \
                EROFS_FS_SECURITY EROFS_FS_BACKED_BY_FILE EROFS_FS_ZIP \
                EROFS_FS_ZIP_DEFLATE EROFS_FS_ZIP_LZMA EROFS_FS_ZIP_ZSTD \
                EROFS_FS_PCPU_KTHREAD EROFS_FS_PCPU_KTHREAD_HIPRI \
                FS_ENCRYPTION FS_ENCRYPTION_ALGS FS_ENCRYPTION_INLINE_CRYPT \
                FS_VERITY DM_CRYPT DM_DEFAULT_KEY DM_VERITY DM_VERITY_FEC \
                EXT4_FS EXT4_USE_FOR_EXT2 EXT4_FS_POSIX_ACL EXT4_FS_SECURITY \
                F2FS_FS F2FS_FS_XATTR F2FS_FS_POSIX_ACL F2FS_FS_SECURITY \
                F2FS_FS_COMPRESSION F2FS_FS_LZO F2FS_FS_LZORLE F2FS_FS_LZ4 \
                F2FS_FS_LZ4HC F2FS_FS_ZSTD F2FS_IOSTAT F2FS_UNFAIR_RWSEM \
                UNICODE NLS_UTF8 NETFS_SUPPORT CIFS OVERLAY_FS \
                OVERLAY_FS_REDIRECT_ALWAYS_FOLLOW TMPFS TMPFS_POSIX_ACL TMPFS_XATTR \
                INTEGRITY INTEGRITY_AUDIT; do
                require_config_enabled "${symbol}"
            done
            for symbol in \
                EROFS_FS_ONDEMAND OVERLAY_FS_REDIRECT_DIR OVERLAY_FS_INDEX \
                OVERLAY_FS_XINO_AUTO OVERLAY_FS_METACOPY OVERLAY_FS_DEBUG \
                TMPFS_INODE64 TMPFS_QUOTA INTEGRITY_SIGNATURE; do
                require_config_not_enabled "${symbol}"
            done
        fi
        if [ "${ENABLE_ADIOS}" = "1" ]; then
            require_config_enabled MQ_IOSCHED_ADIOS
            require_config_not_enabled MQ_IOSCHED_DEFAULT_ADIOS
        fi
        if [ "${ENABLE_STAGE5_NAMESPACES}" = "1" ]; then
            require_config_enabled USER_NS
            require_config_enabled PID_NS
        fi
        if [ "${ENABLE_STAGE5_NETWORK}" = "1" ]; then
            for symbol in TCP_CONG_ADVANCED TCP_CONG_CUBIC TCP_CONG_BBR TCP_CONG_BRUTAL NET_SCH_FQ; do
                require_config_enabled "${symbol}"
            done
            for symbol in TCP_CONG_BIC TCP_CONG_WESTWOOD TCP_CONG_HTCP; do
                require_config_not_enabled "${symbol}"
            done
            require_config_enabled DEFAULT_CUBIC
            grep -qx 'CONFIG_DEFAULT_TCP_CONG="cubic"' "${BUILD_DIR}/.config" || \
                die "默认 TCP 拥塞控制必须保持 cubic"
            require_config_not_enabled NET_SCH_DEFAULT
        fi
        if [ "${ENABLE_IPSET}" = "1" ]; then
            for symbol in \
                IP_SET IP_SET_BITMAP_IP IP_SET_BITMAP_IPMAC IP_SET_BITMAP_PORT \
                IP_SET_HASH_IP IP_SET_HASH_IPMARK IP_SET_HASH_IPPORT \
                IP_SET_HASH_IPPORTIP IP_SET_HASH_IPPORTNET IP_SET_HASH_IPMAC \
                IP_SET_HASH_MAC IP_SET_HASH_NET IP_SET_HASH_NETNET \
                IP_SET_HASH_NETPORT IP_SET_HASH_NETPORTNET IP_SET_HASH_NETIFACE \
                IP_SET_LIST_SET NETFILTER_XT_SET NET_EMATCH_IPSET; do
                require_config_enabled "${symbol}"
            done
            grep -qx 'CONFIG_IP_SET_MAX=256' "${BUILD_DIR}/.config" || die "CONFIG_IP_SET_MAX 必须固定为 256"
            require_config_not_enabled NF_TABLES
        fi
        for symbol in DMABUF_HEAPS_SYSTEM DMABUF_HEAPS_CMA; do
            require_config_not_enabled "${symbol}"
        done
        for symbol in GUNYAH_QCOM_PLATFORM ARM_SMMU ARM_SMMU_V3 ARM_SMMU_V3_PKVM QCOM_IOMMU PKVM_PVIOMMU; do
            require_config_not_enabled "${symbol}"
        done
        for symbol in GUNYAH GUNYAH_HYPERCALLS GUNYAH_PLATFORM_HOOKS GUNYAH_QCOM_TRUSTED_VM; do
            require_config_enabled "${symbol}"
        done
        [ -n "${STAGE_CONFIG_LINES}" ] || die "阶段配置快照尚未固定: STAGE_CONFIG_LINES=${config_lines}"
        [ "${config_lines}" = "${STAGE_CONFIG_LINES}" ] || die "阶段配置行数漂移: ${config_lines} != ${STAGE_CONFIG_LINES}"
    fi
    [ "${config_sha256}" = "${STAGE_CONFIG_SHA256}" ] || \
        die "阶段配置完整指纹漂移: ${config_sha256} != ${STAGE_CONFIG_SHA256}"
    log_success "GKI/KMI 配置检查通过 (${config_lines} 行，完整指纹匹配)"
}

verify_symbol_list_exports() {
    local list_file="$1"
    local label="$2"
    local symvers_file="${BUILD_DIR}/Module.symvers"
    local missing
    missing="$(comm -23 \
        <(awk '/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/ { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }' "${list_file}" | sort -u) \
        <(awk '{ print $2 }' "${symvers_file}" | sort -u) | sed -n '1,20p')"
    [ -z "${missing}" ] || die "${label} KMI symbols 未导出:\n${missing}"
    log_success "${label} KMI symbol list 导出检查通过"
}

verify_stage_abi() {
    local abi_export_count
    local abi_sha256
    local abi_stg abi_stg_filter abi_stg_sha256 abi_stg_symbol_count stg_bin
    local vendor_names vendor_map vendor_crc vendor_count vendor_sha256
    local entry
    local expected_crc
    local symbol
    local -a required_exports=(
        "0x2771bc69 zone_pageset_high_and_batch_update"
        "0x7c5aa8a7 __tracepoint_android_vh_fas_gpu_qos_update_tracer"
        "0x83169769 ashmem_area_name"
        "0x85fa6f3e __mmu_notifier_invalidate_range_start"
        "0x912821da swapper_spaces"
        "0xa8d297cc uprobe_unregister_nosync"
        "0xb89ff97d mte_sync_tags"
        "0xc77e41ec uprobe_register"
        "0xf7e9b9a0 __traceiter_android_vh_f2fs_printk"
    )

    for entry in "${required_exports[@]}"; do
        read -r expected_crc symbol <<<"${entry}"
        grep -Eq "^${expected_crc}[[:space:]]+${symbol}[[:space:]]" "${BUILD_DIR}/Module.symvers" || \
            die "可启动参考 ABI 不匹配: ${symbol} (${expected_crc})"
    done

    abi_export_count="$(awk -F '\t' '$3 == "vmlinux" { print $2 }' "${BUILD_DIR}/Module.symvers" | sort -u | wc -l | tr -d ' ')"
    abi_sha256="$(awk -F '\t' '$3 == "vmlinux" { printf "%s\t%s\n", $1, $2 }' "${BUILD_DIR}/Module.symvers" | LC_ALL=C sort -k2,2 | sha256sum | awk '{ print $1 }')"
    vendor_names="$(mktemp)"
    vendor_map="$(mktemp)"
    vendor_crc="$(mktemp)"
    awk '/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/ { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }' \
        "${COMMON_DIR}/gki/aarch64/symbols/qcom" "${COMMON_DIR}/gki/aarch64/symbols/xiaomi" | LC_ALL=C sort -u > "${vendor_names}"
    awk -F '\t' '{ print $2 "\t" $1 }' "${BUILD_DIR}/Module.symvers" | LC_ALL=C sort -k1,1 -u > "${vendor_map}"
    join -t "$(printf '\t')" -1 1 -2 1 "${vendor_names}" "${vendor_map}" | awk -F '\t' '{ print $2 "\t" $1 }' > "${vendor_crc}"
    vendor_count="$(wc -l < "${vendor_crc}" | tr -d ' ')"
    vendor_sha256="$(sha256sum "${vendor_crc}" | awk '{ print $1 }')"
    rm -f "${vendor_names}" "${vendor_map}" "${vendor_crc}"

    [ "${vendor_count}" = "${VENDOR_KMI_BASELINE_COUNT}" ] || die "vendor KMI CRC 数量漂移: ${vendor_count} != ${VENDOR_KMI_BASELINE_COUNT}"
    [ "${vendor_sha256}" = "${VENDOR_KMI_BASELINE_SHA256}" ] || die "vendor KMI CRC 指纹漂移: ${vendor_sha256}"
    log_success "阶段 1 vendor KMI CRC 保持不变 (${vendor_count} 个符号)"

    if [ -z "${STAGE_ABI_EXPORT_COUNT}" ] || [ -z "${STAGE_ABI_SHA256}" ]; then
        die "阶段 ABI 快照尚未固定: STAGE_ABI_EXPORT_COUNT=${abi_export_count} STAGE_ABI_SHA256=${abi_sha256}"
    fi
    [ "${abi_export_count}" = "${STAGE_ABI_EXPORT_COUNT}" ] || die "阶段 ABI 导出数量不匹配: ${abi_export_count} != ${STAGE_ABI_EXPORT_COUNT}"
    [ "${abi_sha256}" = "${STAGE_ABI_SHA256}" ] || die "阶段 ABI/CRC 指纹不匹配: ${abi_sha256}"
    log_success "阶段完整 ABI/CRC 检查通过 (${abi_export_count} 个导出)"

    stg_bin="${CI_TOOLCHAIN_DIR}/build-tools/bin/stg"
    abi_stg_filter="${BUILD_DIR}/abi-exported-symbols"
    abi_stg="${BUILD_DIR}/abi-exported.stg"
    [ -x "${stg_bin}" ] || die "缺少 STG ABI 提取工具"
    {
        printf '[abi_symbol_list]\n'
        awk -F '\t' '$3 == "vmlinux" { print $2 }' "${BUILD_DIR}/Module.symvers" |
            LC_ALL=C sort -u | sed 's/^/  /'
    } > "${abi_stg_filter}"
    "${stg_bin}" --elf "${BUILD_DIR}/vmlinux" \
        --symbols ":${abi_stg_filter}" --output "${abi_stg}"
    abi_stg_symbol_count="$(grep -c '^elf_symbol {' "${abi_stg}")"
    abi_stg_sha256="$(sha256sum "${abi_stg}" | awk '{ print $1 }')"
    [ "${abi_stg_symbol_count}" = "${abi_export_count}" ] || \
        die "STG 导出符号数量不匹配: ${abi_stg_symbol_count} != ${abi_export_count}"
    [ -n "${STAGE_ABI_STG_SHA256}" ] || \
        die "阶段 STG ABI 快照尚未固定: STAGE_ABI_STG_SHA256=${abi_stg_sha256}"
    [ "${abi_stg_sha256}" = "${STAGE_ABI_STG_SHA256}" ] || \
        die "阶段 STG ABI 类型图指纹不匹配: ${abi_stg_sha256}"
    log_success "阶段 STG ABI 类型图检查通过 (${abi_stg_symbol_count} 个导出)"
}

build_ipset_userspace() {
    local ndk_bin cc userspace_root prefix libmnl_build ipset_build binary module_dir module_zip needed unexpected_needed
    [ "${ENABLE_IPSET}" = "1" ] || return
    ndk_bin="${ANDROID_NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/bin"
    cc="${ndk_bin}/aarch64-linux-android${ANDROID_NDK_API}-clang"
    [ -x "${cc}" ] || die "Android NDK arm64 clang 缺失，请先运行 ./init.sh"
    [ "$(tree_sha256 "${IPSET_DIR}")" = "${IPSET_TREE_SHA256}" ] || die "ipset 源码树完整性校验失败，请重新运行 ./init.sh"
    [ "$(tree_sha256 "${LIBMNL_DIR}")" = "${LIBMNL_TREE_SHA256}" ] || die "libmnl 源码树完整性校验失败，请重新运行 ./init.sh"

    case "${BUILD_DIR%/}" in
        /*/*) ;;
        *) die "拒绝清理异常用户态构建根目录: ${BUILD_DIR}" ;;
    esac
    userspace_root="${BUILD_DIR%/}/userspace"
    rm -rf -- "${userspace_root}"
    prefix="${userspace_root}/ipset-prefix"
    libmnl_build="${userspace_root}/libmnl-build"
    ipset_build="${userspace_root}/ipset-build"
    mkdir -p "${prefix}" "${libmnl_build}" "${ipset_build}"

    log_step "使用 Android NDK 构建静态 arm64 libmnl ${LIBMNL_VERSION}"
    (cd "${libmnl_build}" && env \
        CC="${cc}" AR="${ndk_bin}/llvm-ar" RANLIB="${ndk_bin}/llvm-ranlib" STRIP="${ndk_bin}/llvm-strip" \
        CFLAGS='-O2 -fPIC -ffunction-sections -fdata-sections' LDFLAGS='-Wl,--gc-sections' \
        "${LIBMNL_DIR}/configure" --host=aarch64-linux-android --prefix="${prefix}" --disable-shared --enable-static)
    make -C "${libmnl_build}" -j"${BUILD_JOBS}" install >/dev/null

    log_step "使用 Android NDK 构建内置 libipset/libmnl 的 arm64 ipset ${IPSET_VERSION}"
    (cd "${ipset_build}" && env \
        CC="${cc}" AR="${ndk_bin}/llvm-ar" RANLIB="${ndk_bin}/llvm-ranlib" STRIP="${ndk_bin}/llvm-strip" \
        PKG_CONFIG_LIBDIR="${prefix}/lib/pkgconfig" PKG_CONFIG_PATH="${prefix}/lib/pkgconfig" \
        CPPFLAGS="-I${prefix}/include" LDFLAGS="-L${prefix}/lib -Wl,--gc-sections" \
        CFLAGS='-O2 -fPIE -ffunction-sections -fdata-sections' \
        "${IPSET_DIR}/configure" --host=aarch64-linux-android --prefix="${prefix}" \
            --disable-shared --enable-static --disable-settype-modules --with-kmod=no)
    make -C "${ipset_build}" -j"${BUILD_JOBS}" >/dev/null
    binary="${ipset_build}/src/ipset"
    [ -s "${binary}" ] || die "Android arm64 ipset 命令未生成"
    file "${binary}" | grep -Eq 'ELF 64-bit.*ARM aarch64' || die "ipset 不是 arm64 ELF"
    "${ndk_bin}/llvm-readelf" -l "${binary}" | grep -Fq 'Requesting program interpreter: /system/bin/linker64' || \
        die "ipset Android linker ABI 不匹配"
    needed="$("${ndk_bin}/llvm-readelf" -d "${binary}" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | LC_ALL=C sort -u)"
    unexpected_needed="$(printf '%s\n' "${needed}" | grep -Ev '^(libc\.so|libdl\.so)$' || true)"
    [ -z "${unexpected_needed}" ] || die "ipset 含非 Android 系统共享库依赖: ${unexpected_needed}"
    printf '%s\n' "${needed}" | grep -Fxq 'libc.so' || die "ipset 缺少 Android libc 依赖标识"
    strings "${binary}" | grep -Fx 'ipset' >/dev/null || die "ipset 二进制命令标识缺失"
    strings "${binary}" | grep -Fx "${IPSET_VERSION}" >/dev/null || die "ipset 二进制版本标识不匹配"

    cp -f "${binary}" "${PRODUCT_DIR}/ipset-arm64-v${IPSET_VERSION}"
    chmod 0755 "${PRODUCT_DIR}/ipset-arm64-v${IPSET_VERSION}"
    module_dir="$(mktemp -d "${BUILD_DIR}/ipset-module.XXXXXX")"
    mkdir -p "${module_dir}/system/bin" "${module_dir}/LICENSES"
    cp -a "${HOST_WORKSPACE_DIR}/userspace/ipset_module/." "${module_dir}/"
    cp -f "${binary}" "${module_dir}/system/bin/ipset"
    cp -f "${IPSET_DIR}/COPYING" "${module_dir}/LICENSES/COPYING.ipset"
    cp -f "${LIBMNL_DIR}/COPYING" "${module_dir}/LICENSES/COPYING.libmnl"
    chmod 0755 "${module_dir}/customize.sh" "${module_dir}/system/bin/ipset"
    module_zip="${PRODUCT_DIR}/ipset-v${IPSET_VERSION}-android-arm64-kernelsu-module.zip"
    (cd "${module_dir}" && 7z a -tzip "${module_zip}" . >/dev/null)
    unzip -p "${module_zip}" system/bin/ipset | sha256sum | \
        grep -Fx "$(sha256sum "${binary}" | awk '{ print $1 }')  -" >/dev/null || die "IPSet 模块内命令校验失败"
    case "${module_dir}" in "${BUILD_DIR}"/ipset-module.*) rm -rf -- "${module_dir}" ;; *) die "拒绝清理异常临时目录" ;; esac
    log_success "IPSet 用户态命令与独立 KernelSU 模块已生成: $(basename "${module_zip}")"
}

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "${SCRIPT_SOURCE}")"
HOST_WORKSPACE_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")" && pwd -P)"

load_env_file "${HOST_WORKSPACE_DIR}/.env"

WORKSPACE_NAME="$(sanitize_path_component "$(basename "${HOST_WORKSPACE_DIR}")")"
WORKSPACE_NAME="${WORKSPACE_NAME:-workspace}"
ORB_LINUX_ROOT="${ORB_LINUX_ROOT:-.cache/xiaomi_kernel_build}"
ORB_LINUX_PROJECT="${ORB_LINUX_ROOT%/}/${WORKSPACE_NAME}"
ORB_LINUX_WORKSPACE="${ORB_LINUX_PROJECT}/workspace"
ORB_LINUX_OUTBOX="${ORB_LINUX_PROJECT}/outbox"
ORB_RESULT_ARCHIVE="${SCRIPT_NAME%.sh}-result.tar"
ARTIFACT_MANIFEST_NAME=".build-artifacts"

BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-kernel_out}"
PRODUCT_DIR="${HOST_WORKSPACE_DIR}/${BUILD_OUTPUT_DIR}"

resolve_project_identity
run_in_orb_if_needed "$@"

KERNEL_REPO="${KERNEL_REPO:-https://github.com/MiCode/Xiaomi_Kernel_OpenSource.git}"
KERNEL_COMMIT="${KERNEL_COMMIT:-45705be1220b4cfa8100516ad86711656c0b634e}"
SOC_DIR="$(resolve_workspace_path "${SOC_SOURCE_DIR:-sources/xiaomi_sm8850_soc}")"
COMMON_REPO="${COMMON_REPO:-https://android.googlesource.com/kernel/common}"
COMMON_BRANCH="${COMMON_BRANCH:-android16-6.12-2025-06_r57}"
COMMON_COMMIT="${COMMON_COMMIT:-a82fc641d6d2c687802606190c0a8c33a4242201}"
COMMON_DIR="$(resolve_workspace_path "${COMMON_SOURCE_DIR:-sources/aosp_common_6.12.23_r57}")"
ENABLE_KERNELSU="${ENABLE_KERNELSU:-0}"
KSU_REPO="${KSU_REPO:-https://github.com/tiann/KernelSU.git}"
KSU_REF="${KSU_REF:-v3.2.5}"
KSU_COMMIT="${KSU_COMMIT:-b0bc817b4e966aa6aa830834eaf6ef765d821d40}"
KSU_DIR="$(resolve_workspace_path "${KSU_SOURCE_DIR:-sources/kernelsu}")"
KSU_INTEGRATION_MODE="${KSU_INTEGRATION_MODE:-builtin}"
KSU_GIT_VERSION_COUNT="${KSU_GIT_VERSION_COUNT:-2525}"
KSU_VERSION_CODE="${KSU_VERSION_CODE:-32525}"
KSU_SELINUX_HIDE_FIX_COMMIT="${KSU_SELINUX_HIDE_FIX_COMMIT:-3f388ef137c78e1ca0c92c0ada3b8717cdcc4302}"
KSU_ENHANCED_SECURITY_REMOVAL_COMMIT="${KSU_ENHANCED_SECURITY_REMOVAL_COMMIT:-1b6e2ed6b38dad1c8af90402a82ed2f752b05cfa}"
KSU_MANAGER_APK="${KSU_MANAGER_APK:-KernelSU_v3.2.5_32525-release.apk}"
KSU_MANAGER_SHA256="${KSU_MANAGER_SHA256:-1417081413bf7ab1de8e440ecbcb62685037c8f28f048f0f8b79e305b31ab916}"
ENABLE_SUSFS="${ENABLE_SUSFS:-0}"
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_REF="${SUSFS_REF:-gki-android16-6.12}"
SUSFS_COMMIT="${SUSFS_COMMIT:-d9a486dc7197800149c31fe35a77997ea0ddaa83}"
SUSFS_DIR="$(resolve_workspace_path "${SUSFS_SOURCE_DIR:-sources/susfs4ksu}")"
SUSFS_KSU_PATCH_COMMIT="${SUSFS_KSU_PATCH_COMMIT:-ef69c8322232340f43c78c7fc491b32cb9f7da86}"
SUSFS_HELPER_SHA256="${SUSFS_HELPER_SHA256:-dfa9a11f45c2978789175c3ad15290a831639248d159c34980e27c36f92b833c}"
SUSFS_HOOKS_ADAPTATION="${HOST_WORKSPACE_DIR}/patches/susfs/aosp-r57-selinux-hooks.patch"
ENABLE_BBG="${ENABLE_BBG:-0}"
BBG_REPO="${BBG_REPO:-https://github.com/vc-teahouse/Baseband-guard.git}"
BBG_REF="${BBG_REF:-main}"
BBG_COMMIT="${BBG_COMMIT:-1c664957da7539de860503940ee73c7447f1dfaf}"
BBG_DIR="$(resolve_workspace_path "${BBG_SOURCE_DIR:-sources/baseband_guard}")"
BBG_LSM_COUNT_PATCH="${HOST_WORKSPACE_DIR}/patches/bbg/aosp-r57-lsm-count.patch"
ENABLE_STAGE4_FS="${ENABLE_STAGE4_FS:-0}"
AOSP_BACKPORT_AUDIT_DIR="$(resolve_workspace_path "${AOSP_BACKPORT_AUDIT_SOURCE_DIR:-sources/aosp_common_backport_audit}")"
LINUX_STABLE_AUDIT_DIR="$(resolve_workspace_path "${LINUX_STABLE_AUDIT_SOURCE_DIR:-sources/linux_stable_6.12_audit}")"
ENABLE_FUTEX_EXITING_POINTER_FIX="${ENABLE_FUTEX_EXITING_POINTER_FIX:-0}"
FUTEX_EXITING_POINTER_STABLE_COMMIT="${FUTEX_EXITING_POINTER_STABLE_COMMIT:-7475dfad10a05a5bfadebf5f2499bd61b19ed293}"
FUTEX_EXITING_POINTER_PATCH_ID="${FUTEX_EXITING_POINTER_PATCH_ID:-419d86818387f958327185e62d1581e20b357a1d}"
ENABLE_FUTEX_REQUEUE_PI_LOCKUP_FIX="${ENABLE_FUTEX_REQUEUE_PI_LOCKUP_FIX:-0}"
FUTEX_REQUEUE_PI_LOCKUP_STABLE_COMMIT="${FUTEX_REQUEUE_PI_LOCKUP_STABLE_COMMIT:-0aacb6d18f76552e3e0ee25d9f40d21b3486f4cf}"
FUTEX_REQUEUE_PI_LOCKUP_PATCH_ID="${FUTEX_REQUEUE_PI_LOCKUP_PATCH_ID:-88d19e4a03bfc1fdc6b126a65489e9d62eae2780}"
ENABLE_F2FS_ACL_ENTRY_BOUNDS_FIX="${ENABLE_F2FS_ACL_ENTRY_BOUNDS_FIX:-0}"
F2FS_ACL_ENTRY_BOUNDS_STABLE_COMMIT="${F2FS_ACL_ENTRY_BOUNDS_STABLE_COMMIT:-aba4f94ac1832c7299c33e1b4fe5f87eef6dc8f1}"
F2FS_ACL_ENTRY_BOUNDS_PATCH_ID="${F2FS_ACL_ENTRY_BOUNDS_PATCH_ID:-3021795cf81293828302c01bb7d52bb4d52a7259}"
ENABLE_F2FS_LISTXATTR_BOUNDS_FIX="${ENABLE_F2FS_LISTXATTR_BOUNDS_FIX:-0}"
F2FS_LISTXATTR_BOUNDS_STABLE_COMMIT="${F2FS_LISTXATTR_BOUNDS_STABLE_COMMIT:-7dd01f7d0291583e3e5420c95c7d584e114899bd}"
F2FS_LISTXATTR_BOUNDS_PATCH_ID="${F2FS_LISTXATTR_BOUNDS_PATCH_ID:-daaf1f38e2ef4939e6981e7a563c1a488225a11c}"
ENABLE_BLKCG_RSTAT_RELEASE_FIX="${ENABLE_BLKCG_RSTAT_RELEASE_FIX:-0}"
BLKCG_RSTAT_RELEASE_STABLE_COMMIT="${BLKCG_RSTAT_RELEASE_STABLE_COMMIT:-bbebd9425cad3573d1527441753899b926525a0f}"
BLKCG_RSTAT_RELEASE_PATCH_ID="${BLKCG_RSTAT_RELEASE_PATCH_ID:-5149120b23c377e425b11bfdcb1933e39245a1c7}"
ENABLE_BINDER_TRANSACTION_LIFETIME_FIX="${ENABLE_BINDER_TRANSACTION_LIFETIME_FIX:-0}"
BINDER_THREAD_RELEASE_STABLE_COMMIT="${BINDER_THREAD_RELEASE_STABLE_COMMIT:-e63032dc715026a96bcaa13d375a8e15c91caa84}"
BINDER_THREAD_RELEASE_PATCH_ID="${BINDER_THREAD_RELEASE_PATCH_ID:-bf97fd8b894461ca62445978f4f6422c736611b3}"
BINDER_FREE_TRANSACTION_STABLE_COMMIT="${BINDER_FREE_TRANSACTION_STABLE_COMMIT:-d45ef513eed1abebfec90c3cfb6ae50c2a4182db}"
BINDER_FREE_TRANSACTION_PATCH_ID="${BINDER_FREE_TRANSACTION_PATCH_ID:-5c23abbc83c1a297d19eb039610151fb377ea188}"
BINDER_TRANSACTION_LIFETIME_PATCH="${HOST_WORKSPACE_DIR}/${BINDER_TRANSACTION_LIFETIME_PATCH:-patches/backports/binder-transaction-lifetime-6.12.23.patch}"
BINDER_TRANSACTION_LIFETIME_PATCH_SHA256="${BINDER_TRANSACTION_LIFETIME_PATCH_SHA256:-d3d428c044437c216bf75bbe45e01cd74e780f4685586c08a2e6b3d1d2ac83d3}"
BINDER_TRANSACTION_LIFETIME_PATCH_ID="${BINDER_TRANSACTION_LIFETIME_PATCH_ID:-7d9a01598e58b1f513fcfbe481dc682bd62c1f5c}"
ENABLE_F2FS_FOREGROUND_GC_DEADLOCK_FIX="${ENABLE_F2FS_FOREGROUND_GC_DEADLOCK_FIX:-0}"
F2FS_FOREGROUND_GC_DEADLOCK_STABLE_COMMIT="${F2FS_FOREGROUND_GC_DEADLOCK_STABLE_COMMIT:-44480f7e3f8369671452c0d262831c51aa5a9c20}"
F2FS_FOREGROUND_GC_DEADLOCK_PATCH_ID="${F2FS_FOREGROUND_GC_DEADLOCK_PATCH_ID:-8d86d1f0ff47ad109628af8462bd4506c81dd4f6}"
F2FS_GC_MERGE_DEADLOCK_STABLE_COMMIT="${F2FS_GC_MERGE_DEADLOCK_STABLE_COMMIT:-b885c7783c19c36c7bf899492a0bffcd68afa8c7}"
F2FS_GC_MERGE_DEADLOCK_PATCH_ID="${F2FS_GC_MERGE_DEADLOCK_PATCH_ID:-f1e7da7bf78fadbfd5f41ae8f1d1b196ee96b98d}"
ENABLE_F2FS_ATOMIC_INODE_UAF_FIX="${ENABLE_F2FS_ATOMIC_INODE_UAF_FIX:-0}"
F2FS_ATOMIC_INODE_UAF_STABLE_COMMIT="${F2FS_ATOMIC_INODE_UAF_STABLE_COMMIT:-56038756aae68312df00d4aa1d97e51ef3aca725}"
F2FS_ATOMIC_INODE_UAF_PATCH_ID="${F2FS_ATOMIC_INODE_UAF_PATCH_ID:-fcedf0927ac32abbbc60de374663dc3fec18869d}"
ENABLE_UFS_RUNTIME_PM_ERROR_RECOVERY_FIX="${ENABLE_UFS_RUNTIME_PM_ERROR_RECOVERY_FIX:-0}"
UFS_RUNTIME_SUSPEND_DEADLOCK_AOSP_COMMIT="${UFS_RUNTIME_SUSPEND_DEADLOCK_AOSP_COMMIT:-7ef00d3457d8c9cee0915ee0edff247031c36e0c}"
UFS_RUNTIME_SUSPEND_DEADLOCK_PATCH_ID="${UFS_RUNTIME_SUSPEND_DEADLOCK_PATCH_ID:-d50c32d5918d030180b869f67a0ccd412b62209e}"
UFS_ERROR_HANDLER_HOST_SEM_AOSP_COMMIT="${UFS_ERROR_HANDLER_HOST_SEM_AOSP_COMMIT:-459c818f8b5a562c34a27b915fae53792fa82a71}"
UFS_ERROR_HANDLER_HOST_SEM_PATCH_ID="${UFS_ERROR_HANDLER_HOST_SEM_PATCH_ID:-32e05876eba86a6181f7f2cbc538f2fb73e63528}"
UFS_ERROR_HANDLER_WLUN_AOSP_COMMIT="${UFS_ERROR_HANDLER_WLUN_AOSP_COMMIT:-a460b437af44c3317a57e637455ee891d0ee0352}"
UFS_ERROR_HANDLER_WLUN_PATCH_ID="${UFS_ERROR_HANDLER_WLUN_PATCH_ID:-b4ec70973aaeef49650271cffd241533d63fac57}"
UFS_RUNTIME_PM_ERROR_RECOVERY_PATCH="${HOST_WORKSPACE_DIR}/${UFS_RUNTIME_PM_ERROR_RECOVERY_PATCH:-patches/backports/ufs-runtime-pm-error-recovery-6.12.23.patch}"
UFS_RUNTIME_PM_ERROR_RECOVERY_PATCH_SHA256="${UFS_RUNTIME_PM_ERROR_RECOVERY_PATCH_SHA256:-2b29d2d00f657e518d28361c095e311fbd8cbb31bc6275f641c85587a164eb2a}"
UFS_RUNTIME_PM_ERROR_RECOVERY_PATCH_ID="${UFS_RUNTIME_PM_ERROR_RECOVERY_PATCH_ID:-35f93b5023c3f14d3616f1a3afc236f36c84b11f}"
ENABLE_TIMER_BASE_FAST_PATH="${ENABLE_TIMER_BASE_FAST_PATH:-0}"
TIMER_BASE_FAST_PATH_COMMIT="${TIMER_BASE_FAST_PATH_COMMIT:-3ec955713d9617059d2fc8f2816d0b95ace72256}"
TIMER_BASE_FAST_PATH_PATCH_ID="${TIMER_BASE_FAST_PATH_PATCH_ID:-68dca003ed5b13fb40d3b777155c6568438563ef}"
ENABLE_F2FS_DIO_OVERWRITE_FAST_PATH="${ENABLE_F2FS_DIO_OVERWRITE_FAST_PATH:-0}"
F2FS_DIO_OVERWRITE_FAST_PATH_COMMIT="${F2FS_DIO_OVERWRITE_FAST_PATH_COMMIT:-d860974a7e38d35e9e2c4dc8a9f4223b38b6ad99}"
F2FS_DIO_OVERWRITE_FAST_PATH_PATCH_ID="${F2FS_DIO_OVERWRITE_FAST_PATH_PATCH_ID:-fec231f96375f0622cf9bd9427ef2baf5614ac03}"
ENABLE_EAS_CPUMASK_FAST_PATH="${ENABLE_EAS_CPUMASK_FAST_PATH:-0}"
EAS_CPUMASK_FAST_PATH_COMMIT="${EAS_CPUMASK_FAST_PATH_COMMIT:-ff1de90dd7a69ef43586683535ad87ab899a1214}"
EAS_CPUMASK_FAST_PATH_PATCH_ID="${EAS_CPUMASK_FAST_PATH_PATCH_ID:-26fce9484b896c6e1c89b30faf18e6790b2a005d}"
ENABLE_BLK_WBT_DONE_FAST_PATH="${ENABLE_BLK_WBT_DONE_FAST_PATH:-0}"
BLK_WBT_DONE_FAST_PATH_COMMIT="${BLK_WBT_DONE_FAST_PATH_COMMIT:-d8b96a79622e03813c221450498ca9742704ebf2}"
BLK_WBT_DONE_FAST_PATH_PATCH_ID="${BLK_WBT_DONE_FAST_PATH_PATCH_ID:-097d27325d53feb894b26bb0c7e152fca314e7b9}"
ENABLE_F2FS_OPEN_FAST_PATH="${ENABLE_F2FS_OPEN_FAST_PATH:-0}"
F2FS_OPEN_FAST_PATH_COMMIT="${F2FS_OPEN_FAST_PATH_COMMIT:-f6e898257b3d6a3a52d4bff5cec6237eebe1ce7d}"
F2FS_OPEN_FAST_PATH_PATCH_ID="${F2FS_OPEN_FAST_PATH_PATCH_ID:-685b528beff90bac24b8f54e12238442363a80df}"
ENABLE_MEMCG_RSTAT_FAST_PATH="${ENABLE_MEMCG_RSTAT_FAST_PATH:-0}"
MEMCG_RSTAT_FAST_PATH_COMMIT="${MEMCG_RSTAT_FAST_PATH_COMMIT:-60cada258dfe3694e15c4539259173c37bd5f1fe}"
MEMCG_RSTAT_FAST_PATH_PATCH_ID="${MEMCG_RSTAT_FAST_PATH_PATCH_ID:-5b12701394b4f6a128f5456e3bd8fed4f8740c27}"
ENABLE_TCP_RECV_MSTAMP_FAST_PATH="${ENABLE_TCP_RECV_MSTAMP_FAST_PATH:-0}"
TCP_RECV_MSTAMP_FAST_PATH_COMMIT="${TCP_RECV_MSTAMP_FAST_PATH_COMMIT:-0ae1ac7335ca2328c42fbbe2b71bc9c3fc8e65d9}"
TCP_RECV_MSTAMP_FAST_PATH_PATCH_ID="${TCP_RECV_MSTAMP_FAST_PATH_PATCH_ID:-66387ee17b01507a8f2a2b6537c9f7e22c86b509}"
ENABLE_F2FS_MERGE_PAGE_BIO_UAF_FIX="${ENABLE_F2FS_MERGE_PAGE_BIO_UAF_FIX:-0}"
F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT="${F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT:-f2f676a2f21637b39f7f2be2f6137c1d9570d3e7}"
F2FS_MERGE_PAGE_BIO_UAF_FIX_PATCH_ID="${F2FS_MERGE_PAGE_BIO_UAF_FIX_PATCH_ID:-ae11e76a9f7b489004102506a0896e0894ae681f}"
ENABLE_GUNYAH_CLEAN_RESOURCES_UAF_FIX="${ENABLE_GUNYAH_CLEAN_RESOURCES_UAF_FIX:-0}"
GUNYAH_CLEAN_RESOURCES_UAF_FIX_COMMIT="${GUNYAH_CLEAN_RESOURCES_UAF_FIX_COMMIT:-e5a17398e40d988ce7e9c79259eb8b08b5377b43}"
GUNYAH_CLEAN_RESOURCES_UAF_FIX_PATCH_ID="${GUNYAH_CLEAN_RESOURCES_UAF_FIX_PATCH_ID:-b422a66e01ad0e4046dedafc81785fc8b4a9ff57}"
ENABLE_IDLETIMER_DESTROY_UAF_FIX="${ENABLE_IDLETIMER_DESTROY_UAF_FIX:-0}"
IDLETIMER_DESTROY_UAF_FIX_COMMIT="${IDLETIMER_DESTROY_UAF_FIX_COMMIT:-9317fe019b5be27e888f02629a3de1f4d78cb1aa}"
IDLETIMER_DESTROY_UAF_FIX_PATCH_ID="${IDLETIMER_DESTROY_UAF_FIX_PATCH_ID:-2e6c62f1168d9eb5163373eac35801caa4d4a631}"
ENABLE_EVENTPOLL_RCU_UAF_FIX="${ENABLE_EVENTPOLL_RCU_UAF_FIX:-0}"
EVENTPOLL_RCU_UAF_FIX_COMMIT="${EVENTPOLL_RCU_UAF_FIX_COMMIT:-5b1173b165421561db29f30afc7e97d940a398a9}"
EVENTPOLL_RCU_UAF_FIX_PATCH_ID="${EVENTPOLL_RCU_UAF_FIX_PATCH_ID:-a5abf8e11ad85b58f2924d8bd693b8b644462f6a}"
ENABLE_CGROUP_KERNFS_UAF_FIX="${ENABLE_CGROUP_KERNFS_UAF_FIX:-0}"
CGROUP_KERNFS_UAF_FIX_COMMIT="${CGROUP_KERNFS_UAF_FIX_COMMIT:-993047031c9fcb7f4a58389692e844f7be423cc7}"
CGROUP_KERNFS_UAF_FIX_PATCH_ID="${CGROUP_KERNFS_UAF_FIX_PATCH_ID:-7fb683b637d0db664c6c37667692c27127a28dd1}"
ENABLE_F2FS_SYNC_INODE_META_UAF_FIX="${ENABLE_F2FS_SYNC_INODE_META_UAF_FIX:-0}"
F2FS_SYNC_INODE_META_UAF_FIX_COMMIT="${F2FS_SYNC_INODE_META_UAF_FIX_COMMIT:-dea243f58a8391e76f42ad5eb59ff210519ee772}"
F2FS_SYNC_INODE_META_UAF_FIX_PATCH_ID="${F2FS_SYNC_INODE_META_UAF_FIX_PATCH_ID:-41eeded4f38919c5bffa8aef0c8b9b2468346b9d}"
ENABLE_TIMER_SHUTDOWN_SYNC_RACE_FIX="${ENABLE_TIMER_SHUTDOWN_SYNC_RACE_FIX:-0}"
TIMER_SHUTDOWN_SYNC_RACE_FIX_COMMIT="${TIMER_SHUTDOWN_SYNC_RACE_FIX_COMMIT:-176725f4848376530a0f0da9023f956afcc33585}"
TIMER_SHUTDOWN_SYNC_RACE_FIX_PATCH_ID="${TIMER_SHUTDOWN_SYNC_RACE_FIX_PATCH_ID:-e528717d3d19cb12b0d9ac96781075350fdf4dae}"
ENABLE_FUTEX_REQUEUE_PI_UAF_FIX="${ENABLE_FUTEX_REQUEUE_PI_UAF_FIX:-0}"
FUTEX_REQUEUE_PI_UAF_FIX_COMMIT="${FUTEX_REQUEUE_PI_UAF_FIX_COMMIT:-a170b9c0dde83312b8b58ccc91509c7c15711641}"
FUTEX_REQUEUE_PI_UAF_FIX_PATCH_ID="${FUTEX_REQUEUE_PI_UAF_FIX_PATCH_ID:-8a1bf4596581bd162f4acb909b7ee859ca2c7afa}"
ENABLE_PAGE_POOL_DESTROY_RACE_FIX="${ENABLE_PAGE_POOL_DESTROY_RACE_FIX:-0}"
PAGE_POOL_DESTROY_RACE_FIX_COMMIT="${PAGE_POOL_DESTROY_RACE_FIX_COMMIT:-e869a85acc2e60dc554579b910826a4919d8cd98}"
PAGE_POOL_DESTROY_RACE_FIX_PATCH_ID="${PAGE_POOL_DESTROY_RACE_FIX_PATCH_ID:-dad3ca58feaaae658e77c9e001250fed18853b1e}"
ENABLE_CONNTRACK_UNCONFIRMED_RACE_FIX="${ENABLE_CONNTRACK_UNCONFIRMED_RACE_FIX:-0}"
CONNTRACK_UNCONFIRMED_RACE_FIX_COMMIT="${CONNTRACK_UNCONFIRMED_RACE_FIX_COMMIT:-fc38c249c622ff5e3011b8845fd49dbfd9289afc}"
CONNTRACK_UNCONFIRMED_RACE_FIX_PATCH_ID="${CONNTRACK_UNCONFIRMED_RACE_FIX_PATCH_ID:-37b80fce84a874c3917935828ffbb6b74b3a8ee6}"
ENABLE_EROFS_DIR_TAIL_OOB_FIX="${ENABLE_EROFS_DIR_TAIL_OOB_FIX:-0}"
EROFS_DIR_TAIL_OOB_FIX_COMMIT="${EROFS_DIR_TAIL_OOB_FIX_COMMIT:-48b27a955d22391c7f30169fa7b6b2e1977f1ce4}"
EROFS_DIR_TAIL_OOB_FIX_PATCH_ID="${EROFS_DIR_TAIL_OOB_FIX_PATCH_ID:-86095c51c9af49433ddbba4d32f194c2d3a7a6da}"
ENABLE_EXT4_XATTR_OOB_FIX="${ENABLE_EXT4_XATTR_OOB_FIX:-0}"
EXT4_XATTR_OOB_FIX_COMMIT="${EXT4_XATTR_OOB_FIX_COMMIT:-5a5314d2387633a272a04d1bd8727f99058e4e68}"
EXT4_XATTR_OOB_FIX_PATCH_ID="${EXT4_XATTR_OOB_FIX_PATCH_ID:-98a7513db9abe6f0c8c0713c9e03bca09d99af6c}"
ENABLE_IPV6_MLD_UAF_FIX="${ENABLE_IPV6_MLD_UAF_FIX:-0}"
IPV6_MLD_UAF_FIX_COMMIT="${IPV6_MLD_UAF_FIX_COMMIT:-791c91dc7a9dfb2457d5e29b8216a6484b9c4b40}"
IPV6_MLD_UAF_FIX_PATCH_ID="${IPV6_MLD_UAF_FIX_PATCH_ID:-1358ebc3d619657f50c2f0f50f5408f60ea5b732}"
ENABLE_RTMUTEX_WAITER_ENQUEUE_FIX="${ENABLE_RTMUTEX_WAITER_ENQUEUE_FIX:-0}"
RTMUTEX_WAITER_ENQUEUE_FIX_COMMIT="${RTMUTEX_WAITER_ENQUEUE_FIX_COMMIT:-202a62288cb6884f0bdcea8a8d47a1a8c4d3e143}"
RTMUTEX_WAITER_ENQUEUE_FIX_PATCH_ID="${RTMUTEX_WAITER_ENQUEUE_FIX_PATCH_ID:-0d78a126f83be68e6f97baae61550baacc3a2ecc}"
RTMUTEX_FIX_STACK_PATCH_ID="${RTMUTEX_FIX_STACK_PATCH_ID:-91738174f7b3c38cc0cfc8f7b2157aa1fb648a2a}"
ENABLE_STAGE5_RTMUTEX_FIX="${ENABLE_STAGE5_RTMUTEX_FIX:-0}"
STAGE5_RTMUTEX_FIX_COMMIT="${STAGE5_RTMUTEX_FIX_COMMIT:-e7d9bd94fbdbf9842ea6f1b6d5af45758e87e3d6}"
STAGE5_RTMUTEX_FIX_PATCH_ID="${STAGE5_RTMUTEX_FIX_PATCH_ID:-bd48afa70647e92db0e44335fbe75d2b520671a6}"
ENABLE_UNICODE_IGNORABLE_FIX="${ENABLE_UNICODE_IGNORABLE_FIX:-0}"
UNICODE_FIX_COMMIT="${UNICODE_FIX_COMMIT:-425419e5b2a8c88096b8bbc61d8865600d1a91c0}"
UNICODE_FIX_PATCH_ID="${UNICODE_FIX_PATCH_ID:-8bad10993f9d6df5a0130e8394608f4550904bbd}"
UNICODE_EXT4_COMPAT_COMMIT="${UNICODE_EXT4_COMPAT_COMMIT:-aa66603ddf1b22e65992ae893c76a0224a4dd415}"
UNICODE_EXT4_COMPAT_PATCH_ID="${UNICODE_EXT4_COMPAT_PATCH_ID:-30a2d2ee185826e104434ab83b75c546dfd87900}"
UNICODE_FIX_PATCH="${HOST_WORKSPACE_DIR}/${UNICODE_FIX_PATCH:-patches/unicode/aosp-6.12.23-default-ignorable-compat.patch}"
UNICODE_FIX_PATCH_SHA256="${UNICODE_FIX_PATCH_SHA256:-7bc109d9858c14c78dfdbaadd4be3ff16188e919ee49f4f48981362529d226e3}"
UNICODE_SELFTEST_PATCH="${HOST_WORKSPACE_DIR}/${UNICODE_SELFTEST_PATCH:-patches/unicode/unicode-12.1-default-ignorable-selftest.patch}"
UNICODE_SELFTEST_PATCH_SHA256="${UNICODE_SELFTEST_PATCH_SHA256:-ae0613638230c51ce95563783b307f1ca96efde0e73ada540c14f037438f8acd}"
UNICODE_SELFTEST_EXPECTED_TESTS="${UNICODE_SELFTEST_EXPECTED_TESTS:-87668}"
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
ENABLE_STAGE5_NAMESPACES="${ENABLE_STAGE5_NAMESPACES:-0}"
ENABLE_STAGE5_NETWORK="${ENABLE_STAGE5_NETWORK:-0}"
ENABLE_IPSET="${ENABLE_IPSET:-0}"
IPSET_VERSION="${IPSET_VERSION:-7.24}"
IPSET_SHA512="${IPSET_SHA512:-18ccb49bd38083f0556b11e1d17f43791c52a2b094c9a500b6f770796b17e8e70c3860a628eac2252eb672b1fc9de734d3a0e0823d61dd9be7b4188adc6dd214}"
IPSET_TREE_SHA256="${IPSET_TREE_SHA256:-70530678f3318aad36a3fb8acb3eba17a27ad5e464c0caeb8912dee43f0a81ea}"
IPSET_DIR="$(resolve_workspace_path "${IPSET_SOURCE_DIR:-sources/ipset-7.24}")"
LIBMNL_VERSION="${LIBMNL_VERSION:-1.0.5}"
LIBMNL_SHA256="${LIBMNL_SHA256:-274b9b919ef3152bfb3da3a13c950dd60d6e2bcd54230ffeca298d03b40d0525}"
LIBMNL_TREE_SHA256="${LIBMNL_TREE_SHA256:-8d6597fd107489c8d90106d99302ff5efb061fe38bb3952f8a1062626b80a7c2}"
LIBMNL_DIR="$(resolve_workspace_path "${LIBMNL_SOURCE_DIR:-sources/libmnl-1.0.5}")"
ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION:-r29}"
ANDROID_NDK_TREE_SHA256="${ANDROID_NDK_TREE_SHA256:-401eb9a77478012fdc0c31e986379bf04db9fd72455b060dd13fcce07b84b98e}"
ANDROID_NDK_API="${ANDROID_NDK_API:-35}"
XIAOMI_ACK_BRANCH="${XIAOMI_ACK_BRANCH:-android16-6.12-2025-06_r8}"
XIAOMI_ACK_COMMIT="${XIAOMI_ACK_COMMIT:-f1bdb13583da85a47fcf1632a78ef52d6e6da651}"

verify_repo_identity "Xiaomi popsicle soc-repo" "${SOC_DIR}" "${KERNEL_REPO}" "${KERNEL_COMMIT}"
verify_repo_identity "Android 16 GKI common" "${COMMON_DIR}" "${COMMON_REPO}" "${COMMON_COMMIT}" "0"
verify_first_batch_linux_backports
verify_second_batch_backports
verify_f2fs_open_fast_path
verify_memcg_rstat_fast_path
verify_tcp_recv_mstamp_fast_path
verify_f2fs_merge_page_bio_uaf_fix
verify_gunyah_clean_resources_uaf_fix
verify_idletimer_destroy_uaf_fix
verify_eventpoll_rcu_uaf_fix
verify_cgroup_kernfs_uaf_fix
verify_f2fs_sync_inode_meta_uaf_fix
verify_timer_shutdown_sync_race_fix
verify_futex_requeue_pi_uaf_fix
verify_page_pool_destroy_race_fix
verify_conntrack_unconfirmed_race_fix
verify_erofs_dir_tail_oob_fix
verify_ext4_xattr_oob_fix
verify_ipv6_mld_uaf_fix
verify_rtmutex_waiter_enqueue_fix
verify_stage5_rtmutex_fix
verify_unicode_ignorable_fix
verify_adios_source_state
verify_tcp_brutal_source_state
[ "${ENABLE_KERNELSU}" != "1" ] || verify_kernelsu_source_state
[ "${ENABLE_SUSFS}" != "1" ] || verify_susfs_source_state
[ "${ENABLE_BBG}" != "1" ] || verify_bbg_source_state
[ "$(sed -n '1p' "${SOC_DIR}/android/ACK_SHA")" = "${XIAOMI_ACK_COMMIT}" ] || die "小米 ACK_SHA commit 已变化"
[ "$(sed -n '2p' "${SOC_DIR}/android/ACK_SHA")" = "${XIAOMI_ACK_BRANCH}" ] || die "小米 ACK_SHA tag 已变化"

BUILD_JOBS="$(detect_cpu_count)"
BUILD_DIR="${BUILD_DIR:-/tmp/xiaomi_sm8850_gki_61223_build_out}"
KMI_CONFIG_MIN_LINES="${KMI_CONFIG_MIN_LINES:-8000}"
STAGE_CONFIG_LINES="${STAGE_CONFIG_LINES:-}"
STAGE_CONFIG_SHA256="${STAGE_CONFIG_SHA256:-}"
STAGE_MODULE_COUNT="${STAGE_MODULE_COUNT:-}"
STAGE_MODULES_ORDER_SHA256="${STAGE_MODULES_ORDER_SHA256:-}"
VENDOR_KMI_BASELINE_COUNT="${VENDOR_KMI_BASELINE_COUNT:-4517}"
VENDOR_KMI_BASELINE_SHA256="${VENDOR_KMI_BASELINE_SHA256:-5980570208c7617a89e50f3b1cdf2fcd981f777cd249338fd2bec0071be8935b}"
STAGE_ABI_EXPORT_COUNT="${STAGE_ABI_EXPORT_COUNT:-}"
STAGE_ABI_SHA256="${STAGE_ABI_SHA256:-}"
STAGE_ABI_STG_SHA256="${STAGE_ABI_STG_SHA256:-}"
LUNA_PROJECT_SHORT="${LUNA_PROJECT_COMMIT:0:8}"
KERNEL_LOCALVERSION="-android16-luna-g${LUNA_PROJECT_SHORT}-4k"
KERNEL_BUILD_USER="${KERNEL_BUILD_USER:-luna}"
KERNEL_BUILD_HOST="${KERNEL_BUILD_HOST:-luna-build}"
KERNEL_BUILD_TIMESTAMP="${KERNEL_BUILD_TIMESTAMP:-2026-06-01 18:52:16 HKT}"
KERNEL_BUILD_VERSION="${KERNEL_BUILD_VERSION:-1}"
AK3_BOOT_PARTITION_SIZE="${AK3_BOOT_PARTITION_SIZE:-100663296}"
AK3_UPSTREAM_COMMIT="${AK3_UPSTREAM_COMMIT:-}"
AK3_ARM64_TOOLS_COMMIT="${AK3_ARM64_TOOLS_COMMIT:-}"
AK3_BUSYBOX_SHA256="${AK3_BUSYBOX_SHA256:-}"
AK3_ANYKERNEL_SH_SHA256="${AK3_ANYKERNEL_SH_SHA256:-}"
AK3_UPDATE_BINARY_SHA256="${AK3_UPDATE_BINARY_SHA256:-}"
AK3_UPDATER_SCRIPT_SHA256="${AK3_UPDATER_SCRIPT_SHA256:-}"
AK3_CORE_SHA256="${AK3_CORE_SHA256:-}"
AK3_LICENSE_SHA256="${AK3_LICENSE_SHA256:-}"
AK3_LUNA_PATCH_SHA256="${AK3_LUNA_PATCH_SHA256:-}"
AK3_LUNA_ANYKERNEL_SH_SHA256="${AK3_LUNA_ANYKERNEL_SH_SHA256:-}"
AK3_LUNA_UPDATE_BINARY_SHA256="${AK3_LUNA_UPDATE_BINARY_SHA256:-}"
AK3_LUNA_UPDATER_SCRIPT_SHA256="${AK3_LUNA_UPDATER_SCRIPT_SHA256:-}"
AK3_LUNA_CORE_SHA256="${AK3_LUNA_CORE_SHA256:-}"
MAGISK_VERSION="${MAGISK_VERSION:-30.7}"
MAGISK_COMMIT="${MAGISK_COMMIT:-e8a58776f1d7bdf852072ad0baa6eceb9a1e4aac}"
MAGISKBOOT_ARM64_SHA256="${MAGISKBOOT_ARM64_SHA256:-d7440e2cd89899426e809554bf793baef9804ccbe5a52ce34a8b6242725d3c77}"
[ "${KERNEL_BUILD_USER}" = "luna" ] || die "内核构建用户必须固定为 luna"
[ "${KERNEL_BUILD_HOST}" = "luna-build" ] || die "内核构建主机标识必须固定为 luna-build"
[ "${AK3_BOOT_PARTITION_SIZE}" = "100663296" ] || die "小米 17 boot 分区容量必须固定为 100663296 字节"
[[ "${AK3_UPSTREAM_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "AnyKernel3 脚本 commit 格式错误"
[[ "${AK3_ARM64_TOOLS_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "AnyKernel3 工具 commit 格式错误"
for ak3_sha256 in \
    "${AK3_BUSYBOX_SHA256}" "${AK3_ANYKERNEL_SH_SHA256}" \
    "${AK3_UPDATE_BINARY_SHA256}" "${AK3_UPDATER_SCRIPT_SHA256}" \
    "${AK3_CORE_SHA256}" "${AK3_LICENSE_SHA256}" "${AK3_LUNA_PATCH_SHA256}" \
    "${AK3_LUNA_ANYKERNEL_SH_SHA256}" "${AK3_LUNA_UPDATE_BINARY_SHA256}" \
    "${AK3_LUNA_UPDATER_SCRIPT_SHA256}" "${AK3_LUNA_CORE_SHA256}"; do
    [[ "${ak3_sha256}" =~ ^[0-9a-f]{64}$ ]] || die "AnyKernel3 SHA-256 pin 格式错误"
done
[[ "${MAGISK_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "Magisk commit 格式错误"
[[ "${MAGISKBOOT_ARM64_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "arm64 magiskboot SHA-256 格式错误"
[[ "${STAGE_CONFIG_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "阶段配置 SHA-256 快照格式错误或尚未固定"
[[ "${STAGE_MODULES_ORDER_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "阶段模块顺序 SHA-256 快照格式错误或尚未固定"
EXPECTED_RELEASE="6.12.23${KERNEL_LOCALVERSION}"
EXPECTED_VERSION_LINE="Linux version ${EXPECTED_RELEASE} (${KERNEL_BUILD_USER}@${KERNEL_BUILD_HOST}) (Android (14043575, +pgo, +bolt, +lto, +mlgo, based on r536225) clang version 19.0.1 (https://android.googlesource.com/toolchain/llvm-project b3a530ec6537146650e42be89f1089e9a3588460), LLD 19.0.1) #${KERNEL_BUILD_VERSION} SMP PREEMPT ${KERNEL_BUILD_TIMESTAMP}"

ENVIRONMENT_DIR="$(resolve_workspace_path "${BUILD_ENVIRONMENT_DIR:-environment}")"
CI_TOOLCHAIN_DIR="${ENVIRONMENT_DIR}/toolchain/ci-sm8850-r536225"
ANDROID_NDK_DIR="${ENVIRONMENT_DIR}/toolchain/android-ndk-${ANDROID_NDK_VERSION}"
MAGISKBOOT_ARM64_PATH="${ENVIRONMENT_DIR}/magisk/v${MAGISK_VERSION}/magiskboot-arm64"
AK3_TEMPLATE_DIR="${HOST_WORKSPACE_DIR}/ak3_template"
AK3_BUSYBOX_PATH="${ENVIRONMENT_DIR}/anykernel3/${AK3_ARM64_TOOLS_COMMIT}/busybox-arm64"
CI_TOOLCHAIN_TREE_SHA256="${CI_TOOLCHAIN_TREE_SHA256:-67da74f00a801440ca7c256b028d94e6c85bf7168fbdecab62c3710384a25d5a}"

[ -x "${CI_TOOLCHAIN_DIR}/bin/clang" ] || die "工具链未初始化，请先运行 ./init.sh"
[ -x "${CI_TOOLCHAIN_DIR}/bin/rustc" ] || die "Rust 工具链未初始化，请先运行 ./init.sh"
[ -x "${CI_TOOLCHAIN_DIR}/bindgen-cli-x86_64-unknown-linux-gnu/bindgen" ] || die "bindgen 未初始化，请先运行 ./init.sh"
[ -d "${CI_TOOLCHAIN_DIR}/build-tools/bin" ] || die "build-tools 未初始化，请先运行 ./init.sh"
[ -x "${MAGISKBOOT_ARM64_PATH}" ] || die "arm64 magiskboot 未初始化，请先运行 ./init.sh"
[ "$(sha256sum "${MAGISKBOOT_ARM64_PATH}" | awk '{ print $1 }')" = "${MAGISKBOOT_ARM64_SHA256}" ] || \
    die "arm64 magiskboot SHA-256 校验失败，请重新运行 ./init.sh"
[ -x "${AK3_BUSYBOX_PATH}" ] || die "AnyKernel3 arm64 BusyBox 未初始化，请先运行 ./init.sh"
[ "$(sha256sum "${AK3_BUSYBOX_PATH}" | awk '{ print $1 }')" = "${AK3_BUSYBOX_SHA256}" ] || \
    die "AnyKernel3 arm64 BusyBox SHA-256 校验失败，请重新运行 ./init.sh"
[[ "${CI_TOOLCHAIN_TREE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "工具链安装树 SHA-256 格式错误"
[ "$(tree_sha256 "${CI_TOOLCHAIN_DIR}")" = "${CI_TOOLCHAIN_TREE_SHA256}" ] || \
    die "工具链安装树完整性校验失败，请重新运行 ./init.sh"
if [ "${ENABLE_IPSET}" = "1" ]; then
    [[ "${ANDROID_NDK_TREE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "Android NDK 安装树 SHA-256 格式错误"
    [ "$(tree_sha256 "${ANDROID_NDK_DIR}")" = "${ANDROID_NDK_TREE_SHA256}" ] || \
        die "Android NDK 安装树完整性校验失败，请重新运行 ./init.sh"
fi
log_success "构建工具链安装树完整性校验通过"

export PATH="${CI_TOOLCHAIN_DIR}/host-bin:${CI_TOOLCHAIN_DIR}/bindgen-cli-x86_64-unknown-linux-gnu:${CI_TOOLCHAIN_DIR}/build-tools/bin:${CI_TOOLCHAIN_DIR}/bin:${PATH}"
export RUSTC=rustc HOSTRUSTC=rustc BINDGEN=bindgen LIBCLANG_PATH="${CI_TOOLCHAIN_DIR}/lib"
[ -d "${CI_TOOLCHAIN_DIR}/lib/rustlib/src/rust/library" ] && export RUST_LIB_SRC="${CI_TOOLCHAIN_DIR}/lib/rustlib/src/rust/library"
export ARCH=arm64 SUBARCH=arm64 CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
export KBUILD_GENDWARFKSYMS_STABLE=1 IN_KERNEL_MODULES=1 DO_NOT_STRIP_MODULES=1 PAGE_SIZE=4096
export CC=clang HOSTCC="${CI_TOOLCHAIN_DIR}/host-bin/cc" LD=ld.lld HOSTLD=/usr/bin/ld HOSTRUSTFLAGS="-Clinker=/usr/bin/x86_64-linux-gnu-gcc"

MAKE_ARGS=(
    ARCH=arm64 SUBARCH=arm64 LLVM=1 LLVM_IAS=1 O="${BUILD_DIR}"
    LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump OBJSIZE=llvm-size READELF=llvm-readelf STRIP=llvm-strip
    CC=clang HOSTCC="${CI_TOOLCHAIN_DIR}/host-bin/cc" HOSTCFLAGS="-Wno-error=discarded-qualifiers"
    CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
    RUSTC=rustc HOSTRUSTC=rustc HOSTRUSTFLAGS="-Clinker=/usr/bin/x86_64-linux-gnu-gcc"
    BINDGEN=bindgen HOSTLD=/usr/bin/ld KCFLAGS="-Wno-error=unknown-warning-option"
    LOCALVERSION="${KERNEL_LOCALVERSION}"
    KBUILD_BUILD_USER="${KERNEL_BUILD_USER}"
    KBUILD_BUILD_HOST="${KERNEL_BUILD_HOST}"
    KBUILD_BUILD_TIMESTAMP="${KERNEL_BUILD_TIMESTAMP}"
    KBUILD_BUILD_VERSION="${KERNEL_BUILD_VERSION}"
)

run_unicode_uml_selftest

log_step "生成 Android 16 GKI 6.12.23 配置"
make -C "${COMMON_DIR}" "${MAKE_ARGS[@]}" gki_defconfig
bash "${COMMON_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
    --disable WERROR \
    --disable LOCALVERSION_AUTO \
    --disable TRIM_UNUSED_KSYMS \
    --enable BPF_UNPRIV_DEFAULT_OFF \
    --enable SECCOMP \
    --enable SECCOMP_FILTER \
    --disable SECCOMP_CACHE_DEBUG \
    --enable EROFS_FS_ZIP_LZMA \
    --enable EROFS_FS_ZIP_DEFLATE \
    --enable EROFS_FS_ZIP_ZSTD \
    --enable TMPFS_XATTR \
    --enable TMPFS_POSIX_ACL \
    --enable XZ_DEC_MICROLZMA \
    --enable WQ_POWER_EFFICIENT_DEFAULT \
    --set-str LOCALVERSION ""
if [ "${ENABLE_KERNELSU}" = "1" ]; then
    bash "${COMMON_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --enable KSU \
        --disable KSU_DEBUG
fi
if [ "${ENABLE_SUSFS}" = "1" ]; then
    bash "${COMMON_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --enable KSU_SUSFS
fi
if [ "${ENABLE_BBG}" = "1" ]; then
    bash "${COMMON_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --enable BBG \
        --disable BBG_BLOCK_BOOT \
        --disable BBG_BLOCK_RECOVERY \
        --set-str LSM "landlock,lockdown,yama,loadpin,safesetid,selinux,smack,tomoyo,apparmor,ipe,bpf,baseband_guard"
fi
if [ "${ENABLE_STAGE4_FS}" = "1" ]; then
    bash "${COMMON_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --enable BLK_DEV_LOOP \
        --enable EROFS_FS \
        --enable EROFS_FS_XATTR \
        --enable EROFS_FS_POSIX_ACL \
        --enable EROFS_FS_SECURITY \
        --enable EROFS_FS_BACKED_BY_FILE \
        --enable EROFS_FS_ZIP \
        --enable EROFS_FS_ZIP_DEFLATE \
        --enable EROFS_FS_ZIP_LZMA \
        --enable EROFS_FS_ZIP_ZSTD \
        --disable EROFS_FS_ONDEMAND \
        --enable EROFS_FS_PCPU_KTHREAD \
        --enable EROFS_FS_PCPU_KTHREAD_HIPRI \
        --enable FS_ENCRYPTION \
        --enable FS_ENCRYPTION_ALGS \
        --enable FS_ENCRYPTION_INLINE_CRYPT \
        --enable FS_VERITY \
        --enable DM_CRYPT \
        --enable DM_DEFAULT_KEY \
        --enable DM_VERITY \
        --enable DM_VERITY_FEC \
        --enable EXT4_FS \
        --enable EXT4_USE_FOR_EXT2 \
        --enable EXT4_FS_POSIX_ACL \
        --enable EXT4_FS_SECURITY \
        --enable F2FS_FS \
        --enable F2FS_FS_XATTR \
        --enable F2FS_FS_POSIX_ACL \
        --enable F2FS_FS_SECURITY \
        --enable F2FS_FS_COMPRESSION \
        --enable F2FS_FS_LZO \
        --enable F2FS_FS_LZORLE \
        --enable F2FS_FS_LZ4 \
        --enable F2FS_FS_LZ4HC \
        --enable F2FS_FS_ZSTD \
        --enable F2FS_IOSTAT \
        --enable F2FS_UNFAIR_RWSEM \
        --enable UNICODE \
        --enable NLS_UTF8 \
        --enable NETFS_SUPPORT \
        --enable CIFS \
        --enable OVERLAY_FS \
        --disable OVERLAY_FS_REDIRECT_DIR \
        --enable OVERLAY_FS_REDIRECT_ALWAYS_FOLLOW \
        --disable OVERLAY_FS_INDEX \
        --disable OVERLAY_FS_XINO_AUTO \
        --disable OVERLAY_FS_METACOPY \
        --disable OVERLAY_FS_DEBUG \
        --enable TMPFS \
        --enable TMPFS_POSIX_ACL \
        --enable TMPFS_XATTR \
        --disable TMPFS_INODE64 \
        --disable TMPFS_QUOTA \
        --disable INTEGRITY_SIGNATURE \
        --enable INTEGRITY_AUDIT \
        --enable INTEGRITY
fi
if [ "${ENABLE_ADIOS}" = "1" ]; then
    bash "${COMMON_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --enable MQ_IOSCHED_ADIOS \
        --disable MQ_IOSCHED_DEFAULT_ADIOS
fi
if [ "${ENABLE_STAGE5_NAMESPACES}" = "1" ]; then
    bash "${COMMON_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --enable USER_NS \
        --enable PID_NS
fi
if [ "${ENABLE_STAGE5_NETWORK}" = "1" ]; then
    bash "${COMMON_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --enable TCP_CONG_ADVANCED \
        --enable TCP_CONG_CUBIC \
        --enable TCP_CONG_BBR \
        --enable TCP_CONG_BRUTAL \
        --enable NET_SCH_FQ \
        --enable DEFAULT_CUBIC \
        --disable TCP_CONG_BIC \
        --disable TCP_CONG_WESTWOOD \
        --disable TCP_CONG_HTCP
fi
if [ "${ENABLE_IPSET}" = "1" ]; then
    bash "${COMMON_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --enable NETFILTER_XTABLES \
        --disable NF_TABLES \
        --enable IP_SET \
        --set-val IP_SET_MAX 256 \
        --enable IP_SET_BITMAP_IP \
        --enable IP_SET_BITMAP_IPMAC \
        --enable IP_SET_BITMAP_PORT \
        --enable IP_SET_HASH_IP \
        --enable IP_SET_HASH_IPMARK \
        --enable IP_SET_HASH_IPPORT \
        --enable IP_SET_HASH_IPPORTIP \
        --enable IP_SET_HASH_IPPORTNET \
        --enable IP_SET_HASH_IPMAC \
        --enable IP_SET_HASH_MAC \
        --enable IP_SET_HASH_NET \
        --enable IP_SET_HASH_NETNET \
        --enable IP_SET_HASH_NETPORT \
        --enable IP_SET_HASH_NETPORTNET \
        --enable IP_SET_HASH_NETIFACE \
        --enable IP_SET_LIST_SET \
        --enable NETFILTER_XT_SET \
        --enable NET_EMATCH \
        --enable NET_EMATCH_IPSET
fi
bash "${COMMON_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
    --disable DMABUF_HEAPS_SYSTEM \
    --disable DMABUF_HEAPS_CMA
make -C "${COMMON_DIR}" "${MAKE_ARGS[@]}" olddefconfig -j"${BUILD_JOBS}"
verify_kmi_config
[ "${ENABLE_BBG}" != "1" ] || verify_lsm_slot_capacity

log_step "编译 GKI arm64 Image 与模块 (并行度: ${BUILD_JOBS})"
make -C "${COMMON_DIR}" "${MAKE_ARGS[@]}" Image modules -j"${BUILD_JOBS}"

IMAGE_PATH="${BUILD_DIR}/arch/arm64/boot/Image"
[ -f "${IMAGE_PATH}" ] || die "编译完成但未找到 Image: ${IMAGE_PATH}"
[ -s "${BUILD_DIR}/Module.symvers" ] || die "编译完成但未找到 Module.symvers"
[ -s "${BUILD_DIR}/modules.order" ] || die "编译完成但未找到 modules.order"
MODULE_COUNT="$(sed '/^[[:space:]]*$/d' "${BUILD_DIR}/modules.order" | wc -l | tr -d ' ')"
MODULES_ORDER_SHA256="$(sha256sum "${BUILD_DIR}/modules.order" | awk '{ print $1 }')"
while IFS= read -r module_path; do
    [ -z "${module_path}" ] || [ -s "${BUILD_DIR}/${module_path}" ] || die "活动模块产物缺失: ${module_path}"
done < "${BUILD_DIR}/modules.order"
[ "${MODULE_COUNT}" -ge 100 ] || die "GKI 模块数量异常: ${MODULE_COUNT}"
[ -n "${STAGE_MODULE_COUNT}" ] || die "阶段模块快照尚未固定: STAGE_MODULE_COUNT=${MODULE_COUNT}"
[ "${MODULE_COUNT}" = "${STAGE_MODULE_COUNT}" ] || die "阶段模块数量漂移: ${MODULE_COUNT} != ${STAGE_MODULE_COUNT}"
[ "${MODULES_ORDER_SHA256}" = "${STAGE_MODULES_ORDER_SHA256}" ] || \
    die "阶段模块顺序完整指纹漂移: ${MODULES_ORDER_SHA256} != ${STAGE_MODULES_ORDER_SHA256}"
log_success "GKI 模块构建检查通过 (${MODULE_COUNT} 个，完整指纹匹配)"

[ "${ENABLE_KERNELSU}" != "1" ] || verify_kernelsu_build
[ "${ENABLE_BBG}" != "1" ] || verify_bbg_build
verify_stage5_selected_build

verify_symbol_list_exports "${COMMON_DIR}/gki/aarch64/symbols/qcom" "QCOM"
verify_symbol_list_exports "${COMMON_DIR}/gki/aarch64/symbols/xiaomi" "Xiaomi"
verify_stage_abi

EMBEDDED_CONFIG_LINES="$("${COMMON_DIR}/scripts/extract-ikconfig" "${IMAGE_PATH}" | wc -l | tr -d ' ')"
EMBEDDED_CONFIG_SHA256="$("${COMMON_DIR}/scripts/extract-ikconfig" "${IMAGE_PATH}" | sha256sum | awk '{ print $1 }')"
[ "${EMBEDDED_CONFIG_LINES}" -ge "${KMI_CONFIG_MIN_LINES}" ] || die "Image 内嵌配置异常: ${EMBEDDED_CONFIG_LINES}"
[ "${EMBEDDED_CONFIG_LINES}" = "${STAGE_CONFIG_LINES}" ] || die "Image 内嵌配置行数漂移: ${EMBEDDED_CONFIG_LINES} != ${STAGE_CONFIG_LINES}"
[ "${EMBEDDED_CONFIG_SHA256}" = "${STAGE_CONFIG_SHA256}" ] || \
    die "Image 内嵌配置完整指纹漂移: ${EMBEDDED_CONFIG_SHA256} != ${STAGE_CONFIG_SHA256}"
ACTUAL_VERSION_LINE="$(strings "${IMAGE_PATH}" | grep -Fx -- "${EXPECTED_VERSION_LINE}" | sort -u || true)"
[ "${ACTUAL_VERSION_LINE}" = "${EXPECTED_VERSION_LINE}" ] || die "Image 缺少完整目标版本行"

mkdir -p "${PRODUCT_DIR}"
ARTIFACT_MANIFEST="${PRODUCT_DIR}/${ARTIFACT_MANIFEST_NAME}"
clean_previous_release_artifacts "${PRODUCT_DIR}" "${ARTIFACT_MANIFEST_NAME}"
RELEASE_ARTIFACTS=()
RELEASE_DATE="$(TZ=Asia/Shanghai date +%Y%m%d)"
build_ipset_userspace
if [ "${ENABLE_IPSET}" = "1" ]; then
    RELEASE_ARTIFACTS+=(
        "ipset-arm64-v${IPSET_VERSION}"
        "ipset-v${IPSET_VERSION}-android-arm64-kernelsu-module.zip"
    )
fi
TARGET_IMAGE="${PRODUCT_DIR}/Image-luna-xiaomi17-g${LUNA_PROJECT_SHORT}-${RELEASE_DATE}"
cp -f "${IMAGE_PATH}" "${TARGET_IMAGE}"
cp -f "${IMAGE_PATH}" "${PRODUCT_DIR}/Image"
RELEASE_ARTIFACTS+=("$(basename "${TARGET_IMAGE}")")
log_success "内核 Image 编译成功: ${TARGET_IMAGE}"

if [ "${ENABLE_KERNELSU}" = "1" ]; then
    KSU_MANAGER_PATH="${ENVIRONMENT_DIR}/kernelsu/${KSU_REF}/${KSU_MANAGER_APK}"
    [ -f "${KSU_MANAGER_PATH}" ] || die "官方 KernelSU Manager 缺失，请先运行 ./init.sh"
    [ "$(sha256sum "${KSU_MANAGER_PATH}" | awk '{ print $1 }')" = "${KSU_MANAGER_SHA256}" ] || die "官方 KernelSU Manager SHA-256 校验失败"
    cp -f "${KSU_MANAGER_PATH}" "${PRODUCT_DIR}/${KSU_MANAGER_APK}"
    RELEASE_ARTIFACTS+=("${KSU_MANAGER_APK}")
    log_success "官方 KernelSU Manager 已复制到产物目录"
fi

if [ "${ENABLE_SUSFS}" = "1" ]; then
    SUSFS_HELPER="${SUSFS_DIR}/ksu_module_susfs/tools/ksu_susfs_arm64"
    SUSFS_MODULE_NAME="susfs4ksu-v2.2.0-${SUSFS_COMMIT:0:12}.zip"
    [ -x "${SUSFS_HELPER}" ] || die "官方 ksu_susfs arm64 helper 缺失"
    [ "$(sha256sum "${SUSFS_HELPER}" | awk '{ print $1 }')" = "${SUSFS_HELPER_SHA256}" ] || \
        die "官方 ksu_susfs arm64 helper SHA-256 校验失败"
    grep -Fx 'version=v2.2.0' "${SUSFS_DIR}/ksu_module_susfs/module.prop" >/dev/null || \
        die "SUSFS module.prop 版本不是 v2.2.0"
    (cd "${SUSFS_DIR}/ksu_module_susfs" && 7z a -tzip "${PRODUCT_DIR}/${SUSFS_MODULE_NAME}" . >/dev/null)
    unzip -p "${PRODUCT_DIR}/${SUSFS_MODULE_NAME}" tools/ksu_susfs_arm64 | sha256sum | \
        grep -Fx "${SUSFS_HELPER_SHA256}  -" >/dev/null || die "SUSFS 模块内 helper 校验失败"
    cp -f "${SUSFS_HELPER}" "${PRODUCT_DIR}/ksu_susfs_arm64"
    RELEASE_ARTIFACTS+=("${SUSFS_MODULE_NAME}" "ksu_susfs_arm64")
    log_success "官方 SUSFS helper 与模块已输出: ${SUSFS_MODULE_NAME}"
fi

AK3_UPSTREAM_DIR="${AK3_TEMPLATE_DIR}/upstream"
AK3_LUNA_PATCH="${AK3_TEMPLATE_DIR}/luna.patch"
for ak3_source in \
    "${AK3_UPSTREAM_DIR}/anykernel.sh:${AK3_ANYKERNEL_SH_SHA256}" \
    "${AK3_UPSTREAM_DIR}/META-INF/com/google/android/update-binary:${AK3_UPDATE_BINARY_SHA256}" \
    "${AK3_UPSTREAM_DIR}/META-INF/com/google/android/updater-script:${AK3_UPDATER_SCRIPT_SHA256}" \
    "${AK3_UPSTREAM_DIR}/tools/ak3-core.sh:${AK3_CORE_SHA256}" \
    "${AK3_TEMPLATE_DIR}/LICENSE:${AK3_LICENSE_SHA256}" \
    "${AK3_LUNA_PATCH}:${AK3_LUNA_PATCH_SHA256}"; do
    ak3_source_path=${ak3_source%%:*}
    ak3_source_sha256=${ak3_source#*:}
    [ -f "${ak3_source_path}" ] || die "AnyKernel3 固定源码缺失: ${ak3_source_path}"
    [ "$(sha256sum "${ak3_source_path}" | awk '{ print $1 }')" = "${ak3_source_sha256}" ] || \
        die "AnyKernel3 固定源码 SHA-256 校验失败: ${ak3_source_path}"
done
[ -f "${AK3_TEMPLATE_DIR}/SOURCE.md" ] || die "AnyKernel3 来源记录缺失"

log_step "从固定源码组装 AnyKernel3 刷机包"
ZIP_NAME="${PRODUCT_DIR}/luna-xiaomi17-g${LUNA_PROJECT_SHORT}-${RELEASE_DATE}.zip"
AK3_STAGE="$(mktemp -d "${BUILD_DIR}/ak3-package.XXXXXX")"
cp -a "${AK3_UPSTREAM_DIR}/." "${AK3_STAGE}/"
cp -f "${AK3_TEMPLATE_DIR}/LICENSE" "${AK3_STAGE}/LICENSE"
cp -f "${AK3_TEMPLATE_DIR}/SOURCE.md" "${AK3_STAGE}/SOURCE.md"
patch -d "${AK3_STAGE}" -p1 --batch --forward < "${AK3_LUNA_PATCH}" >/dev/null || \
    die "OS3 Luna AnyKernel3 差异补丁无法应用到固定上游"
cp -f "${AK3_BUSYBOX_PATH}" "${AK3_STAGE}/tools/busybox"
cp -f "${MAGISKBOOT_ARM64_PATH}" "${AK3_STAGE}/tools/magiskboot"
cp -f "${PRODUCT_DIR}/Image" "${AK3_STAGE}/Image"
chmod 0755 \
    "${AK3_STAGE}/META-INF/com/google/android/update-binary" \
    "${AK3_STAGE}/tools/ak3-core.sh" \
    "${AK3_STAGE}/tools/busybox" \
    "${AK3_STAGE}/tools/magiskboot"

[ "$(sha256sum "${AK3_STAGE}/anykernel.sh" | awk '{ print $1 }')" = "${AK3_LUNA_ANYKERNEL_SH_SHA256}" ] || \
    die "OS3 Luna anykernel.sh 结果摘要不匹配"
[ "$(sha256sum "${AK3_STAGE}/META-INF/com/google/android/update-binary" | awk '{ print $1 }')" = \
  "${AK3_LUNA_UPDATE_BINARY_SHA256}" ] || die "OS3 Luna update-binary 结果摘要不匹配"
[ "$(sha256sum "${AK3_STAGE}/META-INF/com/google/android/updater-script" | awk '{ print $1 }')" = \
  "${AK3_LUNA_UPDATER_SCRIPT_SHA256}" ] || die "OS3 Luna updater-script 结果摘要不匹配"
[ "$(sha256sum "${AK3_STAGE}/tools/ak3-core.sh" | awk '{ print $1 }')" = "${AK3_LUNA_CORE_SHA256}" ] || \
    die "OS3 Luna ak3-core.sh 结果摘要不匹配"
for AK3_SHELL_SCRIPT in META-INF/com/google/android/update-binary tools/ak3-core.sh anykernel.sh; do
    bash -n "${AK3_STAGE}/${AK3_SHELL_SCRIPT}" || die "AnyKernel3 脚本语法错误: ${AK3_SHELL_SCRIPT}"
done
grep -Fx 'do.devicecheck=0' "${AK3_STAGE}/anykernel.sh" >/dev/null || die "AnyKernel3 未禁用 do.devicecheck"
grep -Fx 'kernel.string=Luna Kernel for Xiaomi 17' "${AK3_STAGE}/anykernel.sh" >/dev/null || \
    die "AnyKernel3 品牌或设备标识不正确"
grep -Fx "boot_partition_size=${AK3_BOOT_PARTITION_SIZE};" "${AK3_STAGE}/anykernel.sh" >/dev/null || \
    die "AnyKernel3 未固定小米 17 boot 分区容量"
grep -Fx '  partition_size="$(blockdev --getsize64 "$block" 2>/dev/null)";' \
    "${AK3_STAGE}/anykernel.sh" >/dev/null || die "AnyKernel3 未读取真实 boot 块设备容量"
grep -Fx '  if [ "$partition_size" -ne "$boot_partition_size" ]; then' \
    "${AK3_STAGE}/anykernel.sh" >/dev/null || die "AnyKernel3 未校验小米 17 boot 分区容量"
grep -Fx '  elif [ "$image_size" -gt "$partition_size" ]; then' \
    "${AK3_STAGE}/anykernel.sh" >/dev/null || die "AnyKernel3 未限制新 boot 镜像大小"
grep -Fx '  luna_verify_boot_image_size boot-new.img;' "${AK3_STAGE}/tools/ak3-core.sh" >/dev/null || \
    die "AnyKernel3 未使用真实 boot 分区容量门禁"
if grep -F 'wc -c < boot.img' "${AK3_STAGE}/tools/ak3-core.sh" >/dev/null; then
    die "AnyKernel3 仍按原 boot 镜像文件长度拒绝刷写"
fi

(cd "${AK3_STAGE}" && TZ=UTC 7z a -tzip "${ZIP_NAME}" \
    Image LICENSE SOURCE.md anykernel.sh \
    META-INF/com/google/android/update-binary \
    META-INF/com/google/android/updater-script \
    patch/placeholder ramdisk/placeholder \
    tools/ak3-core.sh tools/busybox tools/magiskboot >/dev/null)
unzip -tq "${ZIP_NAME}" >/dev/null || die "刷机包 ZIP 完整性校验失败"
AK3_FILE_LIST="$(unzip -Z1 "${ZIP_NAME}" | sed '/\/$/d' | LC_ALL=C sort)"
[ "${AK3_FILE_LIST}" = $'Image\nLICENSE\nMETA-INF/com/google/android/update-binary\nMETA-INF/com/google/android/updater-script\nSOURCE.md\nanykernel.sh\npatch/placeholder\nramdisk/placeholder\ntools/ak3-core.sh\ntools/busybox\ntools/magiskboot' ] || \
    die "刷机包文件白名单不匹配"
[ "$(unzip -p "${ZIP_NAME}" tools/busybox | sha256sum | awk '{ print $1 }')" = "${AK3_BUSYBOX_SHA256}" ] || \
    die "刷机包 arm64 BusyBox SHA-256 校验失败"
[ "$(unzip -p "${ZIP_NAME}" tools/magiskboot | sha256sum | awk '{ print $1 }')" = \
  "${MAGISKBOOT_ARM64_SHA256}" ] || die "刷机包 arm64 magiskboot SHA-256 校验失败"
case "${AK3_STAGE}" in
    "${BUILD_DIR}"/ak3-package.*) rm -rf -- "${AK3_STAGE}" ;;
    *) die "拒绝清理异常 AnyKernel3 暂存目录" ;;
esac
RELEASE_ARTIFACTS+=("$(basename "${ZIP_NAME}")")
log_success "AnyKernel3 刷机包已生成: ${ZIP_NAME}"
rm -f -- "${PRODUCT_DIR}/Image"

for artifact in "${RELEASE_ARTIFACTS[@]}"; do
    case "${artifact}" in
        ''|*/*|.|..) die "拒绝记录非法产物名: ${artifact}" ;;
    esac
    [ -f "${PRODUCT_DIR}/${artifact}" ] || die "当前构建产物缺失: ${artifact}"
    printf '%s\n' "${artifact}" >> "${ARTIFACT_MANIFEST}"
done
[ -s "${ARTIFACT_MANIFEST}" ] || die "当前构建产物清单为空"
log_success "当前构建产物清单已固定 (${#RELEASE_ARTIFACTS[@]} 项)"

log_success "Luna Kernel for Xiaomi 17 构建与 ABI/KMI 校验完成"
