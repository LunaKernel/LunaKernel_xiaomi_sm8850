#!/usr/bin/env bash
#
# build.sh - Luna Kernel build, verification and release packaging
#
set -euo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
export GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1 GIT_PAGER=cat

die() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

log_step() { printf '[STEP] %s\n' "$1"; }
log_success() { printf '[OK] %s\n' "$1"; }

audit_compare() {
    local metric="$1" reference="$2" actual="$3" status
    if [ "${actual}" = "${reference}" ]; then
        status="MATCH"
    else
        status="DRIFT"
        AUDIT_DRIFT_COUNT="$((AUDIT_DRIFT_COUNT + 1))"
    fi
    printf '%s\t%s\t%s\t%s\n' "${status}" "${metric}" "${reference}" "${actual}" >> "${AUDIT_REPORT}"
    printf '[AUDIT] %s: %s (reference=%s actual=%s)\n' \
        "${metric}" "${status}" "${reference}" "${actual}"
}

sha256_file() {
    local output
    if command -v sha256sum >/dev/null 2>&1; then
        output="$(sha256sum "$1")"
    elif command -v shasum >/dev/null 2>&1; then
        output="$(shasum -a 256 "$1")"
    else
        die "缺少 SHA-256 校验工具"
    fi
    printf '%s\n' "${output%% *}"
}

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

clean_previous_release_artifacts() {
    local output_dir="$1"
    local manifest_name="$2"
    local manifest="${output_dir}/${manifest_name}"
    local digest name extra path

    [ -d "${output_dir}" ] || return
    if [ -f "${manifest}" ]; then
        while read -r digest name extra; do
            if [ -z "${name}" ]; then
                name="${digest}"
            else
                [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] && [ -z "${extra}" ] || \
                    die "已有产物清单含非法摘要记录"
            fi
            case "${name}" in
                ''|*/*|.|..|*[!A-Za-z0-9._-]*) die "已有产物清单含非法条目: ${name}" ;;
            esac
            rm -f -- "${output_dir}/${name}"
        done < "${manifest}"
    fi

    while IFS= read -r -d '' path; do
        rm -f -- "${path}"
    done < <(
        find "${output_dir}" -maxdepth 1 \( -type f -o -type l \) \
            \( -name 'Image-luna-xiaomi17-g????????-????????' \
            -o -name 'luna-xiaomi17-g????????-????????.zip' \
            -o -name 'luna-xiaomi17-g????????-????????-audit.zip' \
            -o -name 'KernelSU_v*-release.apk' \
            -o -name 'ipset-arm64-v*' \
            -o -name 'ipset-v*-android-arm64-kernelsu-module.zip' \
            -o -name 'susfs4ksu-v*.zip' \
            -o -name 'ksu_susfs_arm64' \) -print0
    )
    rm -f -- "${manifest}" "${output_dir}/Image"
}

prepare_product_directory() {
    local relative_dir="$1" path component
    case "${relative_dir}" in
        ''|/*|.|..|../*|*/../*|*/..) die "构建产物目录必须是项目内的普通相对路径: ${relative_dir}" ;;
    esac
    path="${HOST_WORKSPACE_DIR}"
    while IFS= read -r component; do
        case "${component}" in
            ''|.|..) die "构建产物目录含非法路径分量: ${relative_dir}" ;;
        esac
        path="${path}/${component}"
        [ ! -L "${path}" ] || die "构建产物目录不得经过符号链接: ${path}"
    done < <(printf '%s\n' "${relative_dir}" | tr '/' '\n')
    mkdir -p "${path}"
    PRODUCT_DIR="${path}"
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
    for var in NO_COLOR http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy; do
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
    reject_git_environment_overrides
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

normalize_archive_timestamps() {
    local root="$1"
    [ -d "${root}" ] || die "归档暂存目录不存在: ${root}"
    find "${root}" -depth -exec touch -h -d "${KERNEL_BUILD_TIMESTAMP}" -- {} +
}

resolve_project_identity() {
    local actual_commit

    if git -C "${HOST_WORKSPACE_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
        reject_git_object_overrides "项目仓库" "${HOST_WORKSPACE_DIR}"
        verify_no_hidden_index_flags "项目仓库" "${HOST_WORKSPACE_DIR}"
        actual_commit="$(git -C "${HOST_WORKSPACE_DIR}" rev-parse HEAD)"
        [[ "${actual_commit}" =~ ^[0-9a-f]{40}$ ]] || die "项目提交格式异常: ${actual_commit}"
        [ -z "$(git -C "${HOST_WORKSPACE_DIR}" status --porcelain --untracked-files=normal)" ] || \
            die "项目存在未提交或未跟踪文件，拒绝生成发布产物"
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
    [ "${ANDROID17_STOCK_SYSTEM_DLKM_IMAGE:-}" = "tmp/os4/system_dlkm.img" ] || \
        die "macOS 同步只接受固定的 tmp/os4/system_dlkm.img"
    if [ -f "${HOST_WORKSPACE_DIR}/.env" ]; then items="${items} .env"; fi
    if [ -d "${HOST_WORKSPACE_DIR}/ak3_template" ]; then items="${items} ak3_template"; fi
    if [ -d "${HOST_WORKSPACE_DIR}/patches" ]; then items="${items} patches"; fi
    if [ -d "${HOST_WORKSPACE_DIR}/abi" ]; then items="${items} abi"; fi
    if [ -d "${HOST_WORKSPACE_DIR}/tools" ]; then items="${items} tools"; fi
    if [ -d "${HOST_WORKSPACE_DIR}/userspace" ]; then items="${items} userspace"; fi
    if [ -f "${HOST_WORKSPACE_DIR}/tmp/os4/system_dlkm.img" ]; then
        items="${items} tmp/os4/system_dlkm.img"
    fi

    orbctl_run_host_path -w "${HOST_WORKSPACE_DIR}" sh -lc "set -e; target=\"\$HOME/${ORB_LINUX_WORKSPACE}\"; outbox=\"\$HOME/${ORB_LINUX_OUTBOX}\"; mkdir -p \"\$target/tmp/os4\" \"\$outbox\"; rm -rf \"\$target/init.sh\" \"\$target/patch.sh\" \"\$target/patch_external.sh\" \"\$target/build.sh\" \"\$target/.env\" \"\$target/ak3_template\" \"\$target/patches\" \"\$target/abi\" \"\$target/tools\" \"\$target/userspace\"; rm -f \"\$target/tmp/os4/system_dlkm.img\"; tar -cf - --exclude='.DS_Store' --exclude='.idea' --exclude='kernel_out' --exclude='toolchain' ${items} | tar --warning=no-unknown-keyword -xf - -C \"\$target\""
}

export_orb_results() {
    orbctl_run sh -lc "set -e; workspace=\"\$HOME/${ORB_LINUX_WORKSPACE}\"; output_dir='${BUILD_OUTPUT_DIR}'; case \"\$output_dir\" in /*) ;; *) output_dir=\"\$workspace/\$output_dir\" ;; esac; manifest=\"\$output_dir/${ARTIFACT_MANIFEST_NAME}\"; [ -s \"\$manifest\" ] && [ ! -L \"\$manifest\" ] || { printf '[FAIL] 当前构建产物清单缺失或不安全: %s\n' \"\$manifest\" >&2; exit 1; }; rm -rf \"\$workspace/../artifact_out\"; mkdir -p \"\$workspace/../artifact_out/kernel_out\" \"\$workspace/../outbox\"; count=0; while read -r digest name extra; do case \"\$digest\" in ''|*[!0-9a-f]*) printf '[FAIL] 非法产物摘要\n' >&2; exit 1 ;; esac; [ \"\${#digest}\" -eq 64 ] && [ -n \"\$name\" ] && [ -z \"\$extra\" ] || { printf '[FAIL] 非法产物清单记录\n' >&2; exit 1; }; case \"\$name\" in ''|*/*|.|..|*[!A-Za-z0-9._-]*) printf '[FAIL] 非法产物清单项: %s\n' \"\$name\" >&2; exit 1 ;; esac; path=\"\$output_dir/\$name\"; [ -f \"\$path\" ] && [ ! -L \"\$path\" ] || { printf '[FAIL] 当前构建产物缺失或不安全: %s\n' \"\$path\" >&2; exit 1; }; actual=\$(sha256sum \"\$path\"); actual=\${actual%% *}; [ \"\$actual\" = \"\$digest\" ] || { printf '[FAIL] 当前构建产物摘要不匹配: %s\n' \"\$name\" >&2; exit 1; }; cp -f \"\$path\" \"\$workspace/../artifact_out/kernel_out/\$name\"; count=\$((count + 1)); done < \"\$manifest\"; [ \"\$count\" -gt 0 ] || { printf '[FAIL] 当前构建产物清单为空\n' >&2; exit 1; }; cp -f \"\$manifest\" \"\$workspace/../artifact_out/kernel_out/${ARTIFACT_MANIFEST_NAME}\"; tar -cf \"\$workspace/../outbox/${ORB_RESULT_ARCHIVE}\" -C \"\$workspace/../artifact_out\" kernel_out"
}

