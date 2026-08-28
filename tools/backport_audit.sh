#!/usr/bin/env bash
#
# Enumerate official histories after the pinned common baseline without
# modifying kernel sources.
#
set -euo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
export GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1 GIT_PAGER=cat

die() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }
log_info() { printf '[INFO] %s\n' "$1"; }
log_success() { printf '[OK] %s\n' "$1"; }

reject_git_environment_overrides() {
    local name
    while IFS= read -r name; do
        case "${name}" in
            GIT_CONFIG_GLOBAL) [ "${!name}" = "/dev/null" ] || die "Git 全局配置隔离值异常" ;;
            GIT_CONFIG_COUNT) [ "${!name}" = "1" ] || die "Git 命令配置数量异常" ;;
            GIT_CONFIG_KEY_0) [ "${!name}" = "core.hooksPath" ] || die "Git 命令配置键异常" ;;
            GIT_CONFIG_VALUE_0) [ "${!name}" = "/dev/null" ] || die "Git hooks 隔离值异常" ;;
            GIT_CONFIG_NOSYSTEM|GIT_NO_LAZY_FETCH|GIT_NO_REPLACE_OBJECTS)
                [ "${!name}" = "1" ] || die "Git 隔离值异常: ${name}"
                ;;
            GIT_PAGER) [ "${!name}" = "cat" ] || die "Git pager 隔离值异常" ;;
            GIT_*) die "拒绝 Git 环境覆盖: ${name}" ;;
        esac
    done < <(compgen -e)
}
reject_git_environment_overrides

load_env_file() {
    local env_file="$1" had_allexport=0
    [ -f "${env_file}" ] || return
    case "$-" in *a*) had_allexport=1 ;; esac
    set -a
    . "${env_file}"
    [ "${had_allexport}" = "1" ] || set +a
    reject_git_environment_overrides
}

resolve_workspace_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "${WORKSPACE_DIR}" "$1" ;;
    esac
}

normalize_git_url() {
    printf '%s' "$1" | sed -e 's#/$##' -e 's#\.git$##'
}

verify_bare_repo() {
    local label="$1" repo_dir="$2" expected_url="$3"
    local actual_url git_dir replace_refs unexpected_config
    [ "$(git -C "${repo_dir}" rev-parse --is-bare-repository 2>/dev/null)" = "true" ] || \
        die "${label} 不是 bare 审计仓库，请先运行 ./init.sh"
    git_dir="$(git -C "${repo_dir}" rev-parse --absolute-git-dir)"
    replace_refs="$(git -C "${repo_dir}" for-each-ref --format='%(refname)' refs/replace/)"
    [ -z "${replace_refs}" ] || die "${label} 存在 refs/replace 对象替换:\n${replace_refs}"
    [ ! -s "${git_dir}/info/grafts" ] || die "${label} 存在 info/grafts 对象替换"
    unexpected_config="$(git -C "${repo_dir}" config --name-only --list | LC_ALL=C sort -u | awk '
        /^core\.(repositoryformatversion|filemode|bare|hookspath)$/ { next }
        /^remote\.origin\.(url|fetch|promisor|partialclonefilter)$/ { next }
        /^backport\.[a-z0-9.]+$/ { next }
        { print }
    ')"
    [ -z "${unexpected_config}" ] || \
        die "${label} 存在非白名单 Git 配置:\n${unexpected_config}"
    actual_url="$(git -C "${repo_dir}" remote get-url origin 2>/dev/null || true)"
    [ "$(normalize_git_url "${actual_url}")" = "$(normalize_git_url "${expected_url}")" ] || \
        die "${label} remote 不匹配: ${actual_url}"
}

verify_local_commit() {
    local label="$1" repo_dir="$2" commit="$3"
    env GIT_NO_LAZY_FETCH=1 git -C "${repo_dir}" cat-file -e "${commit}^{commit}" 2>/dev/null || \
        die "${label} 固定对象缺失，请先运行 ./init.sh: ${commit}"
}

sanitize_field() {
    local value="$1"
    value="${value//$'\t'/ }"
    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    printf '%s' "${value}"
}

list_paths() {
    local repo_dir="$1" commit="$2"
    env GIT_NO_LAZY_FETCH=1 git -C "${repo_dir}" diff-tree \
        --no-commit-id --name-only -r "${commit}" 2>/dev/null | LC_ALL=C sort -u
}

