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

cleanup_independent() {
	[ -z "${AUDIT_TMP_ROOT:-}" ] || rm -rf -- "${AUDIT_TMP_ROOT}"
}
trap cleanup_independent EXIT

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
WORKSPACE_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")/.." && pwd -P)"
load_env_file "${WORKSPACE_DIR}/.env"

MANIFEST_TOOL="${WORKSPACE_DIR}/tools/backport_manifest.sh"
MANIFEST_DIR="${WORKSPACE_DIR}/patches/backports/kmi6-2026-09-independent"
AUDIT_TMP_ROOT=""
[ -f "${MANIFEST_TOOL}" ] && [ ! -L "${MANIFEST_TOOL}" ] || die "缺少九月回移清单工具"
BACKPORT_MANIFEST_LIBRARY=0 BACKPORT_BUNDLE_LIBRARY=0 . "${MANIFEST_TOOL}"
declare -a MANIFESTS=()
declare -A BATCH_ROWS=() BATCH_GROUPS=() BATCH_PINS=() BATCH_TMP=()
MANIFESTS_READY=0
CONTENTS_READY=0
PATCHES_READY=0

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

select_manifest() {
	local manifest="$1"
	[ "${MANIFESTS_READY}" = 1 ] && [ -n "${BATCH_PINS[${manifest}]:-}" ] || \
		die "清单尚未由本次调用验证"
	MANIFEST="${manifest}"
	MANIFEST_SHA256="${BATCH_PINS[${manifest}]}"
	INDEPENDENT_MANIFEST=1
	mapfile -t MANIFEST_ROWS <<<"${BATCH_ROWS[${manifest}]}"
	GROUP_COUNT="${BATCH_GROUPS[${manifest}]}"
	TMP_ROOT="${BATCH_TMP[${manifest}]:-}"
}

verify_manifests() {
	local manifest pin_name row duplicates overlap
	local order group action source ref commit rest
	local -a new_commits=() old_commits=()
	[ "${MANIFESTS_READY}" != 1 ] || return 0
	discover_manifests
	for manifest in "${MANIFESTS[@]}"; do
		MANIFEST="${manifest}"
		pin_name="$(manifest_pin_name "${manifest}")"
		MANIFEST_SHA256="${!pin_name}"
		INDEPENDENT_MANIFEST=1
		validate_manifest
		BATCH_ROWS["${manifest}"]="$(printf '%s\n' "${MANIFEST_ROWS[@]}")"
		BATCH_GROUPS["${manifest}"]="${GROUP_COUNT}"
		BATCH_PINS["${manifest}"]="${MANIFEST_SHA256}"
		for row in "${MANIFEST_ROWS[@]}"; do
			IFS=$'\t' read -r order group action source ref commit rest <<<"${row}"
			new_commits+=("${commit}")
		done
	done
	if [ "${#MANIFESTS[@]}" = 0 ]; then
		MANIFESTS_READY=1
		return 0
	fi
	duplicates="$(printf '%s\n' "${new_commits[@]}" | LC_ALL=C sort | uniq -d)"
	[ -z "${duplicates}" ] || die "独立回移清单存在重复官方提交:\n${duplicates}"
	MANIFEST="$(resolve_workspace_path "${SELECTED_BACKPORT_MANIFEST:-patches/backports/kmi6-2026-09-selected-backports.tsv}")"
	MANIFEST_SHA256="${SELECTED_BACKPORT_MANIFEST_SHA256:-}"
	INDEPENDENT_MANIFEST=0
	validate_manifest
	for row in "${MANIFEST_ROWS[@]}"; do
		IFS=$'\t' read -r order group action source ref commit rest <<<"${row}"
		old_commits+=("${commit}")
	done
	overlap="$(printf '%s\n' "${new_commits[@]}" "${old_commits[@]}" | LC_ALL=C sort | uniq -d)"
	[ -z "${overlap}" ] || die "独立回移与现有固定集合重复:\n${overlap}"
	MANIFESTS_READY=1
}

list_commits() {
	local requested_source="$1" manifest row order group action source ref commit rest
	verify_manifests
	for manifest in "${MANIFESTS[@]}"; do
		select_manifest "${manifest}"
		for row in "${MANIFEST_ROWS[@]}"; do
			IFS=$'\t' read -r order group action source ref commit rest <<<"${row}"
			[ "${source}" != "${requested_source}" ] || printf '%s\n' "${commit}"
		done
	done
}

list_paths() {
	local manifest
	verify_manifests
	AUDIT_TMP_ROOT="${AUDIT_TMP_ROOT:-$(mktemp -d)}"
	for manifest in "${MANIFESTS[@]}"; do
		select_manifest "${manifest}"
		TMP_ROOT="${AUDIT_TMP_ROOT}"
		write_path_list
		cat "${TMP_ROOT}/paths"
	done | LC_ALL=C sort -u
}