pull_orb_results() {
    local temp_dir manifest digest name extra path actual count=0
    temp_dir="$(mktemp -d "${HOST_WORKSPACE_DIR}/.${SCRIPT_NAME%.sh}.pull.XXXXXX")"
    orbctl_run_host_path -w "${HOST_WORKSPACE_DIR}" sh -lc "set -e; src=\"\$HOME/${ORB_LINUX_OUTBOX}/${ORB_RESULT_ARCHIVE}\"; dst='${temp_dir}/${ORB_RESULT_ARCHIVE}'; [ -f \"\$src\" ] || { printf '[FAIL] Orb 结果归档不存在: %s\n' \"\$src\" >&2; exit 1; }; cp -f \"\$src\" \"\$dst\""
    mkdir -p "${temp_dir}/extracted"
    tar -xf "${temp_dir}/${ORB_RESULT_ARCHIVE}" -C "${temp_dir}/extracted"
    [ -d "${temp_dir}/extracted/kernel_out" ] || die "Orb 结果缺少 kernel_out"
    manifest="${temp_dir}/extracted/kernel_out/${ARTIFACT_MANIFEST_NAME}"
    [ -s "${manifest}" ] && [ ! -L "${manifest}" ] || die "Orb 结果缺少安全的当前构建产物清单"
    mkdir -p "${PRODUCT_DIR}"
    clean_previous_release_artifacts "${PRODUCT_DIR}" "${ARTIFACT_MANIFEST_NAME}"
    while read -r digest name extra; do
        [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] && [ -n "${name}" ] && [ -z "${extra}" ] || \
            die "Orb 结果含非法产物摘要记录"
        case "${name}" in
            ''|*/*|.|..|*[!A-Za-z0-9._-]*) die "Orb 结果含非法产物清单项: ${name}" ;;
        esac
        path="${temp_dir}/extracted/kernel_out/${name}"
        [ -f "${path}" ] && [ ! -L "${path}" ] || \
            die "Orb 结果缺少安全的清单产物: ${name}"
        actual="$(sha256_file "${path}")"
        [ "${actual}" = "${digest}" ] || die "Orb 结果产物摘要不匹配: ${name}"
        cp -f "${path}" "${PRODUCT_DIR}/${name}"
        [ "$(sha256_file "${PRODUCT_DIR}/${name}")" = "${digest}" ] || \
            die "Orb 结果复制后摘要不匹配: ${name}"
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
    reject_git_object_overrides "${label}" "${repo_dir}"
    verify_no_hidden_index_flags "${label}" "${repo_dir}"
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
    local official_selinux_hide
    [ "${KSU_INTEGRATION_MODE}" = "builtin" ] || die "KernelSU 集成模式不是 builtin"
    verify_repo_identity "KernelSU ${KSU_REF}" "${KSU_DIR}" "${KSU_REPO}" "${KSU_COMMIT}" "0"
    [ "$(git -C "${KSU_DIR}" rev-list --count HEAD)" = "${KSU_GIT_VERSION_COUNT}" ] || die "KernelSU Git 历史计数不匹配"
    grep -Fxq "static const __u32 KERNEL_SU_UAPI_VERSION = ${KSU_UAPI_VERSION};" \
        "${KSU_DIR}/uapi/supercall.h" || die "KernelSU 与固定 Manager 的 UAPI 版本不匹配"
    [ "$(grep -Fxc "${kconfig_line}" "${COMMON_DIR}/drivers/Kconfig")" = "1" ] || die "KernelSU Kconfig 接入状态异常"
    [ "$(tail -n 2 "${COMMON_DIR}/drivers/Kconfig")" = "${kconfig_line}"$'\nendmenu' ] || die "KernelSU Kconfig 接入位置异常"
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
    bash "${HOST_WORKSPACE_DIR}/tools/independent_backports.sh" \
        verify-base-diff "${COMMON_DIR}" "${COMMON_BASE_TRACKED_DIFF_SHA256}"
    [ "${ksu_sha256}" = "${KSU_TRACKED_DIFF_SHA256}" ] || \
        die "KernelSU 精确差异指纹不匹配: ${ksu_sha256}"
    log_success "GKI common 基础差异、独立回移层与 KernelSU 精确差异指纹匹配"
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

verify_susfs_source_state() {
    local ksu_patch common_patch allowed_ksu allowed_common
    local actual_sha256 source_file target_file
    verify_repo_identity "SUSFS ${SUSFS_REF}" "${SUSFS_DIR}" "${SUSFS_REPO}" "${SUSFS_COMMIT}"
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
    ksu_patch="$(mktemp)"
    common_patch="$(mktemp)"
    allowed_ksu="$(mktemp)"
    allowed_common="$(mktemp)"
    git -C "${SUSFS_DIR}" show "${SUSFS_KSU_PATCH_COMMIT}:kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" > "${ksu_patch}"
    cp "${SUSFS_DIR}/kernel_patches/50_add_susfs_in_gki-android16-6.12.patch" "${common_patch}"
    verify_rejected_susfs_fdinfo_hunk \
        "${common_patch}" "${COMMON_DIR}" \
        "${SUSFS_CONTEXT_ADAPTATION}" "${SUSFS_COMMON_FIX_PATCH_FILE}"
    git -C "${KSU_DIR}" apply --reverse --check \
        --exclude=kernel/Kconfig \
        --exclude=kernel/policy/app_profile.c \
        --exclude=kernel/runtime/boot_event.c \
        --exclude=kernel/runtime/ksud_integration.c \
        --exclude=kernel/selinux/selinux.c \
        --exclude=kernel/sulog/event.c \
        --exclude=kernel/supercall/dispatch.c \
        "${ksu_patch}" || die "KernelSU SUSFS 官方补丁状态异常"
    git -C "${COMMON_DIR}" apply --reverse --check \
        --exclude=fs/exec.c \
        --exclude=fs/namei.c \
        --exclude=fs/namespace.c \
        --exclude=fs/notify/fdinfo.c \
        --exclude=fs/proc/base.c \
        --exclude=fs/proc/fd.c \
        --exclude=fs/proc/task_mmu.c \
        --exclude=fs/stat.c \
        --exclude=mm/memory.c \
        --exclude=security/selinux/hooks.c \
        "${common_patch}" || \
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
    {
        patch_paths_excluding "${ksu_patch}" \
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
        patch_paths_excluding "${common_patch}" \
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
        if [ "${ENABLE_MEMCG_RSTAT_FAST_PATH}" = "1" ]; then
            printf '%s\n' mm/memcontrol.c
        fi
        if [ "${ENABLE_TCP_RECV_MSTAMP_FAST_PATH}" = "1" ]; then
            printf '%s\n' net/ipv4/tcp.c net/ipv4/tcp_input.c
        fi
        if [ "${ENABLE_IPV6_MLD_UAF_FIX}" = "1" ]; then
            printf '%s\n' net/ipv6/mcast.c
        fi
        if [ "${ENABLE_IPV6_MLD_DELAYED_WORK_UAF_FIX:-0}" = "1" ]; then
            printf '%s\n' include/net/addrconf.h net/ipv6/mcast.c
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
        if [ "${ENABLE_SELECTED_BACKPORTS:-0}" = "1" ]; then
            bash "${HOST_WORKSPACE_DIR}/tools/backport_manifest.sh" list-paths
        fi
        bash "${HOST_WORKSPACE_DIR}/tools/independent_backports.sh" list-paths
    } | sort -u > "${allowed_common}"
    verify_allowed_paths "KernelSU" "${KSU_DIR}" "${allowed_ksu}"
    verify_allowed_paths "GKI common" "${COMMON_DIR}" "${allowed_common}"
    rm -f "${ksu_patch}" "${common_patch}" "${allowed_ksu}" "${allowed_common}"
    git -C "${COMMON_DIR}" diff --check
    git -C "${KSU_DIR}" diff --check
    log_success "SUSFS v2.3.0 固定源码、经审计拒绝项与 Luna 修正版状态检查通过"
}

verify_bbg_source_state() {
    local kconfig_line='source "security/baseband-guard/Kconfig"'
    local makefile_line='obj-$(CONFIG_BBG) += baseband-guard/'
    local allowed actual_sha256 marker_count token
    verify_repo_identity "Baseband Guard ${BBG_REF}" "${BBG_DIR}" "${BBG_REPO}" "${BBG_COMMIT}" "0"
    [ ! -f "$(git -C "${BBG_DIR}" rev-parse --absolute-git-dir)/shallow" ] || \
        die "Baseband Guard 历史未在 init 阶段补齐，拒绝构建期联网"
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
    verify_project_patch "KernelSU Baseband Guard 凭据标记补丁" \
        "${BBG_KSU_CREDENTIAL_PATCH}" "${BBG_KSU_CREDENTIAL_PATCH_SHA256}" \
        "${BBG_KSU_CREDENTIAL_PATCH_ID}"
    git -C "${KSU_DIR}" apply --reverse --check "${BBG_KSU_CREDENTIAL_PATCH}" || \
        die "KernelSU Baseband Guard 凭据标记状态异常"
    verify_project_patch "Baseband Guard AOSP 6.12.69 内部凭据接口补丁" \
        "${BBG_COMMON_CREDENTIAL_PATCH}" "${BBG_COMMON_CREDENTIAL_PATCH_SHA256}" \
        "${BBG_COMMON_CREDENTIAL_PATCH_ID}"
    git -C "${COMMON_DIR}" apply --reverse --check "${BBG_COMMON_CREDENTIAL_PATCH}" || \
        die "Baseband Guard 内部凭据接口状态异常"
    grep -Fq 'void bbg_mark_untrusted_cred(struct cred *cred)' \
        "${COMMON_DIR}/include/linux/baseband_guard.h" || \
        die "Baseband Guard 内部凭据接口缺失"
    grep -Fq '#include <linux/baseband_guard.h>' \
        "${BBG_DIR}/tracing/tracing.c" || \
        die "Baseband Guard 未通过公共内部头文件声明凭据接口"
    [ "$(grep -Fxc 'void bbg_mark_untrusted_cred(struct cred *cred);' \
        "${BBG_DIR}/tracing/tracing.c")" = "0" ] || \
        die "Baseband Guard 仍含重复的本地凭据接口声明"
    ! grep -Rq 'EXPORT_SYMBOL.*bbg_mark_untrusted_cred' "${COMMON_DIR}/include/linux/baseband_guard.h" "${BBG_DIR}/tracing" || \
        die "Baseband Guard 内部凭据接口不得导出"
    [ "$(grep -Fxc "${kconfig_line}" "${COMMON_DIR}/security/Kconfig")" = "1" ] || die "Baseband Guard Kconfig 接入状态异常"
    [ "$(grep -Fxc "${makefile_line}" "${COMMON_DIR}/security/Makefile")" = "1" ] || die "Baseband Guard Kbuild 接入状态异常"
    [ -L "${COMMON_DIR}/security/baseband-guard" ] || die "Baseband Guard security 链接缺失"
    [ "$(readlink -f "${COMMON_DIR}/security/baseband-guard")" = "${BBG_DIR}" ] || die "Baseband Guard security 链接目标错误"
    verify_project_patch "Baseband Guard AOSP 6.12.69 LSM 计数适配补丁" \
        "${BBG_LSM_COUNT_PATCH}" "${BBG_LSM_COUNT_PATCH_SHA256}" \
        "${BBG_LSM_COUNT_PATCH_ID}"
    git -C "${COMMON_DIR}" apply --reverse --check "${BBG_LSM_COUNT_PATCH}" || die "Baseband Guard LSM 计数适配状态异常"
    [ "$(grep -Ec '^#define BASEBAND_GUARD_ENABLED( |$)' "${COMMON_DIR}/include/linux/lsm_count.h")" = "2" ] || die "Baseband Guard LSM 计数宏异常"
    [ "$(grep -Ec '^[[:space:]]*BASEBAND_GUARD_ENABLED\)?[[:space:]]*\\?$' "${COMMON_DIR}/include/linux/lsm_count.h")" = "1" ] || die "Baseband Guard LSM 计数入口异常"
    log_success "Baseband Guard ${BBG_COMMIT:0:12} 保护边界、凭据标记与 overlay 状态检查通过"
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
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        merge-base --is-ancestor "${commit}" "${LINUX_STABLE_AUDIT_COMMIT}" || \
        die "${label} 不属于固定 Linux 6.12.y 审计快照"
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

verify_linux_stable_source_exact() {
    local label="$1" commit="$2" commit_date="$3" expected_patch_id="$4"
    local expected_paths="$5" upstream_commit="$6"
    local actual_date commit_message upstream_patch_id upstream_paths

    [ -n "${LINUX_STABLE_AUDIT_COMMIT}" ] || die "缺少 Linux stable 固定审计终点"
    verify_linux_stable_source "${label}" "${commit}" "${expected_patch_id}" \
        "${expected_paths}"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        merge-base --is-ancestor "${commit}" "${LINUX_STABLE_AUDIT_COMMIT}" || \
        die "${label} 不属于固定 Linux 6.12.y 审计快照"
    actual_date="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        -c log.mailmap=false show -s --format=%cs "${commit}")"
    [ "${actual_date}" = "${commit_date}" ] || die "${label} 提交日期不匹配: ${actual_date}"
    commit_message="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        -c log.mailmap=false show -s --format=%B "${commit}")"
    grep -Fx "[ Upstream commit ${upstream_commit} ]" <<<"${commit_message}" >/dev/null || \
        die "${label} 未绑定固定 Linux mainline 上游提交"
    [ -n "${LINUX_MAINLINE_AUDIT_COMMIT}" ] || die "缺少 Linux mainline 固定审计终点"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        cat-file -e "${upstream_commit}^{commit}" 2>/dev/null || \
        die "${label} Linux mainline 上游对象缺失"
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

verify_linux_mainline_backport_applied() {
    local label="$1" commit="$2" commit_date="$3" expected_patch_id="$4"
    local expected_paths="$5" actual_date actual_paths patch_file patch_id

    [ -n "${LINUX_MAINLINE_AUDIT_COMMIT}" ] || die "缺少 Linux mainline 固定审计终点"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        cat-file -e "${commit}^{commit}" 2>/dev/null || die "${label}对象缺失"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        merge-base --is-ancestor "${commit}" "${LINUX_MAINLINE_AUDIT_COMMIT}" || \
        die "${label}不属于固定 Linux mainline 审计快照"
    actual_date="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        -c log.mailmap=false show -s --format=%cs "${commit}")"
    [ "${actual_date}" = "${commit_date}" ] || die "${label}提交日期不匹配: ${actual_date}"
    actual_paths="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        diff-tree --no-commit-id --name-only -r "${commit}" | LC_ALL=C sort | paste -sd ' ' -)"
    [ "${actual_paths}" = "${expected_paths}" ] || die "${label}路径集合异常: ${actual_paths}"
    patch_file="$(mktemp)"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        -c log.mailmap=false show --format= "${commit}" > "${patch_file}"
    patch_id="$(git patch-id --stable < "${patch_file}" | awk '{ print $1 }')"
    [ "${patch_id}" = "${expected_patch_id}" ] || die "${label}patch-id 不匹配"
    git -C "${COMMON_DIR}" apply --reverse --check "${patch_file}" || die "${label}未完整应用"
    rm -f "${patch_file}"
}

verify_first_batch_linux_backports() {
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
    if [ "${ENABLE_F2FS_FOREGROUND_GC_DEADLOCK_FIX}" = "1" ]; then
        verify_linux_stable_source "F2FS 前台 GC 写回死锁修复" \
            "${F2FS_FOREGROUND_GC_DEADLOCK_STABLE_COMMIT}" \
            "${F2FS_FOREGROUND_GC_DEADLOCK_PATCH_ID}" \
            "fs/f2fs/data.c fs/f2fs/f2fs.h fs/f2fs/segment.c"
        verify_linux_stable_source "F2FS GC_MERGE 写回死锁补充修复" \
            "${F2FS_GC_MERGE_DEADLOCK_STABLE_COMMIT}" \
            "${F2FS_GC_MERGE_DEADLOCK_PATCH_ID}" \
            "fs/f2fs/segment.c"
        [ "$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" rev-parse \
            "${F2FS_GC_MERGE_DEADLOCK_STABLE_COMMIT}^")" = \
            "${F2FS_FOREGROUND_GC_DEADLOCK_STABLE_COMMIT}" ] || \
            die "F2FS GC 死锁组合提交顺序异常"
        verify_project_patch "F2FS GC 死锁 AOSP r21 适配补丁" \
            "${F2FS_FOREGROUND_GC_PATCH}" \
            "${F2FS_FOREGROUND_GC_PATCH_SHA256}" \
            "${F2FS_FOREGROUND_GC_PATCH_ID}"
        git -C "${COMMON_DIR}" apply --reverse --check \
            "${F2FS_FOREGROUND_GC_PATCH}" || \
            die "F2FS GC 死锁 AOSP r21 适配补丁未完整应用"
    fi
    log_success "第一批 Linux 稳定修复来源、路径与应用状态检查通过"
}

verify_second_batch_backports() {
    if [ "${ENABLE_TIMER_BASE_FAST_PATH}" = "1" ]; then
        verify_linux_mainline_backport_applied "timer base 指针获取快路径优化" \
            "${TIMER_BASE_FAST_PATH_COMMIT}" \
            "${TIMER_BASE_FAST_PATH_COMMIT_DATE}" \
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

verify_ipv6_mld_delayed_work_uaf_fix() {
    [ "${ENABLE_IPV6_MLD_DELAYED_WORK_UAF_FIX}" = "1" ] || return
    verify_linux_stable_source_exact "IPv6 MLD delayed-work 生命周期修复" \
        "${IPV6_MLD_DELAYED_WORK_STABLE_COMMIT}" \
        "${IPV6_MLD_DELAYED_WORK_COMMIT_DATE}" \
        "${IPV6_MLD_DELAYED_WORK_OFFICIAL_PATCH_ID}" \
        "include/net/addrconf.h net/ipv6/mcast.c" \
        "${IPV6_MLD_DELAYED_WORK_UPSTREAM_COMMIT}"
    verify_project_patch "IPv6 MLD delayed-work AOSP r21 适配补丁" \
        "${IPV6_MLD_DELAYED_WORK_PATCH_FILE}" \
        "${IPV6_MLD_DELAYED_WORK_PATCH_SHA256}" \
        "${IPV6_MLD_DELAYED_WORK_PATCH_ID}"
    git -C "${COMMON_DIR}" apply --reverse --check \
        "${IPV6_MLD_DELAYED_WORK_PATCH_FILE}" || \
        die "IPv6 MLD delayed-work AOSP r21 适配补丁未完整应用"
    [ "$(grep -Fc 'in6_dev_hold_safe(idev)' "${COMMON_DIR}/net/ipv6/mcast.c")" = "5" ] || \
        die "IPv6 MLD delayed-work 安全引用覆盖点异常"
    grep -Fq 'return refcount_inc_not_zero(&idev->refcnt);' \
        "${COMMON_DIR}/include/net/addrconf.h" || \
        die "IPv6 MLD delayed-work 仍可能复活零引用 inet6_dev"
    log_success "IPv6 MLD delayed-work 生命周期修复检查通过"
}

verify_android17_selected_fixes() {
    grep -Fq 'unlikely(sc->proactive && signal_pending(current))' \
        "${COMMON_DIR}/mm/vmscan.c" || \
        die "九月基线缺少主动回收内层扫描 freezer 检查"
    grep -A1 -F 'if (signal_pending(current))' \
        "${COMMON_DIR}/mm/memcontrol.c" | grep -Fq 'return -ERESTARTSYS;' || \
        die "九月基线主动回收 freezer 返回值语义异常"
    log_success "Android 17 九月基线与所选后续修复检查通过"
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
    if "${CI_TOOLCHAIN_DIR}/bin/llvm-nm" "${BUILD_DIR}/vmlinux" | \
        awk 'tolower($NF) ~ /open_redirect/ { found = 1 } END { exit(found ? 0 : 1) }'; then
        die "vmlinux 不得链接已关闭的 SUSFS OPEN_REDIRECT 实现"
    fi
    log_success "KernelSU built-in、version code ${KSU_VERSION_CODE}、标准 seccomp 与 OPEN_REDIRECT 关闭状态检查通过"
}

verify_bbg_build() {
    local object

    [ -s "${BUILD_DIR}/security/baseband-guard/built-in.a" ] || die "Baseband Guard built-in archive 缺失"
    "${CI_TOOLCHAIN_DIR}/bin/llvm-nm" "${BUILD_DIR}/vmlinux" | \
        grep -E '[[:space:]][Tt][[:space:]]+bbg_init$' >/dev/null || die "vmlinux 未链接 bbg_init"
    "${CI_TOOLCHAIN_DIR}/bin/llvm-nm" "${BUILD_DIR}/vmlinux" | \
        grep -E '[[:space:]][Tt][[:space:]]+bbg_mark_untrusted_cred$' >/dev/null || \
        die "vmlinux 未链接 Baseband Guard 凭据标记"
    for object in \
        drivers/kernelsu/policy/app_profile.o \
        drivers/kernelsu/selinux/selinux.o; do
        [ -s "${BUILD_DIR}/${object}" ] || die "Baseband Guard 凭据调用对象缺失: ${object}"
        "${CI_TOOLCHAIN_DIR}/bin/llvm-nm" "${BUILD_DIR}/${object}" | \
            grep -E '[[:space:]]U[[:space:]]+bbg_mark_untrusted_cred$' >/dev/null || \
            die "KernelSU 对 Baseband Guard 凭据标记的调用缺失: ${object}"
    done
    if awk '$2 == "bbg_mark_untrusted_cred" { found = 1 } END { exit(found ? 0 : 1) }' \
        "${BUILD_DIR}/Module.symvers"; then
        die "Baseband Guard 内部凭据标记不得成为 KMI 导出"
    fi
    strings "${BUILD_DIR}/arch/arm64/boot/Image" | grep -F "${BBG_COMMIT:0:8}" >/dev/null || \
        die "Image 未包含固定 Baseband Guard 版本"
    log_success "Baseband Guard built-in、内部凭据标记与版本 ${BBG_COMMIT:0:8} 检查通过"
}

verify_stage5_selected_build() {
    if [ "${ENABLE_STAGE5_NETWORK}" = "1" ]; then
        "${CI_TOOLCHAIN_DIR}/bin/llvm-nm" "${BUILD_DIR}/vmlinux" | \
            grep -E '[[:space:]][Tt][[:space:]]+bbr_register$' >/dev/null || die "vmlinux 未链接 BBR v1"
    fi
    log_success "阶段 5 网络与 namespace 功能链接检查通过"
}

require_config_enabled() {
    local symbol="$1"
    grep -qx "CONFIG_${symbol}=y" "${BUILD_DIR}/.config" || die "KMI 配置缺失: CONFIG_${symbol}=y"
}

require_config_module() {
    local symbol="$1"
    grep -qx "CONFIG_${symbol}=m" "${BUILD_DIR}/.config" || die "KMI 配置必须为模块: CONFIG_${symbol}=m"
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

    local symbol
    for symbol in \
        ARM64_4K_PAGES PAGE_SIZE_4KB SMP PREEMPT NET \
        MODULES MODULE_UNLOAD MODVERSIONS BASIC_MODVERSIONS EXTENDED_MODVERSIONS GENDWARFKSYMS \
        ANDROID_VENDOR_HOOKS GKI_HACKS_TO_FIX \
        IKCONFIG IKCONFIG_PROC CFI_CLANG RUST \
        BPF BPF_JIT BPF_JIT_ALWAYS_ON BPF_UNPRIV_DEFAULT_OFF \
        HAVE_ARCH_SECCOMP HAVE_ARCH_SECCOMP_FILTER SECCOMP SECCOMP_FILTER \
        ANDROID_BINDER_IPC ANDROID_BINDERFS \
        DEBUG_INFO_BTF DEBUG_INFO_BTF_MODULES \
        FUSE_BPF LTO_NONE BLK_WBT_MQ MODULE_ALLOW_BTF_MISMATCH \
        ARM_PKVM_GUEST VFIO_PKVM_IOMMU PKVM_PVIOMMU \
        TMPFS TMPFS_XATTR TMPFS_POSIX_ACL \
        EROFS_FS_ZIP EROFS_FS_ZIP_LZMA EROFS_FS_ZIP_DEFLATE EROFS_FS_ZIP_ZSTD \
        XZ_DEC_MICROLZMA WQ_POWER_EFFICIENT_DEFAULT; do
        require_config_enabled "${symbol}"
    done
    for symbol in \
        ARM64_16K_PAGES ARM64_64K_PAGES \
        LOCALVERSION_AUTO TRIM_UNUSED_KSYMS MODULE_SIG_FORCE SECCOMP_CACHE_DEBUG \
        CRYPTO_AES_ARM64_NEON_BLK EFIVAR_FS PSTORE_BLK \
        SND_AUDIO_GRAPH_CARD USB_XHCI_PCI_RENESAS NINTENDO_FF \
        LTO_CLANG_FULL LTO_CLANG_THIN; do
        require_config_disabled "${symbol}"
    done
    for symbol in PSTORE_ZONE SND_SIMPLE_CARD_UTILS; do
        require_config_not_enabled "${symbol}"
    done
    for symbol in NETFS_SUPPORT RFKILL CRYPTO_LIB_ARC4 ANDROID_BINDER_IPC_RUST; do
        require_config_module "${symbol}"
    done
    require_config_disabled CIFS
    if [ "${ENABLE_KERNELSU}" = "1" ]; then
        for symbol in KSU KPROBES EXT4_FS; do require_config_enabled "${symbol}"; done
        require_config_disabled KSU_DEBUG
        if [ "${ENABLE_SUSFS}" = "1" ]; then
            for symbol in \
                KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT \
                KSU_SUSFS_SUS_KSTAT KSU_SUSFS_SPOOF_UNAME \
                KSU_SUSFS_ENABLE_LOG KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
                KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
                KSU_SUSFS_SUS_MAP; do
                require_config_enabled "${symbol}"
            done
            require_config_disabled KSU_SUSFS_OPEN_REDIRECT
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
                UNICODE NLS_UTF8 OVERLAY_FS \
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
        if [ "${ENABLE_STAGE5_NAMESPACES}" = "1" ]; then
            require_config_enabled USER_NS
            require_config_enabled PID_NS
        fi
        if [ "${ENABLE_STAGE5_NETWORK}" = "1" ]; then
            for symbol in TCP_CONG_ADVANCED TCP_CONG_CUBIC TCP_CONG_BBR NET_SCH_FQ; do
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
        for symbol in GUNYAH_QCOM_PLATFORM ARM_SMMU ARM_SMMU_V3 ARM_SMMU_V3_PKVM QCOM_IOMMU; do
            require_config_not_enabled "${symbol}"
        done
        for symbol in GUNYAH GUNYAH_HYPERCALLS GUNYAH_PLATFORM_HOOKS GUNYAH_QCOM_TRUSTED_VM; do
            require_config_enabled "${symbol}"
        done
    fi
    audit_compare "config.lines" "${STAGE_CONFIG_LINES}" "${config_lines}"
    audit_compare "config.sha256" "${STAGE_CONFIG_SHA256}" "${config_sha256}"
    log_success "启动与模块兼容所需的配置语义检查通过"
}

verify_symbol_list_exports() {
    local list_file="$1"
    local label="$2"
    local symvers_file="${BUILD_DIR}/Module.symvers"
    local missing missing_count
    missing="$(LC_ALL=C comm -23 \
        <(awk '/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/ { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }' "${list_file}" | LC_ALL=C sort -u) \
        <(awk '{ print $2 }' "${symvers_file}" | LC_ALL=C sort -u) | sed -n '1,20p')"
    missing_count="$(LC_ALL=C comm -23 \
        <(awk '/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/ { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }' "${list_file}" | LC_ALL=C sort -u) \
        <(awk '{ print $2 }' "${symvers_file}" | LC_ALL=C sort -u) | wc -l | tr -d ' ')"
    audit_compare "symbol-list.${label}.missing" "0" "${missing_count}"
    if [ -n "${missing}" ]; then
        printf '[AUDIT] %s symbol-list missing sample:\n%s\n' "${label}" "${missing}"
    fi
}

verify_android17_stock_rust_binder() {
    local requirements expected_missing actual_missing matching mismatched non_vmlinux
    local requirement_count requirement_sha256 missing_count missing_sha256 match_count

    requirements="${AUDIT_DIR}/rust-binder-requirements.tsv"
    expected_missing="${AUDIT_DIR}/rust-binder-expected-missing.tsv"
    actual_missing="${AUDIT_DIR}/rust-binder-actual-missing.tsv"
    matching="${AUDIT_DIR}/rust-binder-matching.tsv"
    mismatched="${AUDIT_DIR}/rust-binder-crc-mismatch.tsv"
    non_vmlinux="${AUDIT_DIR}/rust-binder-non-vmlinux.tsv"

    grep -Fx "# rust_binder extended requirements: entries=${ANDROID17_STOCK_RUST_BINDER_REQUIREMENT_COUNT} sha256:${ANDROID17_STOCK_RUST_BINDER_REQUIREMENT_SHA256}" \
        "${ANDROID17_STOCK_ABI_FILE}" >/dev/null || \
        die "rust_binder 完整需求身份未绑定到 stock ABI 清单"
    grep -Fx "# rust_binder target result: vmlinux-match=${ANDROID17_STOCK_RUST_BINDER_MATCH_COUNT} missing=${ANDROID17_STOCK_RUST_BINDER_MISSING_COUNT} crc-mismatch=0 non-vmlinux=0 missing-sha256:${ANDROID17_STOCK_RUST_BINDER_MISSING_SHA256}" \
        "${ANDROID17_STOCK_ABI_FILE}" >/dev/null || \
        die "rust_binder 精确例外结果未绑定到 stock ABI 清单"

    awk -F '\t' '
        $1 == "# rust_binder-requirement" {
            if (NF != 3 || $2 !~ /^0x[0-9a-f]{8}$/ ||
                $3 !~ /^[A-Za-z_][A-Za-z0-9_]*$/) bad=1
            else print $2 "\t" $3
        }
        END { exit bad }
    ' "${ANDROID17_STOCK_ABI_FILE}" > "${requirements}" || \
        die "rust_binder 完整需求记录格式非法"
    LC_ALL=C sort -c -t "$(printf '\t')" -k2,2 "${requirements}" || \
        die "rust_binder 完整需求未按符号排序"
    [ -z "$(cut -f2 "${requirements}" | uniq -d | sed -n '1,20p')" ] || \
        die "rust_binder 完整需求存在重复符号"
    requirement_count="$(wc -l < "${requirements}" | tr -d ' ')"
    requirement_sha256="$(sha256sum "${requirements}" | awk '{ print $1 }')"
    [ "${requirement_count}" = "${ANDROID17_STOCK_RUST_BINDER_REQUIREMENT_COUNT}" ] || \
        die "rust_binder 完整需求数量错误: ${requirement_count}"
    [ "${requirement_sha256}" = "${ANDROID17_STOCK_RUST_BINDER_REQUIREMENT_SHA256}" ] || \
        die "rust_binder 完整需求 SHA-256 不匹配"

    awk -F '\t' '
        $1 == "# rust_binder-missing" {
            if (NF != 3 || $2 !~ /^0x[0-9a-f]{8}$/ ||
                $3 !~ /^[A-Za-z_][A-Za-z0-9_]*$/) bad=1
            else print $2 "\t" $3
        }
        END { exit bad }
    ' "${ANDROID17_STOCK_ABI_FILE}" > "${expected_missing}" || \
        die "rust_binder 缺失例外记录格式非法"
    LC_ALL=C sort -c -t "$(printf '\t')" -k2,2 "${expected_missing}" || \
        die "rust_binder 缺失例外未按符号排序"
    [ -z "$(cut -f2 "${expected_missing}" | uniq -d | sed -n '1,20p')" ] || \
        die "rust_binder 缺失例外存在重复符号"
    missing_count="$(wc -l < "${expected_missing}" | tr -d ' ')"
    missing_sha256="$(sha256sum "${expected_missing}" | awk '{ print $1 }')"
    [ "${missing_count}" = "${ANDROID17_STOCK_RUST_BINDER_MISSING_COUNT}" ] || \
        die "rust_binder 缺失例外数量错误: ${missing_count}"
    [ "${missing_sha256}" = "${ANDROID17_STOCK_RUST_BINDER_MISSING_SHA256}" ] || \
        die "rust_binder 缺失例外 SHA-256 不匹配"
    awk -F '\t' '
        NR == FNR { required[$2]=$1; next }
        !($2 in required) || required[$2] != $1 { bad=1 }
        END { exit bad }
    ' "${requirements}" "${expected_missing}" || \
        die "rust_binder 缺失例外不是完整需求的精确子集"

    : > "${actual_missing}"
    : > "${matching}"
    : > "${mismatched}"
    : > "${non_vmlinux}"
    awk -F '\t' \
        -v missing_file="${actual_missing}" \
        -v matching_file="${matching}" \
        -v mismatch_file="${mismatched}" \
        -v non_vmlinux_file="${non_vmlinux}" '
        NR == FNR {
            required[$2]=$1
            order[++count]=$2
            next
        }
        NF == 5 {
            actual_crc[$2]=$1
            provider[$2]=$3
        }
        END {
            for (i=1; i <= count; i++) {
                symbol=order[i]
                if (!(symbol in actual_crc))
                    print required[symbol] "\t" symbol > missing_file
                else if (actual_crc[symbol] != required[symbol])
                    print symbol "\tstock=" required[symbol] "\tbuild=" actual_crc[symbol] > mismatch_file
                else if (provider[symbol] != "vmlinux")
                    print symbol "\tprovider=" provider[symbol] > non_vmlinux_file
                else
                    print required[symbol] "\t" symbol > matching_file
            }
        }
    ' "${requirements}" "${BUILD_DIR}/Module.symvers"

    [ ! -s "${mismatched}" ] || \
        die "rust_binder 需求出现 CRC 不匹配:\n$(sed -n '1,20p' "${mismatched}")"
    [ ! -s "${non_vmlinux}" ] || \
        die "rust_binder 需求出现非 vmlinux provider:\n$(sed -n '1,20p' "${non_vmlinux}")"
    cmp -s "${expected_missing}" "${actual_missing}" || \
        die "rust_binder 67 项缺失例外发生变化:\n$(diff -u "${expected_missing}" "${actual_missing}" | sed -n '1,80p' || true)"
    match_count="$(wc -l < "${matching}" | tr -d ' ')"
    [ "${match_count}" = "${ANDROID17_STOCK_RUST_BINDER_MATCH_COUNT}" ] || \
        die "rust_binder vmlinux 精确匹配数量错误: ${match_count}"

    audit_compare "hard.rust-binder.requirements.count" \
        "${ANDROID17_STOCK_RUST_BINDER_REQUIREMENT_COUNT}" "${requirement_count}"
    audit_compare "hard.rust-binder.requirements.sha256" \
        "${ANDROID17_STOCK_RUST_BINDER_REQUIREMENT_SHA256}" "${requirement_sha256}"
    audit_compare "hard.rust-binder.match.count" \
        "${ANDROID17_STOCK_RUST_BINDER_MATCH_COUNT}" "${match_count}"
    audit_compare "hard.rust-binder.missing.count" \
        "${ANDROID17_STOCK_RUST_BINDER_MISSING_COUNT}" "${missing_count}"
    audit_compare "hard.rust-binder.missing.sha256" \
        "${ANDROID17_STOCK_RUST_BINDER_MISSING_SHA256}" "${missing_sha256}"
    log_success "rust_binder 精确例外硬门禁通过 (${match_count} match / ${missing_count} missing / 0 CRC mismatch / 0 non-vmlinux)"
}

verify_android17_stock_abi() {
    local actual_count duplicate_symbols missing_symbols mismatched_symbols
    local stock_tuples stock_tuple_count stock_tuple_sha256
    [ -s "${ANDROID17_STOCK_ABI_FILE}" ] || die "缺少小米 17 Android 17 stock ABI 清单"
    [ "$(sha256sum "${ANDROID17_STOCK_ABI_FILE}" | awk '{ print $1 }')" = \
      "${ANDROID17_STOCK_ABI_SHA256}" ] || die "Android 17 stock ABI 清单 SHA-256 不匹配"
    grep -Fx '# Luna Kernel Xiaomi 17 Android 17 stock-common ABI evidence v5' \
        "${ANDROID17_STOCK_ABI_FILE}" >/dev/null || die "Android 17 stock ABI 清单版本错误"
    grep -Fx "# system_dlkm.img: bytes=${ANDROID17_STOCK_SYSTEM_DLKM_SIZE} sha256:${ANDROID17_STOCK_SYSTEM_DLKM_SHA256}" \
        "${ANDROID17_STOCK_ABI_FILE}" >/dev/null || die "system_dlkm 身份未绑定到 ABI 清单"
    grep -Fx "# system_dlkm fingerprint: ${ANDROID17_STOCK_SYSTEM_DLKM_FINGERPRINT}" \
        "${ANDROID17_STOCK_ABI_FILE}" >/dev/null || die "system_dlkm fingerprint 未绑定到 ABI 清单"
    grep -Fx "# system_dlkm unique release: ${ANDROID17_STOCK_SYSTEM_DLKM_RELEASE}" \
        "${ANDROID17_STOCK_ABI_FILE}" >/dev/null || die "system_dlkm release 未绑定到 ABI 清单"
    grep -Fx "# normalized stock modules.order: entries=${ANDROID17_STOCK_MODULE_COUNT} sha256:${ANDROID17_STOCK_MODULES_ORDER_SHA256}; target module matrix is not frozen" \
        "${ANDROID17_STOCK_ABI_FILE}" >/dev/null || die "stock modules.order 证据未绑定到 system_dlkm 清单"
    awk -F '\t' '
        /^#/ || NF == 0 { next }
        NF != 2 || length($1) != 10 || substr($1, 1, 2) != "0x" ||
        substr($1, 3) !~ /^[0-9a-f]+$/ || $2 !~ /^[A-Za-z_][A-Za-z0-9_]*$/ { exit 1 }
    ' "${ANDROID17_STOCK_ABI_FILE}" || die "Android 17 stock ABI 清单格式非法"
    actual_count="$(awk -F '\t' '!/^#/ && NF { count++ } END { print count + 0 }' \
        "${ANDROID17_STOCK_ABI_FILE}")"
    [ "${actual_count}" = "${ANDROID17_STOCK_ABI_COUNT}" ] || \
        die "Android 17 stock ABI 清单数量错误: ${actual_count}"
    awk -F '\t' '!/^#/ && NF { print $2 }' "${ANDROID17_STOCK_ABI_FILE}" | \
        LC_ALL=C sort -cu || die "Android 17 stock ABI 清单未按符号排序或存在重复"

    duplicate_symbols="$(awk -F '\t' 'NF >= 3 { print $2 }' "${BUILD_DIR}/Module.symvers" | \
        LC_ALL=C sort | uniq -d | sed -n '1,20p')"
    [ -z "${duplicate_symbols}" ] || \
        die "Module.symvers 存在重复符号提供者，拒绝不确定匹配:\n${duplicate_symbols}"
    missing_symbols="$(LC_ALL=C comm -23 \
        <(awk -F '\t' '!/^#/ && NF { print $2 }' "${ANDROID17_STOCK_ABI_FILE}" | LC_ALL=C sort) \
        <(awk -F '\t' 'NF >= 3 && $3 == "vmlinux" { print $2 }' "${BUILD_DIR}/Module.symvers" | LC_ALL=C sort) | \
        sed -n '1,20p')"
    [ -z "${missing_symbols}" ] || \
        die "Android 17 stock 模块依赖的 vmlinux 符号缺失:\n${missing_symbols}"
    mismatched_symbols="$(LC_ALL=C join -t "$(printf '\t')" -1 1 -2 1 \
        <(awk -F '\t' '!/^#/ && NF { print $2 "\t" $1 }' "${ANDROID17_STOCK_ABI_FILE}" | LC_ALL=C sort -k1,1) \
        <(awk -F '\t' 'NF >= 3 && $3 == "vmlinux" { print $2 "\t" $1 }' "${BUILD_DIR}/Module.symvers" | LC_ALL=C sort -k1,1) | \
        awk -F '\t' '$2 != $3 { print $1 " stock=" $2 " build=" $3 }' | sed -n '1,20p')"
    [ -z "${mismatched_symbols}" ] || \
        die "Android 17 stock 模块所需 vmlinux CRC 不兼容:\n${mismatched_symbols}"

    stock_tuples="${AUDIT_DIR}/stock-required-vmlinux-tuples.tsv"
    awk -F '\t' '
        NR == FNR && !/^#/ && NF { required[$2]=1; next }
        NF == 5 && $3 == "vmlinux" && ($2 in required) {
            namespace=$5
            if (namespace == "") namespace="-"
            printf "%s\t%s\t%s\t%s\t%s\n", $2, $1, $3, $4, namespace
        }
    ' "${ANDROID17_STOCK_ABI_FILE}" "${BUILD_DIR}/Module.symvers" | \
        LC_ALL=C sort -t "$(printf '\t')" -k1,1 > "${stock_tuples}"
    stock_tuple_count="$(wc -l < "${stock_tuples}" | tr -d ' ')"
    stock_tuple_sha256="$(sha256sum "${stock_tuples}" | awk '{ print $1 }')"
    [ "${stock_tuple_count}" = "${ANDROID17_STOCK_ABI_TUPLE_COUNT}" ] || \
        die "Android 17 stock vmlinux tuple 数量不匹配: ${stock_tuple_count}"
    [ "${stock_tuple_sha256}" = "${ANDROID17_STOCK_ABI_TUPLE_SHA256}" ] || \
        die "Android 17 stock 模块所需 provider/export type/namespace 不兼容: ${stock_tuple_sha256}"
    audit_compare "hard.stock-vmlinux-tuples.count" \
        "${ANDROID17_STOCK_ABI_TUPLE_COUNT}" "${stock_tuple_count}"
    audit_compare "hard.stock-vmlinux-tuples.sha256" \
        "${ANDROID17_STOCK_ABI_TUPLE_SHA256}" "${stock_tuple_sha256}"
    verify_android17_stock_rust_binder
    log_success "小米 17 固定 OTA 模块闭包硬门禁通过 (${actual_count} 个 vmlinux 依赖及完整 tuple)"
}

verify_android17_stock_system_dlkm_identity() {
    [ -f "${ANDROID17_STOCK_SYSTEM_DLKM_FILE}" ] && \
        [ ! -L "${ANDROID17_STOCK_SYSTEM_DLKM_FILE}" ] || \
        die "缺少安全的同 OTA system_dlkm.img: ${ANDROID17_STOCK_SYSTEM_DLKM_FILE}"
    [ "$(stat -c '%s' "${ANDROID17_STOCK_SYSTEM_DLKM_FILE}")" = \
      "${ANDROID17_STOCK_SYSTEM_DLKM_SIZE}" ] || \
        die "system_dlkm.img 大小与固定 OTA 不符"
    [ "$(sha256sum "${ANDROID17_STOCK_SYSTEM_DLKM_FILE}" | awk '{ print $1 }')" = \
      "${ANDROID17_STOCK_SYSTEM_DLKM_SHA256}" ] || \
        die "system_dlkm.img SHA-256 与固定 OTA 不符"
    "${AVBTOOL_PATH}" verify_image --image "${ANDROID17_STOCK_SYSTEM_DLKM_FILE}" >/dev/null || \
        die "system_dlkm.img AVB hashtree 自洽校验失败"
    "${FSCK_EROFS_PATH}" "${ANDROID17_STOCK_SYSTEM_DLKM_FILE}" >/dev/null || \
        die "system_dlkm.img EROFS 完整性校验失败"
    log_success "同 OTA system_dlkm 身份、AVB hashtree 与 EROFS 完整性校验通过"
}

verify_stage_abi() {
    local all_symvers full_vmlinux duplicate_symbols
    local all_export_count all_export_sha256 abi_export_count abi_sha256
    local vendor_names vendor_map vendor_crc vendor_count vendor_sha256
    local abi_stg abi_stg_filter abi_stg_symbol_count abi_stg_sha256 stg_bin

    duplicate_symbols="$(awk -F '\t' 'NF >= 3 { print $2 }' "${BUILD_DIR}/Module.symvers" | \
        LC_ALL=C sort | uniq -d | sed -n '1,20p')"
    [ -z "${duplicate_symbols}" ] || \
        die "Module.symvers 存在重复符号提供者:\n${duplicate_symbols}"

    all_symvers="${AUDIT_DIR}/module-symvers.full.tsv"
    full_vmlinux="${AUDIT_DIR}/vmlinux.full.tsv"
    LC_ALL=C awk -F '\t' '
        NF != 5 || $1 !~ /^0x[0-9a-f]{8}$/ ||
        $2 !~ /^[A-Za-z_][A-Za-z0-9_]*$/ || $3 !~ /^[!-~]+$/ ||
        ($4 != "EXPORT_SYMBOL" && $4 != "EXPORT_SYMBOL_GPL") ||
        ($5 != "" && $5 !~ /^[!-~]+$/) { bad=1; next }
        { printf "%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5 }
        END { exit bad }
    ' "${BUILD_DIR}/Module.symvers" | LC_ALL=C sort -t "$(printf '\t')" \
        -k2,2 -k3,3 -k1,1 -k4,4 -k5,5 > "${all_symvers}" || \
        die "Module.symvers 五列格式非法"
    awk -F '\t' '$3 == "vmlinux" { print $1 "\t" $2 }' "${all_symvers}" | \
        LC_ALL=C sort -k2,2 > "${full_vmlinux}"

    all_export_count="$(wc -l < "${all_symvers}" | tr -d ' ')"
    all_export_sha256="$(sha256sum "${all_symvers}" | awk '{ print $1 }')"
    audit_compare "module-symvers.full.count" \
        "${STAGE_ABI_ALL_EXPORT_COUNT}" "${all_export_count}"
    audit_compare "module-symvers.full.sha256" \
        "${STAGE_ABI_ALL_SHA256}" "${all_export_sha256}"

    verify_android17_stock_abi

    abi_export_count="$(wc -l < "${full_vmlinux}" | tr -d ' ')"
    abi_sha256="$(sha256sum "${full_vmlinux}" | awk '{ print $1 }')"
    audit_compare "vmlinux.exports.full.count" \
        "${STAGE_ABI_EXPORT_COUNT}" "${abi_export_count}"
    audit_compare "vmlinux.exports.full.sha256" \
        "${STAGE_ABI_SHA256}" "${abi_sha256}"

    vendor_names="${AUDIT_DIR}/vendor-symbol-list.full.txt"
    vendor_map="${AUDIT_DIR}/module-symvers.by-symbol.tsv"
    vendor_crc="${AUDIT_DIR}/vendor-kmi.full.tsv"
    awk '/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/ {
        gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print
    }' "${COMMON_DIR}/gki/aarch64/symbols/qcom" \
       "${COMMON_DIR}/gki/aarch64/symbols/xiaomi" | LC_ALL=C sort -u > "${vendor_names}"
    awk -F '\t' '{ print $2 "\t" $1 }' "${all_symvers}" | \
        LC_ALL=C sort -k1,1 > "${vendor_map}"
    LC_ALL=C join -t "$(printf '\t')" -1 1 -2 1 "${vendor_names}" "${vendor_map}" | \
        awk -F '\t' '{ print $2 "\t" $1 }' > "${vendor_crc}"
    vendor_count="$(wc -l < "${vendor_crc}" | tr -d ' ')"
    [ "${vendor_count}" = "$(wc -l < "${vendor_names}" | tr -d ' ')" ] || \
        die "QCOM/Xiaomi symbol list 含未解析导出"
    vendor_sha256="$(sha256sum "${vendor_crc}" | awk '{ print $1 }')"
    audit_compare "vendor-kmi.full.count" \
        "${VENDOR_KMI_BASELINE_COUNT}" "${vendor_count}"
    audit_compare "vendor-kmi.full.sha256" \
        "${VENDOR_KMI_BASELINE_SHA256}" "${vendor_sha256}"

    stg_bin="${CI_TOOLCHAIN_DIR}/build-tools/bin/stg"
    abi_stg_filter="${AUDIT_DIR}/abi-exported-symbols"
    abi_stg="${AUDIT_DIR}/abi-exported.stg"
    [ -x "${stg_bin}" ] || die "缺少 STG ABI 提取工具"
    {
        printf '[abi_symbol_list]\n'
        awk -F '\t' '$3 == "vmlinux" { print $2 }' "${all_symvers}" | sed 's/^/  /'
    } > "${abi_stg_filter}"
    "${stg_bin}" --elf "${BUILD_DIR}/vmlinux" \
        --symbols ":${abi_stg_filter}" --output "${abi_stg}"
    abi_stg_symbol_count="$(grep -c '^elf_symbol {' "${abi_stg}")"
    abi_stg_sha256="$(sha256sum "${abi_stg}" | awk '{ print $1 }')"
    audit_compare "stg.full.count" "${STAGE_ABI_EXPORT_COUNT}" "${abi_stg_symbol_count}"
    audit_compare "stg.full.sha256" "${STAGE_ABI_STG_SHA256}" "${abi_stg_sha256}"
    log_success "固定 OTA 模块闭包通过；全量 ABI/KMI/STG 差异审计保存在 ${AUDIT_DIR}"
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
    normalize_archive_timestamps "${module_dir}"
    module_zip="${PRODUCT_DIR}/ipset-v${IPSET_VERSION}-android-arm64-kernelsu-module.zip"
    (cd "${module_dir}" && TZ=UTC 7z a -tzip -mtc=off -mta=off "${module_zip}" . >/dev/null)
    unzip -p "${module_zip}" system/bin/ipset | sha256sum | \
        grep -Fx "$(sha256sum "${binary}" | awk '{ print $1 }')  -" >/dev/null || die "IPSet 模块内命令校验失败"
    case "${module_dir}" in "${BUILD_DIR}"/ipset-module.*) rm -rf -- "${module_dir}" ;; *) die "拒绝清理异常临时目录" ;; esac
    log_success "IPSet 用户态命令与独立 KernelSU 模块已生成: $(basename "${module_zip}")"
}

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "${SCRIPT_SOURCE}")"
HOST_WORKSPACE_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")" && pwd -P)"

[ -f "${HOST_WORKSPACE_DIR}/.env" ] || die "缺少受版本控制的 .env"
load_env_file "${HOST_WORKSPACE_DIR}/.env"
[ "${ENABLE_KERNELSU:-0}" = "1" ] || \
    die "Luna 固定构建只支持 ENABLE_KERNELSU=1；拒绝未审计的第二套产品矩阵"
[ "${ENABLE_SUSFS:-0}" = "1" ] || \
    die "Luna 固定构建只支持 ENABLE_SUSFS=1；拒绝未审计的第二套产品矩阵"

WORKSPACE_NAME="$(sanitize_path_component "$(basename "${HOST_WORKSPACE_DIR}")")"
WORKSPACE_NAME="${WORKSPACE_NAME:-workspace}"
ORB_LINUX_ROOT="${ORB_LINUX_ROOT:-.cache/xiaomi_kernel_build}"
ORB_LINUX_PROJECT="${ORB_LINUX_ROOT%/}/${WORKSPACE_NAME}"
ORB_LINUX_WORKSPACE="${ORB_LINUX_PROJECT}/workspace"
ORB_LINUX_OUTBOX="${ORB_LINUX_PROJECT}/outbox"
ORB_RESULT_ARCHIVE="${SCRIPT_NAME%.sh}-result.tar"
ARTIFACT_MANIFEST_NAME=".build-artifacts"

BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-kernel_out}"
PRODUCT_DIR=""

resolve_project_identity
prepare_product_directory "${BUILD_OUTPUT_DIR}"
clean_previous_release_artifacts "${PRODUCT_DIR}" "${ARTIFACT_MANIFEST_NAME}"
run_in_orb_if_needed "$@"

KERNEL_REPO="${KERNEL_REPO:-https://github.com/MiCode/Xiaomi_Kernel_OpenSource.git}"
KERNEL_COMMIT="${KERNEL_COMMIT:-45705be1220b4cfa8100516ad86711656c0b634e}"
SOC_DIR="$(resolve_workspace_path "${SOC_SOURCE_DIR:-sources/xiaomi_sm8850_soc}")"
COMMON_REPO="${COMMON_REPO:-https://android.googlesource.com/kernel/common}"
COMMON_COMMIT="${COMMON_COMMIT:-0316e9866fdf55601aae97b14ee08d1b38a3916c}"
COMMON_DIR="$(resolve_workspace_path "${COMMON_SOURCE_DIR:-sources/aosp_common_6.12.92_kmi6_2026-09}")"
TEGRA_MC_KMI_PATCH_FILE="${HOST_WORKSPACE_DIR}/${TEGRA_MC_KMI_PATCH:-patches/kmi/tegra-mc-opaque-pointer-kmi-r21.patch}"
TEGRA_MC_KMI_PATCH_SHA256="${TEGRA_MC_KMI_PATCH_SHA256:-ed862fd9b766ba5ee47baef59b4f6485c9ee8545c5a3270f2f58258082a9a792}"
TEGRA_MC_KMI_PATCH_ID="${TEGRA_MC_KMI_PATCH_ID:-120d76a884b594c227377b034f0eecf1071b5b91}"
ENABLE_KERNELSU="${ENABLE_KERNELSU:-0}"
KSU_REPO="${KSU_REPO:-https://github.com/tiann/KernelSU.git}"
KSU_REF="${KSU_REF:-main}"
KSU_COMMIT="${KSU_COMMIT:-623eba3e092b911a3a7389b7d87622a5835d2f3a}"
KSU_DIR="$(resolve_workspace_path "${KSU_SOURCE_DIR:-sources/kernelsu}")"
KSU_INTEGRATION_MODE="${KSU_INTEGRATION_MODE:-builtin}"
KSU_GIT_VERSION_COUNT="${KSU_GIT_VERSION_COUNT:-2651}"
KSU_VERSION_CODE="${KSU_VERSION_CODE:-32651}"
KSU_SELINUX_HIDE_FIX_COMMIT="${KSU_SELINUX_HIDE_FIX_COMMIT:-3f388ef137c78e1ca0c92c0ada3b8717cdcc4302}"
KSU_ENHANCED_SECURITY_REMOVAL_COMMIT="${KSU_ENHANCED_SECURITY_REMOVAL_COMMIT:-1b6e2ed6b38dad1c8af90402a82ed2f752b05cfa}"
KSU_MANAGER_APK="${KSU_MANAGER_APK:-KernelSU_v3.3.0-50-g623eba3e_32651-release.apk}"
KSU_MANAGER_SHA256="${KSU_MANAGER_SHA256:-1c7cec1aa8a1d6bd023efdf31dd9f5fa5deb5e84acc904ae1b8e3a5097171b45}"
ENABLE_SUSFS="${ENABLE_SUSFS:-0}"
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_REF="${SUSFS_REF:-gki-android16-6.12}"
SUSFS_COMMIT="${SUSFS_COMMIT:-b213c54126fb243595ce7876e91d84d6e0861fec}"
SUSFS_DIR="$(resolve_workspace_path "${SUSFS_SOURCE_DIR:-sources/susfs4ksu}")"
SUSFS_KSU_PATCH_COMMIT="${SUSFS_KSU_PATCH_COMMIT:-b213c54126fb243595ce7876e91d84d6e0861fec}"
SUSFS_HELPER_SHA256="${SUSFS_HELPER_SHA256:-4b4c392851723a08af49c5a104462897ec9e2fac89f3a2b3faa291290341c749}"
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
ENABLE_STAGE4_FS="${ENABLE_STAGE4_FS:-0}"
AOSP_BACKPORT_AUDIT_DIR="$(resolve_workspace_path "${AOSP_BACKPORT_AUDIT_SOURCE_DIR:-sources/aosp_common_backport_audit}")"
LINUX_STABLE_AUDIT_DIR="$(resolve_workspace_path "${LINUX_STABLE_AUDIT_SOURCE_DIR:-sources/linux_stable_6.12_audit}")"
LINUX_STABLE_AUDIT_COMMIT="${LINUX_STABLE_AUDIT_COMMIT:-}"
LINUX_MAINLINE_AUDIT_DIR="$(resolve_workspace_path "${LINUX_MAINLINE_AUDIT_SOURCE_DIR:-sources/linux_mainline_audit}")"
LINUX_MAINLINE_AUDIT_COMMIT="${LINUX_MAINLINE_AUDIT_COMMIT:-}"
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
F2FS_FOREGROUND_GC_PATCH_SHA256="${F2FS_FOREGROUND_GC_PATCH_SHA256:-f105094430a7d6c1101767b99da3dbf3d1434feba63ae4b99dec4394962947e9}"
F2FS_FOREGROUND_GC_PATCH_ID="${F2FS_FOREGROUND_GC_PATCH_ID:-70442d9fb39ac24622e33231473817e5dc60249b}"
ENABLE_TIMER_BASE_FAST_PATH="${ENABLE_TIMER_BASE_FAST_PATH:-0}"
TIMER_BASE_FAST_PATH_COMMIT="${TIMER_BASE_FAST_PATH_COMMIT:-3ec955713d9617059d2fc8f2816d0b95ace72256}"
TIMER_BASE_FAST_PATH_COMMIT_DATE="${TIMER_BASE_FAST_PATH_COMMIT_DATE:-2025-01-16}"
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
COMMON_BASE_TRACKED_DIFF_SHA256="${COMMON_BASE_TRACKED_DIFF_SHA256:-}"
KSU_TRACKED_DIFF_SHA256="${KSU_TRACKED_DIFF_SHA256:-}"
ENABLE_STAGE5_NAMESPACES="${ENABLE_STAGE5_NAMESPACES:-0}"
ENABLE_STAGE5_NETWORK="${ENABLE_STAGE5_NETWORK:-0}"
ENABLE_IPSET="${ENABLE_IPSET:-0}"
IPSET_VERSION="${IPSET_VERSION:-7.24}"
IPSET_TREE_SHA256="${IPSET_TREE_SHA256:-70530678f3318aad36a3fb8acb3eba17a27ad5e464c0caeb8912dee43f0a81ea}"
IPSET_DIR="$(resolve_workspace_path "${IPSET_SOURCE_DIR:-sources/ipset-7.24}")"
LIBMNL_VERSION="${LIBMNL_VERSION:-1.0.5}"
LIBMNL_TREE_SHA256="${LIBMNL_TREE_SHA256:-8d6597fd107489c8d90106d99302ff5efb061fe38bb3952f8a1062626b80a7c2}"
LIBMNL_DIR="$(resolve_workspace_path "${LIBMNL_SOURCE_DIR:-sources/libmnl-1.0.5}")"
ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION:-r29}"
ANDROID_NDK_TREE_SHA256="${ANDROID_NDK_TREE_SHA256:-401eb9a77478012fdc0c31e986379bf04db9fd72455b060dd13fcce07b84b98e}"
ANDROID_NDK_API="${ANDROID_NDK_API:-35}"
XIAOMI_ACK_BRANCH="${XIAOMI_ACK_BRANCH:-android16-6.12-2025-06_r8}"
XIAOMI_ACK_COMMIT="${XIAOMI_ACK_COMMIT:-f1bdb13583da85a47fcf1632a78ef52d6e6da651}"

verify_repo_identity "Xiaomi popsicle soc-repo" "${SOC_DIR}" "${KERNEL_REPO}" "${KERNEL_COMMIT}"
verify_repo_identity "Android 16 GKI common 九月 KMI6" "${COMMON_DIR}" "${COMMON_REPO}" "${COMMON_COMMIT}" "0"
[ "$(sed -n 's/^VERSION = //p' "${COMMON_DIR}/Makefile").$(sed -n 's/^PATCHLEVEL = //p' "${COMMON_DIR}/Makefile").$(sed -n 's/^SUBLEVEL = //p' "${COMMON_DIR}/Makefile")" = "${COMMON_VERSION:?缺少 COMMON_VERSION}" ] || \
    die "GKI common 版本不是 ${COMMON_VERSION}"
[ "$(sed -n 's/^KMI_GENERATION=//p' "${COMMON_DIR}/build.config.constants")" = "6" ] || \
    die "GKI common KMI generation 不是 6"
verify_first_batch_linux_backports
verify_second_batch_backports
verify_memcg_rstat_fast_path
verify_tcp_recv_mstamp_fast_path
verify_ipv6_mld_uaf_fix
verify_ipv6_mld_delayed_work_uaf_fix
verify_android17_selected_fixes
[ "${ENABLE_SELECTED_BACKPORTS:-0}" != "1" ] || \
    bash "${HOST_WORKSPACE_DIR}/tools/backport_manifest.sh" verify-applied "${COMMON_DIR}"
bash "${HOST_WORKSPACE_DIR}/tools/independent_backports.sh" \
    verify-applied "${COMMON_DIR}"
[ "${ENABLE_KERNELSU}" != "1" ] || verify_kernelsu_source_state
[ "${ENABLE_SUSFS}" != "1" ] || verify_susfs_source_state
[ "${ENABLE_BBG}" != "1" ] || verify_bbg_source_state
[ "$(sed -n '1p' "${SOC_DIR}/android/ACK_SHA")" = "${XIAOMI_ACK_COMMIT}" ] || die "小米 ACK_SHA commit 已变化"
[ "$(sed -n '2p' "${SOC_DIR}/android/ACK_SHA")" = "${XIAOMI_ACK_BRANCH}" ] || die "小米 ACK_SHA tag 已变化"

BUILD_JOBS="$(detect_cpu_count)"
BUILD_DIR="$(resolve_workspace_path "${BUILD_DIR:-kernel_out/.build-kmi6-2026-09}")"
STAGE_CONFIG_LINES="${STAGE_CONFIG_LINES:-}"
STAGE_CONFIG_SHA256="${STAGE_CONFIG_SHA256:-}"
STAGE_MODULE_COUNT="${STAGE_MODULE_COUNT:-}"
STAGE_MODULES_ORDER_SHA256="${STAGE_MODULES_ORDER_SHA256:-}"
VENDOR_KMI_BASELINE_COUNT="${VENDOR_KMI_BASELINE_COUNT-}"
VENDOR_KMI_BASELINE_SHA256="${VENDOR_KMI_BASELINE_SHA256-}"
STAGE_ABI_EXPORT_COUNT="${STAGE_ABI_EXPORT_COUNT:-}"
STAGE_ABI_SHA256="${STAGE_ABI_SHA256:-}"
STAGE_ABI_STG_SHA256="${STAGE_ABI_STG_SHA256:-}"
STAGE_ABI_ALL_EXPORT_COUNT="${STAGE_ABI_ALL_EXPORT_COUNT:-}"
STAGE_ABI_ALL_SHA256="${STAGE_ABI_ALL_SHA256:-}"
ANDROID17_STOCK_ABI_FILE="$(resolve_workspace_path "${ANDROID17_STOCK_ABI_MANIFEST:-abi/xiaomi17-android17-stock-common-abi.tsv}")"
ANDROID17_STOCK_ABI_COUNT="${ANDROID17_STOCK_ABI_COUNT:-}"
ANDROID17_STOCK_ABI_SHA256="${ANDROID17_STOCK_ABI_SHA256:-}"
ANDROID17_STOCK_ABI_TUPLE_COUNT="${ANDROID17_STOCK_ABI_TUPLE_COUNT:-}"
ANDROID17_STOCK_ABI_TUPLE_SHA256="${ANDROID17_STOCK_ABI_TUPLE_SHA256:-}"
ANDROID17_STOCK_RUST_BINDER_REQUIREMENT_COUNT="${ANDROID17_STOCK_RUST_BINDER_REQUIREMENT_COUNT:-}"
ANDROID17_STOCK_RUST_BINDER_REQUIREMENT_SHA256="${ANDROID17_STOCK_RUST_BINDER_REQUIREMENT_SHA256:-}"
ANDROID17_STOCK_RUST_BINDER_MATCH_COUNT="${ANDROID17_STOCK_RUST_BINDER_MATCH_COUNT:-}"
ANDROID17_STOCK_RUST_BINDER_MISSING_COUNT="${ANDROID17_STOCK_RUST_BINDER_MISSING_COUNT:-}"
ANDROID17_STOCK_RUST_BINDER_MISSING_SHA256="${ANDROID17_STOCK_RUST_BINDER_MISSING_SHA256:-}"
ANDROID17_STOCK_MODULE_VERMAGIC_SUFFIX="${ANDROID17_STOCK_MODULE_VERMAGIC_SUFFIX:-}"
ANDROID17_STOCK_MODULE_COUNT="${ANDROID17_STOCK_MODULE_COUNT:-}"
ANDROID17_STOCK_MODULES_ORDER_SHA256="${ANDROID17_STOCK_MODULES_ORDER_SHA256:-}"
ANDROID17_STOCK_SYSTEM_DLKM_FILE="$(resolve_workspace_path "${ANDROID17_STOCK_SYSTEM_DLKM_IMAGE:-tmp/os4/system_dlkm.img}")"
ANDROID17_STOCK_SYSTEM_DLKM_SHA256="${ANDROID17_STOCK_SYSTEM_DLKM_SHA256:-}"
ANDROID17_STOCK_SYSTEM_DLKM_SIZE="${ANDROID17_STOCK_SYSTEM_DLKM_SIZE:-}"
ANDROID17_STOCK_SYSTEM_DLKM_RELEASE="${ANDROID17_STOCK_SYSTEM_DLKM_RELEASE:-}"
ANDROID17_STOCK_SYSTEM_DLKM_FINGERPRINT="${ANDROID17_STOCK_SYSTEM_DLKM_FINGERPRINT:-}"
LUNA_PROJECT_SHORT="${LUNA_PROJECT_COMMIT:0:8}"
KERNEL_LOCALVERSION="-android16-luna-g${LUNA_PROJECT_SHORT}-4k"
KERNEL_BUILD_USER="${KERNEL_BUILD_USER:-luna}"
KERNEL_BUILD_HOST="${KERNEL_BUILD_HOST:-luna-build}"
KERNEL_BUILD_TIMESTAMP="${KERNEL_BUILD_TIMESTAMP:-2026-09-30 21:35:37 +0000}"
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
[ "${KERNEL_BUILD_TIMESTAMP}" = "$(git -C "${COMMON_DIR}" show -s --format=%ci "${COMMON_COMMIT}")" ] || die "内核构建时间必须固定为 common 提交时间"
[ "${KERNEL_BUILD_VERSION}" = "1" ] || die "内核构建版本必须固定为 1"
[ "${AK3_BOOT_PARTITION_SIZE}" = "100663296" ] || die "小米 17 boot 分区容量必须固定为 100663296 字节"
[[ "${AK3_UPSTREAM_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "AnyKernel3 脚本 commit 格式错误"
[[ "${AK3_ARM64_TOOLS_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "AnyKernel3 工具 commit 格式错误"
for ak3_sha256 in \
    "${AK3_BUSYBOX_SHA256}" \
    "${AK3_ANYKERNEL_SH_SHA256}" \
    "${AK3_UPDATE_BINARY_SHA256}" \
    "${AK3_UPDATER_SCRIPT_SHA256}" \
    "${AK3_CORE_SHA256}" \
    "${AK3_LICENSE_SHA256}" \
    "${AK3_LUNA_PATCH_SHA256}" \
    "${AK3_LUNA_ANYKERNEL_SH_SHA256}" \
    "${AK3_LUNA_UPDATE_BINARY_SHA256}" \
    "${AK3_LUNA_UPDATER_SCRIPT_SHA256}" \
    "${AK3_LUNA_CORE_SHA256}"; do
    [[ "${ak3_sha256}" =~ ^[0-9a-f]{64}$ ]] || die "AnyKernel3 SHA-256 pin 格式错误"
done
[[ "${MAGISK_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "Magisk commit 格式错误"
[[ "${MAGISKBOOT_ARM64_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "arm64 magiskboot SHA-256 格式错误"
[[ "${COMMON_BASE_TRACKED_DIFF_SHA256}" =~ ^[0-9a-f]{64}$ ]] || \
    die "GKI common 基础差异快照格式错误或尚未固定"
[[ "${KSU_TRACKED_DIFF_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "KernelSU 精确差异快照格式错误或尚未固定"
[[ "${ANDROID17_STOCK_ABI_COUNT}" =~ ^[1-9][0-9]*$ ]] || die "Android 17 stock ABI 数量快照格式错误"
[[ "${ANDROID17_STOCK_ABI_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "Android 17 stock ABI SHA-256 快照格式错误"
[[ "${ANDROID17_STOCK_ABI_TUPLE_COUNT}" =~ ^[1-9][0-9]*$ ]] || die "Android 17 stock ABI tuple 数量格式错误"
[[ "${ANDROID17_STOCK_ABI_TUPLE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "Android 17 stock ABI tuple SHA-256 格式错误"
[ "${ANDROID17_STOCK_ABI_TUPLE_COUNT}" = "${ANDROID17_STOCK_ABI_COUNT}" ] || \
    die "Android 17 stock ABI tuple 数量未覆盖全部清单依赖"
[[ "${ANDROID17_STOCK_RUST_BINDER_REQUIREMENT_COUNT}" =~ ^[1-9][0-9]*$ ]] || \
    die "rust_binder 完整需求数量格式错误"
[[ "${ANDROID17_STOCK_RUST_BINDER_REQUIREMENT_SHA256}" =~ ^[0-9a-f]{64}$ ]] || \
    die "rust_binder 完整需求 SHA-256 格式错误"
[[ "${ANDROID17_STOCK_RUST_BINDER_MATCH_COUNT}" =~ ^[1-9][0-9]*$ ]] || \
    die "rust_binder 匹配数量格式错误"
[[ "${ANDROID17_STOCK_RUST_BINDER_MISSING_COUNT}" =~ ^[1-9][0-9]*$ ]] || \
    die "rust_binder 缺失数量格式错误"
[[ "${ANDROID17_STOCK_RUST_BINDER_MISSING_SHA256}" =~ ^[0-9a-f]{64}$ ]] || \
    die "rust_binder 缺失 SHA-256 格式错误"
[ "$((ANDROID17_STOCK_RUST_BINDER_MATCH_COUNT + ANDROID17_STOCK_RUST_BINDER_MISSING_COUNT))" = \
  "${ANDROID17_STOCK_RUST_BINDER_REQUIREMENT_COUNT}" ] || \
    die "rust_binder 匹配与缺失数量未覆盖完整需求"
[ "${ANDROID17_STOCK_MODULE_VERMAGIC_SUFFIX}" = "SMP preempt mod_unload modversions aarch64" ] || \
    die "固定 OTA 模块 vermagic 后缀异常"
[[ "${ANDROID17_STOCK_MODULE_COUNT}" =~ ^[1-9][0-9]*$ ]] || die "固定 OTA modules.order 数量格式错误"
[[ "${ANDROID17_STOCK_MODULES_ORDER_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "固定 OTA modules.order SHA-256 格式错误"
[[ "${ANDROID17_STOCK_SYSTEM_DLKM_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "system_dlkm.img SHA-256 快照格式错误"
[[ "${ANDROID17_STOCK_SYSTEM_DLKM_SIZE}" =~ ^[1-9][0-9]*$ ]] || die "system_dlkm.img 大小快照格式错误"
[ "${ANDROID17_STOCK_SYSTEM_DLKM_IMAGE:-}" = "tmp/os4/system_dlkm.img" ] || \
    die "system_dlkm 兼容性输入路径必须固定为 tmp/os4/system_dlkm.img"
[ -n "${ANDROID17_STOCK_SYSTEM_DLKM_RELEASE}" ] && \
    [[ "${ANDROID17_STOCK_SYSTEM_DLKM_RELEASE}" =~ ^[A-Za-z0-9._+-]+$ ]] || \
    die "system_dlkm stock release 快照格式错误"
[ -n "${ANDROID17_STOCK_SYSTEM_DLKM_FINGERPRINT}" ] && \
    [[ "${ANDROID17_STOCK_SYSTEM_DLKM_FINGERPRINT}" =~ ^[A-Za-z0-9./:_+-]+$ ]] || \
    die "system_dlkm OTA fingerprint 快照格式错误"
[[ "${STAGE_CONFIG_LINES}" =~ ^[1-9][0-9]*$ ]] || die "阶段配置行数快照格式错误"
[[ "${STAGE_CONFIG_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "阶段配置 SHA-256 快照格式错误"
[[ "${STAGE_MODULE_COUNT}" =~ ^[1-9][0-9]*$ ]] || die "阶段模块数量快照格式错误"
[[ "${STAGE_MODULES_ORDER_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "阶段模块顺序 SHA-256 快照格式错误"
[[ "${VENDOR_KMI_BASELINE_COUNT}" =~ ^[1-9][0-9]*$ ]] || die "vendor KMI 数量快照格式错误"
[[ "${VENDOR_KMI_BASELINE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "vendor KMI SHA-256 快照格式错误"
[[ "${STAGE_ABI_EXPORT_COUNT}" =~ ^[1-9][0-9]*$ ]] || die "vmlinux 投影数量快照格式错误"
[[ "${STAGE_ABI_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "vmlinux 投影 SHA-256 快照格式错误"
[[ "${STAGE_ABI_STG_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "STG 投影 SHA-256 快照格式错误"
[[ "${STAGE_ABI_ALL_EXPORT_COUNT}" =~ ^[1-9][0-9]*$ ]] || die "Module.symvers 投影数量格式错误"
[[ "${STAGE_ABI_ALL_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "Module.symvers 投影 SHA-256 快照格式错误"
verify_project_patch "Tegra MC opaque-pointer KMI compatibility" \
    "${TEGRA_MC_KMI_PATCH_FILE}" "${TEGRA_MC_KMI_PATCH_SHA256}" \
    "${TEGRA_MC_KMI_PATCH_ID}"
git -C "${COMMON_DIR}" apply --reverse --check "${TEGRA_MC_KMI_PATCH_FILE}" || \
    die "Tegra MC opaque-pointer KMI compatibility patch status is invalid"
verify_final_source_deltas
EXPECTED_RELEASE="${COMMON_VERSION}${KERNEL_LOCALVERSION}"
EXPECTED_VERSION_LINE="Linux version ${EXPECTED_RELEASE} (${KERNEL_BUILD_USER}@${KERNEL_BUILD_HOST}) (Android (14043575, +pgo, +bolt, +lto, +mlgo, based on r536225) clang version 19.0.1 (https://android.googlesource.com/toolchain/llvm-project b3a530ec6537146650e42be89f1089e9a3588460), LLD 19.0.1) #${KERNEL_BUILD_VERSION} SMP PREEMPT ${KERNEL_BUILD_TIMESTAMP}"

ENVIRONMENT_DIR="$(resolve_workspace_path "${BUILD_ENVIRONMENT_DIR:-environment}")"
CI_TOOLCHAIN_DIR="${ENVIRONMENT_DIR}/toolchain/ci-sm8850-r536225"
ANDROID_NDK_DIR="${ENVIRONMENT_DIR}/toolchain/android-ndk-${ANDROID_NDK_VERSION}"
MAGISKBOOT_ARM64_PATH="${ENVIRONMENT_DIR}/magisk/v${MAGISK_VERSION}/magiskboot-arm64"
AK3_TEMPLATE_DIR="${HOST_WORKSPACE_DIR}/ak3_template"
AK3_BUSYBOX_PATH="${ENVIRONMENT_DIR}/anykernel3/${AK3_ARM64_TOOLS_COMMIT}/busybox-arm64"
AVBTOOL_PATH="${CI_TOOLCHAIN_DIR}/build-tools/bin/avbtool"
FSCK_EROFS_PATH="${CI_TOOLCHAIN_DIR}/build-tools/bin/fsck.erofs"
CI_TOOLCHAIN_TREE_SHA256="${CI_TOOLCHAIN_TREE_SHA256:-65644bd77ed4ecde7239e3ce5a4aa53451a28c0a52b12394b88c5bd095517cc0}"

[ -x "${CI_TOOLCHAIN_DIR}/bin/clang" ] || die "工具链未初始化，请先运行 ./init.sh"
[ -x "${CI_TOOLCHAIN_DIR}/bin/rustc" ] || die "Rust 工具链未初始化，请先运行 ./init.sh"
[ -x "${CI_TOOLCHAIN_DIR}/bindgen-cli-x86_64-unknown-linux-gnu/bindgen" ] || die "bindgen 未初始化，请先运行 ./init.sh"
[ -d "${CI_TOOLCHAIN_DIR}/build-tools/bin" ] || die "build-tools 未初始化，请先运行 ./init.sh"
[ -x "${AVBTOOL_PATH}" ] || die "固定 build-tools 缺少 avbtool"
[ -x "${FSCK_EROFS_PATH}" ] || die "固定 build-tools 缺少 fsck.erofs"
[ -x "${MAGISKBOOT_ARM64_PATH}" ] || die "arm64 magiskboot 未初始化，请先运行 ./init.sh"
[ "$(sha256sum "${MAGISKBOOT_ARM64_PATH}" | awk '{ print $1 }')" = "${MAGISKBOOT_ARM64_SHA256}" ] || \
    die "arm64 magiskboot SHA-256 校验失败，请重新运行 ./init.sh"
[ -x "${AK3_BUSYBOX_PATH}" ] || die "AnyKernel3 arm64 BusyBox 未初始化，请先运行 ./init.sh"
[ "$(sha256sum "${AK3_BUSYBOX_PATH}" | awk '{ print $1 }')" = "${AK3_BUSYBOX_SHA256}" ] || \
    die "AnyKernel3 arm64 BusyBox SHA-256 校验失败，请重新运行 ./init.sh"
[[ "${CI_TOOLCHAIN_TREE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "工具链安装树 SHA-256 格式错误"
[ "$(tree_sha256 "${CI_TOOLCHAIN_DIR}")" = "${CI_TOOLCHAIN_TREE_SHA256}" ] || \
    die "工具链安装树完整性校验失败，请重新运行 ./init.sh"
verify_android17_stock_system_dlkm_identity
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
if [ "${ENABLE_CCACHE:-0}" = 1 ] && command -v ccache >/dev/null 2>&1; then
    CC='ccache clang'
    log_success "复用 ccache 编译缓存"
fi

MAKE_ARGS=(
    ARCH=arm64 SUBARCH=arm64 LLVM=1 LLVM_IAS=1 O="${BUILD_DIR}"
    LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump OBJSIZE=llvm-size READELF=llvm-readelf STRIP=llvm-strip
    CC="${CC}" HOSTCC="${CI_TOOLCHAIN_DIR}/host-bin/cc" HOSTCFLAGS="-Wno-error=discarded-qualifiers"
    CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
    RUSTC=rustc HOSTRUSTC=rustc HOSTRUSTFLAGS="-Clinker=/usr/bin/x86_64-linux-gnu-gcc"
    BINDGEN=bindgen HOSTLD=/usr/bin/ld KCFLAGS="-Wno-error=unknown-warning-option"
    LOCALVERSION="${KERNEL_LOCALVERSION}"
    KBUILD_BUILD_USER="${KERNEL_BUILD_USER}"
    KBUILD_BUILD_HOST="${KERNEL_BUILD_HOST}"
    KBUILD_BUILD_TIMESTAMP="${KERNEL_BUILD_TIMESTAMP}"
    KBUILD_BUILD_VERSION="${KERNEL_BUILD_VERSION}"
)

AUDIT_DIR="${BUILD_DIR%/}/luna-compatibility-audit"
[ ! -L "${AUDIT_DIR}" ] || die "ABI/KMI 审计目录不得为符号链接"
mkdir -p "${AUDIT_DIR}"
find "${AUDIT_DIR}" -mindepth 1 -delete
AUDIT_REPORT="${AUDIT_DIR}/summary.tsv"
AUDIT_DRIFT_COUNT=0
{
    printf '# Luna Xiaomi 17 build snapshot audit\n'
    printf '# DRIFT requires review and refreshed reference snapshots before release packaging.\n'
    printf '# Fixed OTA module-closure failures abort immediately and cannot be reviewed away.\n'
    printf 'status\tmetric\treference\tactual\n'
} > "${AUDIT_REPORT}"

log_step "生成 Android 16 GKI ${COMMON_VERSION} 配置"
make -C "${COMMON_DIR}" "${MAKE_ARGS[@]}" gki_defconfig
bash "${COMMON_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
    --disable WERROR \
    --disable LOCALVERSION_AUTO \
    --disable TRIM_UNUSED_KSYMS \
    --enable BASIC_MODVERSIONS \
    --enable EXTENDED_MODVERSIONS \
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
    --enable BLK_WBT_MQ \
    --enable MODULE_ALLOW_BTF_MISMATCH \
    --enable ARM_PKVM_GUEST \
    --enable VFIO_PKVM_IOMMU \
    --enable PKVM_PVIOMMU \
    --disable CRYPTO_AES_ARM64_NEON_BLK \
    --disable EFIVAR_FS \
    --disable PSTORE_BLK \
    --disable PSTORE_ZONE \
    --disable SND_AUDIO_GRAPH_CARD \
    --disable SND_SIMPLE_CARD_UTILS \
    --disable USB_XHCI_PCI_RENESAS \
    --disable NINTENDO_FF \
    --set-str LOCALVERSION ""
if [ "${ENABLE_KERNELSU}" = "1" ]; then
    bash "${COMMON_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --enable KSU \
        --disable KSU_DEBUG
fi
if [ "${ENABLE_SUSFS}" = "1" ]; then
    bash "${COMMON_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --enable KSU_SUSFS \
        --disable KSU_SUSFS_OPEN_REDIRECT
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
        --module NETFS_SUPPORT \
        --disable CIFS \
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
cp -f "${BUILD_DIR}/.config" "${AUDIT_DIR}/config.current"
[ "${ENABLE_BBG}" != "1" ] || verify_lsm_slot_capacity

log_step "编译 GKI arm64 Image 与模块 (并行度: ${BUILD_JOBS})"
make -C "${COMMON_DIR}" "${MAKE_ARGS[@]}" Image modules -j"${BUILD_JOBS}"

IMAGE_PATH="${BUILD_DIR}/arch/arm64/boot/Image"
[ -f "${IMAGE_PATH}" ] || die "编译完成但未找到 Image: ${IMAGE_PATH}"
[ -s "${BUILD_DIR}/Module.symvers" ] || die "编译完成但未找到 Module.symvers"
[ -s "${BUILD_DIR}/modules.order" ] || die "编译完成但未找到 modules.order"
MODULE_COUNT="$(sed '/^[[:space:]]*$/d' "${BUILD_DIR}/modules.order" | wc -l | tr -d ' ')"
MODULES_ORDER_SHA256="$(sha256sum "${BUILD_DIR}/modules.order" | awk '{ print $1 }')"
MODULE_SAMPLE_PATH=""
while IFS= read -r module_path; do
    [ -z "${module_path}" ] && continue
    case "${module_path}" in
        /*|../*|*/../*|*/..) die "modules.order 含不安全路径: ${module_path}" ;;
        *.o) ;;
        *) die "modules.order 条目不是模块对象: ${module_path}" ;;
    esac
    [ -s "${BUILD_DIR}/${module_path}" ] || die "活动模块对象缺失: ${module_path}"
    module_path="${module_path%.o}.ko"
    [ -s "${BUILD_DIR}/${module_path}" ] || die "活动模块 ELF 缺失: ${module_path}"
    [ -n "${MODULE_SAMPLE_PATH}" ] || MODULE_SAMPLE_PATH="${module_path}"
