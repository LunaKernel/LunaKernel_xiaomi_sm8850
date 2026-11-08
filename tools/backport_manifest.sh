#!/usr/bin/env bash
#
# Apply and verify one fixed official-backport manifest as an ordered set.
#
# patch/build 仅导入包校验函数，不加载清单状态或重新读取配置。
VERIFIED_BACKPORT_BUNDLE_WORKSPACE=""
VERIFIED_BACKPORT_BUNDLE_DIR=""
backport_bundle_enabled() {
	[ -n "${BACKPORT_BUNDLE_MANIFEST_SHA256:-}" ] && [ "${BACKPORT_SOURCE_AUDIT:-0}" != 1 ]
}

verify_backport_bundle() {
	local workspace="$1" expected_dir
	[ "${VERIFIED_BACKPORT_BUNDLE_WORKSPACE:-}" != "${workspace}" ] || return 0
	expected_dir="${workspace}/work/cache/dependencies/backports-${BACKPORT_BUNDLE_MANIFEST_SHA256}"
	VERIFIED_BACKPORT_BUNDLE_DIR="$(python3 "${workspace}/tools/ci_dependencies.py" \
		backports-check --workspace "${workspace}")" || die "固定回移补丁包校验失败，请先运行 ./init.sh"
	[ "${VERIFIED_BACKPORT_BUNDLE_DIR}" = "${expected_dir}" ] || die "回移补丁包目录异常"
	VERIFIED_BACKPORT_BUNDLE_WORKSPACE="${workspace}"
}

