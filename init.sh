#!/usr/bin/env bash
#
# init.sh - prepare pinned sources and the Linux build environment
#
set -euo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
export GIT_NO_REPLACE_OBJECTS=1 GIT_PAGER=cat
unset GIT_NO_LAZY_FETCH

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
            GIT_CONFIG_NOSYSTEM|GIT_NO_REPLACE_OBJECTS)
                [ "${!name}" = "1" ] || die "Git 对象替换隔离值异常"
                ;;
            GIT_PAGER)
                [ "${!name}" = "cat" ] || die "Git pager 隔离值异常"
                ;;
            GIT_*) die "拒绝 Git 环境覆盖: ${name}" ;;
        esac
    done < <(compgen -e)
}
reject_git_environment_overrides

git_network() {
    command git \
        -c core.hooksPath=/dev/null \
        -c credential.helper= \
        -c credential.interactive=false \
        -c http.proactiveAuth=none \
        -c http.version=HTTP/1.1 \
        "$@"
}

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

append_orbenv_var() {
    local name="$1"
    case ":${ORBENV:-}:" in *:"${name}":*) ;; *) ORBENV="${ORBENV:+${ORBENV}:}${name}" ;; esac
}

prepare_orb_passthrough_env() {
    local var
    for var in NO_COLOR http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy; do
        [ -z "${!var:-}" ] || append_orbenv_var "${var}"
    done
    export ORBENV
}

orbctl_run() {
    local cmd=(orbctl run)
    [ -z "${ORB_MACHINE:-}" ] || cmd+=(-m "${ORB_MACHINE}")
    "${cmd[@]}" "$@"
}

orbctl_run_host_path() {
    local cmd=(orbctl run -p)
    [ -z "${ORB_MACHINE:-}" ] || cmd+=(-m "${ORB_MACHINE}")
    "${cmd[@]}" "$@"
}

sync_control_files_to_orb() {
    local items="init.sh patch.sh patch_external.sh build.sh"
    [ ! -f "${HOST_WORKSPACE_DIR}/.env" ] || items="${items} .env"
    [ ! -d "${HOST_WORKSPACE_DIR}/ak3_template" ] || items="${items} ak3_template"
    [ ! -d "${HOST_WORKSPACE_DIR}/patches" ] || items="${items} patches"
    [ ! -d "${HOST_WORKSPACE_DIR}/tools" ] || items="${items} tools"
    [ ! -d "${HOST_WORKSPACE_DIR}/userspace" ] || items="${items} userspace"
    orbctl_run_host_path -w "${HOST_WORKSPACE_DIR}" sh -lc "set -e; target=\"\$HOME/${ORB_LINUX_WORKSPACE}\"; mkdir -p \"\$target\"; rm -rf \"\$target/init.sh\" \"\$target/patch.sh\" \"\$target/patch_external.sh\" \"\$target/build.sh\" \"\$target/.env\" \"\$target/ak3_template\" \"\$target/patches\" \"\$target/tools\" \"\$target/userspace\"; tar -cf - --exclude='.DS_Store' --exclude='.idea' --exclude='kernel_out' ${items} | tar --warning=no-unknown-keyword -xf - -C \"\$target\""
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
            log_info "macOS 环境，进入 Orb Linux 工作区 ${ORB_LINUX_WORKSPACE} 执行 ${SCRIPT_NAME}"
            if orbctl_run sh -lc "cd \"\$HOME/${ORB_LINUX_WORKSPACE}\" && exec bash \"./${SCRIPT_NAME}\" \"\$@\"" sh "$@"; then exit 0; else exit $?; fi
            ;;
        *) die "不支持的操作系统: ${host_os}" ;;
    esac
}

ensure_repo() {
    local label="$1" target_dir="$2" repo_url="$3" branch="$4" commit="$5" allow_dirty="${6:-0}"
    local actual_url head
    if ! git -C "${target_dir}" rev-parse --git-dir >/dev/null 2>&1; then
        [ ! -e "${target_dir}" ] || die "${label} 路径存在但不是 Git 仓库: ${target_dir}"
        mkdir -p "$(dirname "${target_dir}")"
        log_step "克隆 ${label}: ${repo_url} (${branch})"
        git_network clone --depth 1 --single-branch \
            --branch "${branch}" "${repo_url}" "${target_dir}"
    fi
    reject_git_object_overrides "${label}" "${target_dir}"
    verify_no_hidden_index_flags "${label}" "${target_dir}"
    actual_url="$(git -C "${target_dir}" remote get-url origin 2>/dev/null || true)"
    [ "$(normalize_git_url "${actual_url}")" = "$(normalize_git_url "${repo_url}")" ] || die "${label} remote 不匹配: ${actual_url}"
    if ! git -C "${target_dir}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
        log_step "获取 ${label} 固定 commit: ${commit}"
        git_network -C "${target_dir}" fetch --depth 1 origin "${commit}"
    fi
    head="$(git -C "${target_dir}" rev-parse HEAD 2>/dev/null || true)"
    if [ "${head}" != "${commit}" ]; then
        [ -z "$(git -C "${target_dir}" status --porcelain)" ] || die "${label} 有未提交修改，不能切换固定提交"
        git_network -C "${target_dir}" checkout --detach "${commit}"
    fi
    if [ -n "$(git -C "${target_dir}" status --porcelain)" ]; then
        [ "${allow_dirty}" = "1" ] || die "${label} 工作树不干净: ${target_dir}"
        log_info "${label} 含当前阶段补丁；后续 patch/build 脚本将严格校验差异"
    fi
    log_success "${label} 已固定: $(git -C "${target_dir}" rev-parse --short=12 HEAD)"
}

ensure_audit_repo() {
    local label="$1" target_dir="$2" repo_url="$3"
    local actual_url
    if ! git -C "${target_dir}" rev-parse --git-dir >/dev/null 2>&1; then
        [ ! -e "${target_dir}" ] || die "${label} 路径存在但不是 Git 仓库: ${target_dir}"
        mkdir -p "$(dirname "${target_dir}")"
        log_step "初始化只读审计仓库 ${label}: ${repo_url}"
        git init --bare "${target_dir}" >/dev/null
        git -C "${target_dir}" remote add origin "${repo_url}"
        git -C "${target_dir}" config remote.origin.promisor true
        git -C "${target_dir}" config remote.origin.partialclonefilter blob:none
    fi
    reject_git_object_overrides "${label}" "${target_dir}"
    [ "$(git -C "${target_dir}" rev-parse --is-bare-repository)" = "true" ] || \
        die "${label} 必须是无工作树的 bare 审计仓库"
    actual_url="$(git -C "${target_dir}" remote get-url origin 2>/dev/null || true)"
    [ "$(normalize_git_url "${actual_url}")" = "$(normalize_git_url "${repo_url}")" ] || \
        die "${label} remote 不匹配: ${actual_url}"
}

fetch_audit_ref() {
    local label="$1" repo_dir="$2" ref_name="$3" commit="$4" shallow_since="$5"
    local target_ref="refs/backport-audit/${ref_name}"
    if ! env GIT_NO_LAZY_FETCH=1 git -C "${repo_dir}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
        log_step "获取 ${label} 固定审计对象: ${commit}"
        git_network -C "${repo_dir}" fetch --filter=blob:none --no-tags \
            --shallow-since="${shallow_since}" origin "${commit}"
    fi
    env GIT_NO_LAZY_FETCH=1 git -C "${repo_dir}" cat-file -e "${commit}^{commit}" 2>/dev/null || \
        die "${label} 固定审计对象缺失: ${commit}"
    git -C "${repo_dir}" update-ref "${target_ref}" "${commit}"
    [ "$(git -C "${repo_dir}" rev-parse "${target_ref}")" = "${commit}" ] || \
        die "${label} 审计 ref 固定失败: ${ref_name}"
}

hydrate_audit_history() {
    local label="$1" repo_dir="$2" snapshot="$3" shallow_since="$4"
    local identity
    shift 4
    identity="$(
        {
            printf '%s\n' "${snapshot}" "${shallow_since}"
            printf '%s\n' "$@"
        } | sha256sum | awk '{ print $1 }'
    )"
    [ "$(git -C "${repo_dir}" config --get backport.auditHydratedIdentity 2>/dev/null || true)" = "${identity}" ] && return
    log_step "水合 ${label} 固定浅历史，确保审计阶段完全离线"
    git_network -C "${repo_dir}" fetch --no-tags --filter=blob:none \
        --shallow-since="${shallow_since}" origin "$@"
    git -C "${repo_dir}" config backport.auditHydratedIdentity "${identity}"
    git -C "${repo_dir}" config --unset-all backport.auditHydratedSnapshot 2>/dev/null || true
}

hydrate_audit_patches() {
    local label="$1" repo_dir="$2" commit
    shift 2
    [ "$#" -gt 0 ] || return
    log_step "水合 ${label} 已选补丁对象，确保 patch/build 阶段不联网"
    for commit in "$@"; do
        git_network -C "${repo_dir}" -c log.mailmap=false show --format= "${commit}" >/dev/null
        env GIT_NO_LAZY_FETCH=1 git -C "${repo_dir}" -c log.mailmap=false \
            show --format= "${commit}" >/dev/null || \
            die "${label} 补丁对象未完整水合: ${commit}"
    done
}

hydrate_audit_blob() {
    local label="$1" repo_dir="$2" commit="$3" path="$4" expected_sha256="$5"
    local actual_sha256
    actual_sha256="$(git_network -C "${repo_dir}" show "${commit}:${path}" | sha256sum | awk '{ print $1 }')"
    [ "${actual_sha256}" = "${expected_sha256}" ] || \
        die "${label} SHA-256 不匹配: ${actual_sha256}"
    actual_sha256="$(env GIT_NO_LAZY_FETCH=1 git -C "${repo_dir}" \
        show "${commit}:${path}" | sha256sum | awk '{ print $1 }')"
    [ "${actual_sha256}" = "${expected_sha256}" ] || \
        die "${label} 未完整离线水合"
    log_success "${label} 已固定并可离线读取"
}

hydrate_audit_commit_history() {
    local label="$1" repo_dir="$2" snapshot="$3" shallow_since="$4"
    local identity
    shift 4
    identity="$(
        {
            printf '%s\n' "${snapshot}" "${shallow_since}"
            printf '%s\n' "$@"
        } | sha256sum | awk '{ print $1 }'
    )"
    [ "$(git -C "${repo_dir}" config --get backport.auditCommitHistoryIdentity 2>/dev/null || true)" = "${identity}" ] && return
    log_step "水合 ${label} 固定提交与 tree 历史，确保离线漏斗完整"
    git_network -C "${repo_dir}" fetch --no-tags --filter=blob:none \
        --shallow-since="${shallow_since}" origin "$@"
    git -C "${repo_dir}" config backport.auditCommitHistoryIdentity "${identity}"
}

verify_aosp_backport_source() {
    local label="$1" source_ref="$2" commit="$3" commit_date="$4" patch_id="$5" expected_paths="$6"
    local actual_date actual_patch_id actual_paths pair source_ref_commit=""
    [ "${ENABLE_BACKPORT_AUDIT}" = "1" ] || die "${label} 需要启用固定 AOSP 审计源"
    for pair in ${AOSP_BACKPORT_AUDIT_REFS}; do
        if [ "${pair%%:*}" = "${source_ref}" ]; then
            source_ref_commit="${pair#*:}"
            break
        fi
    done
    [ -n "${source_ref_commit}" ] || die "${label} 来源 ref 未固定: ${source_ref}"
    env GIT_NO_LAZY_FETCH=1 git -C "${AOSP_BACKPORT_AUDIT_DIR}" \
        merge-base --is-ancestor "${commit}" "${source_ref_commit}" || \
        die "${label} 不属于固定 AOSP 来源 ref"
    actual_date="$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false \
        -C "${AOSP_BACKPORT_AUDIT_DIR}" show -s --format=%cs "${commit}")"
    [ "${actual_date}" = "${commit_date}" ] || die "${label} 提交日期不匹配: ${actual_date}"
    [[ "${commit_date}" < "${BACKPORT_AUDIT_SNAPSHOT}" ||
       "${commit_date}" = "${BACKPORT_AUDIT_SNAPSHOT}" ]] || \
        die "${label} 晚于固定审计快照"
    actual_paths="$(env GIT_NO_LAZY_FETCH=1 git -C "${AOSP_BACKPORT_AUDIT_DIR}" \
        diff-tree --no-commit-id --name-only -r "${commit}" | LC_ALL=C sort | paste -sd ' ' -)"
    [ "${actual_paths}" = "${expected_paths}" ] || die "${label} 触及非预期路径: ${actual_paths}"
    actual_patch_id="$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false \
        -C "${AOSP_BACKPORT_AUDIT_DIR}" show --format= "${commit}" |
        git patch-id --stable | awk '{ print $1 }')"
    [ "${actual_patch_id}" = "${patch_id}" ] || die "${label} patch-id 不匹配"
    log_success "${label} 官方来源已固定"
}