done < "${BUILD_DIR}/modules.order"
[ -n "${MODULE_SAMPLE_PATH}" ] || die "modules.order 不含活动模块"
cp -f "${BUILD_DIR}/modules.order" "${AUDIT_DIR}/modules.order.current"
MODULE_SAMPLE_VERMAGIC="$("${CI_TOOLCHAIN_DIR}/bin/llvm-readelf" -p .modinfo \
    "${BUILD_DIR}/${MODULE_SAMPLE_PATH}" | sed -n 's/^.*] vermagic=//p')"
[ "$(printf '%s\n' "${MODULE_SAMPLE_VERMAGIC}" | sed '/^$/d' | wc -l | tr -d ' ')" = "1" ] || \
    die "无法从活动模块提取唯一 vermagic: ${MODULE_SAMPLE_PATH}"
[ "${MODULE_SAMPLE_VERMAGIC#* }" = "${ANDROID17_STOCK_MODULE_VERMAGIC_SUFFIX}" ] || \
    die "活动模块 vermagic 后缀与固定 OTA 不兼容: ${MODULE_SAMPLE_VERMAGIC}"
audit_compare "hard.module-vermagic.suffix" "${ANDROID17_STOCK_MODULE_VERMAGIC_SUFFIX}" \
    "${MODULE_SAMPLE_VERMAGIC#* }"
