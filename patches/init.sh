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

parse_init_args() {
    [ "$#" = 0 ] || die "用法: ./patches/init.sh"
}

validate_init_fetch_jobs() {
    INIT_FETCH_JOBS="${INIT_FETCH_JOBS-1}"
    case "${INIT_FETCH_JOBS}" in
        1|2) ;;
        *) die "INIT_FETCH_JOBS 只允许 1 或 2" ;;
    esac
    export INIT_FETCH_JOBS
    readonly INIT_FETCH_JOBS
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

stop_toolchain_fetches() {
    local pid
    trap '' INT TERM
    # Include a job interrupted between its launch and PID registration.
    for pid in $(jobs -pr); do fetch_pids+=("${pid}"); done
    for pid in "${fetch_pids[@]}"; do
        kill -TERM -- "-${pid}" 2>/dev/null || true
    done
    if [ "${#fetch_pids[@]}" -gt 0 ]; then
        sleep 0.2
        for pid in "${fetch_pids[@]}"; do
            kill -KILL -- "-${pid}" 2>/dev/null || true
            wait "${pid}" 2>/dev/null || true
        done
    fi
}

run_init_tasks() {
    local task index next=0 monitor_enabled=0
    local -a fetch_pids=() tasks=("$@")

    case "$-" in *m*) monitor_enabled=1 ;; esac
    # Separate process groups let cancellation stop Git and all its helpers.
    set -m
    trap stop_toolchain_fetches EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    while [ "${next}" -lt "${#tasks[@]}" ] || [ "${#fetch_pids[@]}" -gt 0 ]; do
        for index in "${!fetch_pids[@]}"; do
            # Plain wait retains completed statuses on Bash 5.2. Reap every
            # completed worker before filling slots, including failed workers.
            if ! kill -0 "${fetch_pids[$index]}" 2>/dev/null; then
                wait "${fetch_pids[$index]}" || die "固定依赖准备失败，停止安装"
                unset 'fetch_pids[index]'
            fi
        done
        fetch_pids=("${fetch_pids[@]}")
        while [ "${#fetch_pids[@]}" -lt "${INIT_FETCH_JOBS}" ] && \
                [ "${next}" -lt "${#tasks[@]}" ]; do
            task="${tasks[$next]}"
            (trap - EXIT INT TERM; "${task}") &
            fetch_pids+=("$!")
            next=$((next + 1))
        done
        [ "${#fetch_pids[@]}" -eq 0 ] || sleep 0.05
    done
    trap - EXIT INT TERM
    [ "${monitor_enabled}" = 1 ] || set +m
}

prepare_toolchain_assets() {
    local file expected actual blob
    mkdir -p "${DL_DIR}"
    for file in "$@"; do
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
}

prepare_stock_tools() {
    local file stock_tools_dir
    prepare_toolchain_assets stock-fsck.erofs stock-depmod stock-libc++.so
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
}

verify_installed_toolchain() {
    [ -e "${CI_TOOLCHAIN_DIR}" ] || return 1
    [ -d "${CI_TOOLCHAIN_DIR}" ] && [ ! -L "${CI_TOOLCHAIN_DIR}" ] || die "固定工具链安装路径异常"
    local actual
    actual="$(tree_sha256 "${CI_TOOLCHAIN_DIR}")" || die "无法校验固定工具链安装树"
    [ "${actual}" = "${CI_TOOLCHAIN_TREE_SHA256}" ] || die "固定工具链安装树摘要不匹配，拒绝覆盖: ${actual}"
    verify_toolchain_identity
    log_success "固定工具链安装树完整性校验通过"
}