verify_kernelsu_backport_source() {
    local label="$1" commit="$2" commit_date="$3" patch_id="$4" expected_paths="$5"
    local actual_date actual_patch_id actual_paths
    env GIT_NO_LAZY_FETCH=1 git -C "${KSU_DIR}" merge-base --is-ancestor \
        "${KSU_COMMIT}" "${commit}" || die "${label} 不在 KernelSU ${KSU_REF} 之后"
    env GIT_NO_LAZY_FETCH=1 git -C "${KSU_DIR}" merge-base --is-ancestor \
        "${commit}" "${KSU_POST_RELEASE_AUDIT_COMMIT}" || \
        die "${label} 不属于固定 KernelSU main 快照"
    actual_date="$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false \
        -C "${KSU_DIR}" show -s --format=%cs "${commit}")"
    [ "${actual_date}" = "${commit_date}" ] || die "${label} 提交日期不匹配: ${actual_date}"
    actual_paths="$(env GIT_NO_LAZY_FETCH=1 git -C "${KSU_DIR}" \
        diff-tree --no-commit-id --name-only -r "${commit}" | LC_ALL=C sort | paste -sd ' ' -)"
    [ "${actual_paths}" = "${expected_paths}" ] || die "${label} 触及非预期路径: ${actual_paths}"
    actual_patch_id="$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false \
        -C "${KSU_DIR}" show --format= "${commit}" |
        git patch-id --stable | awk '{ print $1 }')"
    [ "${actual_patch_id}" = "${patch_id}" ] || die "${label} patch-id 不匹配"
    log_success "${label} 官方来源已固定"
}

verify_source_baseline() {
    local branch kmi_generation version tracked_files xiaomi_ack_commit xiaomi_ack_tag
    version="$(sed -n 's/^VERSION = //p' "${COMMON_DIR}/Makefile").$(sed -n 's/^PATCHLEVEL = //p' "${COMMON_DIR}/Makefile").$(sed -n 's/^SUBLEVEL = //p' "${COMMON_DIR}/Makefile")"
    [ "${version}" = "6.12.81" ] || die "GKI common 版本不是 6.12.81: ${version}"
    branch="$(sed -n 's/^BRANCH=//p' "${COMMON_DIR}/build.config.constants")"
    kmi_generation="$(sed -n 's/^KMI_GENERATION=//p' "${COMMON_DIR}/build.config.constants")"
    [ "${branch}" = "android16-6.12" ] || die "GKI common BRANCH 异常: ${branch}"
    [ "${kmi_generation}" = "6" ] || die "GKI common KMI generation 不是 6: ${kmi_generation}"
    tracked_files="$(git -C "${COMMON_DIR}" ls-files | wc -l | tr -d ' ')"
    [ "${tracked_files}" -ge 80000 ] || die "GKI common 文件不完整: ${tracked_files}"
    [ -s "${COMMON_DIR}/gki/aarch64/symbols/qcom" ] || die "缺少 QCOM KMI symbol list"
    [ -s "${COMMON_DIR}/gki/aarch64/symbols/xiaomi" ] || die "缺少 Xiaomi KMI symbol list"
    [ "$(sha256sum "${COMMON_DIR}/gki/aarch64/abi.stg" | awk '{ print $1 }')" = \
      "${COMMON_ABI_STG_SHA256}" ] || die "GKI common 官方 abi.stg 身份不匹配"
    [ -f "${SOC_DIR}/configs/popsicle_perf.bzl" ] || die "小米 soc-repo 缺少 popsicle 配置"
    [ -f "${SOC_DIR}/Kconfig.msm" ] || die "小米 soc-repo 缺少 Kconfig.msm"
    xiaomi_ack_commit="$(sed -n '1p' "${SOC_DIR}/android/ACK_SHA")"
    xiaomi_ack_tag="$(sed -n '2p' "${SOC_DIR}/android/ACK_SHA")"
    [ "${xiaomi_ack_commit}" = "${XIAOMI_ACK_COMMIT}" ] || die "小米 ACK_SHA commit 已变化: ${xiaomi_ack_commit}"
    [ "${xiaomi_ack_tag}" = "${XIAOMI_ACK_BRANCH}" ] || die "小米 ACK_SHA tag 已变化: ${xiaomi_ack_tag}"
}

verify_toolchain_identity() {
    local rustc_verbose
    rustc_verbose="$("${CI_TOOLCHAIN_DIR}/bin/rustc" --version --verbose)"
    printf '%s\n' "${rustc_verbose}" | grep -Fqx "commit-hash: ${CI_RUSTC_COMMIT_HASH}" || \
        die "Rust 编译器 commit-hash 不匹配"
    grep -aFq "Android Rust Toolchain version ${CI_RUST_TOOLCHAIN_VERSION}" \
        "${CI_TOOLCHAIN_DIR}/bin/rustc" || \
        die "Rust 工具链版本标识不匹配"
}

prepare_fixed_git_subtree() {
    local label="$1" cache_dir="$2" repo="$3" commit="$4" subtree="$5"
    local expected_tree="$6" expected_leaf="$7"
    shift 7
    local sparse_paths=("$@")
    local payload_dir actual_url actual_commit actual_tree actual_leaf path

    [ "${#sparse_paths[@]}" -gt 0 ] || die "${label} 缺少稀疏检出路径"
    payload_dir="${cache_dir}/${subtree}"
    mkdir -p "${cache_dir}"
    if [ ! -d "${cache_dir}/.git" ]; then
        [ -z "$(find "${cache_dir}" -mindepth 1 -print -quit)" ] || \
            die "${label} Git 缓存目录不是空目录: ${cache_dir}"
        git -c core.hooksPath=/dev/null init -q "${cache_dir}" || \
            die "初始化 ${label} Git 缓存失败"
        git -C "${cache_dir}" remote add origin "${repo}"
    fi
    reject_git_object_overrides "${label}" "${cache_dir}"
    actual_url="$(git -C "${cache_dir}" remote get-url origin 2>/dev/null || true)"
    [ "$(normalize_git_url "${actual_url}")" = "$(normalize_git_url "${repo}")" ] || \
        die "${label} remote 不匹配: ${actual_url}"
    git -C "${cache_dir}" config core.hooksPath /dev/null
    git -C "${cache_dir}" config fetch.fsckObjects true
    git -C "${cache_dir}" config transfer.fsckObjects true
    git -C "${cache_dir}" config remote.origin.promisor true
    git -C "${cache_dir}" config remote.origin.partialclonefilter blob:none

    log_step "获取固定 ${label} 提交与对象树"
    git_network -c fetch.fsckObjects=true \
        -C "${cache_dir}" fetch --no-tags --filter=blob:none origin "${commit}" || \
        die "获取固定 ${label} 提交失败"
    actual_commit="$(git -C "${cache_dir}" rev-parse FETCH_HEAD^{commit})"
    [ "${actual_commit}" = "${commit}" ] || die "${label} commit 不匹配: ${actual_commit}"
    actual_tree="$(git -C "${cache_dir}" rev-parse "${commit}:${subtree}")"
    [ "${actual_tree}" = "${expected_tree}" ] || \
        die "${label} 目标 Git tree 不匹配: ${actual_tree}"
    if git -C "${cache_dir}" rev-parse --verify HEAD >/dev/null 2>&1; then
        [ "$(git -C "${cache_dir}" rev-parse HEAD)" = "${commit}" ] || \
            die "${label} checkout commit 不匹配"
        [ -z "$(git -C "${cache_dir}" status --porcelain --untracked-files=all)" ] || \
            die "${label} checkout 存在本地修改"
    fi

    git_network -C "${cache_dir}" sparse-checkout init --cone
    git_network -C "${cache_dir}" sparse-checkout set "${sparse_paths[0]}"
    git_network -C "${cache_dir}" checkout -q --detach "${commit}" || \
        die "检出固定 ${label} 提交失败"
    for path in "${sparse_paths[@]:1}"; do
        log_step "水合 ${label} 子树: ${path#${subtree}/}"
        git_network -C "${cache_dir}" sparse-checkout add "${path}" || \
            die "水合 ${label} 子树失败: ${path}"
    done
    git_network -C "${cache_dir}" sparse-checkout set "${subtree}"
    [ "$(git -C "${cache_dir}" rev-parse HEAD)" = "${commit}" ] || \
        die "${label} checkout commit 发生变化"
    [ -z "$(git -C "${cache_dir}" status --porcelain --untracked-files=all)" ] || \
        die "${label} checkout 存在本地修改"
    actual_leaf="$(tree_sha256 "${payload_dir}")"
    [ "${actual_leaf}" = "${expected_leaf}" ] || \
        die "${label} 完整叶树 SHA-256 不匹配: ${actual_leaf}"
    PREPARED_GIT_PAYLOAD_DIR="${payload_dir}"
    log_success "固定 ${label} 对象树完整性校验通过"
}

prepare_rust_source_tree() {
    local cache_dir="${ENVIRONMENT_DIR}/toolchain/aosp-rust-${AOSP_RUST_COMMIT}"
    local paths=(
        "${CI_RUST_SUBTREE}/bin"
        "${CI_RUST_SUBTREE}/etc"
        "${CI_RUST_SUBTREE}/lib64"
        "${CI_RUST_SUBTREE}/libexec"
        "${CI_RUST_SUBTREE}/share"
        "${CI_RUST_SUBTREE}/src"
        "${CI_RUST_SUBTREE}/lib/rustlib/aarch64-linux-android"
        "${CI_RUST_SUBTREE}/lib/rustlib/aarch64-unknown-none"
        "${CI_RUST_SUBTREE}/lib/rustlib/aarch64-unknown-uefi"
        "${CI_RUST_SUBTREE}/lib/rustlib/armv7-linux-androideabi"
        "${CI_RUST_SUBTREE}/lib/rustlib/armv7a-none-eabi"
        "${CI_RUST_SUBTREE}/lib/rustlib/etc"
        "${CI_RUST_SUBTREE}/lib/rustlib/i686-linux-android"
        "${CI_RUST_SUBTREE}/lib/rustlib/i686-unknown-linux-gnu"
        "${CI_RUST_SUBTREE}/lib/rustlib/i686-unknown-linux-musl"
        "${CI_RUST_SUBTREE}/lib/rustlib/i686-unknown-uefi"
        "${CI_RUST_SUBTREE}/lib/rustlib/riscv32i-unknown-none-elf"
        "${CI_RUST_SUBTREE}/lib/rustlib/riscv32imc-unknown-none-elf"
        "${CI_RUST_SUBTREE}/lib/rustlib/riscv64-linux-android"
        "${CI_RUST_SUBTREE}/lib/rustlib/src"
        "${CI_RUST_SUBTREE}/lib/rustlib/x86_64-linux-android"
        "${CI_RUST_SUBTREE}/lib/rustlib/x86_64-pc-windows-gnu"
        "${CI_RUST_SUBTREE}/lib/rustlib/x86_64-unknown-linux-gnu"
        "${CI_RUST_SUBTREE}/lib/rustlib/x86_64-unknown-linux-musl"
        "${CI_RUST_SUBTREE}/lib/rustlib/x86_64-unknown-uefi"
    )
    prepare_fixed_git_subtree "AOSP Rust 工具链" "${cache_dir}" \
        "${AOSP_RUST_REPO}" "${AOSP_RUST_COMMIT}" "${CI_RUST_SUBTREE}" \
        "${CI_RUST_GIT_TREE}" "${CI_RUST_LEAF_TREE_SHA256}" "${paths[@]}"
    CI_RUST_PAYLOAD_DIR="${PREPARED_GIT_PAYLOAD_DIR}"
}

