#!/usr/bin/env bash
#
# Orchestrate independently revertible official-backport manifests.
#
set -euo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
export GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1 GIT_PAGER=cat

die() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }
log_success() { printf '[OK] %s\n' "$1"; }

reject_git_environment_overrides() {
	local name
	while IFS= read -r name; do
		case "${name}" in
			GIT_CONFIG_GLOBAL) [ "${!name}" = /dev/null ] || die "Git 全局配置隔离值异常" ;;
			GIT_CONFIG_COUNT) [ "${!name}" = 1 ] || die "Git 命令配置数量异常" ;;
			GIT_CONFIG_KEY_0) [ "${!name}" = core.hooksPath ] || die "Git 命令配置键异常" ;;
			GIT_CONFIG_VALUE_0) [ "${!name}" = /dev/null ] || die "Git hooks 隔离值异常" ;;
			GIT_CONFIG_NOSYSTEM|GIT_NO_LAZY_FETCH|GIT_NO_REPLACE_OBJECTS)
				[ "${!name}" = 1 ] || die "Git 隔离值异常: ${name}"
				;;
			GIT_PAGER) [ "${!name}" = cat ] || die "Git pager 隔离值异常" ;;
			GIT_*) die "拒绝 Git 环境覆盖: ${name}" ;;
		esac
	done < <(compgen -e)
}

load_env_file() {
	local env_file="$1" had_allexport=0
	[ -f "${env_file}" ] || die "缺少受版本控制的 .env"
	case "$-" in *a*) had_allexport=1 ;; esac
	set -a
	. "${env_file}"
	[ "${had_allexport}" = 1 ] || set +a
	reject_git_environment_overrides
}

cleanup() {
	[ -z "${TMP_ROOT:-}" ] || rm -rf -- "${TMP_ROOT}"
}
trap cleanup EXIT

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
WORKSPACE_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")/.." && pwd -P)"
load_env_file "${WORKSPACE_DIR}/.env"

MANIFEST_TOOL="${WORKSPACE_DIR}/tools/backport_manifest.sh"
MANIFEST_DIR="${WORKSPACE_DIR}/patches/backports/r21-independent"
TMP_ROOT=""
declare -a MANIFESTS=()

manifest_pin_name() {
	local base key
	base="$(basename "$1" .tsv)"
	key="$(tr '[:lower:]-' '[:upper:]_' <<<"${base}")"
	printf 'INDEPENDENT_%s_SHA256\n' "${key}"
}

discover_manifests() {
	local manifest base pin_name pin_value variable expected_file
	MANIFESTS=()
	if [ -d "${MANIFEST_DIR}" ]; then
		shopt -s nullglob
		MANIFESTS=("${MANIFEST_DIR}"/[0-9][0-9][0-9]-*.tsv)
		shopt -u nullglob
	fi
	for manifest in "${MANIFESTS[@]}"; do
		base="$(basename "${manifest}")"
		[[ "${base}" =~ ^[0-9]{3}-[a-z0-9]+(-[a-z0-9]+)*\.tsv$ ]] || \
			die "独立回移清单文件名非法: ${base}"
		[ -f "${manifest}" ] && [ ! -L "${manifest}" ] || \
			die "独立回移清单缺失或不安全: ${base}"
		pin_name="$(manifest_pin_name "${manifest}")"
		pin_value="${!pin_name:-}"
		[[ "${pin_value}" =~ ^[0-9a-f]{64}$ ]] || \
			die "${base} 缺少独立 SHA-256 pin: ${pin_name}"
	done
	while IFS= read -r variable; do
		case "${variable}" in
			INDEPENDENT_[0-9][0-9][0-9]_*_SHA256)
				expected_file="${variable#INDEPENDENT_}"
				expected_file="${expected_file%_SHA256}"
				expected_file="$(tr '[:upper:]_' '[:lower:]-' <<<"${expected_file}").tsv"
				[ -f "${MANIFEST_DIR}/${expected_file}" ] || \
					die "独立回移 SHA-256 pin 没有对应清单: ${variable}"
				;;
		esac
	done < <(compgen -A variable | LC_ALL=C sort)
}