audit_compare "modules.order.count" "${STAGE_MODULE_COUNT}" "${MODULE_COUNT}"
audit_compare "modules.order.sha256" "${STAGE_MODULES_ORDER_SHA256}" "${MODULES_ORDER_SHA256}"
log_success "活动模块产物与固定 OTA vermagic 后缀兼容 (${MODULE_COUNT} 个模块)"

[ "${ENABLE_KERNELSU}" != "1" ] || verify_kernelsu_build
[ "${ENABLE_BBG}" != "1" ] || verify_bbg_build
verify_stage5_selected_build

verify_symbol_list_exports "${COMMON_DIR}/gki/aarch64/symbols/qcom" "QCOM"
verify_symbol_list_exports "${COMMON_DIR}/gki/aarch64/symbols/xiaomi" "Xiaomi"
verify_stage_abi

EMBEDDED_CONFIG_FILE="${AUDIT_DIR}/image.config.current"
EMBEDDED_CONFIG_LOG="${AUDIT_DIR}/image-config-extract.stderr"
if ! "${COMMON_DIR}/scripts/extract-ikconfig" "${IMAGE_PATH}" \
    > "${EMBEDDED_CONFIG_FILE}" 2> "${EMBEDDED_CONFIG_LOG}"; then
    die "无法从 Image 提取内嵌配置:\n$(sed -n '1,20p' "${EMBEDDED_CONFIG_LOG}")"