prepare_build_tools_source_tree() {
    local cache_dir="${ENVIRONMENT_DIR}/toolchain/aosp-build-tools-${AOSP_BUILD_TOOLS_COMMIT}"
    local paths=(
        "${CI_BUILD_TOOLS_SUBTREE}/bin"
        "${CI_BUILD_TOOLS_SUBTREE}/include"
        "${CI_BUILD_TOOLS_SUBTREE}/lib64"
        "${CI_BUILD_TOOLS_SUBTREE}/share"
    )
    prepare_fixed_git_subtree "AOSP kernel build-tools" "${cache_dir}" \
        "${AOSP_BUILD_TOOLS_REPO}" "${AOSP_BUILD_TOOLS_COMMIT}" \
        "${CI_BUILD_TOOLS_SUBTREE}" "${CI_BUILD_TOOLS_GIT_TREE}" \
        "${CI_BUILD_TOOLS_LEAF_TREE_SHA256}" "${paths[@]}"
    CI_BUILD_TOOLS_PAYLOAD_DIR="${PREPARED_GIT_PAYLOAD_DIR}"
}

setup_toolchain() {
    local files=(
        aosp-clang-r536225.tar.gz
        bindgen.tar.xz
        busybox-1.35.0-x86_64-linux-musl
    )
    local file expected actual marker marker_value staging backup rust_bin compiler
    mkdir -p "${DL_DIR}" "$(dirname "${CI_TOOLCHAIN_DIR}")"
    prepare_rust_source_tree
    prepare_build_tools_source_tree
    for file in "${files[@]}"; do
        expected="${TC_SHA256[$file]:-}"
        [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || die "工具链归档缺少固定 SHA-256: ${file}"
        if [ ! -f "${DL_DIR}/${file}" ]; then
            log_step "下载固定工具链资产: ${file}"
            curl --proto '=https' --tlsv1.2 -fSL --retry 3 \
                -o "${DL_DIR}/${file}.part" "${TC_PKGS[$file]}" || die "下载失败: ${file}"
            actual="$(sha256sum "${DL_DIR}/${file}.part" | awk '{ print $1 }')"
            [ "${actual}" = "${expected}" ] || die "工具链下载文件 SHA-256 不匹配: ${file} ${actual}"
            mv "${DL_DIR}/${file}.part" "${DL_DIR}/${file}"
        fi
        actual="$(sha256sum "${DL_DIR}/${file}" | awk '{ print $1 }')"
        [ "${actual}" = "${expected}" ] || die "工具链缓存 SHA-256 不匹配: ${file} ${actual}"
    done

    marker="${CI_TOOLCHAIN_DIR}.project-tree-sha256"
    if [ -d "${CI_TOOLCHAIN_DIR}" ]; then
        actual="$(tree_sha256 "${CI_TOOLCHAIN_DIR}")"
        if [ "${actual}" = "${CI_TOOLCHAIN_TREE_SHA256}" ]; then
            printf '%s\n' "${CI_TOOLCHAIN_TREE_SHA256}" > "${marker}"
            verify_toolchain_identity
            log_success "固定工具链安装树完整性校验通过"
            return
        fi
        marker_value="$(sed -n '1p' "${marker}" 2>/dev/null || true)"
        [ "${marker_value}" != "${CI_TOOLCHAIN_TREE_SHA256}" ] || \
            die "固定工具链安装树在初始化后被修改: ${actual}"
        log_step "工具链 pin 已变化或缺少旧树指纹，使用已校验来源重建"
    fi

    staging="$(mktemp -d "$(dirname "${CI_TOOLCHAIN_DIR}")/.ci-toolchain-install.XXXXXX")"
    if ! {
        tar --no-same-owner -xzf "${DL_DIR}/aosp-clang-r536225.tar.gz" -C "${staging}" &&
        rm -rf -- \
            "${staging}/BUILD.bazel" \
            "${staging}/manifest_14043575.xml" \
            "${staging}/android_libc++" \
            "${staging}/musl" \
            "${staging}/runtimes_ndk_cxx" \
            "${staging}/lib/clang/19/lib/aarch64-unknown-linux-musl" \
            "${staging}/lib/clang/19/lib/i386-unknown-linux-gnu" \
            "${staging}/lib/clang/19/lib/i686-unknown-linux-musl" \
            "${staging}/lib/clang/19/lib/x86_64-unknown-linux-musl" \
            "${staging}/lib/clang/19/lib/linux/aarch64-unknown-linux-musl" \
            "${staging}/lib/clang/19/lib/linux/i386" \
            "${staging}/lib/clang/19/lib/linux/i686-unknown-linux-musl" \
            "${staging}/lib/clang/19/lib/linux/riscv64" \
            "${staging}/lib/clang/19/lib/linux/x86_64-unknown-linux-musl" \
            "${staging}/lib/i386-unknown-linux-gnu" \
            "${staging}/lib/i686-unknown-linux-musl" \
            "${staging}/lib/i686-w64-windows-gnu" &&
        find "${staging}/lib/clang/19/lib/linux" -maxdepth 1 \
            \( -type f -o -type l \) \
            \( -name '*-i386.*' -o -name '*-i686-android*' -o -name '*-riscv64-android*' \) \
            -delete &&
        cp -a "${CI_RUST_PAYLOAD_DIR}/." "${staging}/" &&
        rm -f -- \
            "${staging}/BUILD.bazel" \
            "${staging}/lib/rustlib/install.log" &&
        find "${staging}/lib/rustlib" -mindepth 1 -maxdepth 1 -type d \
            ! -name aarch64-linux-android \
            ! -name x86_64-unknown-linux-gnu \
            ! -name src \
            ! -name etc \
            -exec rm -rf -- {} + &&
        find "${staging}/lib/rustlib" -maxdepth 1 -type f \
            -name 'manifest-rust-std-*' \
            ! -name manifest-rust-std-aarch64-linux-android \
            ! -name manifest-rust-std-x86_64-unknown-linux-gnu \
            -delete &&
        mkdir -p "${staging}/build-tools" &&
        cp -a "${CI_BUILD_TOOLS_PAYLOAD_DIR}/." "${staging}/build-tools/" &&
        find "${staging}" -type d -exec chmod 0775 {} + &&
        find "${staging}" -type f -perm /111 -exec chmod 0775 {} + &&
        find "${staging}" -type f ! -perm /111 -exec chmod 0664 {} + &&
        tar --no-same-owner -xJf "${DL_DIR}/bindgen.tar.xz" -C "${staging}" &&
        cp -f "${staging}/bindgen-cli-x86_64-unknown-linux-gnu/bindgen" \
            "${staging}/bin/bindgen" &&
        chmod 0755 "${staging}/bin/bindgen";
    }; then
        rm -rf -- "${staging}"
        die "固定工具链解压失败"
    fi
    ln -sfn clang-19 "${staging}/bin/clang"
    ln -sfn clang++.real "${staging}/bin/clang++"
    mkdir -p "${staging}/host-bin"
    cp -f "${DL_DIR}/busybox-1.35.0-x86_64-linux-musl" "${staging}/host-bin/busybox"
    chmod 0755 "${staging}/host-bin/busybox"
    ln -sfn busybox "${staging}/host-bin/bc"
    { printf '#!/usr/bin/env sh\n'; printf 'for arg do\n'; printf '  case "$arg" in\n'; printf '    -m64) exec /usr/bin/x86_64-linux-gnu-gcc "$@" ;;\n'; printf '  esac\n'; printf 'done\n'; printf 'exec /usr/bin/cc "$@"\n'; } > "${staging}/host-bin/cc"
    chmod 0755 "${staging}/host-bin/cc"
    rust_bin="${staging}/lib/rustlib/x86_64-unknown-linux-gnu/bin"
    mkdir -p "${rust_bin}"
    for compiler in cc gcc; do
        { printf '#!/usr/bin/env sh\n'; printf 'exec /usr/bin/x86_64-linux-gnu-gcc "$@"\n'; } > "${rust_bin}/${compiler}"
        chmod 0755 "${rust_bin}/${compiler}"
    done
    actual="$(tree_sha256 "${staging}")"
    if [ "${actual}" != "${CI_TOOLCHAIN_TREE_SHA256}" ]; then
        rm -rf -- "${staging}"
        die "固定工具链解压树指纹不匹配: ${actual}"
    fi
    case "${CI_TOOLCHAIN_DIR}" in
        "${ENVIRONMENT_DIR}"/toolchain/ci-sm8850-r536225) ;;
        *) rm -rf -- "${staging}"; die "拒绝替换异常工具链目录: ${CI_TOOLCHAIN_DIR}" ;;
    esac
    backup="${CI_TOOLCHAIN_DIR}.replace.$$"
    [ ! -e "${backup}" ] || die "工具链备份路径已存在: ${backup}"
    [ ! -d "${CI_TOOLCHAIN_DIR}" ] || mv "${CI_TOOLCHAIN_DIR}" "${backup}"
    if ! mv "${staging}" "${CI_TOOLCHAIN_DIR}"; then
        [ ! -d "${backup}" ] || mv "${backup}" "${CI_TOOLCHAIN_DIR}"
        die "固定工具链安装失败"
    fi
    [ ! -d "${backup}" ] || rm -rf -- "${backup}"
    printf '%s\n' "${CI_TOOLCHAIN_TREE_SHA256}" > "${marker}"
    verify_toolchain_identity
    log_success "固定工具链准备完成: $("${CI_TOOLCHAIN_DIR}/bin/clang" --version | sed -n '1p')"
}

prepare_kernelsu_manager() {
    local manager_dir manager_path actual_sha256
    manager_dir="${ENVIRONMENT_DIR}/kernelsu/${KSU_REF}"
    manager_path="${manager_dir}/${KSU_MANAGER_APK}"
    mkdir -p "${manager_dir}"
    if [ ! -f "${manager_path}" ]; then
        log_step "下载官方 KernelSU Manager ${KSU_REF}"
        curl -fSL --retry 3 -o "${manager_path}" "${KSU_MANAGER_URL}"
    fi
    actual_sha256="$(sha256sum "${manager_path}" | awk '{ print $1 }')"
    [ "${actual_sha256}" = "${KSU_MANAGER_SHA256}" ] || die "KernelSU Manager SHA-256 不匹配: ${actual_sha256}"
    log_success "官方 KernelSU Manager 校验通过: ${KSU_MANAGER_APK}"
}

prepare_magiskboot() {
    local magisk_dir apk_path binary_path part_path actual_sha256

    magisk_dir="${ENVIRONMENT_DIR}/magisk/v${MAGISK_VERSION}"
    apk_path="${magisk_dir}/Magisk-v${MAGISK_VERSION}.apk"
    binary_path="${magisk_dir}/magiskboot-arm64"
    mkdir -p "${magisk_dir}"

    if [ ! -f "${apk_path}" ]; then
        part_path="${apk_path}.part"
        log_step "下载官方 Magisk v${MAGISK_VERSION}，准备 arm64 magiskboot"
        curl --proto '=https' --tlsv1.2 -fSL --retry 3 \
            -o "${part_path}" "${MAGISK_APK_URL}" || die "Magisk v${MAGISK_VERSION} 下载失败"
        actual_sha256="$(sha256sum "${part_path}" | awk '{ print $1 }')"
        [ "${actual_sha256}" = "${MAGISK_APK_SHA256}" ] || \
            die "Magisk APK SHA-256 不匹配: ${actual_sha256}"
        mv "${part_path}" "${apk_path}"
    fi

    actual_sha256="$(sha256sum "${apk_path}" | awk '{ print $1 }')"
    [ "${actual_sha256}" = "${MAGISK_APK_SHA256}" ] || \
        die "Magisk APK 缓存 SHA-256 不匹配: ${actual_sha256}"

    part_path="${binary_path}.part"
    unzip -p "${apk_path}" lib/arm64-v8a/libmagiskboot.so > "${part_path}" ||
        die "无法从官方 Magisk APK 提取 arm64 magiskboot"
    actual_sha256="$(sha256sum "${part_path}" | awk '{ print $1 }')"
    [ "${actual_sha256}" = "${MAGISKBOOT_ARM64_SHA256}" ] || \
        die "arm64 magiskboot SHA-256 不匹配: ${actual_sha256}"
    chmod 0755 "${part_path}"
    mv "${part_path}" "${binary_path}"
    log_success "官方 MagiskBoot v${MAGISK_VERSION} 校验通过"
}

