#!/usr/bin/env bash
#
# init.sh - prepare pinned sources and the Linux build environment
#
set -euo pipefail

die() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }
log_info() { printf '[INFO] %s\n' "$1"; }
log_step() { printf '[STEP] %s\n' "$1"; }
log_success() { printf '[OK] %s\n' "$1"; }

load_env_file() {
    local env_file="$1"
    local had_allexport=0
    [ -f "${env_file}" ] || return
    case "$-" in *a*) had_allexport=1 ;; esac
    set -a
    . "${env_file}"
    [ "${had_allexport}" = "1" ] || set +a
}

sanitize_path_component() { printf '%s' "$1" | LC_ALL=C tr -cs 'A-Za-z0-9._-' '_'; }
resolve_workspace_path() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "${HOST_WORKSPACE_DIR}" "$1" ;; esac; }
normalize_git_url() { printf '%s' "$1" | sed -e 's#/$##' -e 's#\.git$##'; }

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
    for var in NO_COLOR USE_CCACHE CCACHE_MAXSIZE CCACHE_COMPRESS CCACHE_COMPILERCHECK CCACHE_NOHASHDIR http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy; do
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
    [ ! -d "${HOST_WORKSPACE_DIR}/userspace" ] || items="${items} userspace"
    orbctl_run_host_path -w "${HOST_WORKSPACE_DIR}" sh -lc "set -e; target=\"\$HOME/${ORB_LINUX_WORKSPACE}\"; mkdir -p \"\$target\"; rm -rf \"\$target/init.sh\" \"\$target/patch.sh\" \"\$target/patch_external.sh\" \"\$target/build.sh\" \"\$target/.env\" \"\$target/ak3_template\" \"\$target/patches\"; tar -cf - --exclude='.DS_Store' --exclude='.idea' --exclude='kernel_out' ${items} | tar --warning=no-unknown-keyword -xf - -C \"\$target\""
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
        git clone --depth 1 --single-branch --branch "${branch}" "${repo_url}" "${target_dir}"
    fi
    actual_url="$(git -C "${target_dir}" remote get-url origin 2>/dev/null || true)"
    [ "$(normalize_git_url "${actual_url}")" = "$(normalize_git_url "${repo_url}")" ] || die "${label} remote 不匹配: ${actual_url}"
    if ! git -C "${target_dir}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
        log_step "获取 ${label} 固定 commit: ${commit}"
        git -C "${target_dir}" fetch --depth 1 origin "${commit}"
    fi
    head="$(git -C "${target_dir}" rev-parse HEAD)"
    if [ "${head}" != "${commit}" ]; then
        [ -z "$(git -C "${target_dir}" status --porcelain)" ] || die "${label} 有未提交修改，不能切换固定提交"
        git -C "${target_dir}" checkout --detach "${commit}"
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
        git -C "${repo_dir}" fetch --filter=blob:none --no-tags \
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
    git -C "${repo_dir}" fetch --refetch --no-tags --filter=blob:limit=1g \
        --shallow-since="${shallow_since}" origin "$@"
    git -C "${repo_dir}" config backport.auditHydratedIdentity "${identity}"
    git -C "${repo_dir}" config --unset-all backport.auditHydratedSnapshot 2>/dev/null || true
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
    git -C "${repo_dir}" fetch --refetch --no-tags --filter=blob:none \
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
    local version tracked_files xiaomi_ack_commit xiaomi_ack_tag
    version="$(sed -n 's/^VERSION = //p' "${COMMON_DIR}/Makefile").$(sed -n 's/^PATCHLEVEL = //p' "${COMMON_DIR}/Makefile").$(sed -n 's/^SUBLEVEL = //p' "${COMMON_DIR}/Makefile")"
    [ "${version}" = "6.12.23" ] || die "GKI common 版本不是 6.12.23: ${version}"
    tracked_files="$(git -C "${COMMON_DIR}" ls-files | wc -l | tr -d ' ')"
    [ "${tracked_files}" -ge 80000 ] || die "GKI common 文件不完整: ${tracked_files}"
    [ -s "${COMMON_DIR}/gki/aarch64/symbols/qcom" ] || die "缺少 QCOM KMI symbol list"
    [ -s "${COMMON_DIR}/gki/aarch64/symbols/xiaomi" ] || die "缺少 Xiaomi KMI symbol list"
    [ -f "${SOC_DIR}/configs/popsicle_perf.bzl" ] || die "小米 soc-repo 缺少 popsicle 配置"
    [ -f "${SOC_DIR}/Kconfig.msm" ] || die "小米 soc-repo 缺少 Kconfig.msm"
    xiaomi_ack_commit="$(sed -n '1p' "${SOC_DIR}/android/ACK_SHA")"
    xiaomi_ack_tag="$(sed -n '2p' "${SOC_DIR}/android/ACK_SHA")"
    [ "${xiaomi_ack_commit}" = "${XIAOMI_ACK_COMMIT}" ] || die "小米 ACK_SHA commit 已变化: ${xiaomi_ack_commit}"
    [ "${xiaomi_ack_tag}" = "${XIAOMI_ACK_BRANCH}" ] || die "小米 ACK_SHA tag 已变化: ${xiaomi_ack_tag}"
}