fi
EMBEDDED_CONFIG_LINES="$(wc -l < "${EMBEDDED_CONFIG_FILE}" | tr -d ' ')"
EMBEDDED_CONFIG_SHA256="$(sha256sum "${EMBEDDED_CONFIG_FILE}" | awk '{ print $1 }')"
GENERATED_CONFIG_SHA256="$(sha256sum "${BUILD_DIR}/.config" | awk '{ print $1 }')"
[ "${EMBEDDED_CONFIG_SHA256}" = "${GENERATED_CONFIG_SHA256}" ] || \
    die "Image 内嵌配置与本次已审查生成配置不一致"
audit_compare "image.config.lines" "${STAGE_CONFIG_LINES}" "${EMBEDDED_CONFIG_LINES}"
audit_compare "image.config.sha256" "${STAGE_CONFIG_SHA256}" "${EMBEDDED_CONFIG_SHA256}"
ACTUAL_VERSION_LINE="$(strings "${IMAGE_PATH}" | grep -Fx -- "${EXPECTED_VERSION_LINE}" | sort -u || true)"
[ "${ACTUAL_VERSION_LINE}" = "${EXPECTED_VERSION_LINE}" ] || die "Image 缺少完整目标版本行"

printf '# drift_count=%s\n' "${AUDIT_DRIFT_COUNT}" >> "${AUDIT_REPORT}"
[ "${AUDIT_DRIFT_COUNT}" = "0" ] || \
    die "发现 ${AUDIT_DRIFT_COUNT} 项未确认参考快照漂移；本次 Image 保留在构建目录，审查 ${AUDIT_DIR} 后更新参考摘要再打包"