prepare_source_archive() {
    local label="$1" url="$2" archive="$3" checksum_tool="$4" expected_checksum="$5" source_dir="$6" extracted_name="$7" expected_tree="$8"
    local actual_checksum actual_tree marker
    [[ "${expected_tree}" =~ ^[0-9a-f]{64}$ ]] || die "${label} 源码树 SHA-256 格式错误"
    mkdir -p "${SOURCE_DOWNLOAD_DIR}" "$(dirname "${source_dir}")"
    if [ ! -f "${archive}" ]; then
        log_step "下载 ${label} 官方源码"
        curl -fSL --retry 3 -C - -o "${archive}.part" "${url}"
        actual_checksum="$(${checksum_tool} "${archive}.part" | awk '{ print $1 }')"
        [ "${actual_checksum}" = "${expected_checksum}" ] || die "${label} 下载文件校验失败: ${actual_checksum}"
        mv "${archive}.part" "${archive}"
    fi
    actual_checksum="$(${checksum_tool} "${archive}" | awk '{ print $1 }')"
    [ "${actual_checksum}" = "${expected_checksum}" ] || die "${label} 源码归档校验失败: ${actual_checksum}"
    marker="${source_dir}/.project-source-checksum"
    if [ ! -d "${source_dir}" ]; then
        log_step "解压 ${label} 官方源码"
        tar -xjf "${archive}" -C "$(dirname "${source_dir}")"
        [ "$(basename "${source_dir}")" = "${extracted_name}" ] || die "${label} 解压目录配置异常"
        printf '%s\n' "${expected_checksum}" > "${marker}"
    fi
    [ -f "${source_dir}/configure" ] || die "${label} 源码缺少 configure"
    [ -f "${marker}" ] || die "${label} 源码目录缺少初始化校验标记，请移走该目录后重试"
    [ "$(sed -n '1p' "${marker}")" = "${expected_checksum}" ] || die "${label} 源码目录校验标记不匹配"
    actual_tree="$(tree_sha256 "${source_dir}")"
    [ "${actual_tree}" = "${expected_tree}" ] || die "${label} 源码树完整性校验失败: ${actual_tree}"
    log_success "${label} 官方源码树完整性校验通过"
}

prepare_android_ndk() {
    local archive actual_sha1 actual_sha256 actual_tree marker marker_value staging candidate backup
    archive="${SOURCE_DOWNLOAD_DIR}/android-ndk-${ANDROID_NDK_VERSION}-linux.zip"
    mkdir -p "${SOURCE_DOWNLOAD_DIR}" "$(dirname "${ANDROID_NDK_DIR}")"
    if [ ! -f "${archive}" ]; then
        log_step "下载 Android NDK ${ANDROID_NDK_VERSION}"
        curl -fSL --retry 3 -C - -o "${archive}.part" "${ANDROID_NDK_URL}"
        actual_sha1="$(sha1sum "${archive}.part" | awk '{ print $1 }')"
        [ "${actual_sha1}" = "${ANDROID_NDK_SHA1}" ] || die "Android NDK 下载文件 SHA-1 不匹配: ${actual_sha1}"
        actual_sha256="$(sha256sum "${archive}.part" | awk '{ print $1 }')"
        [ "${actual_sha256}" = "${ANDROID_NDK_SHA256}" ] || die "Android NDK 下载文件 SHA-256 不匹配: ${actual_sha256}"
        mv "${archive}.part" "${archive}"
    fi
    actual_sha1="$(sha1sum "${archive}" | awk '{ print $1 }')"
    [ "${actual_sha1}" = "${ANDROID_NDK_SHA1}" ] || die "Android NDK SHA-1 不匹配: ${actual_sha1}"
    actual_sha256="$(sha256sum "${archive}" | awk '{ print $1 }')"
    [ "${actual_sha256}" = "${ANDROID_NDK_SHA256}" ] || die "Android NDK SHA-256 不匹配: ${actual_sha256}"

    marker="${ANDROID_NDK_DIR}.project-tree-sha256"
    if [ -d "${ANDROID_NDK_DIR}" ]; then
        actual_tree="$(tree_sha256 "${ANDROID_NDK_DIR}")"
        if [ "${actual_tree}" = "${ANDROID_NDK_TREE_SHA256}" ]; then
            printf '%s\n' "${ANDROID_NDK_TREE_SHA256}" > "${marker}"
            log_success "Android NDK ${ANDROID_NDK_VERSION} 安装树完整性校验通过"
            return
        fi
        marker_value="$(sed -n '1p' "${marker}" 2>/dev/null || true)"
        [ "${marker_value}" != "${ANDROID_NDK_TREE_SHA256}" ] || \
            die "Android NDK 安装树在初始化后被修改: ${actual_tree}"
        log_step "Android NDK pin 已变化或缺少旧树指纹，使用已校验归档重建"
    fi

    staging="$(mktemp -d "$(dirname "${ANDROID_NDK_DIR}")/.android-ndk-install.XXXXXX")"
    if ! unzip -q "${archive}" -d "${staging}"; then
        rm -rf -- "${staging}"
        die "Android NDK ${ANDROID_NDK_VERSION} 解压失败"
    fi
    candidate="${staging}/android-ndk-${ANDROID_NDK_VERSION}"
    [ -d "${candidate}" ] || { rm -rf -- "${staging}"; die "Android NDK 解压目录异常"; }
    actual_tree="$(tree_sha256 "${candidate}")"
    if [ "${actual_tree}" != "${ANDROID_NDK_TREE_SHA256}" ]; then
        rm -rf -- "${staging}"
        die "Android NDK 解压树指纹不匹配: ${actual_tree}"
    fi
    case "${ANDROID_NDK_DIR}" in
        "${ENVIRONMENT_DIR}"/toolchain/android-ndk-"${ANDROID_NDK_VERSION}") ;;
        *) rm -rf -- "${staging}"; die "拒绝替换异常 Android NDK 目录: ${ANDROID_NDK_DIR}" ;;
    esac
    backup="${ANDROID_NDK_DIR}.replace.$$"
    [ ! -e "${backup}" ] || die "Android NDK 备份路径已存在: ${backup}"
    [ ! -d "${ANDROID_NDK_DIR}" ] || mv "${ANDROID_NDK_DIR}" "${backup}"
    if ! mv "${candidate}" "${ANDROID_NDK_DIR}"; then
        [ ! -d "${backup}" ] || mv "${backup}" "${ANDROID_NDK_DIR}"
        rm -rf -- "${staging}"
        die "Android NDK 安装失败"
    fi
    rm -rf -- "${staging}"
    [ ! -d "${backup}" ] || rm -rf -- "${backup}"
    printf '%s\n' "${ANDROID_NDK_TREE_SHA256}" > "${marker}"
    [ -x "${ANDROID_NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${ANDROID_NDK_API}-clang" ] || \
        die "Android NDK arm64 API ${ANDROID_NDK_API} clang 缺失"
    log_success "Android NDK ${ANDROID_NDK_VERSION} arm64 工具链准备完成"
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
run_in_orb_if_needed "$@"