setup_toolchain() {
    local files=(
        aosp-clang-r536225.tar.gz
        aosp-rust-1.82.0.tar.gz
        aosp-kernel-build-tools-linux-x86.tar.gz
        bindgen.tar.xz
        busybox-1.35.0-x86_64-linux-musl
    )
    local file expected actual marker marker_value staging backup rust_bin compiler
    mkdir -p "${DL_DIR}" "$(dirname "${CI_TOOLCHAIN_DIR}")"
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
            log_success "固定工具链安装树完整性校验通过"
            return
        fi
        marker_value="$(sed -n '1p' "${marker}" 2>/dev/null || true)"
        [ "${marker_value}" != "${CI_TOOLCHAIN_TREE_SHA256}" ] || \
            die "固定工具链安装树在初始化后被修改: ${actual}"
        log_step "工具链 pin 已变化或缺少旧树指纹，使用已校验归档重建"
    fi

    staging="$(mktemp -d "$(dirname "${CI_TOOLCHAIN_DIR}")/.ci-toolchain-install.XXXXXX")"
    if ! {
        tar -xzf "${DL_DIR}/aosp-clang-r536225.tar.gz" -C "${staging}" &&
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
        tar -xzf "${DL_DIR}/aosp-rust-1.82.0.tar.gz" -C "${staging}" &&
        rm -f -- \
            "${staging}/BUILD.bazel" \
            "${staging}/manifest_12909517.xml" \
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
        tar -xzf "${DL_DIR}/aosp-kernel-build-tools-linux-x86.tar.gz" \
            -C "${staging}/build-tools" &&
        find "${staging}" -type d -exec chmod 0775 {} + &&
        find "${staging}" -type f -perm /111 -exec chmod 0775 {} + &&
        find "${staging}" -type f ! -perm /111 -exec chmod 0664 {} + &&
        tar -xJf "${DL_DIR}/bindgen.tar.xz" -C "${staging}" &&
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
load_env_file "${HOST_WORKSPACE_DIR}/.env"

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
COMMON_BRANCH="${COMMON_BRANCH:-android16-6.12-2025-06_r57}"
COMMON_COMMIT="${COMMON_COMMIT:-a82fc641d6d2c687802606190c0a8c33a4242201}"
COMMON_DIR="$(resolve_workspace_path "${COMMON_SOURCE_DIR:-sources/aosp_common_6.12.23_r57}")"
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
MAGISK_VERSION="${MAGISK_VERSION:-30.7}"
MAGISK_COMMIT="${MAGISK_COMMIT:-e8a58776f1d7bdf852072ad0baa6eceb9a1e4aac}"
MAGISK_APK_URL="${MAGISK_APK_URL:-https://github.com/topjohnwu/Magisk/releases/download/v30.7/Magisk-v30.7.apk}"
MAGISK_APK_SHA256="${MAGISK_APK_SHA256:-e0d32d2123532860f97123d927b1bb86c4e08e6fd8a48bfc6b5bee0afae9ebd5}"
MAGISKBOOT_ARM64_SHA256="${MAGISKBOOT_ARM64_SHA256:-d7440e2cd89899426e809554bf793baef9804ccbe5a52ce34a8b6242725d3c77}"
ENABLE_SUSFS="${ENABLE_SUSFS:-0}"
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_REF="${SUSFS_REF:-gki-android16-6.12}"
SUSFS_COMMIT="${SUSFS_COMMIT:-d9a486dc7197800149c31fe35a77997ea0ddaa83}"
SUSFS_DIR="$(resolve_workspace_path "${SUSFS_SOURCE_DIR:-sources/susfs4ksu}")"
SUSFS_KSU_PATCH_COMMIT="${SUSFS_KSU_PATCH_COMMIT:-ef69c8322232340f43c78c7fc491b32cb9f7da86}"
ENABLE_BBG="${ENABLE_BBG:-0}"
BBG_REPO="${BBG_REPO:-https://github.com/vc-teahouse/Baseband-guard.git}"
BBG_REF="${BBG_REF:-main}"
BBG_COMMIT="${BBG_COMMIT:-1c664957da7539de860503940ee73c7447f1dfaf}"
BBG_DIR="$(resolve_workspace_path "${BBG_SOURCE_DIR:-sources/baseband_guard}")"
ENABLE_ADIOS="${ENABLE_ADIOS:-0}"
ADIOS_REPO="${ADIOS_REPO:-https://github.com/firelzrd/adios.git}"
ADIOS_REF="${ADIOS_REF:-main}"
ADIOS_COMMIT="${ADIOS_COMMIT:-08bf078aac99075a0bef73c2b2497574a82e4c41}"
ADIOS_DIR="$(resolve_workspace_path "${ADIOS_SOURCE_DIR:-sources/adios}")"
ADIOS_STABLE_PATCH="${ADIOS_STABLE_PATCH:-patches/stable/0001-linux6.12.44-ADIOS-3.2.0.patch}"
ADIOS_FORCE_DEFAULT_PATCH="${ADIOS_FORCE_DEFAULT_PATCH:-patches/0002-Make-ADIOS-the-Default-I-O-scheduler.patch}"
ENABLE_TCP_BRUTAL="${ENABLE_TCP_BRUTAL:-0}"
TCP_BRUTAL_REPO="${TCP_BRUTAL_REPO:-https://github.com/apernet/tcp-brutal.git}"
TCP_BRUTAL_REF="${TCP_BRUTAL_REF:-master}"
TCP_BRUTAL_COMMIT="${TCP_BRUTAL_COMMIT:-f11e52d88c7ad2285896de018c2d96d4687f0ab6}"
TCP_BRUTAL_DIR="$(resolve_workspace_path "${TCP_BRUTAL_SOURCE_DIR:-sources/tcp_brutal}")"
TCP_BRUTAL_SOURCE_SHA256="${TCP_BRUTAL_SOURCE_SHA256:-171d775cc494f9378c89772ef68ad8001e093f701a35d1566ec9c7e459cb81c0}"
ENABLE_BACKPORT_AUDIT="${ENABLE_BACKPORT_AUDIT:-0}"
BACKPORT_AUDIT_SNAPSHOT="${BACKPORT_AUDIT_SNAPSHOT:-}"
AOSP_BACKPORT_AUDIT_DIR="$(resolve_workspace_path "${AOSP_BACKPORT_AUDIT_SOURCE_DIR:-sources/aosp_common_backport_audit}")"
AOSP_BACKPORT_AUDIT_REFS="${AOSP_BACKPORT_AUDIT_REFS:-}"
LINUX_STABLE_AUDIT_REPO="${LINUX_STABLE_AUDIT_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
LINUX_STABLE_AUDIT_REF="${LINUX_STABLE_AUDIT_REF:-linux-6.12.y}"
LINUX_STABLE_AUDIT_BASE_COMMIT="${LINUX_STABLE_AUDIT_BASE_COMMIT:-}"
LINUX_STABLE_AUDIT_COMMIT="${LINUX_STABLE_AUDIT_COMMIT:-}"
LINUX_STABLE_AUDIT_DIR="$(resolve_workspace_path "${LINUX_STABLE_AUDIT_SOURCE_DIR:-sources/linux_stable_6.12_audit}")"
LINUX_MAINLINE_AUDIT_REPO="${LINUX_MAINLINE_AUDIT_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git}"
LINUX_MAINLINE_AUDIT_BASE_COMMIT="${LINUX_MAINLINE_AUDIT_BASE_COMMIT:-}"
LINUX_MAINLINE_AUDIT_COMMIT="${LINUX_MAINLINE_AUDIT_COMMIT:-}"
LINUX_MAINLINE_AUDIT_DIR="$(resolve_workspace_path "${LINUX_MAINLINE_AUDIT_SOURCE_DIR:-sources/linux_mainline_audit}")"
ENABLE_F2FS_OPEN_FAST_PATH="${ENABLE_F2FS_OPEN_FAST_PATH:-0}"
F2FS_OPEN_FAST_PATH_AOSP_REF="${F2FS_OPEN_FAST_PATH_AOSP_REF:-android16-6.12}"
F2FS_OPEN_FAST_PATH_COMMIT="${F2FS_OPEN_FAST_PATH_COMMIT:-f6e898257b3d6a3a52d4bff5cec6237eebe1ce7d}"
F2FS_OPEN_FAST_PATH_COMMIT_DATE="${F2FS_OPEN_FAST_PATH_COMMIT_DATE:-2025-06-12}"
F2FS_OPEN_FAST_PATH_PATCH_ID="${F2FS_OPEN_FAST_PATH_PATCH_ID:-685b528beff90bac24b8f54e12238442363a80df}"
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
ENABLE_F2FS_MERGE_PAGE_BIO_UAF_FIX="${ENABLE_F2FS_MERGE_PAGE_BIO_UAF_FIX:-0}"
F2FS_MERGE_PAGE_BIO_UAF_FIX_AOSP_REF="${F2FS_MERGE_PAGE_BIO_UAF_FIX_AOSP_REF:-android16-6.12-2025-09}"
F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT="${F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT:-f2f676a2f21637b39f7f2be2f6137c1d9570d3e7}"
F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT_DATE="${F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT_DATE:-2025-10-31}"
F2FS_MERGE_PAGE_BIO_UAF_FIX_PATCH_ID="${F2FS_MERGE_PAGE_BIO_UAF_FIX_PATCH_ID:-ae11e76a9f7b489004102506a0896e0894ae681f}"
ENABLE_GUNYAH_CLEAN_RESOURCES_UAF_FIX="${ENABLE_GUNYAH_CLEAN_RESOURCES_UAF_FIX:-0}"
GUNYAH_CLEAN_RESOURCES_UAF_FIX_AOSP_REF="${GUNYAH_CLEAN_RESOURCES_UAF_FIX_AOSP_REF:-android16-6.12-lts}"
GUNYAH_CLEAN_RESOURCES_UAF_FIX_COMMIT="${GUNYAH_CLEAN_RESOURCES_UAF_FIX_COMMIT:-e5a17398e40d988ce7e9c79259eb8b08b5377b43}"
GUNYAH_CLEAN_RESOURCES_UAF_FIX_COMMIT_DATE="${GUNYAH_CLEAN_RESOURCES_UAF_FIX_COMMIT_DATE:-2025-08-07}"
GUNYAH_CLEAN_RESOURCES_UAF_FIX_PATCH_ID="${GUNYAH_CLEAN_RESOURCES_UAF_FIX_PATCH_ID:-b422a66e01ad0e4046dedafc81785fc8b4a9ff57}"
ENABLE_IDLETIMER_DESTROY_UAF_FIX="${ENABLE_IDLETIMER_DESTROY_UAF_FIX:-0}"
IDLETIMER_DESTROY_UAF_FIX_AOSP_REF="${IDLETIMER_DESTROY_UAF_FIX_AOSP_REF:-android16-6.12-lts}"
IDLETIMER_DESTROY_UAF_FIX_COMMIT="${IDLETIMER_DESTROY_UAF_FIX_COMMIT:-9317fe019b5be27e888f02629a3de1f4d78cb1aa}"
IDLETIMER_DESTROY_UAF_FIX_COMMIT_DATE="${IDLETIMER_DESTROY_UAF_FIX_COMMIT_DATE:-2026-04-21}"
IDLETIMER_DESTROY_UAF_FIX_PATCH_ID="${IDLETIMER_DESTROY_UAF_FIX_PATCH_ID:-2e6c62f1168d9eb5163373eac35801caa4d4a631}"
ENABLE_EVENTPOLL_RCU_UAF_FIX="${ENABLE_EVENTPOLL_RCU_UAF_FIX:-0}"
EVENTPOLL_RCU_UAF_FIX_AOSP_REF="${EVENTPOLL_RCU_UAF_FIX_AOSP_REF:-android16-6.12-lts}"
EVENTPOLL_RCU_UAF_FIX_COMMIT="${EVENTPOLL_RCU_UAF_FIX_COMMIT:-5b1173b165421561db29f30afc7e97d940a398a9}"
EVENTPOLL_RCU_UAF_FIX_COMMIT_DATE="${EVENTPOLL_RCU_UAF_FIX_COMMIT_DATE:-2026-04-22}"
EVENTPOLL_RCU_UAF_FIX_PATCH_ID="${EVENTPOLL_RCU_UAF_FIX_PATCH_ID:-a5abf8e11ad85b58f2924d8bd693b8b644462f6a}"
ENABLE_CGROUP_KERNFS_UAF_FIX="${ENABLE_CGROUP_KERNFS_UAF_FIX:-0}"
CGROUP_KERNFS_UAF_FIX_AOSP_REF="${CGROUP_KERNFS_UAF_FIX_AOSP_REF:-android16-6.12-lts}"
CGROUP_KERNFS_UAF_FIX_COMMIT="${CGROUP_KERNFS_UAF_FIX_COMMIT:-993047031c9fcb7f4a58389692e844f7be423cc7}"
CGROUP_KERNFS_UAF_FIX_COMMIT_DATE="${CGROUP_KERNFS_UAF_FIX_COMMIT_DATE:-2026-02-06}"
CGROUP_KERNFS_UAF_FIX_PATCH_ID="${CGROUP_KERNFS_UAF_FIX_PATCH_ID:-7fb683b637d0db664c6c37667692c27127a28dd1}"
ENABLE_F2FS_SYNC_INODE_META_UAF_FIX="${ENABLE_F2FS_SYNC_INODE_META_UAF_FIX:-0}"
F2FS_SYNC_INODE_META_UAF_FIX_AOSP_REF="${F2FS_SYNC_INODE_META_UAF_FIX_AOSP_REF:-android16-6.12-lts}"
F2FS_SYNC_INODE_META_UAF_FIX_COMMIT="${F2FS_SYNC_INODE_META_UAF_FIX_COMMIT:-dea243f58a8391e76f42ad5eb59ff210519ee772}"
F2FS_SYNC_INODE_META_UAF_FIX_COMMIT_DATE="${F2FS_SYNC_INODE_META_UAF_FIX_COMMIT_DATE:-2025-08-15}"
F2FS_SYNC_INODE_META_UAF_FIX_PATCH_ID="${F2FS_SYNC_INODE_META_UAF_FIX_PATCH_ID:-41eeded4f38919c5bffa8aef0c8b9b2468346b9d}"
ENABLE_TIMER_SHUTDOWN_SYNC_RACE_FIX="${ENABLE_TIMER_SHUTDOWN_SYNC_RACE_FIX:-0}"
TIMER_SHUTDOWN_SYNC_RACE_FIX_AOSP_REF="${TIMER_SHUTDOWN_SYNC_RACE_FIX_AOSP_REF:-android16-6.12-lts}"
TIMER_SHUTDOWN_SYNC_RACE_FIX_COMMIT="${TIMER_SHUTDOWN_SYNC_RACE_FIX_COMMIT:-176725f4848376530a0f0da9023f956afcc33585}"
TIMER_SHUTDOWN_SYNC_RACE_FIX_COMMIT_DATE="${TIMER_SHUTDOWN_SYNC_RACE_FIX_COMMIT_DATE:-2025-12-01}"
TIMER_SHUTDOWN_SYNC_RACE_FIX_PATCH_ID="${TIMER_SHUTDOWN_SYNC_RACE_FIX_PATCH_ID:-e528717d3d19cb12b0d9ac96781075350fdf4dae}"
ENABLE_FUTEX_REQUEUE_PI_UAF_FIX="${ENABLE_FUTEX_REQUEUE_PI_UAF_FIX:-0}"
FUTEX_REQUEUE_PI_UAF_FIX_AOSP_REF="${FUTEX_REQUEUE_PI_UAF_FIX_AOSP_REF:-android16-6.12-lts}"
FUTEX_REQUEUE_PI_UAF_FIX_COMMIT="${FUTEX_REQUEUE_PI_UAF_FIX_COMMIT:-a170b9c0dde83312b8b58ccc91509c7c15711641}"
FUTEX_REQUEUE_PI_UAF_FIX_COMMIT_DATE="${FUTEX_REQUEUE_PI_UAF_FIX_COMMIT_DATE:-2025-10-02}"
FUTEX_REQUEUE_PI_UAF_FIX_PATCH_ID="${FUTEX_REQUEUE_PI_UAF_FIX_PATCH_ID:-8a1bf4596581bd162f4acb909b7ee859ca2c7afa}"
ENABLE_PAGE_POOL_DESTROY_RACE_FIX="${ENABLE_PAGE_POOL_DESTROY_RACE_FIX:-0}"
PAGE_POOL_DESTROY_RACE_FIX_AOSP_REF="${PAGE_POOL_DESTROY_RACE_FIX_AOSP_REF:-android16-6.12-lts}"
PAGE_POOL_DESTROY_RACE_FIX_COMMIT="${PAGE_POOL_DESTROY_RACE_FIX_COMMIT:-e869a85acc2e60dc554579b910826a4919d8cd98}"
PAGE_POOL_DESTROY_RACE_FIX_COMMIT_DATE="${PAGE_POOL_DESTROY_RACE_FIX_COMMIT_DATE:-2025-06-19}"
PAGE_POOL_DESTROY_RACE_FIX_PATCH_ID="${PAGE_POOL_DESTROY_RACE_FIX_PATCH_ID:-dad3ca58feaaae658e77c9e001250fed18853b1e}"
ENABLE_CONNTRACK_UNCONFIRMED_RACE_FIX="${ENABLE_CONNTRACK_UNCONFIRMED_RACE_FIX:-0}"
CONNTRACK_UNCONFIRMED_RACE_FIX_AOSP_REF="${CONNTRACK_UNCONFIRMED_RACE_FIX_AOSP_REF:-android16-6.12-lts}"
CONNTRACK_UNCONFIRMED_RACE_FIX_COMMIT="${CONNTRACK_UNCONFIRMED_RACE_FIX_COMMIT:-fc38c249c622ff5e3011b8845fd49dbfd9289afc}"
CONNTRACK_UNCONFIRMED_RACE_FIX_COMMIT_DATE="${CONNTRACK_UNCONFIRMED_RACE_FIX_COMMIT_DATE:-2025-07-24}"
CONNTRACK_UNCONFIRMED_RACE_FIX_PATCH_ID="${CONNTRACK_UNCONFIRMED_RACE_FIX_PATCH_ID:-37b80fce84a874c3917935828ffbb6b74b3a8ee6}"
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
ENABLE_RTMUTEX_WAITER_ENQUEUE_FIX="${ENABLE_RTMUTEX_WAITER_ENQUEUE_FIX:-0}"
RTMUTEX_WAITER_ENQUEUE_FIX_AOSP_REF="${RTMUTEX_WAITER_ENQUEUE_FIX_AOSP_REF:-android16-6.12-2026-03}"
RTMUTEX_WAITER_ENQUEUE_FIX_COMMIT="${RTMUTEX_WAITER_ENQUEUE_FIX_COMMIT:-202a62288cb6884f0bdcea8a8d47a1a8c4d3e143}"
RTMUTEX_WAITER_ENQUEUE_FIX_COMMIT_DATE="${RTMUTEX_WAITER_ENQUEUE_FIX_COMMIT_DATE:-2026-07-23}"
RTMUTEX_WAITER_ENQUEUE_FIX_PATCH_ID="${RTMUTEX_WAITER_ENQUEUE_FIX_PATCH_ID:-0d78a126f83be68e6f97baae61550baacc3a2ecc}"
ENABLE_STAGE5_RTMUTEX_FIX="${ENABLE_STAGE5_RTMUTEX_FIX:-0}"
STAGE5_AOSP_SECURITY_REF="${STAGE5_AOSP_SECURITY_REF:-android16-6.12-2026-06}"
STAGE5_RTMUTEX_FIX_COMMIT="${STAGE5_RTMUTEX_FIX_COMMIT:-e7d9bd94fbdbf9842ea6f1b6d5af45758e87e3d6}"
STAGE5_RTMUTEX_FIX_PATCH_ID="${STAGE5_RTMUTEX_FIX_PATCH_ID:-bd48afa70647e92db0e44335fbe75d2b520671a6}"
ENABLE_UNICODE_IGNORABLE_FIX="${ENABLE_UNICODE_IGNORABLE_FIX:-0}"
UNICODE_FIX_COMMIT="${UNICODE_FIX_COMMIT:-425419e5b2a8c88096b8bbc61d8865600d1a91c0}"
UNICODE_FIX_PATCH_ID="${UNICODE_FIX_PATCH_ID:-8bad10993f9d6df5a0130e8394608f4550904bbd}"
UNICODE_FIX_UPSTREAM_COMMIT="${UNICODE_FIX_UPSTREAM_COMMIT:-5c26d2f1d3f5e4be3e196526bead29ecb139cf91}"
UNICODE_EXT4_COMPAT_COMMIT="${UNICODE_EXT4_COMPAT_COMMIT:-aa66603ddf1b22e65992ae893c76a0224a4dd415}"
UNICODE_EXT4_COMPAT_PATCH_ID="${UNICODE_EXT4_COMPAT_PATCH_ID:-30a2d2ee185826e104434ab83b75c546dfd87900}"
UNICODE_F2FS_FALLBACK_COMMIT="${UNICODE_F2FS_FALLBACK_COMMIT:-79f2beb7a4f5f256928e57fd79cc194b422d2694}"
UNICODE_F2FS_FALLBACK_PATCH_ID="${UNICODE_F2FS_FALLBACK_PATCH_ID:-c02cc596ec7a8785afd11511ee49ed043c655163}"
UNICODE_F2FS_POLICY_COMMIT="${UNICODE_F2FS_POLICY_COMMIT:-3a1ee29cd6df3069bce8321784d065fa01d219ff}"
UNICODE_F2FS_POLICY_PATCH_ID="${UNICODE_F2FS_POLICY_PATCH_ID:-7c165eee5689f89c2f553b6a958d11a2e72cb2e5}"
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
CI_TOOLCHAIN_TREE_SHA256="${CI_TOOLCHAIN_TREE_SHA256:-67da74f00a801440ca7c256b028d94e6c85bf7168fbdecab62c3710384a25d5a}"
AOSP_CLANG_COMMIT="${AOSP_CLANG_COMMIT:-77c95e8253c2c82ffd4fee92c0ad9f5ac1e8ca04}"
CI_CLANG_URL="${CI_CLANG_URL:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/${AOSP_CLANG_COMMIT}/clang-r536225.tar.gz}"
CI_CLANG_SHA256="${CI_CLANG_SHA256:-4a1e231a9bfff63f7708d956d661e1a5cbf61a6dbaa8bc20246a7e5684a8c79c}"
AOSP_RUST_COMMIT="${AOSP_RUST_COMMIT:-5c78b1e636b2bf68d46a6980437590fddca64147}"
CI_RUST_URL="${CI_RUST_URL:-https://android.googlesource.com/platform/prebuilts/rust/+archive/${AOSP_RUST_COMMIT}/linux-x86/1.82.0.tar.gz}"
CI_RUST_SHA256="${CI_RUST_SHA256:-fd9a88b659172bc392ff4b70858b2b93d95f738680aa872605dcd81772e130ba}"
AOSP_BUILD_TOOLS_COMMIT="${AOSP_BUILD_TOOLS_COMMIT:-b12d639efb8844ee1be5b437d707e7c94be3ce3a}"
CI_BUILD_TOOLS_URL="${CI_BUILD_TOOLS_URL:-https://android.googlesource.com/kernel/prebuilts/build-tools/+archive/${AOSP_BUILD_TOOLS_COMMIT}/linux-x86.tar.gz}"
CI_BUILD_TOOLS_SHA256="${CI_BUILD_TOOLS_SHA256:-af9938dde2454368c8a5bb8c461f49ac6a96c4b92852eacac5d7c13fec3844be}"
CI_BINDGEN_URL="${CI_BINDGEN_URL:-https://github.com/rust-lang/rust-bindgen/releases/download/v0.69.5/bindgen-cli-x86_64-unknown-linux-gnu.tar.xz}"
CI_BINDGEN_SHA256="${CI_BINDGEN_SHA256:-b7e2321ee8c617f14ccc5b9f39b3a804db173ee217e924ad93ed16af6bc62b1d}"
CI_BUSYBOX_URL="${CI_BUSYBOX_URL:-https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox}"
CI_BUSYBOX_SHA256="${CI_BUSYBOX_SHA256:-6e123e7f3202a8c1e9b1f94d8941580a25135382b99e8d3e34fb858bba311348}"
[[ "${CI_TOOLCHAIN_TREE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "工具链安装树 SHA-256 格式错误"
[[ "${AOSP_CLANG_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "AOSP clang commit 格式错误"
[[ "${MAGISK_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "Magisk commit 格式错误"
[[ "${MAGISK_APK_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "Magisk APK SHA-256 格式错误"
[[ "${MAGISKBOOT_ARM64_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "arm64 magiskboot SHA-256 格式错误"
[[ "${AOSP_RUST_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "AOSP Rust commit 格式错误"
[[ "${AOSP_BUILD_TOOLS_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "AOSP build-tools commit 格式错误"
[ "${CI_CLANG_URL}" = "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/${AOSP_CLANG_COMMIT}/clang-r536225.tar.gz" ] || \
    die "clang 必须来自固定 AOSP Gitiles 提交"
[ "${CI_RUST_URL}" = "https://android.googlesource.com/platform/prebuilts/rust/+archive/${AOSP_RUST_COMMIT}/linux-x86/1.82.0.tar.gz" ] || \
    die "Rust 必须来自固定 AOSP Gitiles 提交"
[ "${CI_BUILD_TOOLS_URL}" = "https://android.googlesource.com/kernel/prebuilts/build-tools/+archive/${AOSP_BUILD_TOOLS_COMMIT}/linux-x86.tar.gz" ] || \
    die "build-tools 必须来自固定 AOSP Gitiles 提交"
[[ "${ANDROID_NDK_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "Android NDK SHA-256 格式错误"
[[ "${ANDROID_NDK_TREE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "Android NDK 安装树 SHA-256 格式错误"
declare -A TC_PKGS=(
    [aosp-clang-r536225.tar.gz]="${CI_CLANG_URL}"
    [aosp-rust-1.82.0.tar.gz]="${CI_RUST_URL}"
    [aosp-kernel-build-tools-linux-x86.tar.gz]="${CI_BUILD_TOOLS_URL}"
    [bindgen.tar.xz]="${CI_BINDGEN_URL}"
    [busybox-1.35.0-x86_64-linux-musl]="${CI_BUSYBOX_URL}"
)
declare -A TC_SHA256=(
    [aosp-clang-r536225.tar.gz]="${CI_CLANG_SHA256}"
    [aosp-rust-1.82.0.tar.gz]="${CI_RUST_SHA256}"
    [aosp-kernel-build-tools-linux-x86.tar.gz]="${CI_BUILD_TOOLS_SHA256}"
    [bindgen.tar.xz]="${CI_BINDGEN_SHA256}"
    [busybox-1.35.0-x86_64-linux-musl]="${CI_BUSYBOX_SHA256}"
)

ensure_repo "Xiaomi popsicle soc-repo" "${SOC_DIR}" "${KERNEL_REPO}" "${KERNEL_BRANCH}" "${KERNEL_COMMIT}"
ensure_repo "Android 16 GKI common" "${COMMON_DIR}" "${COMMON_REPO}" "${COMMON_BRANCH}" "${COMMON_COMMIT}" "${ENABLE_KERNELSU}"
if [ "${ENABLE_KERNELSU}" = "1" ]; then
    ensure_repo "KernelSU ${KSU_REF}" "${KSU_DIR}" "${KSU_REPO}" "${KSU_REF}" "${KSU_COMMIT}" "${ENABLE_SUSFS}"
    if [ -f "$(git -C "${KSU_DIR}" rev-parse --absolute-git-dir)/shallow" ]; then
        log_step "在初始化阶段补齐 KernelSU Git 历史以固定 KSU_VERSION"
        git -C "${KSU_DIR}" fetch --unshallow --tags origin
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
        git -C "${SUSFS_DIR}" fetch --depth 1 origin "${SUSFS_KSU_PATCH_COMMIT}"
    fi
    git -C "${SUSFS_DIR}" cat-file -e "${SUSFS_KSU_PATCH_COMMIT}:kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" 2>/dev/null || \
        die "SUSFS KernelSU 兼容补丁不存在: ${SUSFS_KSU_PATCH_COMMIT}"
fi
if [ "${ENABLE_BBG}" = "1" ]; then
    ensure_repo "Baseband Guard ${BBG_REF}" "${BBG_DIR}" "${BBG_REPO}" "${BBG_REF}" "${BBG_COMMIT}"
    if [ -f "$(git -C "${BBG_DIR}" rev-parse --absolute-git-dir)/shallow" ]; then
        log_step "在初始化阶段补齐 Baseband Guard 历史，禁止构建期联网"
        git -C "${BBG_DIR}" fetch --unshallow origin
    fi
fi
if [ "${ENABLE_ADIOS}" = "1" ]; then
    ensure_repo "ADIOS ${ADIOS_REF}" "${ADIOS_DIR}" "${ADIOS_REPO}" "${ADIOS_REF}" "${ADIOS_COMMIT}"
    [ -s "${ADIOS_DIR}/${ADIOS_STABLE_PATCH}" ] || die "ADIOS 6.12 stable 补丁缺失"
    [ -s "${ADIOS_DIR}/${ADIOS_FORCE_DEFAULT_PATCH}" ] || die "ADIOS 强制默认补丁审计输入缺失"
fi
if [ "${ENABLE_TCP_BRUTAL}" = "1" ]; then
    ensure_repo "TCP Brutal ${TCP_BRUTAL_REF}" "${TCP_BRUTAL_DIR}" "${TCP_BRUTAL_REPO}" "${TCP_BRUTAL_REF}" "${TCP_BRUTAL_COMMIT}"
    [ "$(sha256sum "${TCP_BRUTAL_DIR}/brutal.c" | awk '{ print $1 }')" = "${TCP_BRUTAL_SOURCE_SHA256}" ] || \
        die "TCP Brutal 官方源码 SHA-256 不匹配"
fi
if [ "${ENABLE_BACKPORT_AUDIT}" = "1" ]; then
    [ -n "${BACKPORT_AUDIT_SNAPSHOT}" ] || die "缺少后续改进审计快照日期"
    [ -n "${AOSP_BACKPORT_AUDIT_REFS}" ] || die "缺少 AOSP 后续审计 refs"
    [ -n "${LINUX_STABLE_AUDIT_BASE_COMMIT}" ] || die "缺少 Linux stable 审计起点"
    [ -n "${LINUX_STABLE_AUDIT_COMMIT}" ] || die "缺少 Linux stable 审计终点"
    [ -n "${LINUX_MAINLINE_AUDIT_BASE_COMMIT}" ] || die "缺少 Linux mainline 审计起点"
    [ -n "${LINUX_MAINLINE_AUDIT_COMMIT}" ] || die "缺少 Linux mainline 审计终点"

    aosp_audit_commits=("${COMMON_COMMIT}")
    ensure_audit_repo "AOSP common 后续历史" "${AOSP_BACKPORT_AUDIT_DIR}" "${COMMON_REPO}"
    fetch_audit_ref "AOSP common r57 基线" "${AOSP_BACKPORT_AUDIT_DIR}" \
        "aosp/base-r57" "${COMMON_COMMIT}" "2025-01-01"
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

    ensure_audit_repo "Linux 6.12 stable 历史" "${LINUX_STABLE_AUDIT_DIR}" "${LINUX_STABLE_AUDIT_REPO}"
    fetch_audit_ref "Linux stable v6.12.23" "${LINUX_STABLE_AUDIT_DIR}" \
        "linux-stable/base-v6.12.23" "${LINUX_STABLE_AUDIT_BASE_COMMIT}" "2024-11-01"
    fetch_audit_ref "Linux stable ${LINUX_STABLE_AUDIT_REF}" "${LINUX_STABLE_AUDIT_DIR}" \
        "linux-stable/${LINUX_STABLE_AUDIT_REF}" "${LINUX_STABLE_AUDIT_COMMIT}" "2024-11-01"
    hydrate_audit_commit_history "Linux 6.12 stable" "${LINUX_STABLE_AUDIT_DIR}" \
        "${BACKPORT_AUDIT_SNAPSHOT}" "2024-11-01" \
        "${LINUX_STABLE_AUDIT_BASE_COMMIT}" "${LINUX_STABLE_AUDIT_COMMIT}"

    ensure_audit_repo "Linux mainline 历史" "${LINUX_MAINLINE_AUDIT_DIR}" "${LINUX_MAINLINE_AUDIT_REPO}"
    fetch_audit_ref "Linux mainline v6.12" "${LINUX_MAINLINE_AUDIT_DIR}" \
        "linux-mainline/base-v6.12" "${LINUX_MAINLINE_AUDIT_BASE_COMMIT}" "2024-11-01"
    fetch_audit_ref "Linux mainline 快照" "${LINUX_MAINLINE_AUDIT_DIR}" \
        "linux-mainline/snapshot-${BACKPORT_AUDIT_SNAPSHOT}" "${LINUX_MAINLINE_AUDIT_COMMIT}" "2024-11-01"
    hydrate_audit_commit_history "Linux mainline" "${LINUX_MAINLINE_AUDIT_DIR}" \
        "${BACKPORT_AUDIT_SNAPSHOT}" "2024-11-01" \
        "${LINUX_MAINLINE_AUDIT_BASE_COMMIT}" "${LINUX_MAINLINE_AUDIT_COMMIT}"
    log_success "后续改进只读审计历史已固定"
fi
if [ "${ENABLE_F2FS_OPEN_FAST_PATH}" = "1" ]; then
    verify_aosp_backport_source "F2FS open 快路径优化" \
        "${F2FS_OPEN_FAST_PATH_AOSP_REF}" \
        "${F2FS_OPEN_FAST_PATH_COMMIT}" \
        "${F2FS_OPEN_FAST_PATH_COMMIT_DATE}" \
        "${F2FS_OPEN_FAST_PATH_PATCH_ID}" \
        "fs/f2fs/file.c"
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
if [ "${ENABLE_F2FS_MERGE_PAGE_BIO_UAF_FIX}" = "1" ]; then
    [ "${ENABLE_BACKPORT_AUDIT}" = "1" ] || \
        die "F2FS merge_page_bio UAF 修复需要启用固定 AOSP 审计源"
    f2fs_fix_ref_commit=""
    for audit_ref in ${AOSP_BACKPORT_AUDIT_REFS}; do
        if [ "${audit_ref%%:*}" = "${F2FS_MERGE_PAGE_BIO_UAF_FIX_AOSP_REF}" ]; then
            f2fs_fix_ref_commit="${audit_ref#*:}"
            break
        fi
    done
    [ -n "${f2fs_fix_ref_commit}" ] || \
        die "F2FS merge_page_bio UAF 修复来源 ref 未固定"
    env GIT_NO_LAZY_FETCH=1 git -C "${AOSP_BACKPORT_AUDIT_DIR}" \
        merge-base --is-ancestor "${F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT}" "${f2fs_fix_ref_commit}" || \
        die "F2FS merge_page_bio UAF 修复不属于固定 AOSP 来源 ref"
    [ "$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${AOSP_BACKPORT_AUDIT_DIR}" \
        show -s --format=%cs "${F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT}")" = \
      "${F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT_DATE}" ] || \
        die "F2FS merge_page_bio UAF 修复提交日期不匹配"
    [[ "${F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT_DATE}" < "${BACKPORT_AUDIT_SNAPSHOT}" ||
       "${F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT_DATE}" = "${BACKPORT_AUDIT_SNAPSHOT}" ]] || \
        die "F2FS merge_page_bio UAF 修复晚于固定审计快照"
    [ "$(env GIT_NO_LAZY_FETCH=1 git -C "${AOSP_BACKPORT_AUDIT_DIR}" \
        diff-tree --no-commit-id --name-only -r "${F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT}")" = \
      "fs/f2fs/data.c" ] || die "F2FS merge_page_bio UAF 修复触及非预期路径"
    [ "$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${AOSP_BACKPORT_AUDIT_DIR}" \
        show --format= "${F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT}" |
        git patch-id --stable | awk '{ print $1 }')" = \
      "${F2FS_MERGE_PAGE_BIO_UAF_FIX_PATCH_ID}" ] || \
        die "F2FS merge_page_bio UAF 修复 patch-id 不匹配"
    log_success "F2FS merge_page_bio UAF 官方修复来源已固定"
fi
if [ "${ENABLE_GUNYAH_CLEAN_RESOURCES_UAF_FIX}" = "1" ]; then
    verify_aosp_backport_source "Gunyah clean_resources UAF 修复" \
        "${GUNYAH_CLEAN_RESOURCES_UAF_FIX_AOSP_REF}" \
        "${GUNYAH_CLEAN_RESOURCES_UAF_FIX_COMMIT}" \
        "${GUNYAH_CLEAN_RESOURCES_UAF_FIX_COMMIT_DATE}" \
        "${GUNYAH_CLEAN_RESOURCES_UAF_FIX_PATCH_ID}" \
        "drivers/virt/gunyah/vm_mgr.c"
fi
if [ "${ENABLE_IDLETIMER_DESTROY_UAF_FIX}" = "1" ]; then
    verify_aosp_backport_source "IDLETIMER destroy UAF 修复" \
        "${IDLETIMER_DESTROY_UAF_FIX_AOSP_REF}" \
        "${IDLETIMER_DESTROY_UAF_FIX_COMMIT}" \
        "${IDLETIMER_DESTROY_UAF_FIX_COMMIT_DATE}" \
        "${IDLETIMER_DESTROY_UAF_FIX_PATCH_ID}" \
        "net/netfilter/xt_IDLETIMER.c"
fi
if [ "${ENABLE_EVENTPOLL_RCU_UAF_FIX}" = "1" ]; then
    verify_aosp_backport_source "eventpoll RCU UAF 修复" \
        "${EVENTPOLL_RCU_UAF_FIX_AOSP_REF}" \
        "${EVENTPOLL_RCU_UAF_FIX_COMMIT}" \
        "${EVENTPOLL_RCU_UAF_FIX_COMMIT_DATE}" \
        "${EVENTPOLL_RCU_UAF_FIX_PATCH_ID}" \
        "fs/eventpoll.c"
fi
if [ "${ENABLE_CGROUP_KERNFS_UAF_FIX}" = "1" ]; then
    verify_aosp_backport_source "cgroup kernfs UAF 修复" \
        "${CGROUP_KERNFS_UAF_FIX_AOSP_REF}" \
        "${CGROUP_KERNFS_UAF_FIX_COMMIT}" \
        "${CGROUP_KERNFS_UAF_FIX_COMMIT_DATE}" \
        "${CGROUP_KERNFS_UAF_FIX_PATCH_ID}" \
        "kernel/cgroup/cgroup.c"
fi
if [ "${ENABLE_F2FS_SYNC_INODE_META_UAF_FIX}" = "1" ]; then
    verify_aosp_backport_source "F2FS sync_inode_meta UAF 修复" \
        "${F2FS_SYNC_INODE_META_UAF_FIX_AOSP_REF}" \
        "${F2FS_SYNC_INODE_META_UAF_FIX_COMMIT}" \
        "${F2FS_SYNC_INODE_META_UAF_FIX_COMMIT_DATE}" \
        "${F2FS_SYNC_INODE_META_UAF_FIX_PATCH_ID}" \
        "fs/f2fs/inode.c"
fi
if [ "${ENABLE_TIMER_SHUTDOWN_SYNC_RACE_FIX}" = "1" ]; then
    verify_aosp_backport_source "timer shutdown_sync 竞态修复" \
        "${TIMER_SHUTDOWN_SYNC_RACE_FIX_AOSP_REF}" \
        "${TIMER_SHUTDOWN_SYNC_RACE_FIX_COMMIT}" \
        "${TIMER_SHUTDOWN_SYNC_RACE_FIX_COMMIT_DATE}" \
        "${TIMER_SHUTDOWN_SYNC_RACE_FIX_PATCH_ID}" \
        "kernel/time/timer.c"
fi
if [ "${ENABLE_FUTEX_REQUEUE_PI_UAF_FIX}" = "1" ]; then
    verify_aosp_backport_source "futex requeue-PI UAF 修复" \
        "${FUTEX_REQUEUE_PI_UAF_FIX_AOSP_REF}" \
        "${FUTEX_REQUEUE_PI_UAF_FIX_COMMIT}" \
        "${FUTEX_REQUEUE_PI_UAF_FIX_COMMIT_DATE}" \
        "${FUTEX_REQUEUE_PI_UAF_FIX_PATCH_ID}" \
        "kernel/futex/requeue.c"
fi
if [ "${ENABLE_PAGE_POOL_DESTROY_RACE_FIX}" = "1" ]; then
    verify_aosp_backport_source "page_pool 销毁竞态修复" \
        "${PAGE_POOL_DESTROY_RACE_FIX_AOSP_REF}" \
        "${PAGE_POOL_DESTROY_RACE_FIX_COMMIT}" \
        "${PAGE_POOL_DESTROY_RACE_FIX_COMMIT_DATE}" \
        "${PAGE_POOL_DESTROY_RACE_FIX_PATCH_ID}" \
        "net/core/page_pool.c"
fi
if [ "${ENABLE_CONNTRACK_UNCONFIRMED_RACE_FIX}" = "1" ]; then
    verify_aosp_backport_source "conntrack 未确认项并发删除修复" \
        "${CONNTRACK_UNCONFIRMED_RACE_FIX_AOSP_REF}" \
        "${CONNTRACK_UNCONFIRMED_RACE_FIX_COMMIT}" \
        "${CONNTRACK_UNCONFIRMED_RACE_FIX_COMMIT_DATE}" \
        "${CONNTRACK_UNCONFIRMED_RACE_FIX_PATCH_ID}" \
        "include/net/netfilter/nf_conntrack.h net/netfilter/nf_conntrack_core.c"
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
if [ "${ENABLE_RTMUTEX_WAITER_ENQUEUE_FIX}" = "1" ]; then
    verify_aosp_backport_source "rtmutex 未入队 waiter 错误路径修复" \
        "${RTMUTEX_WAITER_ENQUEUE_FIX_AOSP_REF}" \
        "${RTMUTEX_WAITER_ENQUEUE_FIX_COMMIT}" \
        "${RTMUTEX_WAITER_ENQUEUE_FIX_COMMIT_DATE}" \
        "${RTMUTEX_WAITER_ENQUEUE_FIX_PATCH_ID}" \
        "kernel/locking/rtmutex.c kernel/locking/rtmutex_api.c"
fi
if [ "${ENABLE_STAGE5_RTMUTEX_FIX}" = "1" ]; then
    if ! git -C "${COMMON_DIR}" cat-file -e "${STAGE5_RTMUTEX_FIX_COMMIT}^{commit}" 2>/dev/null; then
        log_step "获取阶段 5 AOSP rtmutex 官方修复"
        git -C "${COMMON_DIR}" fetch --depth=300 --no-tags origin \
            "refs/heads/${STAGE5_AOSP_SECURITY_REF}:refs/stage5/aosp-security-source"
    fi
    [ "$(git -C "${COMMON_DIR}" diff-tree --no-commit-id --name-only -r "${STAGE5_RTMUTEX_FIX_COMMIT}")" = "kernel/locking/rtmutex.c" ] || \
        die "阶段 5 rtmutex 修复触及了非预期路径"
    [ "$(git -C "${COMMON_DIR}" show --format= "${STAGE5_RTMUTEX_FIX_COMMIT}" | git patch-id --stable | awk '{ print $1 }')" = "${STAGE5_RTMUTEX_FIX_PATCH_ID}" ] || \
        die "阶段 5 rtmutex 官方修复 patch-id 不匹配"
fi
if [ "${ENABLE_UNICODE_IGNORABLE_FIX}" = "1" ]; then
    if ! git -C "${COMMON_DIR}" cat-file -e "${UNICODE_FIX_COMMIT}^" 2>/dev/null; then
        log_step "获取 AOSP Unicode default-ignorable 官方修复及父对象"
        git -C "${COMMON_DIR}" fetch --depth=2 --no-tags origin "${UNICODE_FIX_COMMIT}"
    fi
    [ "$(git -C "${COMMON_DIR}" diff-tree --no-commit-id --name-only -r "${UNICODE_FIX_COMMIT}" | LC_ALL=C sort | paste -sd ' ' -)" = \
      "fs/unicode/mkutf8data.c fs/unicode/utf8data.h_shipped" ] || die "Unicode 官方修复触及了非预期路径"
    [ "$(git -C "${COMMON_DIR}" show --format= "${UNICODE_FIX_COMMIT}" | git patch-id --stable | awk '{ print $1 }')" = "${UNICODE_FIX_PATCH_ID}" ] || \
        die "Unicode 官方修复 patch-id 不匹配"
    git -C "${COMMON_DIR}" show -s --format=%B "${UNICODE_FIX_COMMIT}" | grep -Fq "cherry picked from commit ${UNICODE_FIX_UPSTREAM_COMMIT}" || \
        die "Unicode 修复缺少预期上游来源"
    if ! git -C "${COMMON_DIR}" cat-file -e "${UNICODE_EXT4_COMPAT_COMMIT}^" 2>/dev/null; then
        log_step "获取 AOSP ext4 casefold 兼容回退及父对象"
        git -C "${COMMON_DIR}" fetch --depth=2 --no-tags origin "${UNICODE_EXT4_COMPAT_COMMIT}"
    fi
    [ "$(git -C "${COMMON_DIR}" diff-tree --no-commit-id --name-only -r "${UNICODE_EXT4_COMPAT_COMMIT}" | LC_ALL=C sort | paste -sd ' ' -)" = \
      "fs/ext4/namei.c include/linux/fs.h" ] || die "ext4 casefold 官方兼容提交触及了非预期路径"
    [ "$(git -C "${COMMON_DIR}" show --format= "${UNICODE_EXT4_COMPAT_COMMIT}" -- fs/ext4/namei.c | git patch-id --stable | awk '{ print $1 }')" = \
      "${UNICODE_EXT4_COMPAT_PATCH_ID}" ] || die "ext4 casefold 官方兼容提交 patch-id 不匹配"
    for unicode_f2fs_commit in "${UNICODE_F2FS_FALLBACK_COMMIT}" "${UNICODE_F2FS_POLICY_COMMIT}"; do
        if ! git -C "${COMMON_DIR}" cat-file -e "${unicode_f2fs_commit}^" 2>/dev/null; then
            log_step "获取 AOSP f2fs casefold 兼容对象 ${unicode_f2fs_commit:0:12}"
            git -C "${COMMON_DIR}" fetch --depth=2 --no-tags origin "${unicode_f2fs_commit}"
        fi
    done
    [ "$(git -C "${COMMON_DIR}" diff-tree --no-commit-id --name-only -r "${UNICODE_F2FS_FALLBACK_COMMIT}" | LC_ALL=C sort | paste -sd ' ' -)" = \
      "fs/f2fs/dir.c fs/f2fs/f2fs.h fs/f2fs/inline.c" ] || die "f2fs 官方线性回退提交路径集合异常"
    [ "$(git -C "${COMMON_DIR}" show --format= "${UNICODE_F2FS_FALLBACK_COMMIT}" | git patch-id --stable | awk '{ print $1 }')" = \
      "${UNICODE_F2FS_FALLBACK_PATCH_ID}" ] || die "f2fs 官方线性回退 patch-id 不匹配"
    [ "$(git -C "${COMMON_DIR}" diff-tree --no-commit-id --name-only -r "${UNICODE_F2FS_POLICY_COMMIT}" | LC_ALL=C sort | paste -sd ' ' -)" = \
      "fs/f2fs/dir.c include/linux/fs.h" ] || die "f2fs 官方回退策略提交路径集合异常"
    [ "$(git -C "${COMMON_DIR}" show --format= "${UNICODE_F2FS_POLICY_COMMIT}" | git patch-id --stable | awk '{ print $1 }')" = \
      "${UNICODE_F2FS_POLICY_PATCH_ID}" ] || die "f2fs 官方回退策略 patch-id 不匹配"
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
[ "${ENABLE_ADIOS}" != "1" ] || log_info "ADIOS: ${ADIOS_DIR} (${ADIOS_REF} @ ${ADIOS_COMMIT})"
[ "${ENABLE_TCP_BRUTAL}" != "1" ] || log_info "TCP Brutal: ${TCP_BRUTAL_DIR} (${TCP_BRUTAL_REF} @ ${TCP_BRUTAL_COMMIT})"
[ "${ENABLE_BACKPORT_AUDIT}" != "1" ] || log_info "Backport audit snapshot: ${BACKPORT_AUDIT_SNAPSHOT} (no age cutoff)"
[ "${ENABLE_F2FS_OPEN_FAST_PATH}" != "1" ] || log_info "AOSP F2FS open fast path: ${F2FS_OPEN_FAST_PATH_COMMIT} (${F2FS_OPEN_FAST_PATH_AOSP_REF})"
[ "${ENABLE_MEMCG_RSTAT_FAST_PATH}" != "1" ] || log_info "Linux memcg rstat fast path: ${MEMCG_RSTAT_FAST_PATH_COMMIT} (${MEMCG_RSTAT_FAST_PATH_AOSP_REF})"
[ "${ENABLE_TCP_RECV_MSTAMP_FAST_PATH}" != "1" ] || log_info "Linux TCP recv timestamp fast path: ${TCP_RECV_MSTAMP_FAST_PATH_COMMIT} (${TCP_RECV_MSTAMP_FAST_PATH_AOSP_REF})"
[ "${ENABLE_F2FS_MERGE_PAGE_BIO_UAF_FIX}" != "1" ] || log_info "AOSP F2FS merge_page_bio UAF fix: ${F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT} (${F2FS_MERGE_PAGE_BIO_UAF_FIX_AOSP_REF})"
[ "${ENABLE_GUNYAH_CLEAN_RESOURCES_UAF_FIX}" != "1" ] || log_info "AOSP Gunyah clean_resources UAF fix: ${GUNYAH_CLEAN_RESOURCES_UAF_FIX_COMMIT} (${GUNYAH_CLEAN_RESOURCES_UAF_FIX_AOSP_REF})"
[ "${ENABLE_IDLETIMER_DESTROY_UAF_FIX}" != "1" ] || log_info "AOSP IDLETIMER destroy UAF fix: ${IDLETIMER_DESTROY_UAF_FIX_COMMIT} (${IDLETIMER_DESTROY_UAF_FIX_AOSP_REF})"
[ "${ENABLE_EVENTPOLL_RCU_UAF_FIX}" != "1" ] || log_info "AOSP eventpoll RCU UAF fix: ${EVENTPOLL_RCU_UAF_FIX_COMMIT} (${EVENTPOLL_RCU_UAF_FIX_AOSP_REF})"
[ "${ENABLE_CGROUP_KERNFS_UAF_FIX}" != "1" ] || log_info "AOSP cgroup kernfs UAF fix: ${CGROUP_KERNFS_UAF_FIX_COMMIT} (${CGROUP_KERNFS_UAF_FIX_AOSP_REF})"
[ "${ENABLE_F2FS_SYNC_INODE_META_UAF_FIX}" != "1" ] || log_info "AOSP F2FS sync_inode_meta UAF fix: ${F2FS_SYNC_INODE_META_UAF_FIX_COMMIT} (${F2FS_SYNC_INODE_META_UAF_FIX_AOSP_REF})"
[ "${ENABLE_TIMER_SHUTDOWN_SYNC_RACE_FIX}" != "1" ] || log_info "AOSP timer shutdown_sync race fix: ${TIMER_SHUTDOWN_SYNC_RACE_FIX_COMMIT} (${TIMER_SHUTDOWN_SYNC_RACE_FIX_AOSP_REF})"
[ "${ENABLE_FUTEX_REQUEUE_PI_UAF_FIX}" != "1" ] || log_info "AOSP futex requeue-PI UAF fix: ${FUTEX_REQUEUE_PI_UAF_FIX_COMMIT} (${FUTEX_REQUEUE_PI_UAF_FIX_AOSP_REF})"
[ "${ENABLE_PAGE_POOL_DESTROY_RACE_FIX}" != "1" ] || log_info "AOSP page_pool destroy race fix: ${PAGE_POOL_DESTROY_RACE_FIX_COMMIT} (${PAGE_POOL_DESTROY_RACE_FIX_AOSP_REF})"
[ "${ENABLE_CONNTRACK_UNCONFIRMED_RACE_FIX}" != "1" ] || log_info "AOSP conntrack unconfirmed race fix: ${CONNTRACK_UNCONFIRMED_RACE_FIX_COMMIT} (${CONNTRACK_UNCONFIRMED_RACE_FIX_AOSP_REF})"
[ "${ENABLE_EROFS_DIR_TAIL_OOB_FIX}" != "1" ] || log_info "AOSP EROFS directory tail OOB fix: ${EROFS_DIR_TAIL_OOB_FIX_COMMIT} (${EROFS_DIR_TAIL_OOB_FIX_AOSP_REF})"
[ "${ENABLE_EXT4_XATTR_OOB_FIX}" != "1" ] || log_info "AOSP ext4 xattr OOB fix: ${EXT4_XATTR_OOB_FIX_COMMIT} (${EXT4_XATTR_OOB_FIX_AOSP_REF})"
[ "${ENABLE_IPV6_MLD_UAF_FIX}" != "1" ] || log_info "AOSP IPv6 MLD UAF fix: ${IPV6_MLD_UAF_FIX_COMMIT} (${IPV6_MLD_UAF_FIX_AOSP_REF})"
[ "${ENABLE_RTMUTEX_WAITER_ENQUEUE_FIX}" != "1" ] || log_info "AOSP rtmutex waiter enqueue fix: ${RTMUTEX_WAITER_ENQUEUE_FIX_COMMIT} (${RTMUTEX_WAITER_ENQUEUE_FIX_AOSP_REF})"
[ "${ENABLE_STAGE5_RTMUTEX_FIX}" != "1" ] || log_info "AOSP rtmutex fix: ${STAGE5_RTMUTEX_FIX_COMMIT} (${STAGE5_AOSP_SECURITY_REF})"
[ "${ENABLE_UNICODE_IGNORABLE_FIX}" != "1" ] || log_info "AOSP Unicode fix: ${UNICODE_FIX_COMMIT} (upstream ${UNICODE_FIX_UPSTREAM_COMMIT})"
[ "${ENABLE_IPSET}" != "1" ] || log_info "IPSet userspace: ${IPSET_DIR} + libmnl ${LIBMNL_DIR} (NDK ${ANDROID_NDK_VERSION})"
log_info "toolchain: ${CI_TOOLCHAIN_DIR}"
log_info "MagiskBoot: v${MAGISK_VERSION} (${MAGISK_COMMIT})"