log_success "同 OTA 模块闭包已固定：102 个 system_dlkm 模块严格兼容，rust_binder.ko 为 C Binder 默认路径下的精确例外"

mkdir -p "${PRODUCT_DIR}"
ARTIFACT_MANIFEST="${PRODUCT_DIR}/${ARTIFACT_MANIFEST_NAME}"
RELEASE_ARTIFACTS=()
RELEASE_DATE="$(TZ=Asia/Shanghai date +%Y%m%d)"
AUDIT_ARTIFACT="luna-xiaomi17-g${LUNA_PROJECT_SHORT}-${RELEASE_DATE}-audit.zip"
normalize_archive_timestamps "${AUDIT_DIR}"
(cd "${AUDIT_DIR}" && \
    TZ=UTC 7z a -tzip -mtc=off -mta=off "${PRODUCT_DIR}/${AUDIT_ARTIFACT}" . >/dev/null)
unzip -tq "${PRODUCT_DIR}/${AUDIT_ARTIFACT}" >/dev/null || die "兼容性审计归档损坏"
[ "$(unzip -Z1 "${PRODUCT_DIR}/${AUDIT_ARTIFACT}" | grep -Fxc 'summary.tsv')" = "1" ] || \
    die "兼容性审计归档缺少唯一 summary.tsv"