KERNEL_REPO="${KERNEL_REPO:-https://github.com/MiCode/Xiaomi_Kernel_OpenSource.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-popsicle-w-oss}"
KERNEL_COMMIT="${KERNEL_COMMIT:-45705be1220b4cfa8100516ad86711656c0b634e}"
SOC_DIR="$(resolve_workspace_path "${SOC_SOURCE_DIR:-sources/xiaomi_sm8850_soc}")"
COMMON_REPO="${COMMON_REPO:-https://android.googlesource.com/kernel/common}"
COMMON_BRANCH="${COMMON_BRANCH:-android16-6.12-2026-06_r21}"
COMMON_COMMIT="${COMMON_COMMIT:-0b90ebc7cfc914b9353f3d6898b8b65c35e8bc28}"
COMMON_DIR="$(resolve_workspace_path "${COMMON_SOURCE_DIR:-sources/aosp_common_6.12.81_kmi6_r21}")"
COMMON_ABI_STG_SHA256="${COMMON_ABI_STG_SHA256:-5b1f1a3c95fe1cfd8020666730cb1aef1de54498ff037afc2c541e119b18e39f}"
ABI_BASELINE_COMMIT="${ABI_BASELINE_COMMIT:-160343479eb972500e11fe76957fdb41b1772f97}"
ABI_BASELINE_STG_SHA256="${ABI_BASELINE_STG_SHA256:-f9802b066d9ffd4a0363ee57615e9af34360a84b3427549d9398de3eadb54691}"
ENABLE_KERNELSU="${ENABLE_KERNELSU:-0}"
KSU_REPO="${KSU_REPO:-https://github.com/tiann/KernelSU.git}"
KSU_REF="${KSU_REF:-v3.2.5}"
KSU_COMMIT="${KSU_COMMIT:-b0bc817b4e966aa6aa830834eaf6ef765d821d40}"
KSU_DIR="$(resolve_workspace_path "${KSU_SOURCE_DIR:-sources/kernelsu}")"
KSU_GIT_VERSION_COUNT="${KSU_GIT_VERSION_COUNT:-2525}"
KSU_ENHANCED_SECURITY_REMOVAL_COMMIT="${KSU_ENHANCED_SECURITY_REMOVAL_COMMIT:-1b6e2ed6b38dad1c8af90402a82ed2f752b05cfa}"
KSU_MANAGER_APK="${KSU_MANAGER_APK:-KernelSU_v3.2.5_32525-release.apk}"
KSU_MANAGER_URL="${KSU_MANAGER_URL:-https://github.com/tiann/KernelSU/releases/download/v3.2.5/KernelSU_v3.2.5_32525-release.apk}"
KSU_MANAGER_SHA256="${KSU_MANAGER_SHA256:-1417081413bf7ab1de8e440ecbcb62685037c8f28f048f0f8b79e305b31ab916}"
ENABLE_KSU_POST_RELEASE_FIXES="${ENABLE_KSU_POST_RELEASE_FIXES:-0}"
KSU_POST_RELEASE_AUDIT_COMMIT="${KSU_POST_RELEASE_AUDIT_COMMIT:-62e88ca93df8affff54064e74948a37945c1865a}"
KSU_ALLOCATION_FAILURE_COMMIT="${KSU_ALLOCATION_FAILURE_COMMIT:-e9e5b616a433b32c286dbf3f6708afd0c5ef7485}"
KSU_ALLOCATION_FAILURE_DATE="${KSU_ALLOCATION_FAILURE_DATE:-2026-07-19}"
KSU_ALLOCATION_FAILURE_PATCH_ID="${KSU_ALLOCATION_FAILURE_PATCH_ID:-2abefc35882130184b6399f60481c66d4261bb2b}"
KSU_APK_SHORT_READ_COMMIT="${KSU_APK_SHORT_READ_COMMIT:-be53d75fd360a9f75231c58970bee1f20a870a4e}"
KSU_APK_SHORT_READ_DATE="${KSU_APK_SHORT_READ_DATE:-2026-07-27}"
KSU_APK_SHORT_READ_PATCH_ID="${KSU_APK_SHORT_READ_PATCH_ID:-1c906b1d21e4a79efaa307aa94fd73c445b09e07}"
KSU_APK_AOSP_PARSER_COMMIT="${KSU_APK_AOSP_PARSER_COMMIT:-e6cc0ef7b0cf7a96af553dedd3282eb3f8ad8d03}"
KSU_APK_AOSP_PARSER_DATE="${KSU_APK_AOSP_PARSER_DATE:-2026-08-07}"
KSU_APK_AOSP_PARSER_PATCH_ID="${KSU_APK_AOSP_PARSER_PATCH_ID:-46da4ee6a88ea901ecfd58ec3a255f03b302312a}"
KSU_APK_EOCD_VALIDATION_COMMIT="${KSU_APK_EOCD_VALIDATION_COMMIT:-aab67974f1210cad94880ce1fdc14cf63f6e30e0}"
KSU_APK_EOCD_VALIDATION_DATE="${KSU_APK_EOCD_VALIDATION_DATE:-2026-08-11}"
KSU_APK_EOCD_VALIDATION_PATCH_ID="${KSU_APK_EOCD_VALIDATION_PATCH_ID:-74e074cec2eb4e43467619d3dbc952e31769b39c}"
MAGISK_VERSION="${MAGISK_VERSION:-30.7}"
MAGISK_COMMIT="${MAGISK_COMMIT:-e8a58776f1d7bdf852072ad0baa6eceb9a1e4aac}"
MAGISK_APK_URL="${MAGISK_APK_URL:-https://github.com/topjohnwu/Magisk/releases/download/v30.7/Magisk-v30.7.apk}"
MAGISK_APK_SHA256="${MAGISK_APK_SHA256:-e0d32d2123532860f97123d927b1bb86c4e08e6fd8a48bfc6b5bee0afae9ebd5}"
MAGISKBOOT_ARM64_SHA256="${MAGISKBOOT_ARM64_SHA256:-d7440e2cd89899426e809554bf793baef9804ccbe5a52ce34a8b6242725d3c77}"
ENABLE_SUSFS="${ENABLE_SUSFS:-0}"
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_REF="${SUSFS_REF:-gki-android16-6.12}"
SUSFS_COMMIT="${SUSFS_COMMIT:-0e43d12a6cb5e6b2814c8214466784285d64ebec}"
SUSFS_DIR="$(resolve_workspace_path "${SUSFS_SOURCE_DIR:-sources/susfs4ksu}")"
SUSFS_KSU_PATCH_COMMIT="${SUSFS_KSU_PATCH_COMMIT:-ef69c8322232340f43c78c7fc491b32cb9f7da86}"
ENABLE_BBG="${ENABLE_BBG:-0}"
BBG_REPO="${BBG_REPO:-https://github.com/vc-teahouse/Baseband-guard.git}"
BBG_REF="${BBG_REF:-main}"
BBG_COMMIT="${BBG_COMMIT:-a54e0dc6cf0aff4dd87fec49644a02d2eb612905}"
BBG_DIR="$(resolve_workspace_path "${BBG_SOURCE_DIR:-sources/baseband_guard}")"
ENABLE_BACKPORT_AUDIT="${ENABLE_BACKPORT_AUDIT:-0}"
BACKPORT_AUDIT_SNAPSHOT="${BACKPORT_AUDIT_SNAPSHOT:-}"
AOSP_BACKPORT_AUDIT_DIR="$(resolve_workspace_path "${AOSP_BACKPORT_AUDIT_SOURCE_DIR:-sources/aosp_common_backport_audit}")"
AOSP_BACKPORT_AUDIT_REFS="${AOSP_BACKPORT_AUDIT_REFS:-}"
ANDROID17_ABI_CLASSIFICATION_REF="${ANDROID17_ABI_CLASSIFICATION_REF:-}"
ANDROID17_ABI_CLASSIFICATION_COMMIT="${ANDROID17_ABI_CLASSIFICATION_COMMIT:-}"
ANDROID17_ABI_CLASSIFICATION_QCOM_SHA256="${ANDROID17_ABI_CLASSIFICATION_QCOM_SHA256:-}"
ANDROID17_ABI_CLASSIFICATION_XIAOMI_SHA256="${ANDROID17_ABI_CLASSIFICATION_XIAOMI_SHA256:-}"
LINUX_STABLE_AUDIT_REPO="${LINUX_STABLE_AUDIT_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
LINUX_STABLE_AUDIT_REF="${LINUX_STABLE_AUDIT_REF:-linux-6.12.y}"
LINUX_STABLE_AUDIT_BASE_COMMIT="${LINUX_STABLE_AUDIT_BASE_COMMIT:-}"
LINUX_STABLE_AUDIT_COMMIT="${LINUX_STABLE_AUDIT_COMMIT:-}"
LINUX_STABLE_AUDIT_DIR="$(resolve_workspace_path "${LINUX_STABLE_AUDIT_SOURCE_DIR:-sources/linux_stable_6.12_audit}")"
LINUX_MAINLINE_AUDIT_REPO="${LINUX_MAINLINE_AUDIT_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git}"
LINUX_MAINLINE_AUDIT_BASE_COMMIT="${LINUX_MAINLINE_AUDIT_BASE_COMMIT:-}"
LINUX_MAINLINE_AUDIT_COMMIT="${LINUX_MAINLINE_AUDIT_COMMIT:-}"
LINUX_MAINLINE_AUDIT_DIR="$(resolve_workspace_path "${LINUX_MAINLINE_AUDIT_SOURCE_DIR:-sources/linux_mainline_audit}")"
BACKPORT_TOOL="${HOST_WORKSPACE_DIR}/tools/backport_manifest.sh"
INDEPENDENT_BACKPORT_TOOL="${HOST_WORKSPACE_DIR}/tools/independent_backports.sh"
ENABLE_MEMCG_RSTAT_FAST_PATH="${ENABLE_MEMCG_RSTAT_FAST_PATH:-0}"
MEMCG_RSTAT_FAST_PATH_AOSP_REF="${MEMCG_RSTAT_FAST_PATH_AOSP_REF:-android-mainline}"
MEMCG_RSTAT_FAST_PATH_COMMIT="${MEMCG_RSTAT_FAST_PATH_COMMIT:-60cada258dfe3694e15c4539259173c37bd5f1fe}"
MEMCG_RSTAT_FAST_PATH_COMMIT_DATE="${MEMCG_RSTAT_FAST_PATH_COMMIT_DATE:-2025-05-11}"
MEMCG_RSTAT_FAST_PATH_PATCH_ID="${MEMCG_RSTAT_FAST_PATH_PATCH_ID:-5b12701394b4f6a128f5456e3bd8fed4f8740c27}"
ENABLE_TCP_RECV_MSTAMP_FAST_PATH="${ENABLE_TCP_RECV_MSTAMP_FAST_PATH:-0}"
TCP_RECV_MSTAMP_FAST_PATH_AOSP_REF="${TCP_RECV_MSTAMP_FAST_PATH_AOSP_REF:-android-mainline}"
TCP_RECV_MSTAMP_FAST_PATH_COMMIT="${TCP_RECV_MSTAMP_FAST_PATH_COMMIT:-0ae1ac7335ca2328c42fbbe2b71bc9c3fc8e65d9}"
TCP_RECV_MSTAMP_FAST_PATH_COMMIT_DATE="${TCP_RECV_MSTAMP_FAST_PATH_COMMIT_DATE:-2025-10-27}"
TCP_RECV_MSTAMP_FAST_PATH_PATCH_ID="${TCP_RECV_MSTAMP_FAST_PATH_PATCH_ID:-66387ee17b01507a8f2a2b6537c9f7e22c86b509}"
ENABLE_EROFS_DIR_TAIL_OOB_FIX="${ENABLE_EROFS_DIR_TAIL_OOB_FIX:-0}"
EROFS_DIR_TAIL_OOB_FIX_AOSP_REF="${EROFS_DIR_TAIL_OOB_FIX_AOSP_REF:-android16-6.12-lts}"
EROFS_DIR_TAIL_OOB_FIX_COMMIT="${EROFS_DIR_TAIL_OOB_FIX_COMMIT:-48b27a955d22391c7f30169fa7b6b2e1977f1ce4}"
EROFS_DIR_TAIL_OOB_FIX_COMMIT_DATE="${EROFS_DIR_TAIL_OOB_FIX_COMMIT_DATE:-2026-05-07}"
EROFS_DIR_TAIL_OOB_FIX_PATCH_ID="${EROFS_DIR_TAIL_OOB_FIX_PATCH_ID:-86095c51c9af49433ddbba4d32f194c2d3a7a6da}"
ENABLE_EXT4_XATTR_OOB_FIX="${ENABLE_EXT4_XATTR_OOB_FIX:-0}"
EXT4_XATTR_OOB_FIX_AOSP_REF="${EXT4_XATTR_OOB_FIX_AOSP_REF:-android16-6.12-lts}"
EXT4_XATTR_OOB_FIX_COMMIT="${EXT4_XATTR_OOB_FIX_COMMIT:-5a5314d2387633a272a04d1bd8727f99058e4e68}"
EXT4_XATTR_OOB_FIX_COMMIT_DATE="${EXT4_XATTR_OOB_FIX_COMMIT_DATE:-2026-05-07}"
EXT4_XATTR_OOB_FIX_PATCH_ID="${EXT4_XATTR_OOB_FIX_PATCH_ID:-98a7513db9abe6f0c8c0713c9e03bca09d99af6c}"
ENABLE_IPV6_MLD_UAF_FIX="${ENABLE_IPV6_MLD_UAF_FIX:-0}"
IPV6_MLD_UAF_FIX_AOSP_REF="${IPV6_MLD_UAF_FIX_AOSP_REF:-android-mainline}"
IPV6_MLD_UAF_FIX_COMMIT="${IPV6_MLD_UAF_FIX_COMMIT:-791c91dc7a9dfb2457d5e29b8216a6484b9c4b40}"
IPV6_MLD_UAF_FIX_COMMIT_DATE="${IPV6_MLD_UAF_FIX_COMMIT_DATE:-2026-06-04}"
IPV6_MLD_UAF_FIX_PATCH_ID="${IPV6_MLD_UAF_FIX_PATCH_ID:-1358ebc3d619657f50c2f0f50f5408f60ea5b732}"
ENABLE_IPV6_MLD_DELAYED_WORK_UAF_FIX="${ENABLE_IPV6_MLD_DELAYED_WORK_UAF_FIX:-0}"
IPV6_MLD_DELAYED_WORK_STABLE_COMMIT="${IPV6_MLD_DELAYED_WORK_STABLE_COMMIT:-ebbebf6cee950d7f1c81990256c0eae9e62572ae}"
IPV6_MLD_DELAYED_WORK_UPSTREAM_COMMIT="${IPV6_MLD_DELAYED_WORK_UPSTREAM_COMMIT:-9b26518b6896a16b809b1e42986f4ebac7bccc1e}"
ENABLE_KVM_COMPOUND_HEAD_PIN_FIX="${ENABLE_KVM_COMPOUND_HEAD_PIN_FIX:-0}"
KVM_COMPOUND_HEAD_PIN_FIX_AOSP_REF="${KVM_COMPOUND_HEAD_PIN_FIX_AOSP_REF:-android16-6.12}"
KVM_COMPOUND_HEAD_PIN_FIX_COMMIT="${KVM_COMPOUND_HEAD_PIN_FIX_COMMIT:-1a138e24e292579ddcf417ed09e78df667f51396}"
KVM_COMPOUND_HEAD_PIN_FIX_COMMIT_DATE="${KVM_COMPOUND_HEAD_PIN_FIX_COMMIT_DATE:-2026-07-31}"
KVM_COMPOUND_HEAD_PIN_FIX_PATCH_ID="${KVM_COMPOUND_HEAD_PIN_FIX_PATCH_ID:-e57c8f60ba72c69067f5f1327a5b9dd9cf956e3d}"
ENABLE_IPSET="${ENABLE_IPSET:-0}"
IPSET_VERSION="${IPSET_VERSION:-7.24}"
IPSET_URL="${IPSET_URL:-https://ipset.netfilter.org/ipset-7.24.tar.bz2}"
IPSET_SHA512="${IPSET_SHA512:-18ccb49bd38083f0556b11e1d17f43791c52a2b094c9a500b6f770796b17e8e70c3860a628eac2252eb672b1fc9de734d3a0e0823d61dd9be7b4188adc6dd214}"
IPSET_TREE_SHA256="${IPSET_TREE_SHA256:-70530678f3318aad36a3fb8acb3eba17a27ad5e464c0caeb8912dee43f0a81ea}"
IPSET_DIR="$(resolve_workspace_path "${IPSET_SOURCE_DIR:-sources/ipset-7.24}")"
LIBMNL_VERSION="${LIBMNL_VERSION:-1.0.5}"
LIBMNL_URL="${LIBMNL_URL:-https://www.netfilter.org/projects/libmnl/files/libmnl-1.0.5.tar.bz2}"
LIBMNL_SHA256="${LIBMNL_SHA256:-274b9b919ef3152bfb3da3a13c950dd60d6e2bcd54230ffeca298d03b40d0525}"
LIBMNL_TREE_SHA256="${LIBMNL_TREE_SHA256:-8d6597fd107489c8d90106d99302ff5efb061fe38bb3952f8a1062626b80a7c2}"
LIBMNL_DIR="$(resolve_workspace_path "${LIBMNL_SOURCE_DIR:-sources/libmnl-1.0.5}")"
ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION:-r29}"
ANDROID_NDK_URL="${ANDROID_NDK_URL:-https://dl.google.com/android/repository/android-ndk-r29-linux.zip}"
ANDROID_NDK_SHA1="${ANDROID_NDK_SHA1:-87e2bb7e9be5d6a1c6cdf5ec40dd4e0c6d07c30b}"
ANDROID_NDK_SHA256="${ANDROID_NDK_SHA256:-4abbbcdc842f3d4879206e9695d52709603e52dd68d3c1fff04b3b5e7a308ecf}"
ANDROID_NDK_TREE_SHA256="${ANDROID_NDK_TREE_SHA256:-401eb9a77478012fdc0c31e986379bf04db9fd72455b060dd13fcce07b84b98e}"
ANDROID_NDK_API="${ANDROID_NDK_API:-35}"
XIAOMI_ACK_BRANCH="${XIAOMI_ACK_BRANCH:-android16-6.12-2025-06_r8}"
XIAOMI_ACK_COMMIT="${XIAOMI_ACK_COMMIT:-f1bdb13583da85a47fcf1632a78ef52d6e6da651}"
ENVIRONMENT_DIR="$(resolve_workspace_path "${BUILD_ENVIRONMENT_DIR:-environment}")"
CI_TOOLCHAIN_DIR="${ENVIRONMENT_DIR}/toolchain/ci-sm8850-r536225"
DL_DIR="${ENVIRONMENT_DIR}/toolchain/ci-sm8850-r536225-downloads"
SOURCE_DOWNLOAD_DIR="${ENVIRONMENT_DIR}/source-downloads"
ANDROID_NDK_DIR="${ENVIRONMENT_DIR}/toolchain/android-ndk-${ANDROID_NDK_VERSION}"
CI_TOOLCHAIN_TREE_SHA256="${CI_TOOLCHAIN_TREE_SHA256:-65644bd77ed4ecde7239e3ce5a4aa53451a28c0a52b12394b88c5bd095517cc0}"
AOSP_CLANG_COMMIT="${AOSP_CLANG_COMMIT:-77c95e8253c2c82ffd4fee92c0ad9f5ac1e8ca04}"
CI_CLANG_URL="${CI_CLANG_URL:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/${AOSP_CLANG_COMMIT}/clang-r536225.tar.gz}"
CI_CLANG_SHA256="${CI_CLANG_SHA256:-4a1e231a9bfff63f7708d956d661e1a5cbf61a6dbaa8bc20246a7e5684a8c79c}"
AOSP_RUST_COMMIT="${AOSP_RUST_COMMIT:-5c78b1e636b2bf68d46a6980437590fddca64147}"
AOSP_RUST_REPO="${AOSP_RUST_REPO:-https://android.googlesource.com/platform/prebuilts/rust}"
CI_RUST_SUBTREE="${CI_RUST_SUBTREE:-linux-x86/1.82.0.p2}"
CI_RUST_GIT_TREE="${CI_RUST_GIT_TREE:-94ac5b5f1377b32edbde5359d17a7994a80363b1}"
CI_RUST_LEAF_TREE_SHA256="${CI_RUST_LEAF_TREE_SHA256:-87288c429cfbc10e1b0083043246adbf3eed26f976e702e0a7ef97348c337627}"
CI_RUSTC_COMMIT_HASH="${CI_RUSTC_COMMIT_HASH:-f6e511eec7342f59a25f7c0534f1dbea00d01b14}"
CI_RUST_TOOLCHAIN_VERSION="${CI_RUST_TOOLCHAIN_VERSION:-linux-glibc-15545352}"
AOSP_BUILD_TOOLS_COMMIT="${AOSP_BUILD_TOOLS_COMMIT:-811c6e2938d53b3c318d7635b03931601a68c765}"
AOSP_BUILD_TOOLS_REPO="${AOSP_BUILD_TOOLS_REPO:-https://android.googlesource.com/kernel/prebuilts/build-tools}"
CI_BUILD_TOOLS_SUBTREE="${CI_BUILD_TOOLS_SUBTREE:-linux-x86}"
CI_BUILD_TOOLS_GIT_TREE="${CI_BUILD_TOOLS_GIT_TREE:-c7f55719e28bb1a324140f7dae7018e8c41a1b7c}"
CI_BUILD_TOOLS_LEAF_TREE_SHA256="${CI_BUILD_TOOLS_LEAF_TREE_SHA256:-82f36c2f3efbaea6f5b278aae01c9b1c0318a0de00603b66a5cb5e815a249c2d}"
CI_BINDGEN_URL="${CI_BINDGEN_URL:-https://github.com/rust-lang/rust-bindgen/releases/download/v0.69.5/bindgen-cli-x86_64-unknown-linux-gnu.tar.xz}"
CI_BINDGEN_SHA256="${CI_BINDGEN_SHA256:-b7e2321ee8c617f14ccc5b9f39b3a804db173ee217e924ad93ed16af6bc62b1d}"
CI_BUSYBOX_URL="${CI_BUSYBOX_URL:-https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox}"
CI_BUSYBOX_SHA256="${CI_BUSYBOX_SHA256:-6e123e7f3202a8c1e9b1f94d8941580a25135382b99e8d3e34fb858bba311348}"
[[ "${CI_TOOLCHAIN_TREE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "工具链安装树 SHA-256 格式错误"
[[ "${COMMON_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "GKI common commit 格式错误"
[[ "${COMMON_ABI_STG_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "GKI common abi.stg SHA-256 格式错误"
[[ "${ABI_BASELINE_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "ABI 基线 commit 格式错误"
[[ "${ABI_BASELINE_STG_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "ABI 基线 abi.stg SHA-256 格式错误"
[[ "${AOSP_CLANG_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "AOSP clang commit 格式错误"
[[ "${MAGISK_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "Magisk commit 格式错误"
for ksu_fix_commit in \
    "${KSU_POST_RELEASE_AUDIT_COMMIT}" \
    "${KSU_ALLOCATION_FAILURE_COMMIT}" \
    "${KSU_APK_SHORT_READ_COMMIT}" \
    "${KSU_APK_AOSP_PARSER_COMMIT}" \
    "${KSU_APK_EOCD_VALIDATION_COMMIT}"; do
    [[ "${ksu_fix_commit}" =~ ^[0-9a-f]{40}$ ]] || die "KernelSU 回移 commit 格式错误"
done
[[ "${MAGISK_APK_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "Magisk APK SHA-256 格式错误"
[[ "${MAGISKBOOT_ARM64_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "arm64 magiskboot SHA-256 格式错误"
[[ "${AOSP_RUST_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "AOSP Rust commit 格式错误"
[[ "${CI_RUST_GIT_TREE}" =~ ^[0-9a-f]{40}$ ]] || die "Rust Git tree 格式错误"
[[ "${CI_RUST_LEAF_TREE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "Rust 叶子树 SHA-256 格式错误"
[[ "${CI_RUSTC_COMMIT_HASH}" =~ ^[0-9a-f]{40}$ ]] || die "Rust 编译器 commit-hash 格式错误"
[[ "${CI_RUST_TOOLCHAIN_VERSION}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Rust 工具链版本标识格式错误"
[[ "${AOSP_BUILD_TOOLS_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "AOSP build-tools commit 格式错误"
[[ "${CI_BUILD_TOOLS_GIT_TREE}" =~ ^[0-9a-f]{40}$ ]] || die "build-tools Git tree 格式错误"
[[ "${CI_BUILD_TOOLS_LEAF_TREE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "build-tools 叶子树 SHA-256 格式错误"
[ "${AOSP_RUST_REPO}" = "https://android.googlesource.com/platform/prebuilts/rust" ] || \
    die "Rust 必须来自 AOSP 官方仓库"
[ "${CI_RUST_SUBTREE}" = "linux-x86/1.82.0.p2" ] || die "Rust 工具链子树异常"
[ "${CI_CLANG_URL}" = "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/${AOSP_CLANG_COMMIT}/clang-r536225.tar.gz" ] || \
    die "clang 必须来自固定 AOSP Gitiles 提交"
[ "${AOSP_BUILD_TOOLS_REPO}" = "https://android.googlesource.com/kernel/prebuilts/build-tools" ] || \
    die "build-tools 必须来自 AOSP 官方仓库"
[ "${CI_BUILD_TOOLS_SUBTREE}" = "linux-x86" ] || die "build-tools 子树异常"
[[ "${ANDROID_NDK_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "Android NDK SHA-256 格式错误"
[[ "${ANDROID_NDK_TREE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "Android NDK 安装树 SHA-256 格式错误"
declare -A TC_PKGS=(
    [aosp-clang-r536225.tar.gz]="${CI_CLANG_URL}"
    [bindgen.tar.xz]="${CI_BINDGEN_URL}"
    [busybox-1.35.0-x86_64-linux-musl]="${CI_BUSYBOX_URL}"
)
declare -A TC_SHA256=(
    [aosp-clang-r536225.tar.gz]="${CI_CLANG_SHA256}"
    [bindgen.tar.xz]="${CI_BINDGEN_SHA256}"
    [busybox-1.35.0-x86_64-linux-musl]="${CI_BUSYBOX_SHA256}"
)

ensure_repo "Xiaomi popsicle soc-repo" "${SOC_DIR}" "${KERNEL_REPO}" "${KERNEL_BRANCH}" "${KERNEL_COMMIT}"
ensure_repo "Android 16 GKI common" "${COMMON_DIR}" "${COMMON_REPO}" "${COMMON_BRANCH}" "${COMMON_COMMIT}" "${ENABLE_KERNELSU}"
if [ "${ENABLE_KERNELSU}" = "1" ]; then
    ensure_repo "KernelSU ${KSU_REF}" "${KSU_DIR}" "${KSU_REPO}" "${KSU_REF}" "${KSU_COMMIT}" "${ENABLE_SUSFS}"
    if [ -f "$(git -C "${KSU_DIR}" rev-parse --absolute-git-dir)/shallow" ]; then
        log_step "在初始化阶段补齐 KernelSU Git 历史以固定 KSU_VERSION"
        git_network -C "${KSU_DIR}" fetch --unshallow --tags origin
    fi
    [ "$(git -C "${KSU_DIR}" rev-list --count HEAD)" = "${KSU_GIT_VERSION_COUNT}" ] || die "KernelSU Git 历史计数不匹配"
    git -C "${KSU_DIR}" merge-base --is-ancestor "${KSU_ENHANCED_SECURITY_REMOVAL_COMMIT}" "${KSU_COMMIT}" || \
        die "固定 KernelSU 版本未包含官方增强安全功能移除提交"
    if [ "${ENABLE_KSU_POST_RELEASE_FIXES}" = "1" ]; then
        if ! env GIT_NO_LAZY_FETCH=1 git -C "${KSU_DIR}" \
            cat-file -e "${KSU_POST_RELEASE_AUDIT_COMMIT}^{commit}" 2>/dev/null; then
            log_step "获取固定 KernelSU main 修复快照"
            git_network -C "${KSU_DIR}" fetch --no-tags origin \
                "${KSU_POST_RELEASE_AUDIT_COMMIT}"
        fi
        env GIT_NO_LAZY_FETCH=1 git -C "${KSU_DIR}" merge-base --is-ancestor \
            "${KSU_COMMIT}" "${KSU_POST_RELEASE_AUDIT_COMMIT}" || \
            die "KernelSU 修复快照不以 ${KSU_REF} 为祖先"
        git -C "${KSU_DIR}" update-ref \
            refs/backport-audit/kernelsu-post-release \
            "${KSU_POST_RELEASE_AUDIT_COMMIT}"
        [ "$(git -C "${KSU_DIR}" rev-parse refs/backport-audit/kernelsu-post-release)" = \
            "${KSU_POST_RELEASE_AUDIT_COMMIT}" ] || die "KernelSU 修复快照保活引用异常"
        verify_kernelsu_backport_source "KernelSU 分配失败处理修复" \
            "${KSU_ALLOCATION_FAILURE_COMMIT}" "${KSU_ALLOCATION_FAILURE_DATE}" \
            "${KSU_ALLOCATION_FAILURE_PATCH_ID}" \
            "kernel/manager/throne_tracker.c kernel/selinux/sepolicy.c"
        verify_kernelsu_backport_source "KernelSU APK 签名块短读修复" \
            "${KSU_APK_SHORT_READ_COMMIT}" "${KSU_APK_SHORT_READ_DATE}" \
            "${KSU_APK_SHORT_READ_PATCH_ID}" "kernel/manager/apk_sign.c"
        verify_kernelsu_backport_source "KernelSU AOSP APK 签名块解析修复" \
            "${KSU_APK_AOSP_PARSER_COMMIT}" "${KSU_APK_AOSP_PARSER_DATE}" \
            "${KSU_APK_AOSP_PARSER_PATCH_ID}" "kernel/manager/apk_sign.c"
        verify_kernelsu_backport_source "KernelSU APK EOCD 边界验证修复" \
            "${KSU_APK_EOCD_VALIDATION_COMMIT}" "${KSU_APK_EOCD_VALIDATION_DATE}" \
            "${KSU_APK_EOCD_VALIDATION_PATCH_ID}" "kernel/manager/apk_sign.c"
    fi
fi
if [ "${ENABLE_SUSFS}" = "1" ]; then
    [ "${ENABLE_KERNELSU}" = "1" ] || die "SUSFS 需要先启用官方 KernelSU"
    ensure_repo "SUSFS ${SUSFS_REF}" "${SUSFS_DIR}" "${SUSFS_REPO}" "${SUSFS_REF}" "${SUSFS_COMMIT}"
    if ! git -C "${SUSFS_DIR}" cat-file -e "${SUSFS_KSU_PATCH_COMMIT}^{commit}" 2>/dev/null; then
        log_step "获取与 KernelSU ${KSU_REF} 兼容的官方 SUSFS 补丁提交"
        git_network -C "${SUSFS_DIR}" fetch --depth 1 origin "${SUSFS_KSU_PATCH_COMMIT}"
    fi
    git -C "${SUSFS_DIR}" cat-file -e "${SUSFS_KSU_PATCH_COMMIT}:kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" 2>/dev/null || \
        die "SUSFS KernelSU 兼容补丁不存在: ${SUSFS_KSU_PATCH_COMMIT}"
    git -C "${SUSFS_DIR}" update-ref \
        refs/backport-audit/susfs-kernelsu-patch "${SUSFS_KSU_PATCH_COMMIT}"
    [ "$(git -C "${SUSFS_DIR}" rev-parse refs/backport-audit/susfs-kernelsu-patch)" = \
        "${SUSFS_KSU_PATCH_COMMIT}" ] || die "SUSFS KernelSU 兼容补丁保活引用异常"
fi
if [ "${ENABLE_BBG}" = "1" ]; then
    ensure_repo "Baseband Guard ${BBG_REF}" "${BBG_DIR}" "${BBG_REPO}" "${BBG_REF}" "${BBG_COMMIT}" "1"
    if [ -f "$(git -C "${BBG_DIR}" rev-parse --absolute-git-dir)/shallow" ]; then
        log_step "在初始化阶段补齐 Baseband Guard 历史，禁止构建期联网"
        git_network -C "${BBG_DIR}" fetch --unshallow origin
    fi
fi
if [ "${ENABLE_BACKPORT_AUDIT}" = "1" ]; then
    [ -n "${BACKPORT_AUDIT_SNAPSHOT}" ] || die "缺少后续改进审计快照日期"
    [ -n "${AOSP_BACKPORT_AUDIT_REFS}" ] || die "缺少 AOSP 后续审计 refs"
    [ -n "${LINUX_STABLE_AUDIT_BASE_COMMIT}" ] || die "缺少 Linux stable 审计起点"
    [ -n "${LINUX_STABLE_AUDIT_COMMIT}" ] || die "缺少 Linux stable 审计终点"
    [ -n "${LINUX_MAINLINE_AUDIT_BASE_COMMIT}" ] || die "缺少 Linux mainline 审计起点"
    [ -n "${LINUX_MAINLINE_AUDIT_COMMIT}" ] || die "缺少 Linux mainline 审计终点"
    if [ "${ENABLE_SELECTED_BACKPORTS:-0}" = "1" ]; then
        bash "${BACKPORT_TOOL}" verify-manifest
    fi
    bash "${INDEPENDENT_BACKPORT_TOOL}" verify-manifests

    aosp_audit_commits=("${COMMON_COMMIT}" "${ABI_BASELINE_COMMIT}")
    ensure_audit_repo "AOSP common 后续历史" "${AOSP_BACKPORT_AUDIT_DIR}" "${COMMON_REPO}"
    fetch_audit_ref "AOSP common r21 构建基线" "${AOSP_BACKPORT_AUDIT_DIR}" \
        "aosp/build-base-r21" "${COMMON_COMMIT}" "2025-01-01"
    fetch_audit_ref "AOSP generation-6 ABI 历史基线" "${AOSP_BACKPORT_AUDIT_DIR}" \
        "aosp/abi-generation-6-base" "${ABI_BASELINE_COMMIT}" "2025-01-01"
    for audit_ref in ${AOSP_BACKPORT_AUDIT_REFS}; do
        audit_name="${audit_ref%%:*}"
        audit_commit="${audit_ref#*:}"
        [ -n "${audit_name}" ] && [ -n "${audit_commit}" ] || die "AOSP 审计 ref 格式错误: ${audit_ref}"
        aosp_audit_commits+=("${audit_commit}")
        fetch_audit_ref "AOSP ${audit_name}" "${AOSP_BACKPORT_AUDIT_DIR}" \
            "aosp/${audit_name}" "${audit_commit}" "2025-01-01"
    done
    hydrate_audit_history "AOSP common" "${AOSP_BACKPORT_AUDIT_DIR}" \
        "${BACKPORT_AUDIT_SNAPSHOT}" "2025-01-01" "${aosp_audit_commits[@]}"
    hydrate_audit_blob "AOSP generation-6 历史 ABI STG" \
        "${AOSP_BACKPORT_AUDIT_DIR}" "${ABI_BASELINE_COMMIT}" \
        "gki/aarch64/abi.stg" "${ABI_BASELINE_STG_SHA256}"
    hydrate_audit_blob "AOSP r21 ABI STG" \
        "${AOSP_BACKPORT_AUDIT_DIR}" "${COMMON_COMMIT}" \
        "gki/aarch64/abi.stg" "${COMMON_ABI_STG_SHA256}"
    [ "$(git -C "${AOSP_BACKPORT_AUDIT_DIR}" rev-parse \
        "refs/backport-audit/aosp/${ANDROID17_ABI_CLASSIFICATION_REF}^{commit}")" = \
        "${ANDROID17_ABI_CLASSIFICATION_COMMIT}" ] || \
        die "Android 17 ABI 分类 ref 与固定提交不匹配"
    hydrate_audit_blob "Android 17 ABI 分类 QCOM symbol list" \
        "${AOSP_BACKPORT_AUDIT_DIR}" "${ANDROID17_ABI_CLASSIFICATION_COMMIT}" \
        "gki/aarch64/symbols/qcom" "${ANDROID17_ABI_CLASSIFICATION_QCOM_SHA256}"
    hydrate_audit_blob "Android 17 ABI 分类 Xiaomi symbol list" \
        "${AOSP_BACKPORT_AUDIT_DIR}" "${ANDROID17_ABI_CLASSIFICATION_COMMIT}" \
        "gki/aarch64/symbols/xiaomi" "${ANDROID17_ABI_CLASSIFICATION_XIAOMI_SHA256}"

    selected_aosp_patches=()
    for selected_aosp_entry in \
        "${ENABLE_F2FS_DIO_OVERWRITE_FAST_PATH:-0}:${F2FS_DIO_OVERWRITE_FAST_PATH_COMMIT:-}" \
        "${ENABLE_EAS_CPUMASK_FAST_PATH:-0}:${EAS_CPUMASK_FAST_PATH_COMMIT:-}" \
        "${ENABLE_BLK_WBT_DONE_FAST_PATH:-0}:${BLK_WBT_DONE_FAST_PATH_COMMIT:-}" \
        "${ENABLE_MEMCG_RSTAT_FAST_PATH:-0}:${MEMCG_RSTAT_FAST_PATH_COMMIT:-}" \
        "${ENABLE_TCP_RECV_MSTAMP_FAST_PATH:-0}:${TCP_RECV_MSTAMP_FAST_PATH_COMMIT:-}" \
        "${ENABLE_EROFS_DIR_TAIL_OOB_FIX:-0}:${EROFS_DIR_TAIL_OOB_FIX_COMMIT:-}" \
        "${ENABLE_EXT4_XATTR_OOB_FIX:-0}:${EXT4_XATTR_OOB_FIX_COMMIT:-}" \
        "${ENABLE_IPV6_MLD_UAF_FIX:-0}:${IPV6_MLD_UAF_FIX_COMMIT:-}" \
        "${ENABLE_KVM_COMPOUND_HEAD_PIN_FIX:-0}:${KVM_COMPOUND_HEAD_PIN_FIX_COMMIT:-}"; do
        [ "${selected_aosp_entry%%:*}" = "1" ] || continue
        selected_aosp_patches+=("${selected_aosp_entry#*:}")
    done
    if [ "${ENABLE_SELECTED_BACKPORTS:-0}" = "1" ]; then
        while IFS= read -r audit_commit; do
            selected_aosp_patches+=("${audit_commit}")
        done < <(bash "${BACKPORT_TOOL}" list aosp)
    fi
    while IFS= read -r audit_commit; do
        [ -n "${audit_commit}" ] && selected_aosp_patches+=("${audit_commit}")
    done < <(bash "${INDEPENDENT_BACKPORT_TOOL}" list aosp)
    hydrate_audit_patches "AOSP common" "${AOSP_BACKPORT_AUDIT_DIR}" \
        "${selected_aosp_patches[@]}"

    ensure_audit_repo "Linux 6.12 stable 历史" "${LINUX_STABLE_AUDIT_DIR}" "${LINUX_STABLE_AUDIT_REPO}"
    fetch_audit_ref "Linux stable v6.12.69" "${LINUX_STABLE_AUDIT_DIR}" \
        "linux-stable/base-v6.12.69" "${LINUX_STABLE_AUDIT_BASE_COMMIT}" "2026-01-01"
    fetch_audit_ref "Linux stable ${LINUX_STABLE_AUDIT_REF}" "${LINUX_STABLE_AUDIT_DIR}" \
        "linux-stable/${LINUX_STABLE_AUDIT_REF}" "${LINUX_STABLE_AUDIT_COMMIT}" "2026-02-01"
    hydrate_audit_commit_history "Linux 6.12 stable" "${LINUX_STABLE_AUDIT_DIR}" \
        "${BACKPORT_AUDIT_SNAPSHOT}" "2026-02-01" \
        "${LINUX_STABLE_AUDIT_BASE_COMMIT}" "${LINUX_STABLE_AUDIT_COMMIT}"
    env GIT_NO_LAZY_FETCH=1 git -C "${LINUX_STABLE_AUDIT_DIR}" merge-base --is-ancestor \
        "${LINUX_STABLE_AUDIT_BASE_COMMIT}" "${LINUX_STABLE_AUDIT_COMMIT}" || \
        die "Linux stable 审计历史未形成 v6.12.69 到固定终点的完整祖先链"
    selected_stable_patches=()
    for selected_stable_entry in \
        "${ENABLE_FUTEX_REQUEUE_PI_LOCKUP_FIX:-0}:${FUTEX_REQUEUE_PI_LOCKUP_STABLE_COMMIT:-}" \
        "${ENABLE_F2FS_ACL_ENTRY_BOUNDS_FIX:-0}:${F2FS_ACL_ENTRY_BOUNDS_STABLE_COMMIT:-}" \
        "${ENABLE_F2FS_LISTXATTR_BOUNDS_FIX:-0}:${F2FS_LISTXATTR_BOUNDS_STABLE_COMMIT:-}" \
        "${ENABLE_BLKCG_RSTAT_RELEASE_FIX:-0}:${BLKCG_RSTAT_RELEASE_STABLE_COMMIT:-}" \
        "${ENABLE_F2FS_FOREGROUND_GC_DEADLOCK_FIX:-0}:${F2FS_FOREGROUND_GC_DEADLOCK_STABLE_COMMIT:-}" \
        "${ENABLE_F2FS_FOREGROUND_GC_DEADLOCK_FIX:-0}:${F2FS_GC_MERGE_DEADLOCK_STABLE_COMMIT:-}" \
        "${ENABLE_IPV6_MLD_DELAYED_WORK_UAF_FIX:-0}:${IPV6_MLD_DELAYED_WORK_STABLE_COMMIT:-}"; do
        [ "${selected_stable_entry%%:*}" = "1" ] || continue
        selected_stable_patches+=("${selected_stable_entry#*:}")
    done
    if [ "${ENABLE_SELECTED_BACKPORTS:-0}" = "1" ]; then
        while IFS= read -r audit_commit; do
            selected_stable_patches+=("${audit_commit}")
        done < <(bash "${BACKPORT_TOOL}" list stable)
    fi
    while IFS= read -r audit_commit; do
        [ -n "${audit_commit}" ] && selected_stable_patches+=("${audit_commit}")
    done < <(bash "${INDEPENDENT_BACKPORT_TOOL}" list stable)
    hydrate_audit_patches "Linux 6.12 stable" "${LINUX_STABLE_AUDIT_DIR}" \
        "${selected_stable_patches[@]}"

    ensure_audit_repo "Linux mainline 历史" "${LINUX_MAINLINE_AUDIT_DIR}" "${LINUX_MAINLINE_AUDIT_REPO}"
    fetch_audit_ref "Linux mainline v6.12" "${LINUX_MAINLINE_AUDIT_DIR}" \
        "linux-mainline/base-v6.12" "${LINUX_MAINLINE_AUDIT_BASE_COMMIT}" "2024-11-01"
    fetch_audit_ref "Linux mainline 快照" "${LINUX_MAINLINE_AUDIT_DIR}" \
        "linux-mainline/snapshot-${BACKPORT_AUDIT_SNAPSHOT}" "${LINUX_MAINLINE_AUDIT_COMMIT}" "2024-11-01"
    hydrate_audit_commit_history "Linux mainline" "${LINUX_MAINLINE_AUDIT_DIR}" \
        "${BACKPORT_AUDIT_SNAPSHOT}" "2024-11-01" \
        "${LINUX_MAINLINE_AUDIT_BASE_COMMIT}" "${LINUX_MAINLINE_AUDIT_COMMIT}"
    selected_mainline_patches=()
    if [ "${ENABLE_TIMER_BASE_FAST_PATH:-0}" = "1" ]; then
        selected_mainline_patches+=("${TIMER_BASE_FAST_PATH_COMMIT}")
    fi
    if [ "${ENABLE_IPV6_MLD_DELAYED_WORK_UAF_FIX:-0}" = "1" ]; then
        selected_mainline_patches+=("${IPV6_MLD_DELAYED_WORK_UPSTREAM_COMMIT}")
    fi
    if [ "${ENABLE_SELECTED_BACKPORTS:-0}" = "1" ]; then
        while IFS= read -r audit_commit; do
            selected_mainline_patches+=("${audit_commit}")
        done < <(bash "${BACKPORT_TOOL}" list mainline)
    fi
    while IFS= read -r audit_commit; do
        [ -n "${audit_commit}" ] && selected_mainline_patches+=("${audit_commit}")
    done < <(bash "${INDEPENDENT_BACKPORT_TOOL}" list mainline)
    hydrate_audit_patches "Linux mainline 已选补丁" "${LINUX_MAINLINE_AUDIT_DIR}" \
        "${selected_mainline_patches[@]}"
    if [ "${ENABLE_SELECTED_BACKPORTS:-0}" = "1" ]; then
        bash "${BACKPORT_TOOL}" verify-sources
    fi
    bash "${INDEPENDENT_BACKPORT_TOOL}" verify-sources
    log_success "后续改进只读审计历史已固定"
fi
if [ "${ENABLE_MEMCG_RSTAT_FAST_PATH}" = "1" ]; then
    verify_aosp_backport_source "memcg rstat 快路径优化" \
        "${MEMCG_RSTAT_FAST_PATH_AOSP_REF}" \
        "${MEMCG_RSTAT_FAST_PATH_COMMIT}" \
        "${MEMCG_RSTAT_FAST_PATH_COMMIT_DATE}" \
        "${MEMCG_RSTAT_FAST_PATH_PATCH_ID}" \
        "mm/memcontrol.c"
fi
if [ "${ENABLE_TCP_RECV_MSTAMP_FAST_PATH}" = "1" ]; then
    verify_aosp_backport_source "TCP recv 时间戳快路径优化" \
        "${TCP_RECV_MSTAMP_FAST_PATH_AOSP_REF}" \
        "${TCP_RECV_MSTAMP_FAST_PATH_COMMIT}" \
        "${TCP_RECV_MSTAMP_FAST_PATH_COMMIT_DATE}" \
        "${TCP_RECV_MSTAMP_FAST_PATH_PATCH_ID}" \
        "net/ipv4/tcp.c net/ipv4/tcp_input.c"
fi
if [ "${ENABLE_EROFS_DIR_TAIL_OOB_FIX}" = "1" ]; then
    verify_aosp_backport_source "EROFS 目录尾项越界读取修复" \
        "${EROFS_DIR_TAIL_OOB_FIX_AOSP_REF}" \
        "${EROFS_DIR_TAIL_OOB_FIX_COMMIT}" \
        "${EROFS_DIR_TAIL_OOB_FIX_COMMIT_DATE}" \
        "${EROFS_DIR_TAIL_OOB_FIX_PATCH_ID}" \
        "fs/erofs/dir.c"
fi
if [ "${ENABLE_EXT4_XATTR_OOB_FIX}" = "1" ]; then
    verify_aosp_backport_source "ext4 扩展属性边界越界读取修复" \
        "${EXT4_XATTR_OOB_FIX_AOSP_REF}" \
        "${EXT4_XATTR_OOB_FIX_COMMIT}" \
        "${EXT4_XATTR_OOB_FIX_COMMIT_DATE}" \
        "${EXT4_XATTR_OOB_FIX_PATCH_ID}" \
        "fs/ext4/xattr.c"
fi
if [ "${ENABLE_IPV6_MLD_UAF_FIX}" = "1" ]; then
    verify_aosp_backport_source "IPv6 MLD 查询释放后访问修复" \
        "${IPV6_MLD_UAF_FIX_AOSP_REF}" \
        "${IPV6_MLD_UAF_FIX_COMMIT}" \
        "${IPV6_MLD_UAF_FIX_COMMIT_DATE}" \
        "${IPV6_MLD_UAF_FIX_PATCH_ID}" \
        "net/ipv6/mcast.c"
fi
if [ "${ENABLE_KVM_COMPOUND_HEAD_PIN_FIX}" = "1" ]; then
    verify_aosp_backport_source "KVM compound head 引用修复" \
        "${KVM_COMPOUND_HEAD_PIN_FIX_AOSP_REF}" \
        "${KVM_COMPOUND_HEAD_PIN_FIX_COMMIT}" \
        "${KVM_COMPOUND_HEAD_PIN_FIX_COMMIT_DATE}" \
        "${KVM_COMPOUND_HEAD_PIN_FIX_PATCH_ID}" \
        "virt/kvm/kvm_main.c"
fi
if [ "${ENABLE_IPSET}" = "1" ]; then
    prepare_source_archive "ipset ${IPSET_VERSION}" "${IPSET_URL}" \
        "${SOURCE_DOWNLOAD_DIR}/ipset-${IPSET_VERSION}.tar.bz2" sha512sum "${IPSET_SHA512}" \
        "${IPSET_DIR}" "ipset-${IPSET_VERSION}" "${IPSET_TREE_SHA256}"
    prepare_source_archive "libmnl ${LIBMNL_VERSION}" "${LIBMNL_URL}" \
        "${SOURCE_DOWNLOAD_DIR}/libmnl-${LIBMNL_VERSION}.tar.bz2" sha256sum "${LIBMNL_SHA256}" \
        "${LIBMNL_DIR}" "libmnl-${LIBMNL_VERSION}" "${LIBMNL_TREE_SHA256}"
    prepare_android_ndk
fi
verify_source_baseline
setup_toolchain
prepare_magiskboot
[ "${ENABLE_KERNELSU}" != "1" ] || prepare_kernelsu_manager

log_success "源码与编译环境初始化完成"
log_info "soc-repo: ${SOC_DIR}"
log_info "GKI common: ${COMMON_DIR}"
[ "${ENABLE_KERNELSU}" != "1" ] || log_info "KernelSU: ${KSU_DIR} (${KSU_REF} @ ${KSU_COMMIT})"
[ "${ENABLE_SUSFS}" != "1" ] || log_info "SUSFS: ${SUSFS_DIR} (${SUSFS_REF} @ ${SUSFS_COMMIT})"
[ "${ENABLE_BBG}" != "1" ] || log_info "Baseband Guard: ${BBG_DIR} (${BBG_REF} @ ${BBG_COMMIT})"
[ "${ENABLE_BACKPORT_AUDIT}" != "1" ] || log_info "Backport audit snapshot: ${BACKPORT_AUDIT_SNAPSHOT} (no age cutoff)"
[ "${ENABLE_MEMCG_RSTAT_FAST_PATH}" != "1" ] || log_info "Linux memcg rstat fast path: ${MEMCG_RSTAT_FAST_PATH_COMMIT} (${MEMCG_RSTAT_FAST_PATH_AOSP_REF})"
[ "${ENABLE_TCP_RECV_MSTAMP_FAST_PATH}" != "1" ] || log_info "Linux TCP recv timestamp fast path: ${TCP_RECV_MSTAMP_FAST_PATH_COMMIT} (${TCP_RECV_MSTAMP_FAST_PATH_AOSP_REF})"
[ "${ENABLE_EROFS_DIR_TAIL_OOB_FIX}" != "1" ] || log_info "AOSP EROFS directory tail OOB fix: ${EROFS_DIR_TAIL_OOB_FIX_COMMIT} (${EROFS_DIR_TAIL_OOB_FIX_AOSP_REF})"
[ "${ENABLE_EXT4_XATTR_OOB_FIX}" != "1" ] || log_info "AOSP ext4 xattr OOB fix: ${EXT4_XATTR_OOB_FIX_COMMIT} (${EXT4_XATTR_OOB_FIX_AOSP_REF})"
[ "${ENABLE_IPV6_MLD_UAF_FIX}" != "1" ] || log_info "AOSP IPv6 MLD UAF fix: ${IPV6_MLD_UAF_FIX_COMMIT} (${IPV6_MLD_UAF_FIX_AOSP_REF})"
[ "${ENABLE_KVM_COMPOUND_HEAD_PIN_FIX}" != "1" ] || log_info "AOSP KVM compound head pin fix: ${KVM_COMPOUND_HEAD_PIN_FIX_COMMIT} (${KVM_COMPOUND_HEAD_PIN_FIX_AOSP_REF})"
[ "${ENABLE_IPSET}" != "1" ] || log_info "IPSet userspace: ${IPSET_DIR} + libmnl ${LIBMNL_DIR} (NDK ${ANDROID_NDK_VERSION})"
log_info "toolchain: ${CI_TOOLCHAIN_DIR}"
log_info "MagiskBoot: v${MAGISK_VERSION} (${MAGISK_COMMIT})"