copy_backport_bundle_patch() {
	local workspace="$1" commit="$2" target="$3" source_sha patch_file
	verify_backport_bundle "${workspace}"
	[[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || die "回移补丁提交 ID 非法"
	patch_file="${VERIFIED_BACKPORT_BUNDLE_DIR}/patches/${commit}.patch"
	[ -f "${patch_file}" ] && [ ! -L "${patch_file}" ] || die "固定回移补丁缺失或不安全: ${commit}"
	source_sha="$(sha256sum "${patch_file}" | awk '{ print $1 }')"
	cp -- "${patch_file}" "${target}"
	[ "$(sha256sum "${target}" | awk '{ print $1 }')" = "${source_sha}" ] && \
		[ "$(sha256sum "${patch_file}" | awk '{ print $1 }')" = "${source_sha}" ] || \
		die "固定回移补丁复制期间发生变化: ${commit}"
}

verify_backport_bundle_patch() {
	local workspace="$1" commit="$2" expected_patch_id="$3" expected_paths="${4:-}"
	local patch_file actual_paths
	verify_backport_bundle "${workspace}"
	[[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || die "回移补丁提交 ID 非法"
	patch_file="${VERIFIED_BACKPORT_BUNDLE_DIR}/patches/${commit}.patch"
	[ -f "${patch_file}" ] && [ ! -L "${patch_file}" ] || die "固定回移补丁缺失或不安全: ${commit}"
	[ "$(git patch-id --stable < "${patch_file}" | awk '{ print $1 }')" = "${expected_patch_id}" ] || \
		die "固定回移补丁 patch-id 不匹配: ${commit}"
	if [ -n "${expected_paths}" ]; then
		actual_paths="$(git apply --numstat "${patch_file}" | cut -f3 | LC_ALL=C sort | paste -sd ' ' -)"
		[ "${actual_paths}" = "${expected_paths}" ] || die "固定回移补丁路径不匹配: ${commit}"
	fi
}

if [ "${BASH_SOURCE[0]}" != "$0" ] && [ "${BACKPORT_BUNDLE_LIBRARY:-0}" = 1 ]; then
	return 0
fi

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
	# 同次调用的审计仓库不被修改；清单共用的仓库只验证一次。
	[ "${VERIFIED_AUDIT_REPOS["${repo}|${expected_url}"]:-}" != 1 ] || return 0
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
	VERIFIED_AUDIT_REPOS["${repo}|${expected_url}"]=1
}

cleanup() {
	[ -z "${TMP_ROOT:-}" ] || rm -rf -- "${TMP_ROOT}"
}

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
	MANIFEST="$(resolve_workspace_path "${SELECTED_BACKPORT_MANIFEST:-patches/backports/kmi6-2026-09-selected-backports.tsv}")"
	MANIFEST_SHA256="${SELECTED_BACKPORT_MANIFEST_SHA256:-}"
fi
AOSP_DIR="$(resolve_workspace_path "${AOSP_BACKPORT_AUDIT_SOURCE_DIR:-sources/aosp_common_backport_audit}")"
STABLE_DIR="$(resolve_workspace_path "${LINUX_STABLE_AUDIT_SOURCE_DIR:-sources/linux_stable_6.12_audit}")"
MAINLINE_DIR="$(resolve_workspace_path "${LINUX_MAINLINE_AUDIT_SOURCE_DIR:-sources/linux_mainline_audit}")"
KBUILD_DIR="$(resolve_workspace_path "${KBUILD_AUDIT_SOURCE_DIR:-sources/linux_kbuild_audit}")"
TMP_ROOT=""
declare -a MANIFEST_ROWS=()
declare -A VERIFIED_AUDIT_REPOS=()
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
	[ "${LINUX_STABLE_STANDALONE_COMMITS:-}" = \
		"03cb8cc2961f5f781d12e903782cb3815ed84b1c" ] || \
		die "Linux stable-only 来源例外集合异常"
	[ -f "${MANIFEST}" ] && [ ! -L "${MANIFEST}" ] || die "九月回移清单缺失或不安全"
	[ -n "${MANIFEST_SHA256}" ] || die "缺少九月回移清单 SHA-256"
	actual_sha256="$(sha256sum "${MANIFEST}" | awk '{ print $1 }')"
	[ "${actual_sha256}" = "${MANIFEST_SHA256}" ] || die "九月回移清单 SHA-256 不匹配"
	! grep -q $'\r' "${MANIFEST}" || die "九月回移清单含 CR 字符"
	expected_header=$'# order\tgroup\taction\tsource\tref\tcommit\tdate\tpatch-id\tpaths\tproject-patch\tproject-sha256\tproject-patch-id'
	[ "$(sed -n '1p' "${MANIFEST}")" = "${expected_header}" ] || die "九月回移清单表头异常"

	awk -F '\t' \
		-v stable_ref="${LINUX_STABLE_AUDIT_REF:-}" \
		-v snapshot="${BACKPORT_AUDIT_SNAPSHOT:-}" \
		-v kbuild_ref="${KBUILD_AUDIT_REF:-}" \
		-v independent="${INDEPENDENT_MANIFEST}" '
		function fail(message) { print "[FAIL] 九月回移清单: " message > "/dev/stderr"; exit 1 }
		/^#/ { next }
		{
			rows++
			if (NF != 12) fail("第 " NR " 行字段数不是 12")
			if ($1 != sprintf("%03d", rows)) fail("顺序号不连续: " $1)
			if ($2 !~ /^[a-z0-9_]+$/) fail("逻辑组名非法: " $2)
			if ($3 !~ /^(direct|adapt|proof)$/) fail("动作非法: " $3)
			if ($4 !~ /^(aosp|stable|mainline|kbuild)$/) fail("来源非法: " $4)
			if ($4 == "kbuild" && (independent != 1 || kbuild_ref == "" || $5 != kbuild_ref)) fail("Kbuild 来源必须独立且 ref 固定")
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
			"direct:367abcacc13a8e2e7624408b7f593bd1e60e49d9" ] || \
			die "Ethernet MAC header 原子链顺序异常"
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
		kbuild)
			[ "${ref}" = "${KBUILD_AUDIT_REF:-}" ] || die "Kbuild ref 不匹配"
			SOURCE_REPO="${KBUILD_DIR}"
			SOURCE_TIP="${KBUILD_AUDIT_COMMIT:-}"
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
	if [ "${source}" = stable ]; then
		verify_stable_origin "${group}" "${commit}" "${actual_paths}"
	fi

	if [ "${action}" = adapt ]; then
		verify_project_patch "${group}" "${paths}" "${project_patch}" \
			"${project_sha}" "${project_patch_id}" "${source}" "${commit}"
	fi
}

verify_stable_origin() {
	local group="$1" commit="$2" stable_paths="$3"
	local message upstream upstream_paths stable_subject upstream_subject count
	case " ${LINUX_STABLE_STANDALONE_COMMITS:-} " in
		*" ${commit} "*) return ;;
	esac
	message="$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${STABLE_DIR}" \
		show -s --format=%B "${commit}")"
	upstream="$(printf '%s\n' "${message}" | sed -n -E \
		-e 's/^\[ Upstream commit ([0-9a-f]{40}) \]$/\1/p' \
		-e 's/^commit ([0-9a-f]{40}) upstream\.$/\1/p' | LC_ALL=C sort -u)"
	count="$(grep -c . <<<"${upstream}" || true)"
	[ "${count}" = 1 ] || die "${group} stable 提交未唯一绑定 mainline 原始提交"
	env GIT_NO_LAZY_FETCH=1 git -C "${MAINLINE_DIR}" cat-file \
		-e "${upstream}^{commit}" 2>/dev/null || \
		die "${group} mainline 原始提交对象缺失，请先运行 ./init.sh"
	env GIT_NO_LAZY_FETCH=1 git -C "${MAINLINE_DIR}" merge-base --is-ancestor \
		"${upstream}" "${LINUX_MAINLINE_AUDIT_COMMIT}" || \
		die "${group} mainline 原始提交不属于固定审计快照"
	upstream_paths="$(env GIT_NO_LAZY_FETCH=1 git -C "${MAINLINE_DIR}" diff-tree \
		--no-commit-id --name-only -r "${upstream}" | LC_ALL=C sort -u | paste -sd, -)"
	[ "${upstream_paths}" = "${stable_paths}" ] || \
		die "${group} stable 与 mainline 原始提交路径不一致"
	stable_subject="$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${STABLE_DIR}" \
		show -s --format=%s "${commit}")"
	upstream_subject="$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${MAINLINE_DIR}" \
		show -s --format=%s "${upstream}")"
	[ "${stable_subject}" = "${upstream_subject}" ] || \
		die "${group} stable 与 mainline 原始提交标题不一致"
}