validate_dependency_pins() {
    local key
    local pins=(BACKPORT_BUNDLE_MANIFEST_SHA256 BACKPORT_BUNDLE_SHA256 BACKPORT_BUNDLE_URL
        CI_TOOLCHAIN_BUNDLE_SHA256 CI_TOOLCHAIN_BUNDLE_URL)
    for key in "${pins[@]}"; do
        [[ -n "${!key:-}" ]] || die "固定依赖 pin 不完整: ${key}"
    done
    for key in BACKPORT_BUNDLE_MANIFEST_SHA256 BACKPORT_BUNDLE_SHA256 \
        CI_TOOLCHAIN_BUNDLE_SHA256 CI_TOOLCHAIN_TREE_SHA256; do
        [[ "${!key:-}" =~ ^[0-9a-f]{64}$ ]] || die "固定依赖摘要无效: ${key}"
    done
    for key in BACKPORT_BUNDLE_URL CI_TOOLCHAIN_BUNDLE_URL; do
        [[ "${!key}" =~ ^https://[^/[:space:]]+(/[^[:space:]]*)?$ ]] || \
            die "固定依赖下载地址必须使用 HTTPS: ${key}"
    done
}

setup_toolchain() {
    local prepared
    mkdir -p "${DL_DIR}" "$(dirname "${CI_TOOLCHAIN_DIR}")"
    prepare_stock_tools
    if verify_installed_toolchain; then return; fi
    prepared="$(python3 "${HOST_WORKSPACE_DIR}/tools/ci_dependencies.py" prepare-toolchain \
        --workspace "${HOST_WORKSPACE_DIR}")" || die "固定工具链包准备失败"
    [ "${prepared}" = "${CI_TOOLCHAIN_DIR}" ] || die "固定工具链包安装目录不匹配: ${prepared}"
    verify_installed_toolchain || die "固定工具链包安装树不匹配"
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
            --header 'Accept: application/octet-stream' \
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

    candidate="${archive}"
    if [ ! -f "${archive}" ]; then
        candidate="${archive}.part"
        log_step "下载 Android NDK ${ANDROID_NDK_VERSION}"
        curl -fSL --retry 3 -C - -o "${candidate}" "${ANDROID_NDK_URL}"
    fi
    actual_sha1="$(sha1sum "${candidate}" | awk '{ print $1 }')"
    [ "${actual_sha1}" = "${ANDROID_NDK_SHA1}" ] || die "Android NDK SHA-1 不匹配: ${actual_sha1}"
    actual_sha256="$(sha256sum "${candidate}" | awk '{ print $1 }')"
    [ "${actual_sha256}" = "${ANDROID_NDK_SHA256}" ] || die "Android NDK SHA-256 不匹配: ${actual_sha256}"
    [ "${candidate}" = "${archive}" ] || mv "${candidate}" "${archive}"

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

prepare_userspace_sources() {
    [ "${ENABLE_IPSET}" = "1" ] || return 0
    ensure_repo "额外模块模板" "${EXTRA_MODULES_DIR}" "${EXTRA_MODULES_REPO:?缺少额外模块 URL pin}" \
        "${EXTRA_MODULES_REF:?缺少额外模块 ref pin}" "${EXTRA_MODULES_COMMIT:?缺少额外模块 commit pin}"
    [ "$(tree_sha256 "${EXTRA_MODULES_DIR}/ipset")" = "${IPSET_MODULE_TREE_SHA256:?缺少 IPSet 模板树 pin}" ] || \
        die "IPSet 模板树完整性校验失败"
    prepare_source_archive "ipset ${IPSET_VERSION}" "${IPSET_URL}" \
        "${SOURCE_DOWNLOAD_DIR}/ipset-${IPSET_VERSION}.tar.bz2" sha512sum "${IPSET_SHA512}" \
        "${IPSET_DIR}" "ipset-${IPSET_VERSION}" "${IPSET_TREE_SHA256}"
    prepare_source_archive "libmnl ${LIBMNL_VERSION}" "${LIBMNL_URL}" \
        "${SOURCE_DOWNLOAD_DIR}/libmnl-${LIBMNL_VERSION}.tar.bz2" sha256sum "${LIBMNL_SHA256}" \
        "${LIBMNL_DIR}" "libmnl-${LIBMNL_VERSION}" "${LIBMNL_TREE_SHA256}"
    prepare_android_ndk
}

prepare_build_dependencies() {
    run_init_tasks setup_toolchain prepare_userspace_sources
}

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
HOST_WORKSPACE_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")/.." && pwd -P)"
parse_init_args "$@"
[ -f "${HOST_WORKSPACE_DIR}/.env" ] || die "缺少受版本控制的 .env"
validate_init_fetch_jobs
load_env_file "${HOST_WORKSPACE_DIR}/.env"
validate_dependency_pins
[ "${ENABLE_KERNELSU:-0}" = "1" ] || \
    die "Luna 固定构建只支持 ENABLE_KERNELSU=1；拒绝未审计的第二套产品矩阵"
[ "${ENABLE_SUSFS:-0}" = "1" ] || \
    die "Luna 固定构建只支持 ENABLE_SUSFS=1；拒绝未审计的第二套产品矩阵"

KERNEL_REPO="${KERNEL_REPO:-https://github.com/MiCode/Xiaomi_Kernel_OpenSource.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-popsicle-w-oss}"
KERNEL_COMMIT="${KERNEL_COMMIT:-45705be1220b4cfa8100516ad86711656c0b634e}"
SOC_DIR="$(resolve_workspace_path "${SOC_SOURCE_DIR:-sources/xiaomi_sm8850_soc}")"
COMMON_REPO="${COMMON_REPO:-https://android.googlesource.com/kernel/common}"
COMMON_BRANCH="${COMMON_BRANCH:-android16-6.12-2026-09_r11}"
COMMON_COMMIT="${COMMON_COMMIT:-aa556307b679df7ced0cc644068a529280dbc412}"
COMMON_DIR="$(resolve_workspace_path "${COMMON_SOURCE_DIR:-sources/aosp_common_6.12.92_kmi6_2026-09}")"
COMMON_ABI_STG_SHA256="${COMMON_ABI_STG_SHA256:-7b73ac72ecf2ff1c7d36d01902a7e34c3c5a993d3126058ee4eb0dd53417e581}"
ENABLE_KERNELSU="${ENABLE_KERNELSU:-0}"
KSU_REPO="${KSU_REPO:-https://github.com/tiann/KernelSU.git}"
KSU_REF="${KSU_REF:-main}"
KSU_COMMIT="${KSU_COMMIT:-dbb73665d103da40c7ecbd21ba3b5ac76eb95784}"
KSU_DIR="$(resolve_workspace_path "${KSU_SOURCE_DIR:-sources/kernelsu}")"
KSU_GIT_VERSION_COUNT="${KSU_GIT_VERSION_COUNT:-2727}"
KSU_ENHANCED_SECURITY_REMOVAL_COMMIT="${KSU_ENHANCED_SECURITY_REMOVAL_COMMIT:-1b6e2ed6b38dad1c8af90402a82ed2f752b05cfa}"
MAGISK_VERSION="${MAGISK_VERSION:-31.1}"
MAGISK_COMMIT="${MAGISK_COMMIT:-0972f67d97f9b6302b67c5171283330c74114b4a}"
MAGISK_APK_URL="${MAGISK_APK_URL:-https://api.github.com/repos/topjohnwu/Magisk/releases/assets/673844395}"
MAGISK_APK_SHA256="${MAGISK_APK_SHA256:-89cefac0a318afa39fb3880c45c87b036c05bc1ebf02a7a715b7f8d7c26ac6e7}"
MAGISKBOOT_ARM64_SHA256="${MAGISKBOOT_ARM64_SHA256:-97e9ec75731103d31c9e1effca7a50c6444309ce8f78c2ec27e9fe721da4bb54}"
AK3_UPSTREAM_COMMIT="${AK3_UPSTREAM_COMMIT:-41f04bdb4ee30a44e429c2c1131d5e8bb32b15f1}"
AK3_ARM64_TOOLS_COMMIT="${AK3_ARM64_TOOLS_COMMIT:-cc7d2cee9b1b4298f6ab8666eb4486dea342748c}"
AK3_BUSYBOX_URL="${AK3_BUSYBOX_URL:-https://raw.githubusercontent.com/osm0sis/AnyKernel3/${AK3_ARM64_TOOLS_COMMIT}/busybox}"
AK3_BUSYBOX_SHA256="${AK3_BUSYBOX_SHA256:-c629fce4b0dd3ba9775f851d0941e74582115f423258d3a79800f2bd11d30f5c}"
ENABLE_SUSFS="${ENABLE_SUSFS:-0}"
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_REF="${SUSFS_REF:-gki-android16-6.12}"
SUSFS_COMMIT="${SUSFS_COMMIT:-6b60a305d418148bd311f4fc9bddedc82d99e1fc}"
SUSFS_DIR="$(resolve_workspace_path "${SUSFS_SOURCE_DIR:-sources/susfs4ksu}")"
SUSFS_KSU_PATCH_COMMIT="${SUSFS_KSU_PATCH_COMMIT:-6b60a305d418148bd311f4fc9bddedc82d99e1fc}"
ENABLE_BBG="${ENABLE_BBG:-0}"
BBG_REPO="${BBG_REPO:-https://github.com/vc-teahouse/Baseband-guard.git}"
BBG_REF="${BBG_REF:-main}"
BBG_COMMIT="${BBG_COMMIT:-028ff7fd509e2104596da7cc1ef8e6ce2a0c9082}"
BBG_DIR="$(resolve_workspace_path "${BBG_SOURCE_DIR:-sources/baseband_guard}")"
ENABLE_IPSET="${ENABLE_IPSET:-0}"
IPSET_VERSION="${IPSET_VERSION:-7.24}"
IPSET_URL="${IPSET_URL:-https://ipset.netfilter.org/ipset-7.24.tar.bz2}"
IPSET_SHA512="${IPSET_SHA512:-18ccb49bd38083f0556b11e1d17f43791c52a2b094c9a500b6f770796b17e8e70c3860a628eac2252eb672b1fc9de734d3a0e0823d61dd9be7b4188adc6dd214}"
IPSET_TREE_SHA256="${IPSET_TREE_SHA256:-70530678f3318aad36a3fb8acb3eba17a27ad5e464c0caeb8912dee43f0a81ea}"
IPSET_DIR="$(resolve_workspace_path "${IPSET_SOURCE_DIR:-sources/ipset-7.24}")"
EXTRA_MODULES_DIR="$(resolve_workspace_path "${EXTRA_MODULES_SOURCE_DIR:-sources/extra-modules}")"
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
[[ "${AOSP_CLANG_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "AOSP clang commit 格式错误"
[[ "${MAGISK_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "Magisk commit 格式错误"
[[ "${AK3_UPSTREAM_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "AnyKernel3 脚本 commit 格式错误"
[[ "${AK3_ARM64_TOOLS_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "AnyKernel3 工具 commit 格式错误"
[[ "${MAGISK_APK_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "Magisk APK SHA-256 格式错误"
[[ "${MAGISKBOOT_ARM64_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "arm64 magiskboot SHA-256 格式错误"
[[ "${AK3_BUSYBOX_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "AnyKernel3 BusyBox SHA-256 格式错误"
[ "${AK3_BUSYBOX_URL}" = "https://raw.githubusercontent.com/osm0sis/AnyKernel3/${AK3_ARM64_TOOLS_COMMIT}/busybox" ] || \
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
    [stock-fsck.erofs]="${AOSP_BUILD_TOOLS_REPO}/+/${STOCK_AUDIT_TOOLS_COMMIT}/linux-x86/bin/fsck.erofs?format=TEXT"
    [stock-depmod]="${AOSP_BUILD_TOOLS_REPO}/+/${STOCK_AUDIT_TOOLS_COMMIT}/linux-x86/bin/depmod?format=TEXT"
    [stock-libc++.so]="${AOSP_BUILD_TOOLS_REPO}/+/${STOCK_AUDIT_TOOLS_COMMIT}/linux-x86/lib64/libc++.so?format=TEXT"
)
declare -A TC_SHA256=(
    [stock-fsck.erofs]="${STOCK_FSCK_EROFS_SHA256:?缺少 stock fsck.erofs SHA-256 pin}"
    [stock-depmod]="${STOCK_KMOD_SHA256:?缺少 stock kmod SHA-256 pin}"
    [stock-libc++.so]="${STOCK_LIBCXX_SHA256:?缺少 stock libc++ SHA-256 pin}"
)
declare -A TC_GIT_BLOB=(
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
    [[ "${KSU_MANAGER_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] || die "KernelSU Manager commit pin 无效"
    if ! env GIT_NO_LAZY_FETCH=1 git -C "${KSU_DIR}" cat-file -e "${KSU_MANAGER_COMMIT}^{commit}" 2>/dev/null; then
        git_network -C "${KSU_DIR}" fetch --filter=blob:none --no-tags origin "${KSU_MANAGER_COMMIT}"
    fi
    KSU_MANAGER_APK="$(python3 "${HOST_WORKSPACE_DIR}/tools/ksu_manager.py" prepare \
        --workspace "${HOST_WORKSPACE_DIR}" --ksu-dir "${KSU_DIR}")" || \
        die "官方 KernelSU Manager 准备失败"
    log_success "官方 KernelSU Manager 已准备: ${KSU_MANAGER_APK}"
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
python3 "${HOST_WORKSPACE_DIR}/tools/ci_dependencies.py" prepare-inputs \
    --workspace "${HOST_WORKSPACE_DIR}" || die "固定 AK3 模板或 OTA 镜像准备失败"

BACKPORT_BUNDLE_DIR="$(python3 "${HOST_WORKSPACE_DIR}/tools/ci_dependencies.py" prepare-backports \
    --workspace "${HOST_WORKSPACE_DIR}")" || die "固定回移包准备失败"
[ -d "${BACKPORT_BUNDLE_DIR}" ] || die "固定回移包目录缺失: ${BACKPORT_BUNDLE_DIR}"
log_success "固定回移包已准备并通过验证: ${BACKPORT_BUNDLE_DIR}"

verify_source_baseline
prepare_build_dependencies
prepare_magiskboot
prepare_anykernel_tools

log_success "源码与编译环境初始化完成"
log_info "soc-repo: ${SOC_DIR}"
log_info "GKI common: ${COMMON_DIR}"
[ "${ENABLE_KERNELSU}" != "1" ] || log_info "KernelSU: ${KSU_DIR} (${KSU_REF} @ ${KSU_COMMIT})"
[ "${ENABLE_SUSFS}" != "1" ] || log_info "SUSFS: ${SUSFS_DIR} (${SUSFS_REF} @ ${SUSFS_COMMIT})"
[ "${ENABLE_BBG}" != "1" ] || log_info "Baseband Guard: ${BBG_DIR} (${BBG_REF} @ ${BBG_COMMIT})"
[ "${ENABLE_IPSET}" != "1" ] || log_info "IPSet userspace: ${IPSET_DIR} + libmnl ${LIBMNL_DIR} (NDK ${ANDROID_NDK_VERSION})"
log_info "toolchain: ${CI_TOOLCHAIN_DIR}"
log_info "MagiskBoot: v${MAGISK_VERSION} (${MAGISK_COMMIT})"
log_info "AnyKernel3: scripts ${AK3_UPSTREAM_COMMIT}, arm64 tools ${AK3_ARM64_TOOLS_COMMIT}"
