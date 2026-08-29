#!/usr/bin/env bash
#
# Apply and verify one fixed official-backport manifest as an ordered set.
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

resolve_workspace_path() {
	case "$1" in
		/*) printf '%s\n' "$1" ;;
		*) printf '%s/%s\n' "${WORKSPACE_DIR}" "$1" ;;
	esac
}

normalize_git_url() {
	printf '%s' "$1" | sed -e 's#/$##' -e 's#\.git$##'
}

verify_audit_repo() {
	local label="$1" repo="$2" expected_url="$3"
	local actual_url git_dir replace_refs unexpected_config
	[ "$(git -C "${repo}" rev-parse --is-bare-repository 2>/dev/null)" = true ] || \
		die "${label} 不是 bare 审计仓库，请先运行 ./init.sh"
	git_dir="$(git -C "${repo}" rev-parse --absolute-git-dir)"
	actual_url="$(git -C "${repo}" remote get-url origin 2>/dev/null || true)"
	[ "$(normalize_git_url "${actual_url}")" = "$(normalize_git_url "${expected_url}")" ] || \
		die "${label} remote 不匹配: ${actual_url}"
	replace_refs="$(git -C "${repo}" for-each-ref --format='%(refname)' refs/replace/)"
	[ -z "${replace_refs}" ] || die "${label} 存在 refs/replace 对象替换"
	[ ! -s "${git_dir}/info/grafts" ] || die "${label} 存在 info/grafts 对象替换"
	[ ! -s "${git_dir}/info/attributes" ] || die "${label} 存在 info/attributes 差异覆盖"
	[ ! -s "${git_dir}/objects/info/alternates" ] || die "${label} 存在外部 object alternates"
	unexpected_config="$(git -C "${repo}" config --name-only --list | LC_ALL=C sort -u | awk '
		/^core\.(repositoryformatversion|filemode|bare|hookspath)$/ { next }
		/^remote\.origin\.(url|fetch|promisor|partialclonefilter)$/ { next }
		/^backport\.[a-z0-9.]+$/ { next }
		{ print }
	')"
	[ -z "${unexpected_config}" ] || die "${label} 存在非白名单 Git 配置:\n${unexpected_config}"
}

cleanup() {
	[ -z "${TMP_ROOT:-}" ] || rm -rf -- "${TMP_ROOT}"
}
trap cleanup EXIT

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
WORKSPACE_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")/.." && pwd -P)"
load_env_file "${WORKSPACE_DIR}/.env"

INDEPENDENT_MANIFEST="${BACKPORT_INDEPENDENT:-0}"
if [ "${INDEPENDENT_MANIFEST}" = 1 ]; then
	[ -n "${BACKPORT_MANIFEST_OVERRIDE:-}" ] || \
		die "独立回移缺少清单路径覆盖"
	[ -n "${BACKPORT_MANIFEST_SHA256_OVERRIDE:-}" ] || \
		die "独立回移缺少清单 SHA-256 覆盖"
	MANIFEST="$(resolve_workspace_path "${BACKPORT_MANIFEST_OVERRIDE}")"
	MANIFEST_SHA256="${BACKPORT_MANIFEST_SHA256_OVERRIDE}"
else
	MANIFEST="$(resolve_workspace_path "${SELECTED_BACKPORT_MANIFEST:-patches/backports/r21-selected-backports.tsv}")"
	MANIFEST_SHA256="${SELECTED_BACKPORT_MANIFEST_SHA256:-}"
fi
AOSP_DIR="$(resolve_workspace_path "${AOSP_BACKPORT_AUDIT_SOURCE_DIR:-sources/aosp_common_backport_audit}")"
STABLE_DIR="$(resolve_workspace_path "${LINUX_STABLE_AUDIT_SOURCE_DIR:-sources/linux_stable_6.12_audit}")"
MAINLINE_DIR="$(resolve_workspace_path "${LINUX_MAINLINE_AUDIT_SOURCE_DIR:-sources/linux_mainline_audit}")"
TMP_ROOT=""
declare -a MANIFEST_ROWS=()
GROUP_COUNT=0

manifest_group_sequence() {
	local group="$1"
	awk -F '\t' -v group="${group}" '
		!/^#/ && $2 == group {
			printf "%s%s:%s", separator, $3, $6
			separator = ","
		}
		END { print "" }
	' "${MANIFEST}"
}

validate_manifest() {
	local actual_sha256 expected_header
	[ -f "${MANIFEST}" ] && [ ! -L "${MANIFEST}" ] || die "r21 回移清单缺失或不安全"
	[ -n "${MANIFEST_SHA256}" ] || die "缺少 r21 回移清单 SHA-256"
	actual_sha256="$(sha256sum "${MANIFEST}" | awk '{ print $1 }')"
	[ "${actual_sha256}" = "${MANIFEST_SHA256}" ] || die "r21 回移清单 SHA-256 不匹配"
	! grep -q $'\r' "${MANIFEST}" || die "r21 回移清单含 CR 字符"
	expected_header=$'# order\tgroup\taction\tsource\tref\tcommit\tdate\tpatch-id\tpaths\tproject-patch\tproject-sha256\tproject-patch-id'
	[ "$(sed -n '1p' "${MANIFEST}")" = "${expected_header}" ] || die "r21 回移清单表头异常"

	awk -F '\t' \
		-v stable_ref="${LINUX_STABLE_AUDIT_REF:-}" \
		-v snapshot="${BACKPORT_AUDIT_SNAPSHOT:-}" \
		-v independent="${INDEPENDENT_MANIFEST}" '
		function fail(message) { print "[FAIL] r21 回移清单: " message > "/dev/stderr"; exit 1 }
		/^#/ { next }
		{
			rows++
			if (NF != 12) fail("第 " NR " 行字段数不是 12")
			if ($1 != sprintf("%03d", rows)) fail("顺序号不连续: " $1)
			if ($2 !~ /^[a-z0-9_]+$/) fail("逻辑组名非法: " $2)
			if ($3 !~ /^(direct|adapt|proof)$/) fail("动作非法: " $3)
			if ($4 !~ /^(aosp|stable|mainline)$/) fail("来源非法: " $4)
			if ($4 == "stable" && $5 != stable_ref) fail("stable ref 未固定")
			if ($4 == "mainline" && $5 != "snapshot-" snapshot) fail("mainline ref 未固定")
			if ($4 == "aosp" && $5 !~ /^[A-Za-z0-9._-]+$/) fail("AOSP ref 非法")
			if ($6 !~ /^[0-9a-f]{40}$/) fail("提交 ID 非 40 位小写十六进制")
			if ($7 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) fail("提交日期格式错误")
			if ($8 !~ /^[0-9a-f]{40}$/) fail("patch-id 非 40 位小写十六进制")
			count = split($9, path, ",")
			previous = ""
			for (i = 1; i <= count; i++) {
				if (path[i] == "" || path[i] ~ /[[:space:]]/ || path[i] ~ /^\// ||
				    path[i] ~ /(^|\/)\.\.?($|\/)/ || path[i] ~ /\/\//)
					fail("路径非法: " path[i])
				if (previous != "" && path[i] <= previous) fail("路径未严格排序或重复: " $9)
				previous = path[i]
			}
			if ($3 == "adapt") {
				adapt++
				if ($10 == "-" || $11 !~ /^[0-9a-f]{64}$/ || $12 !~ /^[0-9a-f]{40}$/)
					fail("adapt 行缺少固定项目补丁身份")
			} else {
				if ($10 != "-" || $11 != "-" || $12 != "-") fail("非 adapt 行携带项目补丁")
			}
			direct += ($3 == "direct")
			proof += ($3 == "proof")
			if (seen_commit[$6]++) fail("提交重复: " $6)
			groups[$2] = 1
		}
		END {
			for (group in groups) group_count++
			if (independent == 1) {
				if (rows < 1 || direct + adapt < 1 || group_count != 1)
					fail("独立清单必须只包含一个且至少实际应用一次的逻辑项")
			} else {
				if (rows < 1 || direct + adapt < 1 || group_count < 1)
					fail("固定集合没有可应用的逻辑项")
			}
		}
	' "${MANIFEST}" || exit $?

	if [ "${INDEPENDENT_MANIFEST}" != 1 ]; then
		[ "$(manifest_group_sequence blk_mq_cached_request)" = \
			"direct:44e41381591dc5b4ea67a9f170b4ec85c817586e,direct:23d8ea1e303b5f32d883757a4a707e791dbc9808,direct:8e23114b89e28549393351afde3c87e7b43a0c97" ] || \
			die "blk-mq 原子链顺序异常"
		[ "$(manifest_group_sequence ipset_publication)" = \
			"direct:7e06a41b36638d514638de468428c14ae79db475,direct:157c0a896127d16466d69729a3e140c29dfbf239,direct:7445fe965b7d8756070a40e80f8b73348ccda1d7" ] || \
			die "IPSet publication 原子链顺序异常"
		[ "$(manifest_group_sequence ethernet_mac_header)" = \
			"direct:9eda5478746ef7dc0e4e537b5a5e4b0ca1027091,direct:367abcacc13a8e2e7624408b7f593bd1e60e49d9" ] || \
			die "Ethernet MAC header 原子链顺序异常"
		[ "$(manifest_group_sequence f2fs_write_end_io_uaf)" = \
			"proof:2d9c4a4ed4eef1f82c5b16b037aee8bad819fd53,adapt:7be222de96c0f9eee6e65eeb017ef855ee185cfa" ] || \
			die "普通 F2FS write_end_io UAF 证明链异常"
	fi

	mapfile -t MANIFEST_ROWS < <(grep -v '^#' "${MANIFEST}")
	GROUP_COUNT="$(awk -F '\t' '!/^#/ { groups[$2] = 1 } END { for (group in groups) count++; print count + 0 }' "${MANIFEST}")"
}

aosp_tip() {
	local requested_ref="$1" pair found=""
	for pair in ${AOSP_BACKPORT_AUDIT_REFS:-}; do
		[ "${pair%%:*}" = "${requested_ref}" ] || continue
		[ -z "${found}" ] || die "AOSP ref 重复: ${requested_ref}"
		found="${pair#*:}"
	done
	[ -n "${found}" ] || die "AOSP ref 未固定: ${requested_ref}"
	printf '%s\n' "${found}"
}

source_repo_and_tip() {
	local source="$1" ref="$2"
	case "${source}" in
		aosp)
			SOURCE_REPO="${AOSP_DIR}"
			SOURCE_TIP="$(aosp_tip "${ref}")"
			;;
		stable)
			[ "${ref}" = "${LINUX_STABLE_AUDIT_REF:-}" ] || die "Linux stable ref 不匹配"
			SOURCE_REPO="${STABLE_DIR}"
			SOURCE_TIP="${LINUX_STABLE_AUDIT_COMMIT:-}"
			;;
		mainline)
			[ "${ref}" = "snapshot-${BACKPORT_AUDIT_SNAPSHOT:-}" ] || die "Linux mainline ref 不匹配"
			SOURCE_REPO="${MAINLINE_DIR}"
			SOURCE_TIP="${LINUX_MAINLINE_AUDIT_COMMIT:-}"
			;;
		*) die "未知官方来源: ${source}" ;;
	esac
	[ -n "${SOURCE_TIP}" ] || die "${source} 审计终点为空"
}

verify_source_row() {
	local row="$1" order group action source ref commit date patch_id paths
	local project_patch project_sha project_patch_id actual_date actual_paths actual_patch_id
	local parents patch_output
	IFS=$'\t' read -r order group action source ref commit date patch_id paths \
		project_patch project_sha project_patch_id <<<"${row}"
	source_repo_and_tip "${source}" "${ref}"
	[ -d "${SOURCE_REPO}" ] || die "${source} 审计仓库缺失，请先运行 ./init.sh"
	env GIT_NO_LAZY_FETCH=1 git -C "${SOURCE_REPO}" cat-file -e "${SOURCE_TIP}^{commit}" 2>/dev/null || \
		die "${source} 固定审计终点对象缺失，请先运行 ./init.sh"
	env GIT_NO_LAZY_FETCH=1 git -C "${SOURCE_REPO}" cat-file -e "${commit}^{commit}" 2>/dev/null || \
		die "${group} 官方提交对象缺失，请先运行 ./init.sh"
	env GIT_NO_LAZY_FETCH=1 git -C "${SOURCE_REPO}" merge-base --is-ancestor \
		"${commit}" "${SOURCE_TIP}" || die "${group} 不属于固定 ${source} 审计终点"
	parents="$(env GIT_NO_LAZY_FETCH=1 git -C "${SOURCE_REPO}" rev-list --parents -n 1 "${commit}")"
	[ "$(awk '{ print NF }' <<<"${parents}")" = 2 ] || die "${group} 官方对象不是单父提交"
	actual_date="$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${SOURCE_REPO}" \
		show -s --format=%cs "${commit}")"
	[ "${actual_date}" = "${date}" ] || die "${group} 官方提交日期不匹配: ${actual_date}"
	actual_paths="$(env GIT_NO_LAZY_FETCH=1 git -C "${SOURCE_REPO}" diff-tree \
		--no-commit-id --name-only -r "${commit}" | LC_ALL=C sort -u | paste -sd, -)"
	[ "${actual_paths}" = "${paths}" ] || die "${group} 官方提交路径不匹配: ${actual_paths}"
	patch_output="$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${SOURCE_REPO}" \
		show --format= "${commit}" | git patch-id --stable)"
	[ "$(wc -l <<<"${patch_output}")" = 1 ] || die "${group} 官方提交 patch-id 输出异常"
	actual_patch_id="${patch_output%% *}"
	[ "${actual_patch_id}" = "${patch_id}" ] || die "${group} 官方提交 patch-id 不匹配"

	if [ "${action}" = adapt ]; then
		verify_project_patch "${group}" "${paths}" "${project_patch}" \
			"${project_sha}" "${project_patch_id}"
	fi
}

verify_project_patch() {
	local group="$1" paths="$2" relative_patch="$3" expected_sha="$4" expected_patch_id="$5"
	local patch_file actual_sha actual_patch_id actual_paths patch_output path
	patch_file="$(resolve_workspace_path "${relative_patch}")"
	[ -f "${patch_file}" ] && [ ! -L "${patch_file}" ] || die "${group} 项目适配补丁缺失或不安全"
	actual_sha="$(sha256sum "${patch_file}" | awk '{ print $1 }')"
	[ "${actual_sha}" = "${expected_sha}" ] || die "${group} 项目适配补丁 SHA-256 不匹配"
	patch_output="$(git patch-id --stable < "${patch_file}")"
	[ "$(wc -l <<<"${patch_output}")" = 1 ] || die "${group} 项目适配补丁 patch-id 输出异常"
	actual_patch_id="${patch_output%% *}"
	[ "${actual_patch_id}" = "${expected_patch_id}" ] || die "${group} 项目适配补丁 patch-id 不匹配"
	actual_paths="$(sed -n 's#^+++ b/##p' "${patch_file}" | LC_ALL=C sort -u | paste -sd, -)"
	[ -n "${actual_paths}" ] || die "${group} 项目适配补丁没有目标路径"
	if [ "${INDEPENDENT_MANIFEST}" = 1 ]; then
		IFS=, read -ra project_paths <<<"${actual_paths}"
		for path in "${project_paths[@]}"; do
			case ",${paths}," in
				*,"${path}",*) ;;
				*) die "${group} 项目适配补丁含官方提交之外的路径: ${path}" ;;
			esac
		done
	else
		[ "${actual_paths}" = "${paths}" ] || \
			die "${group} 项目适配补丁路径不匹配: ${actual_paths}"
	fi
}

verify_sources() {
	local row stable_message
	verify_audit_repo "AOSP common 审计源" "${AOSP_DIR}" "${COMMON_REPO}"
	verify_audit_repo "Linux stable 审计源" "${STABLE_DIR}" "${LINUX_STABLE_AUDIT_REPO}"
	verify_audit_repo "Linux mainline 审计源" "${MAINLINE_DIR}" "${LINUX_MAINLINE_AUDIT_REPO}"
	for row in "${MANIFEST_ROWS[@]}"; do
		verify_source_row "${row}"
	done
	if [ "${INDEPENDENT_MANIFEST}" != 1 ]; then
		stable_message="$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${STABLE_DIR}" \
			show -s --format=%B 7be222de96c0f9eee6e65eeb017ef855ee185cfa)"
		grep -Fx '[ Upstream commit 2d9c4a4ed4eef1f82c5b16b037aee8bad819fd53 ]' \
			<<<"${stable_message}" >/dev/null || die "普通 F2FS stable 修复未绑定固定 mainline 提交"
	fi
}

prepare_patch_cache() {
	local row order group action source ref commit rest patch_file
	[ -n "${TMP_ROOT}" ] || TMP_ROOT="$(mktemp -d)"
	mkdir -p "${TMP_ROOT}/patches"
	for row in "${MANIFEST_ROWS[@]}"; do
		IFS=$'\t' read -r order group action source ref commit rest <<<"${row}"
		[ "${action}" = direct ] || continue
		source_repo_and_tip "${source}" "${ref}"
		patch_file="${TMP_ROOT}/patches/${order}.patch"
		env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${SOURCE_REPO}" \
			show --format= "${commit}" > "${patch_file}"
	done
}

row_patch_file() {
	local row="$1" order group action source ref commit date patch_id paths
	local project_patch project_sha project_patch_id
	IFS=$'\t' read -r order group action source ref commit date patch_id paths \
		project_patch project_sha project_patch_id <<<"${row}"
	case "${action}" in
		direct) ROW_PATCH_FILE="${TMP_ROOT}/patches/${order}.patch" ;;
		adapt) ROW_PATCH_FILE="$(resolve_workspace_path "${project_patch}")" ;;
		proof) ROW_PATCH_FILE="" ;;
	esac
}

write_path_list() {
	awk -F '\t' '
		!/^#/ && $3 != "proof" {
			count = split($9, path, ",")
			for (i = 1; i <= count; i++) print path[i]
		}
	' "${MANIFEST}" | LC_ALL=C sort -u > "${TMP_ROOT}/paths"
}

copy_selected_tree() {
	local source_tree="$1" target_tree="$2" path
	mkdir -p "${target_tree}"
	while IFS= read -r path; do
		[ -f "${source_tree}/${path}" ] && [ ! -L "${source_tree}/${path}" ] || \
			die "回移目标路径缺失或不安全: ${path}"
		mkdir -p "${target_tree}/$(dirname "${path}")"
		cp -p -- "${source_tree}/${path}" "${target_tree}/${path}"
	done < "${TMP_ROOT}/paths"
}

selected_tree_digest() {
	local tree="$1" path
	(
		cd "${tree}"
		while IFS= read -r path; do
			sha256sum -- "${path}"
		done < "${TMP_ROOT}/paths"
	) | sha256sum | awk '{ print $1 }'
}

apply_sequence() {
	local tree="$1" direction="$2" row index
	if [ "${direction}" = forward ]; then
		for row in "${MANIFEST_ROWS[@]}"; do
			row_patch_file "${row}"
			[ -n "${ROW_PATCH_FILE}" ] || continue
			git -C "${tree}" apply "${ROW_PATCH_FILE}"
		done
	else
		for ((index=${#MANIFEST_ROWS[@]} - 1; index >= 0; index--)); do
			row="${MANIFEST_ROWS[index]}"
			row_patch_file "${row}"
			[ -n "${ROW_PATCH_FILE}" ] || continue
			git -C "${tree}" apply --reverse "${ROW_PATCH_FILE}"
		done
	fi
}

sequence_applies() {
	local source_tree="$1" direction="$2" scratch
	scratch="$(mktemp -d "${TMP_ROOT}/check.XXXXXX")"
	copy_selected_tree "${source_tree}" "${scratch}"
	if apply_sequence "${scratch}" "${direction}" >/dev/null 2>&1; then
		rm -rf -- "${scratch}"
		return 0
	fi
	rm -rf -- "${scratch}"
	return 1
}

verify_f2fs_adaptation_semantics() {
	local target_tree="$1" body warm_line dec_line
	body="$(sed -n '/^static void f2fs_write_end_io(/,/^}/p' "${target_tree}/fs/f2fs/data.c")"
	[ "$(grep -Fc 'f2fs_in_warm_node_list(sbi, folio)' <<<"${body}")" = 1 ] || \
		die "普通 F2FS write_end_io warm-node 检查数量异常"
	[ "$(grep -Fc 'dec_page_count(sbi, type);' <<<"${body}")" = 1 ] || \
		die "普通 F2FS write_end_io page-count 递减数量异常"
	warm_line="$(grep -nF 'f2fs_in_warm_node_list(sbi, folio)' <<<"${body}" | cut -d: -f1)"
	dec_line="$(grep -nF 'dec_page_count(sbi, type);' <<<"${body}" | cut -d: -f1)"
	[ "${warm_line}" -lt "${dec_line}" ] || die "普通 F2FS write_end_io 仍在生命周期闸门后访问 sbi"
}

verify_applied_set() {
	local target_tree="$1" scratch before_digest after_digest
	scratch="$(mktemp -d "${TMP_ROOT}/verify.XXXXXX")"
	copy_selected_tree "${target_tree}" "${scratch}"
	before_digest="$(selected_tree_digest "${scratch}")"
	apply_sequence "${scratch}" reverse || die "r21 回移集合未完整应用或顺序异常"
	apply_sequence "${scratch}" forward || die "r21 回移集合无法从撤销状态精确重放"
	after_digest="$(selected_tree_digest "${scratch}")"
	[ "${after_digest}" = "${before_digest}" ] || die "r21 回移集合撤销/重放后内容漂移"
	rm -rf -- "${scratch}"
	if [ "${INDEPENDENT_MANIFEST}" != 1 ]; then
		verify_f2fs_adaptation_semantics "${target_tree}"
	fi
}

apply_set() {
	local target_tree="$1" forward_ok=0 reverse_ok=0 row order group action source ref commit
	local before_digest after_digest
	[ -d "${target_tree}" ] || die "r21 回移目标树不存在: ${target_tree}"
	write_path_list
	before_digest="$(selected_tree_digest "${target_tree}")"
	sequence_applies "${target_tree}" forward && forward_ok=1
	sequence_applies "${target_tree}" reverse && reverse_ok=1
	if [ "${forward_ok}" = 1 ] && [ "${reverse_ok}" = 0 ]; then
		log_info "按固定顺序应用 ${GROUP_COUNT} 个 r21 逻辑回移项"
		for row in "${MANIFEST_ROWS[@]}"; do
			IFS=$'\t' read -r order group action source ref commit _ <<<"${row}"
			row_patch_file "${row}"
			[ -n "${ROW_PATCH_FILE}" ] || continue
			log_info "${order} ${group} (${source} ${commit:0:12})"
			git -C "${target_tree}" apply "${ROW_PATCH_FILE}"
		done
	elif [ "${forward_ok}" = 0 ] && [ "${reverse_ok}" = 1 ]; then
		log_info "${GROUP_COUNT} 个 r21 逻辑回移项已完整存在"
	else
		die "r21 回移集合既非完整未应用态，也非完整已应用态，拒绝部分状态"
	fi
	after_digest="$(selected_tree_digest "${target_tree}")"
	if [ "${forward_ok}" = 0 ]; then
		[ "${after_digest}" = "${before_digest}" ] || die "幂等检查意外修改了回移目标树"
	fi
	verify_applied_set "${target_tree}"
}

apply_sequence_to_index() {
	local target_tree="$1" index_file="$2" direction="$3" row index
	[ -f "${index_file}" ] && [ ! -L "${index_file}" ] || \
		die "临时 Git index 缺失或不安全"
	if [ "${direction}" = forward ]; then
		for row in "${MANIFEST_ROWS[@]}"; do
			row_patch_file "${row}"
			[ -n "${ROW_PATCH_FILE}" ] || continue
			env GIT_INDEX_FILE="${index_file}" git -C "${target_tree}" \
				apply --cached "${ROW_PATCH_FILE}"
		done
	else
		for ((index=${#MANIFEST_ROWS[@]} - 1; index >= 0; index--)); do
			row="${MANIFEST_ROWS[index]}"
			row_patch_file "${row}"
			[ -n "${ROW_PATCH_FILE}" ] || continue
			env GIT_INDEX_FILE="${index_file}" git -C "${target_tree}" \
				apply --cached --reverse "${ROW_PATCH_FILE}"
		done
	fi
}

usage() {
	printf '用法: %s {verify-manifest|list SOURCE|list-paths|verify-sources|apply TREE|verify-applied TREE|apply-index TREE INDEX|reverse-index TREE INDEX}\n' "$0" >&2
	exit 2
}

validate_manifest
case "${1:-}" in
	verify-manifest)
		[ "$#" = 1 ] || usage
		log_success "r21 回移清单身份、顺序与逻辑组检查通过"
		;;
	list)
		[ "$#" = 2 ] || usage
		case "$2" in aosp|stable|mainline) ;; *) usage ;; esac
		awk -F '\t' -v source="$2" '!/^#/ && $4 == source { print $6 }' "${MANIFEST}"
		;;
	list-paths)
		[ "$#" = 1 ] || usage
		awk -F '\t' '
			!/^#/ && $3 != "proof" {
				count = split($9, path, ",")
				for (i = 1; i <= count; i++) print path[i]
			}
		' "${MANIFEST}" | LC_ALL=C sort -u
		;;
	verify-sources)
		[ "$#" = 1 ] || usage
		verify_sources
		log_success "r21 回移清单全部官方来源检查通过"
		;;
	apply)
		[ "$#" = 2 ] || usage
		verify_sources
		prepare_patch_cache
		apply_set "$2"
		log_success "${GROUP_COUNT} 个 r21 逻辑回移项状态正确"
		;;
	verify-applied)
		[ "$#" = 2 ] || usage
		verify_sources
		prepare_patch_cache
		write_path_list
		verify_applied_set "$2"
		log_success "${GROUP_COUNT} 个 r21 逻辑回移项来源、顺序和最终应用状态检查通过"
		;;
	apply-index|reverse-index)
		[ "$#" = 3 ] || usage
		[ "${INDEPENDENT_MANIFEST}" = 1 ] || die "临时 index 操作只允许独立回移清单"
		verify_sources
		prepare_patch_cache
		if [ "$1" = apply-index ]; then
			apply_sequence_to_index "$2" "$3" forward
		else
			apply_sequence_to_index "$2" "$3" reverse
		fi
		;;
	*) usage ;;
esac
