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
    python3 "${HOST_WORKSPACE_DIR}/tools/tree_sha256.py" "$1"
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
    local actual_url head history="${7:-shallow}"
    if ! git -C "${target_dir}" rev-parse --git-dir >/dev/null 2>&1; then
        [ ! -e "${target_dir}" ] || die "${label} 路径存在但不是 Git 仓库: ${target_dir}"
        mkdir -p "$(dirname "${target_dir}")"
        log_step "克隆 ${label}: ${repo_url} (${branch})"
        if [ "${history}" = full ]; then
            git init -q "${target_dir}"
            git -C "${target_dir}" remote add origin "${repo_url}"
            git -C "${target_dir}" config remote.origin.promisor true
            git -C "${target_dir}" config remote.origin.partialclonefilter blob:none
            git_network -C "${target_dir}" fetch --filter=blob:none --no-tags origin "${commit}"
            git_network -C "${target_dir}" checkout --detach "${commit}"
        else
            git_network clone --depth 1 --single-branch \
                --branch "${branch}" "${repo_url}" "${target_dir}"
        fi
    fi
    reject_git_object_overrides "${label}" "${target_dir}"
    verify_no_hidden_index_flags "${label}" "${target_dir}"
    actual_url="$(git -C "${target_dir}" remote get-url origin 2>/dev/null || true)"
    [ "$(normalize_git_url "${actual_url}")" = "$(normalize_git_url "${repo_url}")" ] || die "${label} remote 不匹配: ${actual_url}"
    if ! git -C "${target_dir}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
        log_step "获取 ${label} 固定 commit: ${commit}"
        if [ "${history}" = full ]; then
            git_network -C "${target_dir}" fetch --filter=blob:none --no-tags origin "${commit}"
        else
            git_network -C "${target_dir}" fetch --depth 1 origin "${commit}"
        fi
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

verify_source_baseline() {
    local branch kmi_generation version tracked_files xiaomi_ack_commit xiaomi_ack_tag
    version="$(sed -n 's/^VERSION = //p' "${COMMON_DIR}/Makefile").$(sed -n 's/^PATCHLEVEL = //p' "${COMMON_DIR}/Makefile").$(sed -n 's/^SUBLEVEL = //p' "${COMMON_DIR}/Makefile")"
    [ "${version}" = "${COMMON_VERSION:?缺少 COMMON_VERSION}" ] || die "GKI common 版本不是 ${COMMON_VERSION}: ${version}"
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
    [ "$("${CI_TOOLCHAIN_DIR}/bin/clang" --version | sed -n '1p')" = "${CI_CLANG_VERSION_LINE}" ] || \
        die "Clang 编译器版本不匹配"
    rustc_verbose="$("${CI_TOOLCHAIN_DIR}/rust/bin/rustc" --version --verbose)"
    printf '%s\n' "${rustc_verbose}" | grep -Fqx "commit-hash: ${CI_RUSTC_COMMIT_HASH}" || \
        die "Rust 编译器 commit-hash 不匹配"
    printf '%s\n' "${rustc_verbose}" | grep -Fqx "release: ${CI_RUSTC_RELEASE:?缺少 Rust 编译器 release pin}" || \
        die "Rust 编译器 release 不匹配"
    printf '%s\n' "${rustc_verbose}" | sed -n '1p' | \
        grep -Fq "(Android Rust Toolchain version ${CI_RUST_TOOLCHAIN_VERSION})" || \
        die "Rust 工具链构建标识不匹配"
    [ "$("${CI_TOOLCHAIN_DIR}/bin/bindgen" --version)" = "bindgen ${CI_BINDGEN_VERSION}" ] || \
        die "bindgen 版本不匹配"
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

    if ! git -C "${cache_dir}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
        log_step "获取固定 ${label} 提交与对象树"
        git_network -c fetch.fsckObjects=true \
            -C "${cache_dir}" fetch --depth=1 --no-tags --filter=blob:none origin "${commit}" || \
            die "获取固定 ${label} 提交失败"
    else
        log_success "复用固定 ${label} 本地提交"
    fi
    actual_commit="$(git -C "${cache_dir}" rev-parse "${commit}^{commit}")"
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
    git_network -C "${cache_dir}" sparse-checkout set "${sparse_paths[@]}"
    git_network -C "${cache_dir}" checkout -q --detach "${commit}" || \
        die "检出固定 ${label} 提交失败"
    [ "$(git -C "${cache_dir}" rev-parse HEAD)" = "${commit}" ] || \
        die "${label} checkout commit 发生变化"
    [ -z "$(git -C "${cache_dir}" status --porcelain --untracked-files=all)" ] || \
        die "${label} checkout 存在本地修改"
    actual_leaf="$(tree_sha256 "${payload_dir}")"
    [ "${actual_leaf}" = "${expected_leaf}" ] || \
        die "${label} 已检出文件树 SHA-256 不匹配: ${actual_leaf}"
    PREPARED_GIT_PAYLOAD_DIR="${payload_dir}"
    log_success "固定 ${label} 对象树完整性校验通过"
}

prepare_clang_source_tree() {
    local cache_dir="${WORK_DIR}/cache/toolchains/aosp-clang-git-${AOSP_CLANG_COMMIT}"
    local subtree="clang-${CI_CLANG_REVISION}"
    local paths=(
        "${subtree}/bin"
        "${subtree}/include"
        "${subtree}/lib/clang/22/include"
        "${subtree}/lib/clang/22/share"
        "${subtree}/lib/x86_64-unknown-linux-gnu"
        "${subtree}/libexec"
        "${subtree}/prebuilt_include"
        "${subtree}/share"
    )
    prepare_fixed_git_subtree "AOSP Clang 工具链" "${cache_dir}" \
        "${AOSP_CLANG_REPO}" "${AOSP_CLANG_COMMIT}" "${subtree}" \
        "${CI_CLANG_GIT_TREE}" "${CI_CLANG_LEAF_TREE_SHA256}" "${paths[@]}"
    CI_CLANG_PAYLOAD_DIR="${PREPARED_GIT_PAYLOAD_DIR}"
}