RELEASE_ARTIFACTS+=("${AUDIT_ARTIFACT}")
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
    KSU_MANAGER_PATH="${ENVIRONMENT_DIR}/kernelsu/${KSU_COMMIT:0:8}/${KSU_MANAGER_APK}"
    [ -f "${KSU_MANAGER_PATH}" ] || die "官方 KernelSU Manager 缺失，请先运行 ./init.sh"
    [ "$(sha256sum "${KSU_MANAGER_PATH}" | awk '{ print $1 }')" = "${KSU_MANAGER_SHA256}" ] || die "官方 KernelSU Manager SHA-256 校验失败"
    cp -f "${KSU_MANAGER_PATH}" "${PRODUCT_DIR}/${KSU_MANAGER_APK}"
    RELEASE_ARTIFACTS+=("${KSU_MANAGER_APK}")
    log_success "官方 KernelSU Manager 已复制到产物目录"
fi

if [ "${ENABLE_SUSFS}" = "1" ]; then
    SUSFS_HELPER="${SUSFS_DIR}/ksu_module_susfs/tools/ksu_susfs_arm64"
    SUSFS_MODULE_NAME="susfs4ksu-v2.3.0-${SUSFS_COMMIT:0:12}.zip"
    [ -x "${SUSFS_HELPER}" ] || die "官方 ksu_susfs arm64 helper 缺失"
    [ "$(sha256sum "${SUSFS_HELPER}" | awk '{ print $1 }')" = "${SUSFS_HELPER_SHA256}" ] || \
        die "官方 ksu_susfs arm64 helper SHA-256 校验失败"
    grep -Fx 'version=v2.3.0' "${SUSFS_DIR}/ksu_module_susfs/module.prop" >/dev/null || \
        die "SUSFS module.prop 版本不是 v2.3.0"
    SUSFS_MODULE_STAGE="$(mktemp -d "${BUILD_DIR}/susfs-module.XXXXXX")"
    cp -a "${SUSFS_DIR}/ksu_module_susfs/." "${SUSFS_MODULE_STAGE}/"
    normalize_archive_timestamps "${SUSFS_MODULE_STAGE}"
    (cd "${SUSFS_MODULE_STAGE}" && \
        TZ=UTC 7z a -tzip -mtc=off -mta=off "${PRODUCT_DIR}/${SUSFS_MODULE_NAME}" . >/dev/null)
    unzip -p "${PRODUCT_DIR}/${SUSFS_MODULE_NAME}" tools/ksu_susfs_arm64 | sha256sum | \
        grep -Fx "${SUSFS_HELPER_SHA256}  -" >/dev/null || die "SUSFS 模块内 helper 校验失败"
    case "${SUSFS_MODULE_STAGE}" in
        "${BUILD_DIR}"/susfs-module.*) rm -rf -- "${SUSFS_MODULE_STAGE}" ;;
        *) die "拒绝清理异常 SUSFS 模块暂存目录" ;;
    esac
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
    die "Luna AnyKernel3 差异补丁无法应用到固定上游"