verify_project_patch() {
	local group="$1" paths="$2" relative_patch="$3" expected_sha="$4" expected_patch_id="$5"
	local source="$6" commit="$7"
	local patch_file actual_sha actual_patch_id actual_paths patch_output path source_path
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
			source_path="${path}"
			if [ "${source}" = kbuild ] && [ "${commit}" = 454e00cf8ee5aff555ad5865b8c3dbf3731afcc9 ]; then
				case "${path}" in
					init/Kconfig) source_path=scripts/Kconfig.toolchain ;;
					scripts/Makefile.extrawarn) source_path=scripts/Makefile.warn ;;
				esac
			fi
			case ",${paths}," in
				*,"${source_path}",*) ;;
				*) die "${group} 项目适配补丁含官方提交之外的路径: ${path}" ;;
			esac
		done
	else
		[ "${actual_paths}" = "${paths}" ] || \
			die "${group} 项目适配补丁路径不匹配: ${actual_paths}"
	fi
}

verify_sources() {
	local row stable_message order group action source ref commit date patch_id paths
	local project_patch project_sha project_patch_id
	if backport_bundle_enabled; then
		verify_backport_bundle "${WORKSPACE_DIR}"
		for row in "${MANIFEST_ROWS[@]}"; do
			IFS=$'\t' read -r order group action source ref commit date patch_id paths \
				project_patch project_sha project_patch_id <<<"${row}"
			if [ "${action}" = adapt ]; then
				verify_project_patch "${group}" "${paths}" "${project_patch}" \
					"${project_sha}" "${project_patch_id}" "${source}" "${commit}"
			fi
		done
		return 0
	fi
	verify_audit_repo "AOSP common 审计源" "${AOSP_DIR}" "${COMMON_REPO}"
	verify_audit_repo "Linux stable 审计源" "${STABLE_DIR}" "${LINUX_STABLE_AUDIT_REPO}"
	verify_audit_repo "Linux mainline 审计源" "${MAINLINE_DIR}" "${LINUX_MAINLINE_AUDIT_REPO}"
	if awk -F '\t' '!/^#/ && $4 == "kbuild" { found=1 } END { exit !found }' "${MANIFEST}"; then
		verify_audit_repo "Kbuild 官方审计源" "${KBUILD_DIR}" "${KBUILD_AUDIT_REPO}"
	fi
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
	local row order group action source ref commit date patch_id paths
	local project_patch project_sha project_patch_id patch_file
	[ -n "${TMP_ROOT}" ] || TMP_ROOT="$(mktemp -d)"
	mkdir -p "${TMP_ROOT}/patches"
	for row in "${MANIFEST_ROWS[@]}"; do
		IFS=$'\t' read -r order group action source ref commit date patch_id paths \
			project_patch project_sha project_patch_id <<<"${row}"
		patch_file="${TMP_ROOT}/patches/${order}.patch"
		case "${action}" in
			direct)
				if backport_bundle_enabled; then
					copy_backport_bundle_patch "${WORKSPACE_DIR}" "${commit}" "${patch_file}"
				else
					source_repo_and_tip "${source}" "${ref}"
					env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${SOURCE_REPO}" \
						show --format= "${commit}" > "${patch_file}"
				fi
				[ "$(git patch-id --stable < "${patch_file}" | awk '{ print $1 }')" = "${patch_id}" ] || \
					die "${group} 官方补丁准备期间 patch-id 不匹配"
				;;
			adapt)
				# 后续各轮使用同一份已固定内容，不重复读取可变的项目文件。
				cp -- "$(resolve_workspace_path "${project_patch}")" "${patch_file}"
				[ "$(sha256sum "${patch_file}" | awk '{ print $1 }')" = "${project_sha}" ] || \
					die "${group} 项目适配补丁准备期间发生变化"
				;;
		esac
	done
}