prepare_rust_source_tree() {
    local cache_dir="${WORK_DIR}/cache/toolchains/aosp-rust-${AOSP_RUST_COMMIT}"
    local paths=(
        "${CI_RUST_SUBTREE}/bin"
        "${CI_RUST_SUBTREE}/etc"
        "${CI_RUST_SUBTREE}/lib64"
        "${CI_RUST_SUBTREE}/libexec"
        "${CI_RUST_SUBTREE}/share/doc/rustc/licenses"
        "${CI_RUST_SUBTREE}/lib/rustlib/etc"
        "${CI_RUST_SUBTREE}/lib/rustlib/src"
        "${CI_RUST_SUBTREE}/lib/rustlib/x86_64-unknown-linux-gnu"
    )
    prepare_fixed_git_subtree "AOSP Rust 工具链" "${cache_dir}" \
        "${AOSP_RUST_REPO}" "${AOSP_RUST_COMMIT}" "${CI_RUST_SUBTREE}" \
        "${CI_RUST_GIT_TREE}" "${CI_RUST_LEAF_TREE_SHA256}" "${paths[@]}"
    CI_RUST_PAYLOAD_DIR="${PREPARED_GIT_PAYLOAD_DIR}"
}

prepare_build_tools_source_tree() {
    local cache_dir="${WORK_DIR}/cache/toolchains/aosp-build-tools-${AOSP_BUILD_TOOLS_COMMIT}"
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
    local files=(bindgen gavinhoward-bc stock-fsck.erofs stock-depmod stock-libc++.so)
    local file expected actual marker marker_value staging backup rust_bin compiler blob stock_tools_dir
    mkdir -p "${DL_DIR}" "$(dirname "${CI_TOOLCHAIN_DIR}")"
    prepare_clang_source_tree
    prepare_rust_source_tree
    prepare_build_tools_source_tree
    for file in "${files[@]}"; do
        expected="${TC_SHA256[$file]:-}"
        blob="${TC_GIT_BLOB[$file]:-}"
        [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || die "工具链资产缺少固定 SHA-256: ${file}"
        if [ ! -f "${DL_DIR}/${file}" ]; then
            log_step "下载固定工具链资产: ${file}"
            curl --proto '=https' --tlsv1.2 -fSL --connect-timeout 30 \
                --speed-time 180 --speed-limit 1024 --retry 3 \
                -o "${DL_DIR}/${file}.part" "${TC_PKGS[$file]}" || die "下载失败: ${file}"
            if [ -n "${blob}" ]; then
                base64 --decode "${DL_DIR}/${file}.part" > "${DL_DIR}/${file}.decoded" || \
                    die "Gitiles 文件解码失败: ${file}"
                mv "${DL_DIR}/${file}.decoded" "${DL_DIR}/${file}.part"
            fi
            actual="$(sha256sum "${DL_DIR}/${file}.part" | awk '{ print $1 }')"
            [ "${actual}" = "${expected}" ] || die "工具链下载文件 SHA-256 不匹配: ${file} ${actual}"
            if [ -n "${blob}" ]; then
                [ "$(git hash-object --no-filters "${DL_DIR}/${file}.part")" = "${blob}" ] || \
                    die "工具链下载文件 Git blob 不匹配: ${file}"
            fi
            mv "${DL_DIR}/${file}.part" "${DL_DIR}/${file}"
        fi
        actual="$(sha256sum "${DL_DIR}/${file}" | awk '{ print $1 }')"
        [ "${actual}" = "${expected}" ] || die "工具链缓存 SHA-256 不匹配: ${file} ${actual}"
        if [ -n "${blob}" ]; then
            [ "$(git hash-object --no-filters "${DL_DIR}/${file}")" = "${blob}" ] || \
                die "工具链缓存 Git blob 不匹配: ${file}"
        fi
    done

    stock_tools_dir="${WORK_DIR}/tools/stock-evidence"
    [ ! -L "${WORK_DIR}" ] && [ ! -L "${WORK_DIR}/tools" ] && [ ! -L "${stock_tools_dir}" ] || \
        die "stock 解析工具目录不得经过符号链接"
    mkdir -p "${stock_tools_dir}"
    for file in stock-fsck.erofs stock-depmod; do
        [ ! -L "${stock_tools_dir}/${file#stock-}" ] || die "stock 解析工具不得为符号链接"
        cp -f "${DL_DIR}/${file}" "${stock_tools_dir}/${file#stock-}"
        chmod 0755 "${stock_tools_dir}/${file#stock-}"
    done
    [ ! -L "${stock_tools_dir}/lib64" ] && [ ! -L "${stock_tools_dir}/lib64/libc++.so" ] || \
        die "stock 解析工具运行库不得经过符号链接"
    mkdir -p "${stock_tools_dir}/lib64"
    cp -f "${DL_DIR}/stock-libc++.so" "${stock_tools_dir}/lib64/libc++.so"
    chmod 0755 "${stock_tools_dir}/lib64/libc++.so"

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
        cp -a "${CI_CLANG_PAYLOAD_DIR}/." "${staging}/" &&
        mkdir -p "${staging}/rust" "${staging}/build-tools" "${staging}/host-bin" &&
        cp -a "${CI_RUST_PAYLOAD_DIR}/." "${staging}/rust/" &&
        cp -a "${CI_BUILD_TOOLS_PAYLOAD_DIR}/." "${staging}/build-tools/" &&
        find "${staging}" -type d -exec chmod 0775 {} + &&
        find "${staging}" -type f -perm /111 -exec chmod 0775 {} + &&
        find "${staging}" -type f ! -perm /111 -exec chmod 0664 {} + &&
        cp -f "${DL_DIR}/bindgen" "${staging}/bin/bindgen" &&
        cp -f "${DL_DIR}/gavinhoward-bc" "${staging}/host-bin/bc" &&
        chmod 0755 "${staging}/bin/bindgen" "${staging}/host-bin/bc";
    }; then
        rm -rf -- "${staging}"
        die "固定工具链安装失败"
    fi
    { printf '#!/usr/bin/env sh\n'; printf 'for arg do\n'; printf '  case "$arg" in\n'; printf '    -m64) exec /usr/bin/x86_64-linux-gnu-gcc "$@" ;;\n'; printf '  esac\n'; printf 'done\n'; printf 'exec /usr/bin/cc "$@"\n'; } > "${staging}/host-bin/cc"
    chmod 0755 "${staging}/host-bin/cc"
    rust_bin="${staging}/rust/lib/rustlib/x86_64-unknown-linux-gnu/bin"
    mkdir -p "${rust_bin}"
    for compiler in cc gcc; do
        { printf '#!/usr/bin/env sh\n'; printf 'exec /usr/bin/x86_64-linux-gnu-gcc "$@"\n'; } > "${rust_bin}/${compiler}"
        chmod 0755 "${rust_bin}/${compiler}"
    done
    actual="$(tree_sha256 "${staging}")"
    if [ "${actual}" != "${CI_TOOLCHAIN_TREE_SHA256}" ]; then
        rm -rf -- "${staging}"
        die "固定工具链安装树指纹不匹配: ${actual}"
    fi
    case "${CI_TOOLCHAIN_DIR}" in
        "${ENVIRONMENT_DIR}"/toolchain/"${CI_TOOLCHAIN_NAME}") ;;
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
    local manager_dir manager_path archive actual_sha256 metadata expected
    manager_dir="${ENVIRONMENT_DIR}/kernelsu/${KSU_COMMIT:0:8}"
    manager_path="${manager_dir}/${KSU_MANAGER_APK}"
    mkdir -p "${manager_dir}"
    if [ ! -f "${manager_path}" ]; then
        archive="${manager_dir}/manager-${KSU_MANAGER_ARTIFACT_ID}.zip"
        if [ ! -f "${archive}" ]; then
            command -v gh >/dev/null 2>&1 || die "下载官方 CI Manager 需要已认证的 gh；已有固定 APK 可直接复用"
            metadata="$(gh api "repos/tiann/KernelSU/actions/artifacts/${KSU_MANAGER_ARTIFACT_ID}" \
                --jq '[.workflow_run.id, .workflow_run.head_sha, .digest, .name] | @tsv')"
            expected="$(printf '%s\t%s\tsha256:%s\tmanager' \
                "${KSU_MANAGER_RUN_ID}" "${KSU_COMMIT}" "${KSU_MANAGER_ARCHIVE_SHA256}")"
            [ "${metadata}" = "${expected}" ] || die "官方 Manager CI 来源与固定提交不匹配"
            [ "${KSU_MANAGER_URL}" = "https://api.github.com/repos/tiann/KernelSU/actions/artifacts/${KSU_MANAGER_ARTIFACT_ID}/zip" ] || \
                die "官方 Manager CI 归档地址不匹配"
            log_step "下载同提交官方 CI Manager（不编译 APK）"
            gh api "repos/tiann/KernelSU/actions/artifacts/${KSU_MANAGER_ARTIFACT_ID}/zip" > "${archive}.part"
            [ "$(sha256sum "${archive}.part" | awk '{ print $1 }')" = "${KSU_MANAGER_ARCHIVE_SHA256}" ] || \
                die "官方 Manager CI 归档 SHA-256 不匹配"
            mv "${archive}.part" "${archive}"
        fi
        [ "$(sha256sum "${archive}" | awk '{ print $1 }')" = "${KSU_MANAGER_ARCHIVE_SHA256}" ] || \
            die "缓存 Manager CI 归档 SHA-256 不匹配"
        unzip -p "${archive}" "${KSU_MANAGER_APK}" > "${manager_path}.part"
        [ "$(sha256sum "${manager_path}.part" | awk '{ print $1 }')" = "${KSU_MANAGER_SHA256}" ] || \
            die "归档中的 Manager APK SHA-256 不匹配"
        mv "${manager_path}.part" "${manager_path}"
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