run_manifest() {
	local manifest="$1" pin_name pin_value
	shift
	pin_name="$(manifest_pin_name "${manifest}")"
	pin_value="${!pin_name:-}"
	BACKPORT_INDEPENDENT=1 \
	BACKPORT_MANIFEST_OVERRIDE="${manifest}" \
	BACKPORT_MANIFEST_SHA256_OVERRIDE="${pin_value}" \
		bash "${MANIFEST_TOOL}" "$@"
}

verify_manifests() {
	local manifest source duplicates overlap new_commits old_commits
	[ -f "${MANIFEST_TOOL}" ] && [ ! -L "${MANIFEST_TOOL}" ] || \
		die "缺少 r21 回移清单工具"
	discover_manifests
	for manifest in "${MANIFESTS[@]}"; do
		run_manifest "${manifest}" verify-manifest >/dev/null
	done
	[ "${#MANIFESTS[@]}" -gt 0 ] || return 0
	TMP_ROOT="${TMP_ROOT:-$(mktemp -d)}"
	new_commits="${TMP_ROOT}/new-commits"
	old_commits="${TMP_ROOT}/old-commits"
	: > "${new_commits}"
	: > "${old_commits}"
	for manifest in "${MANIFESTS[@]}"; do
		for source in aosp stable mainline; do
			run_manifest "${manifest}" list "${source}" >> "${new_commits}"
		done
	done
	duplicates="$(LC_ALL=C sort "${new_commits}" | uniq -d)"
	[ -z "${duplicates}" ] || die "独立回移清单存在重复官方提交:\n${duplicates}"
	for source in aosp stable mainline; do
		bash "${MANIFEST_TOOL}" list "${source}" >> "${old_commits}"
	done
	overlap="$(LC_ALL=C sort "${new_commits}" "${old_commits}" | uniq -d)"
	[ -z "${overlap}" ] || die "独立回移与现有固定集合重复:\n${overlap}"
}

list_commits() {
	local source="$1" manifest
	verify_manifests
	for manifest in "${MANIFESTS[@]}"; do
		run_manifest "${manifest}" list "${source}"
	done
}

list_paths() {
	local manifest
	verify_manifests
	for manifest in "${MANIFESTS[@]}"; do
		run_manifest "${manifest}" list-paths
	done | LC_ALL=C sort -u
}

verify_sources() {
	local manifest
	verify_manifests
	for manifest in "${MANIFESTS[@]}"; do
		run_manifest "${manifest}" verify-sources
	done
}

tracked_diff() {
	local tree="$1"
	env GIT_NO_LAZY_FETCH=1 LC_ALL=C git -c color.ui=false -C "${tree}" diff \
		--binary --full-index --no-ext-diff --no-textconv --no-renames --no-color \
		--diff-algorithm=myers --src-prefix=a/ --dst-prefix=b/ \
		HEAD -- .
}

tracked_index_diff() {
	local tree="$1" index_file="$2"
	env GIT_INDEX_FILE="${index_file}" GIT_NO_LAZY_FETCH=1 LC_ALL=C \
		git -c color.ui=false -C "${tree}" diff --cached \
		--binary --full-index --no-ext-diff --no-textconv --no-renames --no-color \
		--diff-algorithm=myers --src-prefix=a/ --dst-prefix=b/ \
		HEAD -- .
}