row_patch_file() {
	local row="$1" order group action source ref commit date patch_id paths
	local project_patch project_sha project_patch_id
	IFS=$'\t' read -r order group action source ref commit date patch_id paths \
		project_patch project_sha project_patch_id <<<"${row}"
	case "${action}" in
		direct|adapt) ROW_PATCH_FILE="${TMP_ROOT}/patches/${order}.patch" ;;
		proof) ROW_PATCH_FILE="" ;;
	esac
}

write_path_list() {
	local row order group action source ref commit date patch_id paths project_patch project_sha project_patch_id
	{
		for row in "${MANIFEST_ROWS[@]}"; do
			IFS=$'\t' read -r order group action source ref commit date patch_id paths \
				project_patch project_sha project_patch_id <<<"${row}"
			[ "${action}" != proof ] || continue
			if [ "${source}" = kbuild ] && [ "${action}" = adapt ]; then
				verify_project_patch "${group}" "${paths}" "${project_patch}" \
					"${project_sha}" "${project_patch_id}" "${source}" "${commit}"
				sed -n 's#^+++ b/##p' "$(resolve_workspace_path "${project_patch}")"
			else
				printf '%s\n' "${paths}" | tr , '\n'
			fi
		done
	} | LC_ALL=C sort -u > "${TMP_ROOT}/paths"
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

verify_native_f2fs_write_end_semantics() {
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
	apply_sequence "${scratch}" reverse || die "九月回移集合未完整应用或顺序异常"
	apply_sequence "${scratch}" forward || die "九月回移集合无法从撤销状态精确重放"
	after_digest="$(selected_tree_digest "${scratch}")"
	[ "${after_digest}" = "${before_digest}" ] || die "九月回移集合撤销/重放后内容漂移"
	rm -rf -- "${scratch}"
	if [ "${INDEPENDENT_MANIFEST}" != 1 ]; then
		verify_native_f2fs_write_end_semantics "${target_tree}"
	fi
}

apply_set() {
	local target_tree="$1" forward_ok=0 reverse_ok=0 row order group action source ref commit
	local before_digest after_digest
	[ -d "${target_tree}" ] || die "九月回移目标树不存在: ${target_tree}"
	write_path_list
	before_digest="$(selected_tree_digest "${target_tree}")"
	sequence_applies "${target_tree}" forward && forward_ok=1
	sequence_applies "${target_tree}" reverse && reverse_ok=1
	if [ "${forward_ok}" = 1 ] && [ "${reverse_ok}" = 0 ]; then
		log_info "按固定顺序应用 ${GROUP_COUNT} 个九月逻辑回移项"
		for row in "${MANIFEST_ROWS[@]}"; do
			IFS=$'\t' read -r order group action source ref commit _ <<<"${row}"
			row_patch_file "${row}"
			[ -n "${ROW_PATCH_FILE}" ] || continue
			log_info "${order} ${group} (${source} ${commit:0:12})"
			git -C "${target_tree}" apply "${ROW_PATCH_FILE}"
		done
	elif [ "${forward_ok}" = 0 ] && [ "${reverse_ok}" = 1 ]; then
		log_info "${GROUP_COUNT} 个九月逻辑回移项已完整存在"
	else
		die "九月回移集合既非完整未应用态，也非完整已应用态，拒绝部分状态"
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

# 导入方仍须先验证清单和来源；复用的只是本进程函数，不接受外部跳过标记。
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
	return 0
fi
trap cleanup EXIT

validate_manifest
case "${1:-}" in
	verify-manifest)
		[ "$#" = 1 ] || usage
		log_success "九月回移清单身份、顺序与逻辑组检查通过"
		;;
	list)
		[ "$#" = 2 ] || usage
		case "$2" in aosp|stable|mainline|kbuild) ;; *) usage ;; esac
		awk -F '\t' -v source="$2" '!/^#/ && $4 == source { print $6 }' "${MANIFEST}"
		;;
	list-paths)
		[ "$#" = 1 ] || usage
		TMP_ROOT="$(mktemp -d)"
		write_path_list
		cat "${TMP_ROOT}/paths"
		;;
	verify-sources)
		[ "$#" = 1 ] || usage
		verify_sources
		log_success "九月回移清单全部官方来源检查通过"
		;;
	apply)
		[ "$#" = 2 ] || usage
		verify_sources
		prepare_patch_cache
		apply_set "$2"
		log_success "${GROUP_COUNT} 个九月逻辑回移项状态正确"
		;;
	verify-applied)
		[ "$#" = 2 ] || usage
		verify_sources
		prepare_patch_cache
		write_path_list
		verify_applied_set "$2"
		log_success "${GROUP_COUNT} 个九月逻辑回移项来源、顺序和最终应用状态检查通过"
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