prepare_anykernel_tools() {
    local tools_dir binary_path part_path actual_sha256

    tools_dir="${ENVIRONMENT_DIR}/anykernel3/${AK3_ARM64_TOOLS_COMMIT}"
    binary_path="${tools_dir}/busybox-arm64"
    mkdir -p "${tools_dir}"

    if [ ! -f "${binary_path}" ]; then
        part_path="${binary_path}.part"
        log_step "下载固定 AnyKernel3 arm64 BusyBox"
        curl --proto '=https' --tlsv1.2 -fSL --retry 3 \
            -o "${part_path}" "${AK3_BUSYBOX_URL}" || die "AnyKernel3 BusyBox 下载失败"
        actual_sha256="$(sha256sum "${part_path}" | awk '{ print $1 }')"
        [ "${actual_sha256}" = "${AK3_BUSYBOX_SHA256}" ] || \
            die "AnyKernel3 BusyBox SHA-256 不匹配: ${actual_sha256}"
        chmod 0755 "${part_path}"
        mv "${part_path}" "${binary_path}"
    fi

    actual_sha256="$(sha256sum "${binary_path}" | awk '{ print $1 }')"
    [ "${actual_sha256}" = "${AK3_BUSYBOX_SHA256}" ] || \
        die "AnyKernel3 BusyBox 缓存 SHA-256 不匹配: ${actual_sha256}"
    [ -x "${binary_path}" ] || chmod 0755 "${binary_path}"
    log_success "AnyKernel3 arm64 BusyBox 校验通过"
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
COMMON_BRANCH="${COMMON_BRANCH:-android16-6.12-2026-09}"
COMMON_COMMIT="${COMMON_COMMIT:-0316e9866fdf55601aae97b14ee08d1b38a3916c}"
COMMON_DIR="$(resolve_workspace_path "${COMMON_SOURCE_DIR:-sources/aosp_common_6.12.92_kmi6_2026-09}")"
COMMON_ABI_STG_SHA256="${COMMON_ABI_STG_SHA256:-5b1f1a3c95fe1cfd8020666730cb1aef1de54498ff037afc2c541e119b18e39f}"
ABI_BASELINE_COMMIT="${ABI_BASELINE_COMMIT:-160343479eb972500e11fe76957fdb41b1772f97}"
ABI_BASELINE_STG_SHA256="${ABI_BASELINE_STG_SHA256:-f9802b066d9ffd4a0363ee57615e9af34360a84b3427549d9398de3eadb54691}"
ENABLE_KERNELSU="${ENABLE_KERNELSU:-0}"
KSU_REPO="${KSU_REPO:-https://github.com/tiann/KernelSU.git}"
KSU_REF="${KSU_REF:-main}"
KSU_COMMIT="${KSU_COMMIT:-623eba3e092b911a3a7389b7d87622a5835d2f3a}"
KSU_DIR="$(resolve_workspace_path "${KSU_SOURCE_DIR:-sources/kernelsu}")"
KSU_GIT_VERSION_COUNT="${KSU_GIT_VERSION_COUNT:-2651}"
KSU_ENHANCED_SECURITY_REMOVAL_COMMIT="${KSU_ENHANCED_SECURITY_REMOVAL_COMMIT:-1b6e2ed6b38dad1c8af90402a82ed2f752b05cfa}"
KSU_MANAGER_APK="${KSU_MANAGER_APK:-KernelSU_v3.3.0-50-g623eba3e_32651-release.apk}"
KSU_MANAGER_URL="${KSU_MANAGER_URL:-https://api.github.com/repos/tiann/KernelSU/actions/artifacts/10745463923/zip}"
KSU_MANAGER_SHA256="${KSU_MANAGER_SHA256:-1c7cec1aa8a1d6bd023efdf31dd9f5fa5deb5e84acc904ae1b8e3a5097171b45}"
MAGISK_VERSION="${MAGISK_VERSION:-30.7}"
MAGISK_COMMIT="${MAGISK_COMMIT:-e8a58776f1d7bdf852072ad0baa6eceb9a1e4aac}"
MAGISK_APK_URL="${MAGISK_APK_URL:-https://github.com/topjohnwu/Magisk/releases/download/v30.7/Magisk-v30.7.apk}"
MAGISK_APK_SHA256="${MAGISK_APK_SHA256:-e0d32d2123532860f97123d927b1bb86c4e08e6fd8a48bfc6b5bee0afae9ebd5}"
MAGISKBOOT_ARM64_SHA256="${MAGISKBOOT_ARM64_SHA256:-d7440e2cd89899426e809554bf793baef9804ccbe5a52ce34a8b6242725d3c77}"
AK3_UPSTREAM_COMMIT="${AK3_UPSTREAM_COMMIT:-f63f136037d74f0e6b7eab941eadec5ff30e34c4}"
AK3_ARM64_TOOLS_COMMIT="${AK3_ARM64_TOOLS_COMMIT:-e9101f0378055aa844fd80b7d819e0e1b3f59aed}"
AK3_BUSYBOX_URL="${AK3_BUSYBOX_URL:-https://raw.githubusercontent.com/osm0sis/AnyKernel3/${AK3_ARM64_TOOLS_COMMIT}/tools/busybox}"
AK3_BUSYBOX_SHA256="${AK3_BUSYBOX_SHA256:-c629fce4b0dd3ba9775f851d0941e74582115f423258d3a79800f2bd11d30f5c}"
ENABLE_SUSFS="${ENABLE_SUSFS:-0}"
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_REF="${SUSFS_REF:-gki-android16-6.12}"
SUSFS_COMMIT="${SUSFS_COMMIT:-b213c54126fb243595ce7876e91d84d6e0861fec}"
SUSFS_DIR="$(resolve_workspace_path "${SUSFS_SOURCE_DIR:-sources/susfs4ksu}")"
SUSFS_KSU_PATCH_COMMIT="${SUSFS_KSU_PATCH_COMMIT:-b213c54126fb243595ce7876e91d84d6e0861fec}"
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
ENABLE_F2FS_DIO_OVERWRITE_FAST_PATH="${ENABLE_F2FS_DIO_OVERWRITE_FAST_PATH:-0}"
F2FS_DIO_OVERWRITE_FAST_PATH_AOSP_REF="${F2FS_DIO_OVERWRITE_FAST_PATH_AOSP_REF:-android-mainline}"
F2FS_DIO_OVERWRITE_FAST_PATH_COMMIT="${F2FS_DIO_OVERWRITE_FAST_PATH_COMMIT:-d860974a7e38d35e9e2c4dc8a9f4223b38b6ad99}"
F2FS_DIO_OVERWRITE_FAST_PATH_COMMIT_DATE="${F2FS_DIO_OVERWRITE_FAST_PATH_COMMIT_DATE:-2026-01-31}"
F2FS_DIO_OVERWRITE_FAST_PATH_PATCH_ID="${F2FS_DIO_OVERWRITE_FAST_PATH_PATCH_ID:-fec231f96375f0622cf9bd9427ef2baf5614ac03}"
ENABLE_BLK_WBT_DONE_FAST_PATH="${ENABLE_BLK_WBT_DONE_FAST_PATH:-0}"
BLK_WBT_DONE_FAST_PATH_AOSP_REF="${BLK_WBT_DONE_FAST_PATH_AOSP_REF:-android-mainline}"
BLK_WBT_DONE_FAST_PATH_COMMIT="${BLK_WBT_DONE_FAST_PATH_COMMIT:-d8b96a79622e03813c221450498ca9742704ebf2}"
BLK_WBT_DONE_FAST_PATH_COMMIT_DATE="${BLK_WBT_DONE_FAST_PATH_COMMIT_DATE:-2025-08-11}"
BLK_WBT_DONE_FAST_PATH_PATCH_ID="${BLK_WBT_DONE_FAST_PATH_PATCH_ID:-097d27325d53feb894b26bb0c7e152fca314e7b9}"
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
ENABLE_IPV6_MLD_UAF_FIX="${ENABLE_IPV6_MLD_UAF_FIX:-0}"
IPV6_MLD_UAF_FIX_AOSP_REF="${IPV6_MLD_UAF_FIX_AOSP_REF:-android-mainline}"
IPV6_MLD_UAF_FIX_COMMIT="${IPV6_MLD_UAF_FIX_COMMIT:-791c91dc7a9dfb2457d5e29b8216a6484b9c4b40}"
IPV6_MLD_UAF_FIX_COMMIT_DATE="${IPV6_MLD_UAF_FIX_COMMIT_DATE:-2026-06-04}"
IPV6_MLD_UAF_FIX_PATCH_ID="${IPV6_MLD_UAF_FIX_PATCH_ID:-1358ebc3d619657f50c2f0f50f5408f60ea5b732}"
ENABLE_IPV6_MLD_DELAYED_WORK_UAF_FIX="${ENABLE_IPV6_MLD_DELAYED_WORK_UAF_FIX:-0}"
IPV6_MLD_DELAYED_WORK_STABLE_COMMIT="${IPV6_MLD_DELAYED_WORK_STABLE_COMMIT:-ebbebf6cee950d7f1c81990256c0eae9e62572ae}"
IPV6_MLD_DELAYED_WORK_UPSTREAM_COMMIT="${IPV6_MLD_DELAYED_WORK_UPSTREAM_COMMIT:-9b26518b6896a16b809b1e42986f4ebac7bccc1e}"
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
ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION:?缺少 NDK 版本 pin}"
ANDROID_NDK_URL="${ANDROID_NDK_URL:?缺少 NDK URL pin}"
ANDROID_NDK_SHA1="${ANDROID_NDK_SHA1:?缺少 NDK SHA-1 pin}"
ANDROID_NDK_SHA256="${ANDROID_NDK_SHA256:?缺少 NDK SHA-256 pin}"
ANDROID_NDK_TREE_SHA256="${ANDROID_NDK_TREE_SHA256:?缺少 NDK 安装树 pin}"
ANDROID_NDK_API="${ANDROID_NDK_API:-35}"
XIAOMI_ACK_BRANCH="${XIAOMI_ACK_BRANCH:-android16-6.12-2025-06_r8}"
XIAOMI_ACK_COMMIT="${XIAOMI_ACK_COMMIT:-f1bdb13583da85a47fcf1632a78ef52d6e6da651}"
WORK_DIR="$(resolve_workspace_path "${BUILD_WORK_DIR:-work}")"
ENVIRONMENT_DIR="$(resolve_workspace_path "${BUILD_ENVIRONMENT_DIR:-work/tools}")"
CI_TOOLCHAIN_NAME="${CI_TOOLCHAIN_NAME:?缺少工具链目录 pin}"
CI_CLANG_REVISION="${CI_CLANG_REVISION:?缺少 Clang revision pin}"
[[ "${CI_TOOLCHAIN_NAME}" =~ ^ci-sm8850-[A-Za-z0-9._-]+$ ]] || die "工具链目录名异常"
[[ "${CI_CLANG_REVISION}" =~ ^r[0-9]+[a-z]?$ ]] || die "Clang revision 格式错误"
CI_TOOLCHAIN_DIR="${ENVIRONMENT_DIR}/toolchain/${CI_TOOLCHAIN_NAME}"
DL_DIR="${WORK_DIR}/cache/downloads/toolchain-${CI_CLANG_REVISION}"
SOURCE_DOWNLOAD_DIR="${WORK_DIR}/cache/downloads/sources"
ANDROID_NDK_DIR="${ENVIRONMENT_DIR}/toolchain/android-ndk-${ANDROID_NDK_VERSION}"
CI_TOOLCHAIN_TREE_SHA256="${CI_TOOLCHAIN_TREE_SHA256:?缺少工具链安装树 pin}"
AOSP_CLANG_COMMIT="${AOSP_CLANG_COMMIT:?缺少 AOSP Clang commit pin}"
AOSP_CLANG_REPO="${AOSP_CLANG_REPO:?缺少 AOSP Clang repo pin}"
CI_CLANG_GIT_TREE="${CI_CLANG_GIT_TREE:?缺少 Clang Git tree pin}"
CI_CLANG_LEAF_TREE_SHA256="${CI_CLANG_LEAF_TREE_SHA256:?缺少 Clang 文件树 pin}"
AOSP_RUST_COMMIT="${AOSP_RUST_COMMIT:?缺少 AOSP Rust commit pin}"
AOSP_RUST_REPO="${AOSP_RUST_REPO:?缺少 AOSP Rust repo pin}"
CI_RUST_SUBTREE="${CI_RUST_SUBTREE:?缺少 Rust 子树 pin}"
CI_RUST_GIT_TREE="${CI_RUST_GIT_TREE:?缺少 Rust Git tree pin}"
CI_RUST_LEAF_TREE_SHA256="${CI_RUST_LEAF_TREE_SHA256:?缺少 Rust 已检出文件树 pin}"
CI_RUSTC_COMMIT_HASH="${CI_RUSTC_COMMIT_HASH:?缺少 Rust 编译器 commit pin}"
CI_RUST_VERSION="${CI_RUST_VERSION:?缺少 Rust release pin}"
AOSP_BUILD_TOOLS_COMMIT="${AOSP_BUILD_TOOLS_COMMIT:?缺少 AOSP build-tools commit pin}"
AOSP_BUILD_TOOLS_REPO="${AOSP_BUILD_TOOLS_REPO:?缺少 AOSP build-tools repo pin}"
CI_BUILD_TOOLS_SUBTREE="${CI_BUILD_TOOLS_SUBTREE:?缺少 build-tools 子树 pin}"
CI_BUILD_TOOLS_GIT_TREE="${CI_BUILD_TOOLS_GIT_TREE:?缺少 build-tools Git tree pin}"
CI_BUILD_TOOLS_LEAF_TREE_SHA256="${CI_BUILD_TOOLS_LEAF_TREE_SHA256:?缺少 build-tools 文件树 pin}"
CI_BINDGEN_URL="${CI_BINDGEN_URL:?缺少 bindgen URL pin}"
CI_BINDGEN_SHA256="${CI_BINDGEN_SHA256:?缺少 bindgen SHA-256 pin}"
CI_BINDGEN_GIT_BLOB="${CI_BINDGEN_GIT_BLOB:?缺少 bindgen Git blob pin}"
AOSP_BINDGEN_COMMIT="${AOSP_BINDGEN_COMMIT:?缺少 bindgen commit pin}"
CI_HOST_BC_URL="${CI_HOST_BC_URL:?缺少 bc URL pin}"
CI_HOST_BC_SHA256="${CI_HOST_BC_SHA256:?缺少 bc SHA-256 pin}"
CI_HOST_BC_GIT_BLOB="${CI_HOST_BC_GIT_BLOB:?缺少 bc Git blob pin}"
AOSP_HOST_BC_COMMIT="${AOSP_HOST_BC_COMMIT:?缺少 bc commit pin}"
[[ "${CI_TOOLCHAIN_TREE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "工具链安装树 SHA-256 格式错误"
[[ "${COMMON_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "GKI common commit 格式错误"
[[ "${COMMON_ABI_STG_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "GKI common abi.stg SHA-256 格式错误"
[[ "${ABI_BASELINE_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "ABI 基线 commit 格式错误"
[[ "${ABI_BASELINE_STG_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "ABI 基线 abi.stg SHA-256 格式错误"
[[ "${AOSP_CLANG_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "AOSP clang commit 格式错误"
[[ "${MAGISK_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "Magisk commit 格式错误"
[[ "${AK3_UPSTREAM_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "AnyKernel3 脚本 commit 格式错误"
[[ "${AK3_ARM64_TOOLS_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "AnyKernel3 工具 commit 格式错误"
[[ "${MAGISK_APK_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "Magisk APK SHA-256 格式错误"
[[ "${MAGISKBOOT_ARM64_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "arm64 magiskboot SHA-256 格式错误"
[[ "${AK3_BUSYBOX_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "AnyKernel3 BusyBox SHA-256 格式错误"
[ "${AK3_BUSYBOX_URL}" = "https://raw.githubusercontent.com/osm0sis/AnyKernel3/${AK3_ARM64_TOOLS_COMMIT}/tools/busybox" ] || \
    die "AnyKernel3 BusyBox 必须来自固定官方工具提交"
[[ "${AOSP_RUST_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "AOSP Rust commit 格式错误"
[[ "${CI_RUST_GIT_TREE}" =~ ^[0-9a-f]{40}$ ]] || die "Rust Git tree 格式错误"
[[ "${CI_RUST_LEAF_TREE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "Rust 叶子树 SHA-256 格式错误"
[[ "${CI_RUSTC_COMMIT_HASH}" =~ ^[0-9a-f]{40}$ ]] || die "Rust 编译器 commit-hash 格式错误"
[[ "${CI_RUST_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Rust release 格式错误"
[[ "${AOSP_BUILD_TOOLS_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "AOSP build-tools commit 格式错误"
[[ "${CI_BUILD_TOOLS_GIT_TREE}" =~ ^[0-9a-f]{40}$ ]] || die "build-tools Git tree 格式错误"
[[ "${CI_BUILD_TOOLS_LEAF_TREE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "build-tools 叶子树 SHA-256 格式错误"
[ "${AOSP_RUST_REPO}" = "https://android.googlesource.com/platform/prebuilts/rust-toolchain/linux-x86" ] || \
    die "Rust 必须来自 AOSP 官方仓库"
[ "${CI_RUST_SUBTREE}" = "${CI_RUST_VERSION}" ] || die "Rust 工具链子树异常"
[[ "${CI_CLANG_GIT_TREE}" =~ ^[0-9a-f]{40}$ ]] || die "Clang Git tree 格式错误"
[[ "${CI_CLANG_LEAF_TREE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "Clang 文件树 SHA-256 格式错误"
[ "${AOSP_CLANG_REPO}" = "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86" ] || \
    die "Clang 必须来自 AOSP 官方仓库"
[ "${AOSP_BUILD_TOOLS_REPO}" = "https://android.googlesource.com/kernel/prebuilts/build-tools" ] || \
    die "build-tools 必须来自 AOSP 官方仓库"
[ "${CI_BUILD_TOOLS_SUBTREE}" = "linux_musl-x86" ] || die "build-tools 子树异常"
[[ "${ANDROID_NDK_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "Android NDK SHA-256 格式错误"
[[ "${ANDROID_NDK_TREE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "Android NDK 安装树 SHA-256 格式错误"
[[ "${AOSP_BINDGEN_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "bindgen commit 格式错误"
[[ "${AOSP_HOST_BC_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "bc commit 格式错误"
[[ "${CI_BINDGEN_GIT_BLOB}" =~ ^[0-9a-f]{40}$ ]] || die "bindgen Git blob 格式错误"
[[ "${CI_HOST_BC_GIT_BLOB}" =~ ^[0-9a-f]{40}$ ]] || die "bc Git blob 格式错误"
[[ "${STOCK_AUDIT_TOOLS_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] || die "stock 解析工具 commit 格式错误"
[[ "${STOCK_FSCK_EROFS_GIT_BLOB:-}" =~ ^[0-9a-f]{40}$ ]] || die "stock fsck.erofs Git blob 格式错误"
[[ "${STOCK_KMOD_GIT_BLOB:-}" =~ ^[0-9a-f]{40}$ ]] || die "stock kmod Git blob 格式错误"
[[ "${STOCK_LIBCXX_GIT_BLOB:-}" =~ ^[0-9a-f]{40}$ ]] || die "stock libc++ Git blob 格式错误"
[ "${CI_BINDGEN_URL}" = "https://android.googlesource.com/platform/prebuilts/clang-tools/+/${AOSP_BINDGEN_COMMIT}/linux-x86/bin/bindgen?format=TEXT" ] || \
    die "bindgen 必须来自固定 AOSP Gitiles 提交"
[ "${CI_HOST_BC_URL}" = "https://android.googlesource.com/platform/prebuilts/build-tools/+/${AOSP_HOST_BC_COMMIT}/linux-x86/bin/gavinhoward-bc?format=TEXT" ] || \
    die "bc 必须来自固定 AOSP Gitiles 提交"
declare -A TC_PKGS=(
    [bindgen]="${CI_BINDGEN_URL}"
    [gavinhoward-bc]="${CI_HOST_BC_URL}"
    [stock-fsck.erofs]="${AOSP_BUILD_TOOLS_REPO}/+/${STOCK_AUDIT_TOOLS_COMMIT}/linux-x86/bin/fsck.erofs?format=TEXT"
    [stock-depmod]="${AOSP_BUILD_TOOLS_REPO}/+/${STOCK_AUDIT_TOOLS_COMMIT}/linux-x86/bin/depmod?format=TEXT"
    [stock-libc++.so]="${AOSP_BUILD_TOOLS_REPO}/+/${STOCK_AUDIT_TOOLS_COMMIT}/linux-x86/lib64/libc++.so?format=TEXT"
)
declare -A TC_SHA256=(
    [bindgen]="${CI_BINDGEN_SHA256}"
    [gavinhoward-bc]="${CI_HOST_BC_SHA256}"
    [stock-fsck.erofs]="${STOCK_FSCK_EROFS_SHA256:?缺少 stock fsck.erofs SHA-256 pin}"
    [stock-depmod]="${STOCK_KMOD_SHA256:?缺少 stock kmod SHA-256 pin}"
    [stock-libc++.so]="${STOCK_LIBCXX_SHA256:?缺少 stock libc++ SHA-256 pin}"
)
declare -A TC_GIT_BLOB=(
    [bindgen]="${CI_BINDGEN_GIT_BLOB}"
    [gavinhoward-bc]="${CI_HOST_BC_GIT_BLOB}"
    [stock-fsck.erofs]="${STOCK_FSCK_EROFS_GIT_BLOB}"
    [stock-depmod]="${STOCK_KMOD_GIT_BLOB}"
    [stock-libc++.so]="${STOCK_LIBCXX_GIT_BLOB}"
)

ensure_repo "Xiaomi popsicle soc-repo" "${SOC_DIR}" "${KERNEL_REPO}" "${KERNEL_BRANCH}" "${KERNEL_COMMIT}"
ensure_repo "Android 16 GKI common" "${COMMON_DIR}" "${COMMON_REPO}" "${COMMON_BRANCH}" "${COMMON_COMMIT}" "${ENABLE_KERNELSU}"
[ "${AOSP_AUTOFDO_PROFILE_RELATIVE_PATH:?缺少官方 AutoFDO 路径 pin}" = gki/aarch64/afdo/kernel.afdo ] || die "AutoFDO 必须使用固定 common 自带的 arm64 profile"
[[ "${AOSP_AUTOFDO_PROFILE_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || die "官方 AutoFDO SHA-256 pin 无效"
AUTOFDO_PROFILE="${COMMON_DIR}/${AOSP_AUTOFDO_PROFILE_RELATIVE_PATH}"
[ -f "${AUTOFDO_PROFILE}" ] && [ ! -L "${AUTOFDO_PROFILE}" ] || die "官方 AutoFDO profile 缺失或为符号链接"
[ "$(sha256sum "${AUTOFDO_PROFILE}" | awk '{ print $1 }')" = "${AOSP_AUTOFDO_PROFILE_SHA256}" ] || die "官方 AutoFDO profile SHA-256 不匹配"
log_success "固定 common 自带的官方 AutoFDO profile 摘要检查通过"
if [ "${ENABLE_KERNELSU}" = "1" ]; then
    ensure_repo "KernelSU ${KSU_REF}" "${KSU_DIR}" "${KSU_REPO}" "${KSU_REF}" "${KSU_COMMIT}" "${ENABLE_SUSFS}" full
    if [ -f "$(git -C "${KSU_DIR}" rev-parse --absolute-git-dir)/shallow" ]; then
        log_step "在初始化阶段补齐 KernelSU Git 历史以固定 KSU_VERSION"
        git_network -C "${KSU_DIR}" fetch --unshallow --filter=blob:none --no-tags origin "${KSU_COMMIT}"
    fi
    [ "$(git -C "${KSU_DIR}" rev-list --count HEAD)" = "${KSU_GIT_VERSION_COUNT}" ] || die "KernelSU Git 历史计数不匹配"
    git -C "${KSU_DIR}" merge-base --is-ancestor "${KSU_ENHANCED_SECURITY_REMOVAL_COMMIT}" "${KSU_COMMIT}" || \
        die "固定 KernelSU 版本未包含官方增强安全功能移除提交"
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

    aosp_audit_commits=("${AOSP_BACKPORT_AUDIT_BASE_COMMIT:?缺少回移审计快照基线}" "${ABI_BASELINE_COMMIT}")
    ensure_audit_repo "AOSP common 后续历史" "${AOSP_BACKPORT_AUDIT_DIR}" "${COMMON_REPO}"
    fetch_audit_ref "AOSP common September KMI6 构建基线" "${AOSP_BACKPORT_AUDIT_DIR}" \
        "aosp/build-base-kmi6-2026-09" "${COMMON_COMMIT}" "${AOSP_BACKPORT_AUDIT_SHALLOW_SINCE}"
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
    hydrate_audit_blob "AOSP 九月 ABI STG" \
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
        "${ENABLE_BLK_WBT_DONE_FAST_PATH:-0}:${BLK_WBT_DONE_FAST_PATH_COMMIT:-}" \
        "${ENABLE_MEMCG_RSTAT_FAST_PATH:-0}:${MEMCG_RSTAT_FAST_PATH_COMMIT:-}" \
        "${ENABLE_TCP_RECV_MSTAMP_FAST_PATH:-0}:${TCP_RECV_MSTAMP_FAST_PATH_COMMIT:-}" \
        "${ENABLE_IPV6_MLD_UAF_FIX:-0}:${IPV6_MLD_UAF_FIX_COMMIT:-}"; do
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
if [ "${ENABLE_F2FS_DIO_OVERWRITE_FAST_PATH}" = "1" ]; then
    verify_aosp_backport_source "F2FS DIO overwrite 映射检查优化" \
        "${F2FS_DIO_OVERWRITE_FAST_PATH_AOSP_REF}" \
        "${F2FS_DIO_OVERWRITE_FAST_PATH_COMMIT}" \
        "${F2FS_DIO_OVERWRITE_FAST_PATH_COMMIT_DATE}" \
        "${F2FS_DIO_OVERWRITE_FAST_PATH_PATCH_ID}" \
        "fs/f2fs/data.c"
fi
if [ "${ENABLE_BLK_WBT_DONE_FAST_PATH}" = "1" ]; then
    verify_aosp_backport_source "blk-wbt 非节流写完成快路径优化" \
        "${BLK_WBT_DONE_FAST_PATH_AOSP_REF}" \
        "${BLK_WBT_DONE_FAST_PATH_COMMIT}" \
        "${BLK_WBT_DONE_FAST_PATH_COMMIT_DATE}" \
        "${BLK_WBT_DONE_FAST_PATH_PATCH_ID}" \
        "block/blk-wbt.c"
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
if [ "${ENABLE_IPV6_MLD_UAF_FIX}" = "1" ]; then
    verify_aosp_backport_source "IPv6 MLD 查询释放后访问修复" \
        "${IPV6_MLD_UAF_FIX_AOSP_REF}" \
        "${IPV6_MLD_UAF_FIX_COMMIT}" \
        "${IPV6_MLD_UAF_FIX_COMMIT_DATE}" \
        "${IPV6_MLD_UAF_FIX_PATCH_ID}" \
        "net/ipv6/mcast.c"
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
prepare_anykernel_tools
[ "${ENABLE_KERNELSU}" != "1" ] || prepare_kernelsu_manager

log_success "源码与编译环境初始化完成"
log_info "soc-repo: ${SOC_DIR}"
log_info "GKI common: ${COMMON_DIR}"
[ "${ENABLE_KERNELSU}" != "1" ] || log_info "KernelSU: ${KSU_DIR} (${KSU_REF} @ ${KSU_COMMIT})"
[ "${ENABLE_SUSFS}" != "1" ] || log_info "SUSFS: ${SUSFS_DIR} (${SUSFS_REF} @ ${SUSFS_COMMIT})"
[ "${ENABLE_BBG}" != "1" ] || log_info "Baseband Guard: ${BBG_DIR} (${BBG_REF} @ ${BBG_COMMIT})"
[ "${ENABLE_BACKPORT_AUDIT}" != "1" ] || log_info "Backport audit snapshot: ${BACKPORT_AUDIT_SNAPSHOT} (no age cutoff)"
[ "${ENABLE_F2FS_DIO_OVERWRITE_FAST_PATH}" != "1" ] || log_info "AOSP F2FS DIO overwrite fast path: ${F2FS_DIO_OVERWRITE_FAST_PATH_COMMIT} (${F2FS_DIO_OVERWRITE_FAST_PATH_AOSP_REF})"
[ "${ENABLE_BLK_WBT_DONE_FAST_PATH}" != "1" ] || log_info "AOSP blk-wbt completion fast path: ${BLK_WBT_DONE_FAST_PATH_COMMIT} (${BLK_WBT_DONE_FAST_PATH_AOSP_REF})"
[ "${ENABLE_MEMCG_RSTAT_FAST_PATH}" != "1" ] || log_info "Linux memcg rstat fast path: ${MEMCG_RSTAT_FAST_PATH_COMMIT} (${MEMCG_RSTAT_FAST_PATH_AOSP_REF})"
[ "${ENABLE_TCP_RECV_MSTAMP_FAST_PATH}" != "1" ] || log_info "Linux TCP recv timestamp fast path: ${TCP_RECV_MSTAMP_FAST_PATH_COMMIT} (${TCP_RECV_MSTAMP_FAST_PATH_AOSP_REF})"
[ "${ENABLE_IPV6_MLD_UAF_FIX}" != "1" ] || log_info "AOSP IPv6 MLD UAF fix: ${IPV6_MLD_UAF_FIX_COMMIT} (${IPV6_MLD_UAF_FIX_AOSP_REF})"
[ "${ENABLE_IPSET}" != "1" ] || log_info "IPSet userspace: ${IPSET_DIR} + libmnl ${LIBMNL_DIR} (NDK ${ANDROID_NDK_VERSION})"
log_info "toolchain: ${CI_TOOLCHAIN_DIR}"
log_info "MagiskBoot: v${MAGISK_VERSION} (${MAGISK_COMMIT})"
log_info "AnyKernel3: scripts ${AK3_UPSTREAM_COMMIT}, arm64 tools ${AK3_ARM64_TOOLS_COMMIT}"