verify_all_patches() {
	local manifest
	[ "${CONTENTS_READY}" != 1 ] || return 0
	verify_manifests
	for manifest in "${MANIFESTS[@]}"; do
		select_manifest "${manifest}"
		verify_patches
	done
	CONTENTS_READY=1
}

prepare_all_patches() {
	local manifest
	[ "${PATCHES_READY}" != 1 ] || return 0
	verify_all_patches
	AUDIT_TMP_ROOT="${AUDIT_TMP_ROOT:-$(mktemp -d)}"
	for manifest in "${MANIFESTS[@]}"; do
		select_manifest "${manifest}"
		TMP_ROOT="$(mktemp -d "${AUDIT_TMP_ROOT}/manifest.XXXXXX")"
		BATCH_TMP["${manifest}"]="${TMP_ROOT}"
		prepare_patch_cache
		write_path_list
	done
	PATCHES_READY=1
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
	prepare_all_patches
	index_file="${AUDIT_TMP_ROOT}/layered.index"
	current_patch="${AUDIT_TMP_ROOT}/current.patch"
	replay_patch="${AUDIT_TMP_ROOT}/replay.patch"
	env GIT_INDEX_FILE="${index_file}" git -C "${tree}" read-tree HEAD
	tracked_diff "${tree}" > "${current_patch}"
	actual_final="$(sha256sum "${current_patch}" | awk '{ print $1 }')"
	if [ -s "${current_patch}" ]; then
		env GIT_INDEX_FILE="${index_file}" git -C "${tree}" \
			apply --cached "${current_patch}"
	fi
	for ((i=${#MANIFESTS[@]} - 1; i >= 0; i--)); do
		select_manifest "${MANIFESTS[i]}"
		apply_sequence_to_index "${tree}" "${index_file}" reverse
	done
	actual_base="$(tracked_index_diff "${tree}" "${index_file}" | sha256sum | awk '{ print $1 }')"
	[ "${actual_base}" = "${expected_base}" ] || \
		die "剥离独立回移后的 GKI common 基础差异不匹配: ${actual_base}"

	for manifest in "${MANIFESTS[@]}"; do
		select_manifest "${manifest}"
		one_index="$(mktemp "${AUDIT_TMP_ROOT}/independent.XXXXXX")"
		cp -- "${index_file}" "${one_index}"
		apply_sequence_to_index "${tree}" "${one_index}" forward
		apply_sequence_to_index "${tree}" "${one_index}" reverse
		one_base="$(tracked_index_diff "${tree}" "${one_index}" | sha256sum | awk '{ print $1 }')"
		[ "${one_base}" = "${expected_base}" ] || \
			die "独立回移无法单独撤销: $(basename "${manifest}")"
		rm -f -- "${one_index}"
	done

	for manifest in "${MANIFESTS[@]}"; do
		select_manifest "${manifest}"
		apply_sequence_to_index "${tree}" "${index_file}" forward
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
	prepare_all_patches
	for manifest in "${MANIFESTS[@]}"; do
		select_manifest "${manifest}"
		apply_set "${tree}" >/dev/null
	done
}

verify_applied() {
	local tree="$1" manifest
	prepare_all_patches
	for manifest in "${MANIFESTS[@]}"; do
		select_manifest "${manifest}"
		verify_applied_set "${tree}" >/dev/null
	done
}

usage() {
	printf '用法: %s {verify-manifests|list SOURCE|list-paths|verify-patches|apply TREE|verify-applied TREE|verify-base-diff TREE SHA256|verify-applied-base-diff TREE SHA256}\n' "$0" >&2
	exit 2
}

case "${1:-}" in
	verify-manifests)
		[ "$#" = 1 ] || usage
		verify_manifests
		log_success "九月独立回移清单身份与互斥性检查通过"
		;;
	list)
		[ "$#" = 2 ] || usage
		case "$2" in aosp|stable|mainline|kbuild) ;; *) usage ;; esac
		list_commits "$2"
		;;
	list-paths)
		[ "$#" = 1 ] || usage
		list_paths
		;;
	verify-patches)
		[ "$#" = 1 ] || usage
		verify_all_patches
		log_success "九月独立回移全部固定补丁内容检查通过"
		;;
	apply)
		[ "$#" = 2 ] || usage
		apply_all "$2"
		log_success "九月独立回移状态正确"
		;;
	verify-applied)
		[ "$#" = 2 ] || usage
		verify_applied "$2"
		log_success "九月独立回移最终应用状态正确"
		;;
	verify-base-diff|verify-applied-base-diff)
		[ "$#" = 3 ] || usage
		if [ "$1" = verify-applied-base-diff ]; then
			verify_applied "$2"
			log_success "九月独立回移最终应用状态正确"
		fi
		verify_base_diff "$2" "$3"
		;;
	*) usage ;;
esac