classify_paths() {
    local paths="$1" path any_relevant=0 interface_risk=0
    while IFS= read -r path; do
        [ -n "${path}" ] || continue
        case "${path}" in
            Documentation/*|tools/testing/*|tools/perf/*|samples/*) continue ;;
            scripts/*) case "${path}" in scripts/syscall*) ;; *) continue ;; esac ;;
            arch/*) case "${path}" in arch/arm64/*) ;; *) continue ;; esac ;;
        esac
        any_relevant=1
        case "${path}" in
            include/uapi/*|arch/arm64/include/uapi/*|*/Kconfig|*/Kconfig.*|*/Makefile|\
            */abi|*/abi/*|*/abi.*|*/abi_*|gki/*/symbols/*|\
            arch/arm64/tools/syscall*|scripts/syscall*) interface_risk=1 ;;
        esac
    done <<<"${paths}"
    printf '%s\t%s\n' "${any_relevant}" "${interface_risk}"
}

current_tree_has_path() {
    local paths="$1" path
    while IFS= read -r path; do
        [ -n "${path}" ] || continue
        [ -e "${COMMON_DIR}/${path}" ] && return 0
    done <<<"${paths}"
    return 1
}

extract_upstream_id() {
    local message="$1"
    shopt -s nocasematch
    if [[ "${message}" =~ upstream[[:space:]]commit[[:space:]]([0-9a-f]{12,40}) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "${message}" =~ commit[[:space:]]([0-9a-f]{40})[[:space:]]upstream ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
    shopt -u nocasematch
}

write_candidate() {
    local source="$1" repo_dir="$2" commit="$3" date="$4" subject="$5" body="$6"
    local message class evidence path_flags relevant interface_risk status upstream_id
    local correctness_re='CVE-|Fixes:|KASAN|KMSAN|UBSAN|syzbot|use[- ]after[- ]free|UAF|out[- ]of[- ]bounds|OOB|double[- ]free|deadlock|data (loss|corruption)|corrupt|panic|crash|hang|NULL pointer|null deref|uninitiali[sz]ed|integer overflow|security|privilege|bypass|race condition'
    local dynamic_re='CVE-|KASAN|KMSAN|UBSAN|syzbot'
    local severe_subject_re='use[- ]after[- ]free|UAF|out[- ]of[- ]bounds|OOB|double[- ]free|deadlock|data (loss|corruption)|corrupt|panic|crash|hang|NULL pointer|null deref|uninitiali[sz]ed|integer overflow|security|privilege|bypass|race'
    local performance_re='performance|optimi[sz]|latency|throughput|power|energy|contention|scalab|fast path|slow path|cacheline|wakeups?'
    local needs_paths=0 paths="-"

    message="${subject}"$'\n'"${body}"
    class=""
    evidence=""
    shopt -s nocasematch
    if [[ "${message}" =~ ${correctness_re} ]]; then
        class="correctness"
        [[ "${message}" =~ Fixes: ]] && evidence="${evidence:+${evidence},}Fixes"
        [[ "${message}" =~ CVE- ]] && evidence="${evidence:+${evidence},}CVE"
        [[ "${message}" =~ syzbot|KASAN|KMSAN|UBSAN ]] && evidence="${evidence:+${evidence},}dynamic-report"
        [ -n "${evidence}" ] || evidence="severe-keyword"
        if [[ "${message}" =~ ${dynamic_re} ]] || [[ "${subject}" =~ ${severe_subject_re} ]]; then
            needs_paths=1
        fi
    elif [[ "${subject}" =~ ${performance_re} ]]; then
        class="performance"
        evidence="performance-claim"
        needs_paths=1
    else
        shopt -u nocasematch
        return
    fi
    shopt -u nocasematch

    upstream_id="$(extract_upstream_id "${message}")"

    if [ "${needs_paths}" != "1" ]; then
        status="SCREEN_FIXES_ONLY"
    else
        paths="$(list_paths "${repo_dir}" "${commit}" || true)"
        [ -n "${paths}" ] || paths="-"
        path_flags="$(classify_paths "${paths}")"
        relevant="${path_flags%%$'\t'*}"
        interface_risk="${path_flags#*$'\t'}"
        if [ "${relevant}" != "1" ] || ! current_tree_has_path "${paths}"; then
            status="REJECT_RELEVANCE"
        elif [ "${interface_risk}" = "1" ]; then
            status="REVIEW_INTERFACE_STATIC_RISK"
        elif [ "${class}" = "performance" ]; then
            status="DEEP_REVIEW_PERFORMANCE"
        else
            status="DEEP_REVIEW_CORRECTNESS"
        fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${source}" "${commit}" "${date}" \
        "$(sanitize_field "${subject}")" "${class}" "${evidence}" "${status}" \
        "${upstream_id:--}" "$(sanitize_field "${paths}")" >> "${CANDIDATES_FILE}"
}

emit_source_candidates() {
    local source="$1" repo_dir="$2"
    shift 2
    local record commit date rest subject body
    while IFS= read -r -d '' record; do
        while [[ "${record}" == $'\n'* ]]; do record="${record#$'\n'}"; done
        [ -n "${record}" ] || continue
        commit="${record%%$'\t'*}"
        rest="${record#*$'\t'}"
        date="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        subject="${rest%%$'\t'*}"
        body="${rest#*$'\t'}"
        write_candidate "${source}" "${repo_dir}" "${commit}" "${date}" "${subject}" "${body}"
    done < <(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${repo_dir}" log \
        --no-merges \
        --before="${BACKPORT_AUDIT_SNAPSHOT} 23:59:59 +0000" \
        --format='%H%x09%cs%x09%s%x09%b%x00' "$@")
}

count_status() {
    local status="$1"
    awk -F '\t' -v value="${status}" 'NR > 1 && $7 == value { count++ } END { print count + 0 }' \
        "${CANDIDATES_FILE}"
}

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
WORKSPACE_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")/.." && pwd -P)"
load_env_file "${WORKSPACE_DIR}/.env"

[ "${ENABLE_BACKPORT_AUDIT:-0}" = "1" ] || die "当前 .env 未启用后续改进审计"
[ -n "${BACKPORT_AUDIT_SNAPSHOT:-}" ] || die "缺少 BACKPORT_AUDIT_SNAPSHOT"

COMMON_DIR="$(resolve_workspace_path "${COMMON_SOURCE_DIR}")"
AOSP_DIR="$(resolve_workspace_path "${AOSP_BACKPORT_AUDIT_SOURCE_DIR}")"
STABLE_DIR="$(resolve_workspace_path "${LINUX_STABLE_AUDIT_SOURCE_DIR}")"
MAINLINE_DIR="$(resolve_workspace_path "${LINUX_MAINLINE_AUDIT_SOURCE_DIR}")"
OUTPUT_DIR="${WORKSPACE_DIR}/audit_out/backport-${BACKPORT_AUDIT_SNAPSHOT}"
CANDIDATES_FILE="${OUTPUT_DIR}/candidates.tsv"
REFS_FILE="${OUTPUT_DIR}/refs.tsv"
SUMMARY_FILE="${OUTPUT_DIR}/summary.md"
mkdir -p "${OUTPUT_DIR}"

verify_bare_repo "AOSP common 审计源" "${AOSP_DIR}" "${COMMON_REPO}"
verify_bare_repo "Linux stable 审计源" "${STABLE_DIR}" "${LINUX_STABLE_AUDIT_REPO}"
verify_bare_repo "Linux mainline 审计源" "${MAINLINE_DIR}" "${LINUX_MAINLINE_AUDIT_REPO}"
verify_local_commit "AOSP ${COMMON_BRANCH}" "${AOSP_DIR}" "${COMMON_COMMIT}"
verify_local_commit "Linux stable 起点" "${STABLE_DIR}" "${LINUX_STABLE_AUDIT_BASE_COMMIT}"
verify_local_commit "Linux stable 终点" "${STABLE_DIR}" "${LINUX_STABLE_AUDIT_COMMIT}"
verify_local_commit "Linux mainline 起点" "${MAINLINE_DIR}" "${LINUX_MAINLINE_AUDIT_BASE_COMMIT}"
verify_local_commit "Linux mainline 终点" "${MAINLINE_DIR}" "${LINUX_MAINLINE_AUDIT_COMMIT}"
git -C "${STABLE_DIR}" merge-base --is-ancestor \
    "${LINUX_STABLE_AUDIT_BASE_COMMIT}" "${LINUX_STABLE_AUDIT_COMMIT}" || \
    die "Linux stable 固定范围不是完整祖先链，请重新运行 ./init.sh"
git -C "${MAINLINE_DIR}" merge-base --is-ancestor \
    "${LINUX_MAINLINE_AUDIT_BASE_COMMIT}" "${LINUX_MAINLINE_AUDIT_COMMIT}" || \
    die "Linux mainline 固定范围不是完整祖先链，请重新运行 ./init.sh"
AOSP_BASE_DATE="$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${AOSP_DIR}" \
    show -s --format=%cs "${COMMON_COMMIT}")"

printf 'source\tname\tcommit\n' > "${REFS_FILE}"
aosp_commits=()
for pair in ${AOSP_BACKPORT_AUDIT_REFS}; do
    name="${pair%%:*}"
    commit="${pair#*:}"
    verify_local_commit "AOSP ${name}" "${AOSP_DIR}" "${commit}"
    aosp_commits+=("${commit}")
    printf 'aosp\t%s\t%s\n' "${name}" "${commit}" >> "${REFS_FILE}"
done
printf 'linux-stable\t%s\t%s\n' "${LINUX_STABLE_AUDIT_REF}" "${LINUX_STABLE_AUDIT_COMMIT}" >> "${REFS_FILE}"
printf 'linux-mainline\tsnapshot-%s\t%s\n' "${BACKPORT_AUDIT_SNAPSHOT}" "${LINUX_MAINLINE_AUDIT_COMMIT}" >> "${REFS_FILE}"

AOSP_TOTAL="$(env GIT_NO_LAZY_FETCH=1 git -C "${AOSP_DIR}" rev-list --no-merges --count \
    --since="${AOSP_BASE_DATE} 00:00:00 +0000" "${aosp_commits[@]}" --not "${COMMON_COMMIT}")"
STABLE_TOTAL="$(env GIT_NO_LAZY_FETCH=1 git -C "${STABLE_DIR}" rev-list --no-merges --count \
    "${LINUX_STABLE_AUDIT_BASE_COMMIT}..${LINUX_STABLE_AUDIT_COMMIT}")"
MAINLINE_TOTAL="$(env GIT_NO_LAZY_FETCH=1 git -C "${MAINLINE_DIR}" rev-list --no-merges --count \
    --before="${BACKPORT_AUDIT_SNAPSHOT} 23:59:59 +0000" \
    "${LINUX_MAINLINE_AUDIT_BASE_COMMIT}..${LINUX_MAINLINE_AUDIT_COMMIT}")"

printf 'source\tcommit\tdate\tsubject\tclass\tevidence\tstatus\tupstream_commit\tpaths\n' > "${CANDIDATES_FILE}"
log_info "扫描 AOSP 固定分支并集 (${AOSP_TOTAL} 个非 merge 提交)"
emit_source_candidates "aosp" "${AOSP_DIR}" \
    --since="${AOSP_BASE_DATE} 00:00:00 +0000" "${aosp_commits[@]}" --not "${COMMON_COMMIT}"
log_info "扫描 Linux 6.12 stable (${STABLE_TOTAL} 个非 merge 提交)"
emit_source_candidates "linux-stable" "${STABLE_DIR}" \
    "${LINUX_STABLE_AUDIT_BASE_COMMIT}..${LINUX_STABLE_AUDIT_COMMIT}"
log_info "扫描 Linux mainline (${MAINLINE_TOTAL} 个非 merge 提交)"
emit_source_candidates "linux-mainline" "${MAINLINE_DIR}" \
    "${LINUX_MAINLINE_AUDIT_BASE_COMMIT}..${LINUX_MAINLINE_AUDIT_COMMIT}"

CANDIDATE_TOTAL="$(awk 'END { print (NR > 0 ? NR - 1 : 0) }' "${CANDIDATES_FILE}")"
{
    printf '# 后续改进审计自动筛选摘要\n\n'
    printf -- '- 快照日期：`%s`\n' "${BACKPORT_AUDIT_SNAPSHOT}"
    printf -- '- AOSP `%s` 基线日期：`%s`\n' "${COMMON_BRANCH}" "${AOSP_BASE_DATE}"
    printf -- '- 候选年龄门槛：无；仅拒绝晚于固定快照的提交\n'
    printf -- '- AOSP 分支并集：%s 个非 merge 提交\n' "${AOSP_TOTAL}"
    printf -- '- Linux stable 范围：%s 个非 merge 提交\n' "${STABLE_TOTAL}"
    printf -- '- Linux mainline 范围：%s 个非 merge 提交\n' "${MAINLINE_TOTAL}"
    printf -- '- 关键词初筛：%s 个\n\n' "${CANDIDATE_TOTAL}"
    printf '## 初筛状态\n\n'
    for status in SCREEN_FIXES_ONLY REJECT_RELEVANCE REVIEW_INTERFACE_STATIC_RISK \
        DEEP_REVIEW_CORRECTNESS DEEP_REVIEW_PERFORMANCE; do
        printf -- '- `%s`: %s\n' "${status}" "$(count_status "${status}")"
    done
    printf '\n自动筛选不构成合入结论；接口风险项不得仅凭路径拒绝，所有 review 项仍须证明当前缺陷、收益、用户态兼容和目标 OTA 必需模块闭包。\n'
} > "${SUMMARY_FILE}"

log_success "审计结果已生成: ${OUTPUT_DIR}"