cp -f "${AK3_BUSYBOX_PATH}" "${AK3_STAGE}/tools/busybox"
cp -f "${MAGISKBOOT_ARM64_PATH}" "${AK3_STAGE}/tools/magiskboot"
cp -f "${IMAGE_PATH}" "${AK3_STAGE}/Image"
chmod 0755 \
    "${AK3_STAGE}/META-INF/com/google/android/update-binary" \
    "${AK3_STAGE}/tools/ak3-core.sh" \
    "${AK3_STAGE}/tools/busybox" \
    "${AK3_STAGE}/tools/magiskboot"

[ "$(sha256sum "${AK3_STAGE}/anykernel.sh" | awk '{ print $1 }')" = "${AK3_LUNA_ANYKERNEL_SH_SHA256}" ] || \
    die "Luna anykernel.sh 结果摘要不匹配"
[ "$(sha256sum "${AK3_STAGE}/META-INF/com/google/android/update-binary" | awk '{ print $1 }')" = \
  "${AK3_LUNA_UPDATE_BINARY_SHA256}" ] || die "Luna update-binary 结果摘要不匹配"
[ "$(sha256sum "${AK3_STAGE}/META-INF/com/google/android/updater-script" | awk '{ print $1 }')" = \
  "${AK3_LUNA_UPDATER_SCRIPT_SHA256}" ] || die "Luna updater-script 结果摘要不匹配"
[ "$(sha256sum "${AK3_STAGE}/tools/ak3-core.sh" | awk '{ print $1 }')" = "${AK3_LUNA_CORE_SHA256}" ] || \
    die "Luna ak3-core.sh 结果摘要不匹配"

grep -Fx 'do.devicecheck=0' "${AK3_STAGE}/anykernel.sh" >/dev/null || die "AnyKernel3 未禁用 do.devicecheck"
grep -Fx 'do.modules=0' "${AK3_STAGE}/anykernel.sh" >/dev/null || die "AnyKernel3 不得安装或替换模块"
grep -Fx 'do.systemless=0' "${AK3_STAGE}/anykernel.sh" >/dev/null || die "AnyKernel3 不得修改 ramdisk"
grep -Fx 'kernel.string=Luna Kernel for Xiaomi 17' "${AK3_STAGE}/anykernel.sh" >/dev/null || \
    die "AnyKernel3 品牌或设备标识不正确"
for AK3_SHELL_SCRIPT in META-INF/com/google/android/update-binary tools/ak3-core.sh anykernel.sh; do
    bash -n "${AK3_STAGE}/${AK3_SHELL_SCRIPT}" || die "AnyKernel3 脚本语法错误: ${AK3_SHELL_SCRIPT}"
done
for AK3_SLOT_SCRIPT in META-INF/com/google/android/update-binary tools/ak3-core.sh; do
    grep -Fq 'find_slot_from_bootconfig() {' "${AK3_STAGE}/${AK3_SLOT_SCRIPT}" || \
        die "AnyKernel3 缺少 bootconfig 槽位检测: ${AK3_SLOT_SCRIPT}"
    grep -Fq '  slot=$(find_slot_from_bootconfig);' "${AK3_STAGE}/${AK3_SLOT_SCRIPT}" || \
        die "AnyKernel3 未优先使用 bootconfig 槽位: ${AK3_SLOT_SCRIPT}"
    grep -Fq 'bootctl get-current-slot' "${AK3_STAGE}/${AK3_SLOT_SCRIPT}" || \
        die "AnyKernel3 缺少 boot control 当前槽检测: ${AK3_SLOT_SCRIPT}"
    grep -Fq '_a|_b) echo "$1";;' "${AK3_STAGE}/${AK3_SLOT_SCRIPT}" || \
        die "AnyKernel3 未将槽位限制为 _a/_b: ${AK3_SLOT_SCRIPT}"
    if grep -Eq 'ak3-slot-compat\.env|find_slot_from_propfiles' "${AK3_STAGE}/${AK3_SLOT_SCRIPT}"; then
        die "AnyKernel3 包含不可信的临时文件或静态属性槽位猜测: ${AK3_SLOT_SCRIPT}"
    fi
done
[ "$(grep -Fxc '      slot=$(find_slot);' "${AK3_STAGE}/tools/ak3-core.sh")" = "1" ] || \
    die "AnyKernel3 未唯一使用受检槽位解析入口"
grep -Fx 'slot_select=active;' "${AK3_STAGE}/anykernel.sh" >/dev/null || die "AnyKernel3 未固定刷写当前启动槽"
grep -Fx '[ ! -d /postinstall/tmp ] || abort "OTA post-install is not supported. Aborting...";' \
    "${AK3_STAGE}/anykernel.sh" >/dev/null || die "AnyKernel3 未拒绝语义不同的 OTA post-install 环境"
grep -Fx 'luna_expected_boot="/dev/block/by-name/boot$slot";' "${AK3_STAGE}/anykernel.sh" >/dev/null || \
    die "AnyKernel3 未绑定带槽位后缀的 boot 目标"
grep -Fx '[ "$block" = "$luna_expected_boot" ] || \' "${AK3_STAGE}/anykernel.sh" >/dev/null || \
    die "AnyKernel3 未拒绝无后缀或错槽 boot 目标"
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
AK3_BOOT_FLOW="$(sed 's/[[:space:]]*#.*$//' "${AK3_STAGE}/anykernel.sh" | \
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | \
    grep -E '^(split_boot|flash_boot|dump_boot|write_boot|flash_generic);$')"
[ "${AK3_BOOT_FLOW}" = $'split_boot;\nflash_boot;' ] || die "AnyKernel3 不是严格的 Image-only boot 流程"

normalize_archive_timestamps "${AK3_STAGE}"
(cd "${AK3_STAGE}" && TZ=UTC 7z a -tzip -mtc=off -mta=off "${ZIP_NAME}" \
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
[ "$(unzip -p "${ZIP_NAME}" Image | sha256sum | awk '{ print $1 }')" = \
  "$(sha256sum "${IMAGE_PATH}" | awk '{ print $1 }')" ] || die "刷机包 Image 与本次构建产物不一致"

case "${AK3_STAGE}" in
    "${BUILD_DIR}"/ak3-package.*) rm -rf -- "${AK3_STAGE}" ;;
    *) die "拒绝清理异常 AnyKernel3 暂存目录" ;;
esac
RELEASE_ARTIFACTS+=("$(basename "${ZIP_NAME}")")
log_success "AnyKernel3 刷机包已生成: ${ZIP_NAME}"
rm -f -- "${PRODUCT_DIR}/Image"

: > "${ARTIFACT_MANIFEST}"
for artifact in "${RELEASE_ARTIFACTS[@]}"; do
    case "${artifact}" in
        ''|*/*|.|..|*[!A-Za-z0-9._-]*) die "拒绝记录非法产物名: ${artifact}" ;;
    esac
    [ -f "${PRODUCT_DIR}/${artifact}" ] && [ ! -L "${PRODUCT_DIR}/${artifact}" ] || \
        die "当前构建产物缺失或不安全: ${artifact}"
    artifact_sha256="$(sha256sum "${PRODUCT_DIR}/${artifact}")"
    printf '%s  %s\n' "${artifact_sha256%% *}" "${artifact}" >> "${ARTIFACT_MANIFEST}"
done
[ -s "${ARTIFACT_MANIFEST}" ] || die "当前构建产物清单为空"
(cd "${PRODUCT_DIR}" && sha256sum --strict --status -c "${ARTIFACT_MANIFEST_NAME}") || \
    die "当前构建产物清单摘要自检失败"
log_success "当前构建产物名称与 SHA-256 已固定 (${#RELEASE_ARTIFACTS[@]} 项)"

log_success "Luna Kernel for Xiaomi 17 构建、固定 OTA 可启动门禁与全量差异审计完成"