verify_base_diff() {
	local tree="$1" expected_base="$2" index_file current_patch replay_patch
	local actual_final actual_base replay_final manifest one_index one_base
	local i
	[[ "${expected_base}" =~ ^[0-9a-f]{64}$ ]] || die "GKI common 基础差异 SHA-256 格式错误"
	[ "$(git -C "${tree}" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || \
		die "独立回移目标不是 Git 工作树"
	verify_sources
	TMP_ROOT="${TMP_ROOT:-$(mktemp -d)}"
	index_file="${TMP_ROOT}/layered.index"
	current_patch="${TMP_ROOT}/current.patch"
	replay_patch="${TMP_ROOT}/replay.patch"
	env GIT_INDEX_FILE="${index_file}" git -C "${tree}" read-tree HEAD
	tracked_diff "${tree}" > "${current_patch}"
	actual_final="$(sha256sum "${current_patch}" | awk '{ print $1 }')"
	if [ -s "${current_patch}" ]; then
		env GIT_INDEX_FILE="${index_file}" git -C "${tree}" \
			apply --cached "${current_patch}"
	fi
	for ((i=${#MANIFESTS[@]} - 1; i >= 0; i--)); do
		run_manifest "${MANIFESTS[i]}" reverse-index "${tree}" "${index_file}"
	done
	actual_base="$(tracked_index_diff "${tree}" "${index_file}" | sha256sum | awk '{ print $1 }')"
	[ "${actual_base}" = "${expected_base}" ] || \
		die "剥离独立回移后的 GKI common 基础差异不匹配: ${actual_base}"

	for manifest in "${MANIFESTS[@]}"; do
		one_index="$(mktemp "${TMP_ROOT}/independent.XXXXXX")"
		cp -- "${index_file}" "${one_index}"
		run_manifest "${manifest}" apply-index "${tree}" "${one_index}"
		run_manifest "${manifest}" reverse-index "${tree}" "${one_index}"
		one_base="$(tracked_index_diff "${tree}" "${one_index}" | sha256sum | awk '{ print $1 }')"
		[ "${one_base}" = "${expected_base}" ] || \
			die "独立回移无法单独撤销: $(basename "${manifest}")"
		rm -f -- "${one_index}"
	done

	for manifest in "${MANIFESTS[@]}"; do
		run_manifest "${manifest}" apply-index "${tree}" "${index_file}"
	done
	tracked_index_diff "${tree}" "${index_file}" > "${replay_patch}"
	replay_final="$(sha256sum "${replay_patch}" | awk '{ print $1 }')"
	[ "${replay_final}" = "${actual_final}" ] || \
		die "独立回移重放后的 GKI common 差异摘要不匹配"
	cmp -s "${current_patch}" "${replay_patch}" || \
		die "独立回移重放后的 GKI common 精确差异不匹配"
	log_success "独立回移可逐项剥离，基础差异与完整重放精确匹配"
}

apply_all() {
	local tree="$1" manifest
	verify_sources
	for manifest in "${MANIFESTS[@]}"; do
		run_manifest "${manifest}" apply "${tree}"
	done
}

verify_applied() {
	local tree="$1" manifest
	verify_sources
	for manifest in "${MANIFESTS[@]}"; do
		run_manifest "${manifest}" verify-applied "${tree}"
	done
}

usage() {
	printf '用法: %s {verify-manifests|list SOURCE|list-paths|verify-sources|apply TREE|verify-applied TREE|verify-base-diff TREE SHA256}\n' "$0" >&2
	exit 2
}

case "${1:-}" in
	verify-manifests)
		[ "$#" = 1 ] || usage
		verify_manifests
		log_success "r21 独立回移清单身份与互斥性检查通过"
		;;
	list)
		[ "$#" = 2 ] || usage
		case "$2" in aosp|stable|mainline) ;; *) usage ;; esac
		list_commits "$2"
		;;
	list-paths)
		[ "$#" = 1 ] || usage
		list_paths
		;;
	verify-sources)
		[ "$#" = 1 ] || usage
		verify_sources
		log_success "r21 独立回移全部官方来源检查通过"
		;;
	apply)
		[ "$#" = 2 ] || usage
		apply_all "$2"
		log_success "r21 独立回移状态正确"
		;;
	verify-applied)
		[ "$#" = 2 ] || usage
		verify_applied "$2"
		log_success "r21 独立回移最终应用状态正确"
		;;
	verify-base-diff)
		[ "$#" = 3 ] || usage
		verify_base_diff "$2" "$3"
		;;
	*) usage ;;
esac
